
CREATE OR REPLACE PROCEDURE datawarehouse.sp_aws_monthly_cost_detail__insert
(
  p_invoice_month INT  -- of the form yyyymm
)

AS 

$$

DECLARE v_row_count INT;
DECLARE v_row_count_char VARCHAR;
DECLARE v_msg VARCHAR;
DECLARE v_record RECORD;
DECLARE v_target_invoice_month INT;
DECLARE v_start_time TIMESTAMP;
DECLARE v_elapsed_time VARCHAR;

BEGIN

-- disable notices (for session)
-- TODO : this needs admin level permission to set
/*
SET client_min_messages = warning;
*/

-- start time
v_start_time = GETDATE();

-- no parm passed, get last actual month        
IF NVL(p_invoice_month, 0) = 0  THEN
  SELECT TO_CHAR(MAX(usage_start_date),'yyyyMM')::int INTO v_target_invoice_month FROM integration.aws_usage_transaction; 
ELSE
  v_target_invoice_month = p_invoice_month; 
END IF;

RAISE INFO 'INFO: Executing procedure for invoice_month %', v_target_invoice_month;

-- create parameter table (easier to debug queries if parameter values are kept in memory)
-- can hold other scalar values here as well
DROP TABLE IF EXISTS    parameters;
CREATE TEMP TABLE       parameters
(
  invoice_month       INT
)
;
-- invoice_month will be updated next (depends on actual/estimated choice)
INSERT INTO parameters VALUES(v_target_invoice_month);
-- peek
/*
select * from parameters;
*/
-- ================================================================================================
-- (0) create list of possible calendar month days (used by RIFee amortization and 
--     Ad-Hoc allocation below)
-- ================================================================================================

-- =NOTE= : we could have done this much simpler by getting the  DISTINCT dayofmonth in 
-- datawarehouse.dim_datetime, but we want to keep AWS tables logic independent of the supplychain
-- data, in case we move it to another schema, DB etc.

-- this will produce numbers from 0, 1 ... 31 (covers every possible calendar day)
-- "0" day needed by RIFee amortization below ...

DROP TABLE IF EXISTS    calendar_days;
CREATE TEMPORARY TABLE  calendar_days
AS
select (b1.x * 1) + (b2.x * 2) + (b3.x * 4) + (b4.x * 8) + (b5.x * 16) as day
from (select 0 as x union select 1) b1,(select 0 as x union select 1) b2,
     (select 0 as x union select 1) b3,(select 0 as x union select 1) b4,
     (select 0 as x union select 1) b5
;
-- peek
/*
select * from calendar_days order by 1;
*/

-- ================================================================================================
-- (1) aws usage trx's
-- ================================================================================================

DROP TABLE IF EXISTS    usage_trx;
CREATE TEMPORARY TABLE  usage_trx 
AS
select  
  TO_CHAR(t.usage_start_date,'yyyyMM')::int as invoice_month
  , t.linked_account_id as account_id
  , t.usage_start_date       as usage_date_hour
  , t.usage_start_date::date as usage_date
  --  get tags from aws_resource_tag (overrides aws_resource_user tags)
  , case   
      when rt.user_company is not null then rt.user_company
      when TRIM(NVL(ru.user_company,'')) = '' then UPPER(ac.default_cost_center)
      else UPPER(ru.user_company) 
    end as user_company
  , NVL(ru.user_name, '') as user_name -- Company created instance name
  , t.product_name
  , case when lower(t.lineitem_type) = 'discountedusage' then 'Usage' else t.lineitem_type end as lineitem_type
  , t.usage_type
  , t.pricing_unit      
  , CAST(
      NVL(
        case 
          when t.product_name like 'AWS Support%' then t.unblended_cost -- work around for AWS overprice
          when t.lineitem_type = 'RIFee' then t.public_ondemand_cost  -- =NOTE= RIFee never has a retail cost, only actual cost so this is 0
          when t.lineitem_type = 'SavingsPlanRecurringFee' then t.public_ondemand_cost
          when t.lineitem_type = 'Credit' then t.unblended_cost
          when NVL(t.public_ondemand_cost, 0) = 0 then t.unblended_cost
          else
            case 
              when lower(t.lineitem_type) = 'discountedusage' and NVL(ri.ri_normalizationfactor, 0) <> 0 
                then (NVL(t.normalizationfactor, 0)/NVL(ri.ri_normalizationfactor, 0)) * NVL(t.public_ondemand_cost, 0)
              else NVL(t.public_ondemand_cost, 0)
            end
        end, 0) AS DECIMAL(38,8)) as retail_cost
  , NVL(t.usage_quantity, 0) as quantity
  , CAST('' AS VARCHAR(100)) as note
  -- used for matching Spot Instances to ondemand rate
  , SPLIT_PART(usage_type, ':', 2) as instance_size
