
CREATE OR REPLACE PROCEDURE datawarehouse.sp_aws_monthly_cost_summary__insert
(
  p_trx_source      VARCHAR(10) -- values : ESTIMATED / ACTUAL
  , p_invoice_month INT  -- of the form yyyymm
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

-- start time
v_start_time = GETDATE();

-- check parms
IF p_trx_source NOT IN ('ACTUAL', 'ESTIMATED') THEN
  RAISE INFO 'INFO:ERROR : Invalid parameter value for p_trx_source ''%'', must be in (ACTUAL,ESTIMATED)', p_trx_source;
  RETURN;
END IF;

-- create parameter table (easier to debug queries if parameter values are kept in memory)
-- can hold other scalar values here as well
DROP TABLE IF EXISTS    parameters;
CREATE TEMP TABLE       parameters
(
  trx_source            VARCHAR(10)
  , invoice_month       INT
  , last_trx_datetime   TIMESTAMP
)
;
-- invoice_month will be updated next (depends on actual/estimated choice)
INSERT INTO parameters VALUES(p_trx_source, NULL, NULL);

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
-- (1) get trx level data
-- ================================================================================================

IF p_trx_source = 'ACTUAL' THEN

    -- no parm passed, get last actual month        
    IF NVL(p_invoice_month, 0) = 0  THEN
      SELECT TO_CHAR(MAX(usage_start_date),'yyyyMM')::int INTO v_target_invoice_month FROM integration.aws_usage_transaction; 
    ELSE
      v_target_invoice_month = p_invoice_month; 
    END IF;

    UPDATE parameters SET invoice_month = v_target_invoice_month;

    DROP TABLE IF EXISTS    usage_trx;
    CREATE TEMPORARY TABLE  usage_trx 
    AS
    select  
        TO_CHAR(t.usage_start_date,'yyyyMM')::int as invoice_month
        , t.invoice_id
        , t.linked_account_id as account_id
        , t.usage_start_date       as usage_date_hour
        , t.usage_start_date::date as usage_date
        -- **************************************************************************
        -- *** get tags from aws_resource_tag (overrides aws_resource_user tags)  ***
        -- **************************************************************************
        , ru.user_name -- Company created instance name
        , case   
            when rt.user_company is not null then rt.user_company
            when TRIM(NVL(ru.user_company,'')) = '' then UPPER(ac.default_cost_center)
            else UPPER(ru.user_company) 
          end as user_company
        , case   
            when t.item_description LIKE 'AWS Marketplace%' THEN 'AWS MARKETPLACE'  -- TODO : this is a hack until DevOps tags these machine(s)
            when rt.user_product is not null then rt.user_product
            else UPPER(TRIM(NVL(ru.user_product, '')))
          end as user_product
        -- **************************************************************************
        , t.lineitem_type
        , NVL(t.unblended_cost, 0) as unblended_cost
        , NVL(
          case 
            when t.product_name like 'AWS Support%' then t.unblended_cost -- work around for AWS overprice
            else t.public_ondemand_cost 
          end, 0) as ondemand_cost -- ** always 0 for RIFee ***
        , NVL(ri.ri_normalizationfactor, 0) as ri_normalizationfactor
        , NVL(t.normalizationfactor, 0) as normalizationfactor
        , NVL(t.usage_quantity, 0) as quantity
        , CAST('ACTUAL' AS VARCHAR(12)) as trx_source
        , CAST(NULL AS VARCHAR(30)) as note
        -- used for matching Spot Instances to ondemand rate
        , t.usage_type
        , SPLIT_PART(usage_type, ':', 2) as instance_size
        , CAST(0.00 AS NUMERIC(8,4)) as ondemand_rate 
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

    UPDATE parameters SET last_trx_datetime = (SELECT MAX(usage_date_hour) FROM usage_trx);

END IF;

IF p_trx_source = 'ESTIMATED' THEN

    DROP TABLE IF EXISTS    usage_trx;
    CREATE TEMPORARY TABLE  usage_trx 
    AS
    select  
        TO_CHAR(t.usage_start_date,'yyyyMM')::int as invoice_month
        , t.invoice_id
        , t.linked_account_id as account_id
        , t.usage_start_date       as usage_date_hour
        , t.usage_start_date::date as usage_date
        -- **************************************************************************
        -- *** get tags from aws_resource_tag (overrides aws_resource_user tags)  ***
        -- **************************************************************************
        , ru.user_name -- Company created instance name
        , case   
            when rt.user_company is not null then rt.user_company
            when TRIM(NVL(ru.user_company,'')) = '' then UPPER(ac.default_cost_center)
            else UPPER(ru.user_company) 
          end as user_company
        , case   
            when t.item_description LIKE 'AWS Marketplace%' THEN 'AWS MARKETPLACE' 
            when rt.user_product is not null then rt.user_product
            else UPPER(TRIM(NVL(ru.user_product, '')))
          end as user_product
        -- **************************************************************************
        , t.lineitem_type
        , NVL(t.unblended_cost, 0) as unblended_cost
        , NVL(
          case 
            when t.product_name like 'AWS Support%' then t.unblended_cost -- work around for AWS overprice
            else t.public_ondemand_cost 
          end, 0) as ondemand_cost
        , NVL(ri.ri_normalizationfactor, 0) as ri_normalizationfactor
        , NVL(t.normalizationfactor, 0) as normalizationfactor
        , NVL(t.usage_quantity, 0) as quantity
        , CAST('ESTIMATED' AS VARCHAR(12)) as trx_source
        , CAST(NULL AS VARCHAR(30)) as note
        -- used for matching Spot Instances to ondemand rate
        , t.usage_type
        , SPLIT_PART(usage_type, ':', 2) as instance_size
        , CAST(0.00 AS NUMERIC(8,4)) as ondemand_rate 
    from integration.aws_usage_transaction_estimated t
    join integration.aws_account_config ac on (t.linked_account_id = ac.account_id)
    left join integration.aws_rifee_estimated ri on (t.reservationarn = ri.ri_reservationarn)
    left join integration.aws_resource_user_estimated ru on (t.resource_id = ru.resource_id and t.usage_start_date >= ru.resource_start_dt and t.usage_start_date <= ru.resource_end_dt)
    left join integration.aws_resource_tag rt on (rt.resource_id = t.resource_id)
    where
      -- Exclude :
      --   (a) SavingsPlanNegation (new line item from AWS to indicate SP savings, not necessary for roll-up)
      --   (b) Fee (Upfront RI Fee, these will be amortized using a dedicated table aws_reserved_instance, holding the RI details)
      --   (c) SavingsPlanUpfrontFee(Upfront Savings Plan Fee, these will be amortized using a dedicated table aws_reserved_instance, holding the SP details)
      --   (d) Refund (for RDS, EC2, SavingsPlan Upfront Fees that were cancelled) ==>  The AWS docs not 100% clear on this, but Refunds are apparently for upfront payments, not Usage (which gets a Credit)
      t.lineitem_type NOT IN ('SavingsPlanNegation', 'Fee', 'SavingsPlanUpfrontFee', 'Refund')
    ;

    UPDATE parameters SET invoice_month = (SELECT DISTINCT invoice_month FROM usage_trx);    

    -- AWS  amortizes SavingsPlanRecurringFee over invoice month, so get last real trx date (will be used below to delete trx's)
    UPDATE parameters SET last_trx_datetime = (SELECT MAX(usage_date_hour) FROM usage_trx WHERE lineitem_type != 'SavingsPlanRecurringFee');

    DELETE FROM usage_trx
    WHERE lineitem_type = 'SavingsPlanRecurringFee'
    AND usage_date_hour > (select last_trx_datetime from parameters)
    ;

    SELECT invoice_month INTO v_target_invoice_month FROM parameters;

END IF;

SELECT COUNT(*) INTO v_row_count FROM usage_trx;
SELECT TRIM(TO_CHAR(v_row_count, '999,999,999')) INTO v_row_count_char;

IF v_row_count = 0 THEN
	RAISE INFO 'WARN: No aws billing trx records exist for invoice month % (%), aborting', v_target_invoice_month, p_trx_source;
	DROP TABLE IF EXISTS usage_trx;
    RETURN;
ELSE
    RAISE INFO 'INFO: Executing procedure for invoice_month % (%)', v_target_invoice_month, p_trx_source;
    RAISE INFO 'INFO: % aws billing trx records retrieved', v_row_count_char;
END IF;

-- peek
/*
select * from parameters;
*/

-- ================================================================================================
-- (1.a) retrieve Spot Instance ondemand_cost
-- ================================================================================================

-- check if any instance sizes are not mapped in aws_price_list
FOR v_record IN
  SELECT s.instance_size
  FROM (SELECT DISTINCT instance_size FROM usage_trx WHERE  usage_type LIKE '%SpotUsage%' AND lineitem_type = 'Usage') s
  WHERE  NOT EXISTS(select * from integration.aws_price_list where instance_size = s.instance_size)
LOOP
    RAISE INFO 'INFO: Spot Instance Usage Detected For Unmapped Instance Size (%) In integration.aws_price_list ...', v_record.instance_size;
END LOOP;

-- get ondemand rate from config table
UPDATE usage_trx
SET ondemand_rate = p.pricing_public_on_demand_rate
FROM integration.aws_price_list p
WHERE
  usage_trx.usage_type LIKE '%SpotUsage%' 
  AND usage_trx.lineitem_type = 'Usage'
  AND (usage_trx.instance_size = p.product_instance_type)
;

-- finally calculate ondemand_cost (qty x rate) and update ...
UPDATE usage_trx
SET 
  ondemand_cost = CASE WHEN ondemand_rate != 0.00  THEN ondemand_rate * quantity ELSE unblended_cost END
  --, note = CASE WHEN ondemand_rate != 0.00  THEN 'SPOT RATE USED' ELSE 'SPOT RATE NOT FOUND' END /*debug*/
WHERE
  usage_trx.usage_type LIKE '%SpotUsage%' 
  AND usage_trx.lineitem_type = 'Usage'
;  

-- drop columns
ALTER TABLE usage_trx DROP COLUMN usage_type;
ALTER TABLE usage_trx DROP COLUMN instance_size;
ALTER TABLE usage_trx DROP COLUMN ondemand_rate;

-- peek
/*
select * from usage_trx where item_description LIKE '%Spot%' and lineitem_type = 'Usage' LIMIT 100;
select * from integration.aws_price_list;

select 
  usage_type
  , instance_size
  , ondemand_rate
  , sum(quantity) as quantity
  , sum(unblended_cost) as unblended_cost 
  , sum(ondemand_cost) as ondemand_cost 
  , sum(unblended_cost) / sum(quantity) as unblended_rate_calc
  , sum(ondemand_cost)  / sum(quantity) as ondemand_rate_calc
  , CASE WHEN sum(ondemand_cost) <> 0  THEN (sum(ondemand_cost) -  sum(unblended_cost)) / sum(ondemand_cost) ELSE NULL END as savings_percent
  , count(*) as trx_cnt
  , note  
from usage_trx 
where usage_type LIKE '%SpotUsage%' and lineitem_type = 'Usage'
group by 1,2,3,11
order by 1,2,3
;
*/


-- ================================================================================================
-- (2) amortize monthly RIFee (ESTIMATED month only)
-- ================================================================================================

IF p_trx_source = 'ESTIMATED' THEN

    /*
      the RIFee will be charged on the 1st-of-the-month for a recurring RI (unless it's a mid-month RI purchase
      then it appears to be charged on the date of purchase). we will amortize this fee across the entire month 
      below
    */

    RAISE INFO 'INFO: RIFee will be amortized across month ...';

    DROP TABLE IF EXISTS    amort_rifee; 
    CREATE TEMPORARY TABLE  amort_rifee 
    AS
    select 
      r.*
      , DATEADD(day, d.day, r.usage_date)::date amort_usage_date
      , r.unblended_cost / r.days_in_period as amort_unblended_cost
      , r.quantity / r.days_in_period as amort_quantity
    from
    (
        -- find the total days in RI period, typically the number of days in the month (for recurring RI's)
        -- if the RI was started mid-month, this value will be the remaining days in the month from the RI
        -- purchase date
        select 
          *
          , DATEDIFF(day, usage_date, DATEADD(mm, 1, (TO_CHAR(usage_date, 'yyyy-MM') || '-01')::date)) as days_in_period
        from usage_trx
        where 
          trx_source = 'ESTIMATED'
          and lineitem_type = 'RIFee'
    ) r
    -- Using our calendar_days table, when "less-than-joined" with the days_in_period this gives us the sequence
    -- (0,1,2,..days_in_period - 1), which DATEADD'ed to the usage_date above gives us the sequence of
    -- days (1,2,3,..days_in_period). thus we have our amortized date range for the month
    join calendar_days d on (d.day < r.days_in_period)
    ;
    -- peek
    /*
    select * from amort_rifee order by amort_usage_date;
    select amort_usage_date, sum(amort_unblended_cost) as amort_unblended_cost from amort_rifee group by amort_usage_date order by 1;
    */

    -- delete original un-amortized RIFee line items
    DELETE FROM usage_trx WHERE lineitem_type = 'RIFee';

    -- insert amortized RIFee line items (only up to current usage date)
    INSERT INTO usage_trx
    SELECT
        invoice_month
        , invoice_id
        , account_id
        , amort_usage_date::datetime as usage_date_hour
        , amort_usage_date as usage_date
        , user_name
        , user_company
        , user_product
        , lineitem_type
        , amort_unblended_cost as unblended_cost
        , ondemand_cost
        , ri_normalizationfactor
        , normalizationfactor
        , amort_quantity as quantity
        , trx_source
        , 'AMORTIZED'
    FROM amort_rifee    
    -- only use the current usage date's amortized amount i.e. from 1st, 2nd, ..  (nth usage day) = MAX(usage date)
    WHERE amort_usage_date <= (select last_trx_datetime::DATE from parameters) 
    ;

END IF;


-- ================================================================================================
-- (3) ad hoc allocation (from aws_adhoc_billing_* config tables)
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

    -- check! weights should add up to 1.00 within groups 
    select
      account_id, instance_name, calendar_date, weekday, hour  
      , COUNT(*) AS company_count, SUM(weight) as total_weight, LISTAGG(DISTINCT user_company, ',') WITHIN GROUP (ORDER BY user_company) as user_companies
    from adhoc_alloc
    group by 1,2,3,4,5
    order by 1,2,3,4,5;
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
      AND usage_trx.lineitem_type NOT IN ('RIFee', 'Fee', 'SavingsPlanRecurringFee')
    ;  

    -- peek
    /*
    select account_id, user_name, usage_date_bkk, day_bkk, hour_bkk, count(*) as n, sum(ondemand_cost) as ondemand_cost
    from usage_trx 
    where note = 'AD-HOC-ORIGINAL'
    group by 1,2,3,4,5
    order by 1,2,3,4,5
    */

    -- calculate ad-hoc costs by company, insert into usage
    INSERT INTO usage_trx
    SELECT
        u.invoice_month
        , u.invoice_id
        , u.account_id
        , u.usage_date_hour
        , u.usage_date
        , u.user_name
        , a.user_company
        , u.user_product
        , u.lineitem_type
        , u.unblended_cost * a.weight AS unblended_cost
        , u.ondemand_cost * a.weight AS ondemand_cost
        , u.ri_normalizationfactor
        , u.normalizationfactor
        , u.quantity * a.weight AS quantity
        , u.trx_source
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
    WHERE u.lineitem_type NOT IN ('RIFee', 'Fee', 'SavingsPlanRecurringFee')
    ;  

    -- peek
    /*
    -- should all be zero
    WITH test AS
    (
        select 
          note, account_id, user_name, usage_date_bkk, day_bkk, hour_bkk
          , sum(ondemand_cost) as ondemand_cost, sum(unblended_cost) as unblended_cost, sum(quantity) as quantity
        from usage_trx 
        where note = 'AD-HOC-ORIGINAL'
        group by 1,2,3,4,5,6
        UNION ALL
        select 
          note, account_id, user_name, usage_date_bkk, day_bkk, hour_bkk
          , -sum(ondemand_cost) as ondemand_cost, -sum(unblended_cost) as unblended_cost, -sum(quantity) as quantity
        from usage_trx 
        where note = 'AD-HOC-ALLOC'
        group by 1,2,3,4,5,6
    )
    select 
      account_id, user_name, usage_date_bkk, day_bkk, hour_bkk
      , ROUND(sum(ondemand_cost),4) as ondemand_cost, ROUND(sum(unblended_cost),4) as unblended_cost, ROUND(sum(quantity),4) as quantity
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

END IF;

-- peek
/*
select * from usage_trx limit 100;
*/


-- ================================================================================================
-- (4) aggregate trx over company, product
-- ================================================================================================

DROP TABLE IF EXISTS    usage_agg;
CREATE TEMPORARY TABLE  usage_agg
AS
select  
    invoice_month
    -- currently we don't segment by invoice (can have mult. invoices in trx's), but retain here for debugging later
    --, LISTAGG(DISTINCT invoice_id, ',') WITHIN GROUP (ORDER BY invoice_id) as invoice_id 
    , ISNULL(invoice_id, '') AS invoice_id
    , trx_source
    , account_id
    , user_company
    , user_product
    -- DiscountedUsage (retail cost) is the RIFee offset (actual cost). Since this allocated randomly by AWS we will roll the Usage + DiscountedUsage together
    -- to be used to proportionally allocate the RIFee
    , lineitem_type
    , CAST(sum(CASE WHEN lineitem_type = 'SavingsPlanCoveredUsage' THEN 0 ELSE unblended_cost END) AS DECIMAL(38,8)) as actual_cost 
    , CAST(sum(
        case 
          when lineitem_type = 'RIFee' then ondemand_cost  -- =NOTE= RIFee never has a retail cost, only actual cost
          when lineitem_type = 'SavingsPlanRecurringFee' then ondemand_cost
          when lineitem_type = 'Credit' then unblended_cost -- credit has ondemand_cost = 0, so adjust here
          when ondemand_cost = 0 then unblended_cost
          else
            case 
              when lineitem_type = 'DiscountedUsage' and ri_normalizationfactor <> 0 then (normalizationfactor/ri_normalizationfactor) * ondemand_cost
              else ondemand_cost 
            end
        end) AS DECIMAL(38,8)) as retail_cost
    , CAST('' AS VARCHAR(100)) AS note
from usage_trx
where NOT(unblended_cost = 0 and ondemand_cost = 0)
group by 1,2,3,4,5,6,7
;
-- peek
/*
select * from usage_agg order by 1,2,3,4,5,6,7,8;
select invoice_month, account_id, invoice_id, sum(actual_cost) as actual_cost, sum(retail_cost) as retail_cost
from usage_agg
group by 1,2,3
order by 1,2,3
*/

-- drop trx table, not needed any longer (millions of rows large!)
DROP TABLE IF EXISTS usage_trx;


-- ================================================================================================
-- (5) Allocate Kube costs
-- ================================================================================================

IF EXISTS (
    select * 
    from usage_agg  
    where 
      account_id = '082404710867' -- Regional 
      and user_company = 'COMPANY REGIONAL'
      and user_product IN ('COMPANY.K8S.LOCAL', 'COMPANYDEV.K8S.LOCAL')
) THEN

    IF NOT EXISTS(select * from datawarehouse.kube_monthly_namespace_usage where month_id = (select invoice_month from parameters)) THEN

    	RAISE INFO 'WARN: No kube cluster/namespace records exist for invoice month %, skipping kube cost allocation', v_target_invoice_month;

    ELSE
   
        -- grab kube-product weights and namespace-product mappings to produce  a list of product-weights
        DROP TABLE IF EXISTS    alloc_kube_weights;
        CREATE TEMPORARY TABLE  alloc_kube_weights
        AS
        WITH kube_portion AS
        (
            SELECT
              k.month_id
              , k.cluster_name
              , k.kube_namespace
              -- *** keep cost in K8 product if no mapping found ***
              , NVL(m.company, 'COMPANY REGIONAL') as user_company 
              , NVL(m.company_product, UPPER(k.cluster_name)) as user_product
              -- *******************************************
              , k.usage_portion 
              , CAST( 
                  CASE 
                    WHEN m.company IS NULL THEN 'UNALLOCATED K8 COSTS (MISSING MAPPING)' 
                    ELSE 'REALLOCATED K8 COSTS' 
                  END AS VARCHAR(100) 
                ) AS note -- for debugging
            FROM datawarehouse.kube_monthly_namespace_usage k
            LEFT JOIN datawarehouse.kube_namespace_product_mapping m ON (m.kube_namespace = k.kube_namespace)
            WHERE k.month_id = (select invoice_month from parameters)
        )
        -- Roll up records to product-weight grain (retain the "kube_product" column for debugging)
        -- =NOTE= roll up is necessary as multiple namespaces may be mapped to the same company-product
        SELECT
          month_id
          , UPPER(cluster_name) AS kube_product
          , user_company
          , user_product
          , SUM(usage_portion) AS weight
          , note
        FROM kube_portion
        GROUP BY 1,2,3,4,6
        ;

        -- join weights to kube line items and re-allocate
        DROP TABLE IF EXISTS    alloc_kube;
        CREATE TEMPORARY TABLE  alloc_kube
        AS
        select
          u.invoice_month
          , u.invoice_id
          , u.trx_source
          , u.account_id
          , k.user_company
          , k.user_product
          , u.lineitem_type
          , u.actual_cost * k.weight as actual_cost
          , u.retail_cost * k.weight as retail_cost
          , k.kube_product
          , k.note
        from usage_agg u
        join alloc_kube_weights k on (k.kube_product = u.user_product)
        where 
          u.account_id = '082404710867' -- Regional
          and u.user_company = 'COMPANY REGIONAL'
          and u.user_product IN ('COMPANY.K8S.LOCAL', 'COMPANYDEV.K8S.LOCAL')
        order by 5,6,7
        ;  

        -- delete original kube records
        DELETE FROM usage_agg
        WHERE 
          account_id = '082404710867' -- Regional  
          and user_company = 'COMPANY REGIONAL'
          AND user_product IN ('COMPANY.K8S.LOCAL', 'COMPANYDEV.K8S.LOCAL')
        ;  

        -- insert new allocated kube records
        INSERT INTO usage_agg
        SELECT
          invoice_month
          , invoice_id
          , trx_source
          , account_id
          , user_company
          , user_product
          , lineitem_type
          , actual_cost
          , retail_cost
          , note
        FROM alloc_kube
        ;

    END IF;

 END IF;


-- peek
/*
select * from alloc_kube_weights;
select kube_product, SUM(weight) from alloc_kube_weights group by 1;
select * from alloc_kube;
select * from usage_agg order by 1,2,3,4,5,6,7,8;
*/

-- ================================================================================================
-- (5) re-aggregate again 
-- ================================================================================================

DROP TABLE IF EXISTS    usage_final;
CREATE TEMPORARY TABLE  usage_final
AS
WITH cost_sum AS
(
    SELECT
      u.invoice_month
      , NVL(u.invoice_id, '') AS invoice_id
      , u.trx_source
      , u.account_id
      , a.account_display_name AS account_name
      , u.user_company
      , u.user_product
      , SUM(u.actual_cost) AS actual_cost
      , SUM(u.retail_cost) AS retail_cost
    FROM usage_agg u
    JOIN integration.aws_account_config a ON (a.account_id = u.account_id) 
    GROUP BY 1,2,3,4,5,6,7
    ORDER BY 1,2,3,4,5,6,7
),
-- within account produce total retail cost (used to create  weight), and total actual cost
-- which will be multiplied by the weight to get a weighted actual cost
accounts AS
(
    SELECT 
      invoice_id
      , account_id
      , SUM(retail_cost) as total_retail_cost
      , SUM(actual_cost) as total_actual_cost
    FROM cost_sum
    GROUP BY 1,2
),
cost_sum_weighted AS
(
    SELECT
      c.invoice_month
      , c.invoice_id
      , c.trx_source
      , c.account_id
      , c.account_name
      , c.user_company
      , c.user_product
      , c.actual_cost 
      , ( CAST(c.retail_cost AS DECIMAL(19,8)) / a.total_retail_cost ) * a.total_actual_cost as weighted_actual_cost
      , c.retail_cost as retail_cost 
      , CAST(c.retail_cost AS DECIMAL(19,8)) / a.total_retail_cost as retail_cost_percent
    FROM cost_sum c
    JOIN accounts a on (a.invoice_id = c.invoice_id AND a.account_id = c.account_id) 
)
SELECT
  invoice_month
  , invoice_id
  , trx_source
  , account_id
  , account_name
  , user_company
  , user_product
  , actual_cost
  , CAST(ROUND(weighted_actual_cost,8) AS DECIMAL(38,8)) AS weighted_actual_cost
  , retail_cost
  , CAST(ROUND(retail_cost_percent, 10) AS DECIMAL(11,10)) AS retail_cost_percent
  , CAST('' AS VARCHAR(50)) AS note
FROM cost_sum_weighted
;

-- peek
/*
select * from usage_final order by 1,2,3,4,5,6,7,8;

-- check ==> actual = weighted actual (within accounts) 
-- check ==> retail weights sum to 1.00 (within accounts)
select 
  account_id
  , account_name
  , invoice_id
  , sum(actual_cost) as actual_cost
  , sum(weighted_actual_cost) as weighted_actual_cost
  , sum(retail_cost) as retail_cost
  , sum(retail_cost) - sum(actual_cost) as savings
  , ROUND(sum(actual_cost) - sum(weighted_actual_cost), 6) as actual_diff
  , sum(retail_cost_percent) as total_weight
from usage_final
group by 1,2,3
order by 1,2,3
;
*/


-- ================================================================================================
-- (6) redistribute INFRA costs to both AWS & AZURE clients
-- ================================================================================================
/*
  Re-allocated INFRA cost logic below will produce a record for each company in the 
  Hosting account as well as companies in Azure. These will be rolled up along with existing 
  costs in the next query (but will be carved out in the Jasper client facing report). 

  This means will have Azure (only) clients on the AWS report. Finance and other users will
  need to take this into account when consuming both reports
  
  TODO : combine AWS and Azure reports into one.

*/

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
order by 1
;
-- peek
/*
select * from infra_weights order by 1;
select SUM(weight) from infra_weights;
*/

INSERT INTO usage_final
select
  u.invoice_month
  , u.invoice_id
  , u.trx_source  
  , u.account_id
  , u.account_name
  , i.user_company
  , '' AS user_product
  , u.actual_cost * i.weight AS actual_cost
  , u.weighted_actual_cost * i.weight AS weighted_actual_cost
  , u.retail_cost * i.weight AS retail_cost
  , u.retail_cost_percent * i.weight AS retail_cost_percent
  , 'INFRA COSTS' as note
from usage_final u, infra_weights i
where u.account_name = 'Hosting' and u.user_company = 'COMPANY INFRASTRUCTURE'
;

-- peek
/*
select * 
from usage_final 
where 
  account_name = 'Hosting' 
  and user_product != 'COMPANY INFRASTRUCTURE'
order by 1,2,3,4,5,6,7,8;

-- check
select
  'ORIGINAL' as src
  , actual_cost
  , weighted_actual_cost
  , retail_cost
  , retail_cost_percent
from usage_final 
where account_name = 'Hosting' and user_company = 'COMPANY INFRASTRUCTURE'
UNION
select 
  'ALLOCATED' as src
  , sum(actual_cost)
  , sum(weighted_actual_cost)
  , sum(retail_cost)
  , sum(retail_cost_percent) 
from usage_final 
where account_name = 'Hosting' and note = 'INFRA COSTS'

*/

-- delete original INFRA cost
DELETE FROM usage_final
WHERE 
  account_name = 'Hosting' 
  AND user_company = 'COMPANY INFRASTRUCTURE'
;

-- peek
/*
select * 
from usage_final 
where account_name = 'Hosting' 
order by 1,2,3,4,5,6,7,8;
*/

-- ================================================================================================
-- (7) calculate amortized UpFront RIfee
-- ================================================================================================

ALTER TABLE usage_final ADD COLUMN weighted_upfront_rifee_actual_cost DECIMAL(38,8) DEFAULT 0.00;

-- grab amortized UpFront Rifee (for ESTIMATED we will only grab amortized costs up to current trx dare)
DROP TABLE IF EXISTS    upfront_rifee;
CREATE TEMPORARY TABLE  upfront_rifee
AS
select 
  invoice_month
  , account_id
  , SUM(rifee) AS rifee_actual_cost
from integration.aws_rifee_amortization_schedule 
where 
  invoice_month = (select invoice_month from parameters)
  and usage_date <= (select last_trx_datetime::DATE from parameters)
group by 1, 2
order by 1, 2
;

IF (select count(*) from upfront_rifee) > 0 THEN
    UPDATE usage_final
    SET weighted_upfront_rifee_actual_cost = CAST(ROUND(retail_cost_percent * r.rifee_actual_cost, 8) AS DECIMAL(38,8))
    FROM upfront_rifee r
    WHERE 
      r.account_id = usage_final.account_id
      AND usage_final.user_product != 'AWS MARKETPLACE' -- exclude AWS Marketplace charges from amortization
    ;
END IF;

-- ================================================================================================
-- (999) INSERT into aws_monthly_cost_summary
-- ================================================================================================

-- delete existing data
DELETE FROM datawarehouse.aws_monthly_cost_summary WHERE invoice_month = (select invoice_month from parameters);

-- insert new data
INSERT INTO datawarehouse.aws_monthly_cost_summary
SELECT
  invoice_month
  , invoice_id
  , trx_source
  , account_id
  , account_name
  , user_company
  , user_product
  , ROUND(SUM(actual_cost), 4) AS actual_cost  
  , ROUND(SUM(weighted_actual_cost), 4) AS weighted_actual_cost
  , ROUND(SUM(weighted_upfront_rifee_actual_cost), 4) AS weighted_upfront_rifee_actual_cost
  , ROUND(SUM(retail_cost), 4) AS retail_cost 
  , ROUND(SUM(retail_cost_percent), 10) AS retail_cost_percent
  , (select last_trx_datetime from parameters) AS t_last_trx_date
  , GETDATE() AS t_created_date    
FROM usage_final    
GROUP BY 1,2,3,4,5,6,7
;

-- peek
/*
select * 
from datawarehouse.aws_monthly_cost_summary 
order by 1,2,3,4,5,6,8
;

select 
  account_name
  , invoice_id
  , sum(actual_cost) as actual_cost
  , sum(weighted_actual_cost) as weighted_actual_cost
  , sum(retail_cost) as retail_cost
  , sum(retail_cost) - sum(actual_cost) as savings
  , ROUND(sum(actual_cost) - sum(weighted_actual_cost), 2) as actual_diff
  , ROUND(sum(retail_cost_percent), 6) as total_weight
from datawarehouse.aws_monthly_cost_summary
where invoice_month = 201912
group by 1,2
order by 1,2
*/

-- =NOTE= this is not the precise way to get the number of rows INSERTed. RedShift does expose some
-- STV/STL system tables that will retrieve the row count but it's a bit complicated to do (unlike MS SQL Server
-- which exposes a @@ROWCOUNT variable or pgsql which allows you to wrap a CTE around the INSERT/UPDATE/DELETE
-- and select count(*) from the target table)

SELECT COUNT(*) INTO v_row_count FROM datawarehouse.aws_monthly_cost_summary WHERE invoice_month = (select invoice_month from parameters);
SELECT TRIM(TO_CHAR(v_row_count, '999,999,999')) INTO v_row_count_char;

if v_row_count > 0 then
	RAISE INFO 'INFO: % records inserted into datawarehouse.aws_monthly_cost_summary', v_row_count_char;
else
	RAISE INFO 'INFO: No records inserted into datawarehouse.aws_monthly_cost_summary!';
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
DROP TABLE IF EXISTS usage_agg;
DROP TABLE IF EXISTS usage_final;
DROP TABLE IF EXISTS adhoc_alloc;
DROP TABLE IF EXISTS amort_rifee;
DROP TABLE IF EXISTS alloc_kube_weights;
DROP TABLE IF EXISTS alloc_kube;

END;

$$ LANGUAGE plpgsql

SECURITY INVOKER
;

-- permissions

GRANT EXECUTE ON PROCEDURE datawarehouse.sp_aws_monthly_cost_summary__insert(VARCHAR, INT) TO GROUP engineering;

-- test
/*
CALL datawarehouse.sp_aws_monthly_cost_summary__insert('ESTIMATED', NULL);
CALL datawarehouse.sp_aws_monthly_cost_summary__insert('ACTUAL', 201907);
CALL datawarehouse.sp_aws_monthly_cost_summary__insert('ACTUAL', 201708); -- test abort
select invoice_month, trx_source, t_created_date, count(*) as n from datawarehouse.aws_monthly_cost_summary group by 1,2,3; 
*/