from integration.aws_usage_transaction t
join integration.aws_account_config ac on (t.linked_account_id = ac.account_id)
left join integration.aws_rifee ri on (t.reservationarn = ri.ri_reservationarn and ri.invoice_id = t.invoice_id)
left join integration.aws_resource_user ru on (t.resource_id = ru.resource_id and t.usage_start_date >= ru.resource_start_dt and t.usage_start_date <= ru.resource_end_dt)
left join integration.aws_resource_tag rt on (rt.resource_id = t.resource_id)
where 
  TO_CHAR(t.usage_start_date,'yyyyMM')::int = (select invoice_month from parameters)
  -- Exclude :
  --   (a) SavingsPlanNegation (new line item from AWS to indicate SP savings, not necessary for roll-up)
  --   (b) Fee (Upfront RI Fee, these will be amortized using a dedicated table aws_reserved_instance, holding the RI details)
  --   (c) SavingsPlanUpfrontFee(Upfront Savings Plan Fee, these will be amortized using a dedicated table aws_reserved_instance, holding the SP details)
  --   (d) Refund (for RDS, EC2, SavingsPlan Upfront Fees that were cancelled) ==>  The AWS docs not 100% clear on this, but Refunds are apparently for upfront payments, not Usage (which gets a Credit)
  AND t.lineitem_type NOT IN ('SavingsPlanNegation', 'Fee', 'SavingsPlanUpfrontFee', 'Refund')
;


-- ================================================================================================
-- (1.a) retrieve Spot Instance ondemand_cost
-- ================================================================================================

-- get ondemand rate from config table and update retail_cost
UPDATE usage_trx
SET retail_cost = p.pricing_public_on_demand_rate * usage_trx.quantity
FROM integration.aws_price_list p
WHERE
  usage_trx.usage_type LIKE '%SpotUsage%' 
  AND usage_trx.lineitem_type = 'Usage'
  AND (usage_trx.instance_size = p.product_instance_type)
;
-- peek
/*
select 
  usage_type
  , instance_size
  , sum(quantity) as quantity
  , sum(retail_cost) as retail_cost 
from usage_trx 
where usage_type LIKE '%SpotUsage%' and lineitem_type = 'Usage'
group by 1,2
order by 1,2
;
*/

-- drop columns
ALTER TABLE usage_trx DROP COLUMN instance_size;


-- ================================================================================================
-- (1.b) drop any zero costs
-- ================================================================================================

-- drop any zero costs
DELETE FROM usage_trx WHERE ROUND(retail_cost, 8) = 0;

-- peek
/*
select * from parameters;

select * from usage_trx limit 100;
select * from usage_trx where retail_cost = 0 limit 100;

select
  account_id
  , sum(retail_cost) as retail_cost
  , count(*) as n
from usage_trx
group by 1
order by 1
;
*/


-- ================================================================================================
-- (2) ad hoc allocation (from aws_adhoc_billing_* config tables)
-- ================================================================================================

-- *** only perform ad hoc allocation if we have companies defined for the target month ***
 
IF EXISTS
(
      select * 
      from integration.aws_adhoc_billing 
      where invoice_month = (select invoice_month from parameters) 
) THEN

    FOR v_record IN
        SELECT account_id, LISTAGG(DISTINCT user_company, ',') WITHIN GROUP (ORDER BY user_company) as user_company
        FROM integration.aws_adhoc_billing
        WHERE invoice_month = (select invoice_month from parameters) 
        GROUP BY account_id
    LOOP
        RAISE INFO 'INFO: Ad Hoc billing allocation will be applied for account %, companies (%) ...', v_record.account_id, v_record.user_company;
    END LOOP;

    -- add datepart columns for off hour billing calculations. 
    -- =NOTE= : we use BKK tz as our frame of reference (e.g. off hours/night time costs allocation)
    ALTER TABLE usage_trx ADD usage_date_bkk DATE;

    ALTER TABLE usage_trx ADD hour_bkk INT;
    ALTER TABLE usage_trx ADD day_bkk CHAR(3);

    UPDATE usage_trx
    SET 
      usage_date_bkk = DATEADD(hour, 7, usage_date_hour)::DATE
      , hour_bkk = DATE_PART(hour, DATEADD(hour, 7, usage_date_hour))
      , day_bkk = 
          CASE DATE_PART(dow, DATEADD(hour, 7, usage_date_hour)) 
            WHEN 0 THEN 'SUN'
            WHEN 1 THEN 'MON'
            WHEN 2 THEN 'TUE'
            WHEN 3 THEN 'WED'
            WHEN 4 THEN 'THU'
            WHEN 5 THEN 'FRI'
            WHEN 6 THEN 'SAT'
          END 
    ;

    -- enumerate dates in invoice month
    DROP TABLE IF EXISTS    calendar_dates;
    CREATE TEMPORARY TABLE  calendar_dates
    AS
    WITH dates AS
    (
        SELECT
          ((LEFT(CAST(i.invoice_month AS CHAR(6)), 4) || '-' || RIGHT(CAST(i.invoice_month AS CHAR(6)), 2) || '-01'))::DATE AS first_day
          , DATE_PART(day, DATEADD(day, -1, DATEADD(month, 1, first_day))) as num_of_days
        FROM (select invoice_month from parameters) i
    )
    SELECT 
      DATEADD(day, c.day, d.first_day)::DATE AS calendar_date
      , CASE DATE_PART(dow, calendar_date) 
          WHEN 0 THEN 'SUN'
          WHEN 1 THEN 'MON'
          WHEN 2 THEN 'TUE'
          WHEN 3 THEN 'WED'
          WHEN 4 THEN 'THU'
          WHEN 5 THEN 'FRI'
          WHEN 6 THEN 'SAT'
        END AS day_of_week
    FROM dates d, calendar_days c
    WHERE c.day < d.num_of_days
    ;
    -- peek
    /*
    select * from calendar_dates order by 1;
    */

    -- create allocation weights for each instance x date  x hour x company - simple weights where 
    -- weight = 1 / (# of companies)
    DROP TABLE IF EXISTS    adhoc_alloc;
    CREATE TEMPORARY TABLE  adhoc_alloc
    AS
    WITH adhoc AS
    (
        select
          b.adhoc_billing_id
          , b.invoice_month
          , b.account_id
          , b.user_company
          , i.instance_name
          , d.calendar_date
          , s.weekday
          , s.hour  
        from integration.aws_adhoc_billing b
        join integration.aws_adhoc_billing_instance i on (i.instance_group_id = b.instance_group_id)
        join integration.aws_adhoc_billing_schedule_hours s on (s.schedule_id = b.schedule_id)
        join calendar_dates d on (d.calendar_date BETWEEN b.start_date AND b.end_date and d.day_of_week = s.weekday)
        where b.invoice_month = (select invoice_month from parameters) 
    ),
    weights AS
    (
        select
          account_id
          , instance_name
          , calendar_date
          , hour  
          , COUNT(*) AS n -- number of companys with allocation on this date/hour, on this instance
          --, LISTAGG(DISTINCT user_company, ',') WITHIN GROUP (ORDER BY user_company) as user_companies /*debug*/
        from adhoc
        group by 1,2,3,4
    )
    SELECT
      a.account_id
      , a.instance_name
      , a.calendar_date
      , a.weekday
      , a.hour  
      , a.user_company
      , 1.00/ w.n AS weight
    FROM adhoc a
    JOIN weights w ON (a.account_id = a.account_id AND a.instance_name = w.instance_name AND a.calendar_date = w.calendar_date AND a.hour  = w.hour)
    ;

    -- peek
    /*
    select * from adhoc_alloc limit 100;
    */
    
    -- flag trx records that match the adhoc allocation schedule (exclude *Fee)
    -- used to sanity check our re-weighted records and delete the originals (next)    
    UPDATE usage_trx 
    SET note = 'AD-HOC-ORIGINAL'
    FROM (select DISTINCT account_id, instance_name, calendar_date, hour from adhoc_alloc) aa
    WHERE 
          aa.account_id =       usage_trx.account_id 
      AND aa.instance_name =    usage_trx.user_name
      AND aa.calendar_date =    usage_trx.usage_date_bkk
      AND aa.hour =             usage_trx.hour_bkk
      AND usage_trx.lineitem_type NOT IN ('RIFee', 'SavingsPlanRecurringFee')
    ;  

    -- peek
    /*
    select account_id, user_name, usage_date_bkk, day_bkk, hour_bkk, count(*) as n, sum(retail_cost) as retail_cost
    from usage_trx 
    where note = 'AD-HOC-ORIGINAL'
    group by 1,2,3,4,5
    order by 1,2,3,4,5
    */

    -- calculate ad-hoc costs by company, insert into usage
    INSERT INTO usage_trx
    SELECT
        u.invoice_month
        , u.account_id
        , u.usage_date_hour
        , u.usage_date
        , a.user_company
        , u.user_name
        , u.product_name
        , u.lineitem_type
        , u.usage_type
        , u.pricing_unit
        , u.retail_cost * a.weight AS retail_cost
        , u.quantity    * a.weight AS quantity
        , 'AD-HOC-ALLOC' AS note
        , a.calendar_date AS usage_date_bkk
        , a.hour AS hour_bkk
        , a.weekday AS day_bkk
    FROM usage_trx u
    JOIN adhoc_alloc a ON
    (
          a.account_id =       u.account_id 
      AND a.instance_name =    u.user_name
      AND a.calendar_date =    u.usage_date_bkk
      AND a.hour =             u.hour_bkk
    )
    WHERE u.lineitem_type NOT IN ('RIFee', 'SavingsPlanRecurringFee')
    ;  

    -- peek
    /*
    -- should all be zero
    WITH test AS
    (
        select note, account_id, user_name, usage_date_bkk, day_bkk, hour_bkk, sum(retail_cost) as retail_cost, sum(quantity) as quantity
        from usage_trx 
        where note = 'AD-HOC-ORIGINAL'
        group by 1,2,3,4,5,6
        UNION ALL
        select note, account_id, user_name, usage_date_bkk, day_bkk, hour_bkk, -sum(retail_cost) as retail_cost, -sum(quantity) as quantity
        from usage_trx 
        where note = 'AD-HOC-ALLOC'
        group by 1,2,3,4,5,6
    )
    select 
      account_id, user_name, usage_date_bkk, day_bkk, hour_bkk, ROUND(sum(retail_cost), 4) as retail_cost, ROUND(sum(quantity),4) as quantity
    from test
    group by 1,2,3,4,5
    order by 1,2,3,4,5
    */

    -- delete original records
    DELETE usage_trx WHERE note = 'AD-HOC-ORIGINAL';

    -- drop work columns
    ALTER TABLE usage_trx DROP COLUMN usage_date_bkk;
    ALTER TABLE usage_trx DROP COLUMN hour_bkk;
    ALTER TABLE usage_trx DROP COLUMN day_bkk;

    -- update note to something more report friendnly
    UPDATE usage_trx
    SET note = 'Off Hour Server Costs'
    WHERE note = 'AD-HOC-ALLOC'
    ; 
   
END IF;

-- peek
/*
select * from usage_trx limit 100;
select * from usage_trx where note != '' limit 100;
*/

-- ================================================================================================
-- (3) aggregate to correct grain
-- ================================================================================================

DROP TABLE IF EXISTS usage_final;
CREATE TEMP TABLE    usage_final
AS
SELECT
  t.invoice_month
  , t.account_id
  , a.account_display_name AS account_name
  , t.user_company
  , t.product_name
  , CASE WHEN t.lineitem_type LIKE '%Usage' THEN 'Usage' ELSE t.lineitem_type END AS lineitem_type
  , t.usage_type
  , t.pricing_unit
  , SUM(t.retail_cost) AS retail_cost
  , SUM(t.quantity)    AS quantity
  , t.note
FROM usage_trx t
JOIN integration.aws_account_config a ON (a.account_id = t.account_id) 
GROUP BY 1,2,3,4,5,6,7,8,11
;
-- peek
/*
select * from usage_final limit 100;
select * from usage_final where note != '' limit 100;
select * from usage_final where user_company = 'CLIENT A' order by 1,2,4,5,6,7;
select * from usage_final where user_company = 'CLIENT B' order by 1,2,4,5,6,7;
select * from usage_final where retail_cost = 0;

select
  account_id
  , sum(retail_cost) as retail_cost
  , count(*) as n
from usage_final
group by 1
order by 1
;
*/

-- ================================================================================================
-- (4) redistribute INFRA costs to both AWS & AZURE clients
-- ================================================================================================

DROP TABLE IF EXISTS    infra_weights;
CREATE TEMPORARY TABLE  infra_weights
AS
WITH all_cloud_costs AS
(
    select
      user_company
      , retail_cost 
    from usage_final
    where account_name = 'Hosting' and user_company != 'COMPANY INFRASTRUCTURE'
    UNION ALL
    select 
      tag_company as user_company
      , retail_cost 
    from integration.azure_cost_summary
    where billing_period = (select invoice_month from parameters)           
)
select
  user_company
  , SUM(retail_cost) as retail_cost 
  , CAST(SUM(retail_cost) AS DECIMAL(19,8)) / (select SUM(retail_cost) from all_cloud_costs) as weight
from all_cloud_costs
group by 1
;

-- peek
/*
select * from infra_weights order by 1;
select SUM(weight) from infra_weights;
*/

INSERT INTO usage_final
select
  u.invoice_month
  , u.account_id
  , u.account_name
  , i.user_company
  , u.product_name
  , u.lineitem_type
  , u.usage_type
  , u.pricing_unit
  , u.retail_cost * i.weight AS retail_cost
  , u.quantity    * i.weight AS quantity
  , 'INFRA COSTS' as note
from usage_final u, infra_weights i
where u.account_name = 'Hosting' and u.user_company = 'COMPANY INFRASTRUCTURE'
;

DELETE FROM usage_final WHERE ROUND(retail_cost, 8) = 0;

-- peek
/*
select * 
from usage_final 
where 
  account_name = 'Hosting' 
  and user_company != 'COMPANY INFRASTRUCTURE'
order by 1,2,3,4,5,6,7,8;

-- check
select
  'ORIGINAL' as src
  , sum(retail_cost) as retail_cost
  , sum(quantity) as quantity 
from usage_final 
where account_name = 'Hosting' and user_company = 'COMPANY INFRASTRUCTURE'
UNION ALL
select 
  'ALLOCATED' as src
  , sum(retail_cost)
  , sum(quantity) 
from usage_final 
where account_name = 'Hosting' and note = 'INFRA COSTS'

*/

-- delete original INFRA cost
DELETE FROM usage_final
WHERE 
  account_name = 'Hosting' 
  AND user_company = 'COMPANY INFRASTRUCTURE'
;

-- update note to something more report friendnly
UPDATE usage_final
SET note = 'Hosted Monitoring Systems'
WHERE note = 'INFRA COSTS'
;

-- peek
/*

select * 
from usage_final 
where account_name = 'Hosting' 
order by 1,2,3,4,5,6,7,8;

select
  account_id
  , sum(retail_cost) as retail_cost
  , count(*) as n
from usage_trx
group by 1
order by 1
;

*/


-- ================================================================================================
-- (999) INSERT into aws_monthly_cost_detail
-- ================================================================================================

-- delete existing data
DELETE FROM datawarehouse.aws_monthly_cost_detail WHERE invoice_month = (select invoice_month from parameters);

-- insert new data
INSERT INTO datawarehouse.aws_monthly_cost_detail
SELECT
  t.invoice_month
  , t.account_id
  , t.account_name
  , t.user_company
  , t.product_name
  , t.lineitem_type
  , t.usage_type
  , t.pricing_unit
  , ROUND(retail_cost, 4) AS retail_cost 
  , ROUND(quantity,    8) AS quantity 
  , NVL(t.note, '') AS NOTE
  , GETDATE() AS t_created_date
FROM usage_final t
WHERE ROUND(t.retail_cost, 4) != 0
;

-- =NOTE= this is not the precise way to get the number of rows INSERTed. RedShift does expose some
-- STV/STL system tables that will retrieve the row count but it's a bit complicated to do (unlike MS SQL Server
-- which exposes a @@ROWCOUNT variable or pgsql which allows you to wrap a CTE around the INSERT/UPDATE/DELETE
-- and select count(*) from the CTE result)

SELECT COUNT(*) INTO v_row_count FROM usage_final;
SELECT TRIM(TO_CHAR(v_row_count, '999,999,999')) INTO v_row_count_char;

if v_row_count > 0 then
	RAISE INFO 'INFO: % records inserted into datawarehouse.aws_monthly_cost_detail', v_row_count_char;
else
	RAISE INFO 'INFO: No records inserted into datawarehouse.aws_monthly_cost_detail!';
end if;

-- elapsed time
v_elapsed_time = TO_CHAR(DATEADD(ms, DATEDIFF(ms, v_start_time, GETDATE()), '1900-01-01'::datetime), 'HH24:mi:ss');
RAISE INFO 'INFO: Exec Time = %', v_elapsed_time;


-- ================================================================================================
-- (!) clean-up 
-- ================================================================================================
/*
  pgsql retains temp tables even between proc calls (most SQL instances drop these after execution)
  drop these tables explicitly for good housekeeping
*/

DROP TABLE IF EXISTS parameters;
DROP TABLE IF EXISTS calendar_days;
DROP TABLE IF EXISTS calendar_dates;
DROP TABLE IF EXISTS usage_trx;
DROP TABLE IF EXISTS usage_final;
DROP TABLE IF EXISTS adhoc_alloc;

END;

$$ LANGUAGE plpgsql

SECURITY INVOKER
;

-- permissions

GRANT EXECUTE ON PROCEDURE datawarehouse.sp_aws_monthly_cost_detail__insert(INT) TO GROUP engineering;

-- test
/*
CALL datawarehouse.sp_aws_monthly_cost_detail__insert(202001);
*/

