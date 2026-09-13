
/*
DROP PROCEDURE datawarehouse.sp_aws_cost_usage_report_daily_aggregation__insert(INOUT INT, IN VARCHAR, OUT INT, OUT TIMESTAMP, OUT INT, OUT VARCHAR);
*/

CREATE OR REPLACE PROCEDURE datawarehouse.sp_aws_cost_usage_report_daily_aggregation__insert
(
  p_invoice_month     INOUT INT  -- yyyymm => for specific invoice month, 0 => current month, -1 => previous month
  , p_process_mode    IN VARCHAR(15)-- PROCESS_DATA (default) or STATS_ONLY
  , p_is_invoiced     OUT INT -- 1 => ALL records invoiced, 0 => has at least one record not invoiced (invoice_id = '')
  , p_created_date    OUT TIMESTAMP -- the t_create_date for the invoice_month
  , p_row_count       OUT INT -- row count
  , p_error           OUT VARCHAR(100)
)

AS 

$$

DECLARE v_process_mode VARCHAR(15);
DECLARE v_trx_source VARCHAR(10); -- values : ESTIMATED / ACTUAL
DECLARE v_invoice_month INT;
DECLARE v_row_count INT;
DECLARE v_row_count_char VARCHAR;
DECLARE v_msg VARCHAR(100);
DECLARE v_record RECORD;
DECLARE v_start_time TIMESTAMP;
DECLARE v_elapsed_time VARCHAR;

BEGIN

-- ================================================================================
-- parameter processing
-- ================================================================================

v_start_time = GETDATE();

v_process_mode = UPPER(NVL(p_process_mode, 'PROCESS_DATA'));
p_error = '';

-- Null or 0 passed ==> current month
IF NVL(p_invoice_month, 0) = 0 THEN
  v_invoice_month = TO_CHAR(GETDATE(),'yyyyMM')::INT;
  p_invoice_month = v_invoice_month; -- put value into INOUT parm 
-- -1 passed  ==> previous month
ELSIF p_invoice_month = -1 THEN
  v_invoice_month = TO_CHAR(GETDATE() - interval '1 month','yyyyMM')::INT;
  p_invoice_month = v_invoice_month; -- put value into INOUT parm 
-- explicit month
ELSE
  v_invoice_month = p_invoice_month;
END IF;

-- only calculate stats for specific data set and return
IF v_process_mode = 'STATS_ONLY' THEN

    select     
      min(case when NVL(bill_invoice_id, '') != '' then 1 else 0 end)
      , max(t_created_date) 
      , count(*) INTO p_is_invoiced, p_created_date, p_row_count
    from integration.aws_cost_usage_report_daily_aggregation
    where invoice_month = v_invoice_month
    ;

  	RAISE INFO 'INFO: Executing under processing mode %, stats for invoice_month % are returned only ', v_process_mode, v_invoice_month;
   
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
INSERT INTO parameters
SELECT 
  NULL AS trx_source -- populated later
  , v_invoice_month AS invoice_month
  , NULL AS last_trx_datetime -- populated later
;
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
-- (1) get trx level data
-- ================================================================================================
/*
we are keeping this initial rollup at the daiy-hour grain, which is needed for the ad hoc billing
allocation further down the procedure. ultimately we will roll up to only the daily grain
*/

DROP TABLE IF EXISTS    usage_trx;
CREATE TEMPORARY TABLE  usage_trx 
AS
WITH usage_trx AS
(
  select
    t.invoice_month
    , t.bill_billing_entity
    , t.line_item_usage_account_id
    , a.account_display_name as usage_account_name
    , t.bill_invoice_id
    , t.line_item_usage_start_date
    , t.line_item_line_item_type
    , t.line_item_usage_type
    , t.line_item_resource_id
    , t.product_product_name
    , t.product_instance_type
    , t.product_instance_type_family
    , t.line_item_line_item_description
    , t.reservation_reservation_a_r_n
    , t.savings_plan_savings_plan_a_r_n
    , CASE 
        WHEN NVL(t.resource_tags_user_company, '') = '' THEN UPPER(a.default_cost_center)
        ELSE UPPER(t.resource_tags_user_company) 
      END AS resource_tags_user_company
    , UPPER(t.resource_tags_user_product) AS resource_tags_user_product
    , UPPER(t.resource_tags_user_company) AS resource_tags_user_company_original
    , UPPER(t.resource_tags_user_product) AS resource_tags_user_product_original
    , UPPER(t.resource_tags_user_stage)   AS resource_tags_user_stage
    , t.resource_tags_user_name -- leave as is (no UPPER), we need this to match to ad hoc billing config table
    , CASE
      -- SavingsPlanCoveredUsage functions just like DiscountedUsage (for RI's), but AWS DOES NOT zero out
      -- the unblended_cost like it does for DiscountedUsage. Zero out here        
        WHEN t.line_item_line_item_type = 'SavingsPlanCoveredUsage' THEN 0
        ELSE t.line_item_unblended_cost        
      END AS line_item_unblended_cost
    , CASE
        -- AWS Support is calculated as a % of total $usage; it appears AWS puts this usage amount (or something close to it)
        -- in the on_demand_cost column resulting in an overhelmingly  large value. Correct this problem here by using the
        -- unblended_cost value (and thus no savings which is expected)
        WHEN product_product_name LIKE 'AWS Support%' THEN t.line_item_unblended_cost 
        -- no change
        WHEN t.line_item_line_item_type IN ('RIFee', 'SavingsPlanRecurringFee') THEN t.pricing_public_on_demand_cost
        -- Credit has ondemand_cost = 0, so adjust here
        WHEN t.line_item_line_item_type = 'Credit' THEN t.line_item_unblended_cost
        ELSE t.pricing_public_on_demand_cost
      END AS pricing_public_on_demand_cost  
    , t.pricing_public_on_demand_rate
    , t.line_item_unblended_rate
    , t.pricing_unit
    , t.line_item_usage_amount
  from integration_external.aws_cost_usage_report t
  join integration.aws_account_config a on (a.account_id = t.line_item_usage_account_id)
  where 
    t.invoice_month = (select invoice_month from parameters)
    and t.line_item_line_item_type NOT IN ('SavingsPlanNegation', 'SavingsPlanUpfrontFee', 'Refund')
    /*
    this excludes RI upfront purchases but allows line items with line_item_type = 'Fee' and
    bill_type = 'Anniversary' (AWS Support) to be included
    */
    and NOT(t.line_item_line_item_type = 'Fee' and bill_bill_type = 'Purchase') 
    /* exclude these credits, Finance can amortize these theirselves */
    and NOT(t.line_item_line_item_type = 'Credit' and t.line_item_line_item_description = 'Defensive credit for Company')
)
select
  invoice_month
  , bill_billing_entity
  , line_item_usage_account_id
  , usage_account_name
  , bill_invoice_id
  , line_item_usage_start_date
  , line_item_line_item_type
  , line_item_usage_type
  , line_item_unblended_rate
  , line_item_line_item_description
  , line_item_resource_id
  , reservation_reservation_a_r_n
  , savings_plan_savings_plan_a_r_n
  , product_product_name
  , product_instance_type
  , product_instance_type_family
  , pricing_public_on_demand_rate
  , pricing_unit
  , resource_tags_user_company
  , resource_tags_user_product
  , resource_tags_user_company_original
  , resource_tags_user_product_original
  , resource_tags_user_stage
  , resource_tags_user_name
  , SUM(line_item_unblended_cost) AS line_item_unblended_cost
  , SUM(pricing_public_on_demand_cost) AS pricing_public_on_demand_cost
  , SUM(line_item_usage_amount) AS line_item_usage_amount
  , CAST('' AS VARCHAR(100)) AS note
from usage_trx
group by 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24
;
-- peek
/*
select * from usage_trx LIMIT 100;
select count(*) as n from usage_trx; -- ~ 2,306,377
*/

SELECT COUNT(*) INTO v_row_count FROM usage_trx;
SELECT TRIM(TO_CHAR(v_row_count, '999,999,999')) INTO v_row_count_char;
SELECT invoice_month INTO v_invoice_month FROM parameters;

IF v_row_count = 0 THEN
  v_msg = 'No AWS Spectrum data exists for invoice month ' || v_invoice_month;
  p_error = v_msg;
  p_row_count = 0;
	RAISE INFO 'WARN: %, aborting', v_msg; 
	DROP TABLE IF EXISTS usage_trx;
  RETURN;
END IF;

-- check if any records exist WITHOUT an invoice ==> still in ESTIMATED mode
-- =NOTE= in the case of  partially invoiced products/services, this ensure we 
-- dont close the month until ALL  products/services are invoiced!

IF EXISTS(select * from usage_trx where NVL(bill_invoice_id, '') = '') THEN
  UPDATE parameters SET trx_source = 'ESTIMATED';
ELSE  
  UPDATE parameters SET trx_source = 'ACTUAL';
END IF;  

SELECT trx_source INTO  v_trx_source from parameters;

RAISE INFO 'INFO: Executing procedure for invoice_month % (%)', v_invoice_month, v_trx_source;
RAISE INFO 'INFO: % aws billing trx records retrieved', v_row_count_char;

-- ================================================================================================
-- (1.a) Daily SavingsPlanRecurringFee Adjustment
-- ================================================================================================

-- AWS  amortizes SavingsPlanRecurringFee over invoice month, so get last real trx date (will 
-- be used below to delete future trx's)

UPDATE parameters 
SET last_trx_datetime = 
(
	SELECT MAX(line_item_usage_start_date) 
	FROM usage_trx 
	WHERE line_item_line_item_type != 'SavingsPlanRecurringFee'
)
;

DELETE FROM usage_trx
WHERE 
  line_item_line_item_type = 'SavingsPlanRecurringFee'
  AND line_item_usage_start_date > (select last_trx_datetime from parameters)
;

-- ================================================================================================
-- (1.b) retrieve Spot Instance ondemand_cost (this is zero in CUR)
-- ================================================================================================

-- AWS DOES NOT populate the product_instance_type/product_instance_type_family (as well as
-- pricing_public_on_demand_rate) for SpotInstance usage so populate here for subsequent
-- calculations

UPDATE usage_trx 
SET 
  product_instance_type           = SPLIT_PART(line_item_usage_type, ':', 2)
  , product_instance_type_family  = SPLIT_PART(SPLIT_PART(line_item_usage_type, ':', 2), '.', 1)
FROM usage_trx 
WHERE 
  line_item_line_item_type = 'Usage'
  AND line_item_usage_type LIKE '%Spot%'
;

-- check if any instance sizes are not mapped in aws_price_list
FOR v_record IN
  SELECT s.product_instance_type
  FROM (SELECT DISTINCT product_instance_type FROM usage_trx WHERE line_item_usage_type LIKE '%SpotUsage%' AND line_item_line_item_type = 'Usage') s
  WHERE NOT EXISTS(select * from integration.aws_price_list where product_instance_type = s.product_instance_type)
LOOP
  RAISE INFO 'INFO: Spot Instance Usage Detected For Unmapped Instance Size (%) In integration.aws_price_list ...', v_record.product_instance_type;
END LOOP;

-- update on_demand_rate with value from price list config table, and calculate on_demand_cost
UPDATE usage_trx
SET 
  pricing_public_on_demand_rate		= p.pricing_public_on_demand_rate
  , pricing_public_on_demand_cost	= p.pricing_public_on_demand_rate * line_item_usage_amount
FROM integration.aws_price_list p
WHERE
  usage_trx.line_item_line_item_type = 'Usage'
  AND usage_trx.line_item_usage_type LIKE '%Spot%'
  AND (usage_trx.product_instance_type = p.product_instance_type)
;

-- ================================================================================================
-- (1.c) delete any records with no costs (both on demand and unblended costs are zero)
-- ================================================================================================
/*

  A large amount of rows have line_item_unblended_cost = 0 and pricing_public_on_demand_cost = 0
  (but with a positive line_item_usage_amount, mostly trivial, i.e. usage amount < 1.0).
  These DO NOT affect our calculations since the costs are all zero.

  We could filter them out in the main query  above, but I'd prefer to keep them in the procedure flow
  in case they need revisited.
  
  =NOTE= most of these are zero-charge data transfers, e.g.
  
    $0.000 per GB - data transfer in per month
  
*/

DELETE FROM usage_trx 
WHERE line_item_unblended_cost = 0 AND pricing_public_on_demand_cost = 0
;

-- ================================================================================================
-- (2) amortize monthly RIFee (non Upfront)
-- ================================================================================================
/*
  For non-Upfront RIs, the RIFee will be charged on the 1st-of-the-month for a recurring RI (unless
  it's a mid-month RI purchase then it appears to be charged on the date of purchase). we will 
  amortize this fee across the entire month below
*/

IF EXISTS (select * from usage_trx where line_item_line_item_type = 'RIFee') THEN

  RAISE INFO 'INFO: RIFee will be amortized across month ...';

  DROP TABLE IF EXISTS    amort_rifee; 
  CREATE TEMPORARY TABLE  amort_rifee 
  AS
  select 
    r.*
    , DATEADD(day, d.day, r.line_item_usage_start_date) as amort_line_item_usage_start_date
    , r.line_item_unblended_cost / r.days_in_period     as amort_line_item_unblended_cost
    , r.line_item_usage_amount / r.days_in_period       as amort_line_item_usage_amount
  from
  (
      -- find the total days in RI period, typically the number of days in the month (for recurring RI's)
      -- if the RI was started mid-month, this value will be the remaining days in the month from the RI
      -- purchase date
      select 
        *
        , DATEDIFF(day, line_item_usage_start_date, DATEADD(mm, 1, (TO_CHAR(line_item_usage_start_date, 'yyyy-MM') || '-01')::date)) as days_in_period
      from usage_trx
      where line_item_line_item_type = 'RIFee'
  ) r
  -- Using our calendar_days table, when "less-than-joined" with the days_in_period this gives us the sequence
  -- (0,1,2,..days_in_period - 1), which DATEADD'ed to the usage_date above gives us the sequence of
  -- days (1,2,3,..days_in_period). thus we have our amortized date range for the month
  join calendar_days d on (d.day < r.days_in_period)
  ;

  INSERT INTO usage_trx
  SELECT
    invoice_month
    , bill_billing_entity
    , line_item_usage_account_id
    , usage_account_name
    , bill_invoice_id
    , amort_line_item_usage_start_date -- * amortized column
    , line_item_line_item_type
    , line_item_usage_type
    , line_item_unblended_rate
    , line_item_line_item_description
    , line_item_resource_id
    , reservation_reservation_a_r_n
    , savings_plan_savings_plan_a_r_n
    , product_product_name
    , product_instance_type
    , product_instance_type_family
    , pricing_public_on_demand_rate
    , pricing_unit
    , resource_tags_user_company
    , resource_tags_user_product
    , resource_tags_user_company_original
    , resource_tags_user_product_original
    , resource_tags_user_stage
    , resource_tags_user_name
    , amort_line_item_unblended_cost -- * amortized column
    , pricing_public_on_demand_cost
    , amort_line_item_usage_amount -- * amortized column
    , 'AMORTIZED NON-UPFRONT RI FEE' AS note
  FROM amort_rifee    
  WHERE amort_line_item_usage_start_date::DATE <= (select last_trx_datetime::DATE from parameters) 
  ;

  -- delete original un-amortized RIFee line items
  DELETE FROM usage_trx WHERE line_item_line_item_type = 'RIFee' AND note = '';

END IF;


-- ================================================================================================
-- (3) ad hoc allocation (from aws_adhoc_billing_* config tables)
-- ================================================================================================
/*
  only perform ad hoc allocation if we have companies defined for the target month
*/
 
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
      usage_date_bkk = DATEADD(hour, 7, line_item_usage_start_date)::DATE
      , hour_bkk = DATE_PART(hour, DATEADD(hour, 7, line_item_usage_start_date))
      , day_bkk = 
          CASE DATE_PART(dow, DATEADD(hour, 7, line_item_usage_start_date)) 
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
    
    -- flag trx records that match the adhoc allocation schedule (exclude *Fee)
    -- used to sanity check our re-weighted records and delete the originals (next)    
    UPDATE usage_trx 
    SET note = 'ORIGINAL AD HOC USAGE'
    FROM (select DISTINCT account_id, instance_name, calendar_date, hour from adhoc_alloc) aa
    WHERE 
          aa.account_id     = usage_trx.line_item_usage_account_id
      AND aa.instance_name  = usage_trx.resource_tags_user_name
      AND aa.calendar_date  = usage_trx.usage_date_bkk
      AND aa.hour           = usage_trx.hour_bkk
      AND usage_trx.line_item_line_item_type NOT IN ('RIFee', 'Fee', 'SavingsPlanRecurringFee')
    ;  

    -- calculate ad-hoc costs by company, insert into usage
    INSERT INTO usage_trx
    SELECT
      u.invoice_month
      , u.bill_billing_entity
      , u.line_item_usage_account_id
      , u.usage_account_name
      , u.bill_invoice_id
      , u.line_item_usage_start_date
      , u.line_item_line_item_type
      , u.line_item_usage_type
      , u.line_item_unblended_rate
      , u.line_item_line_item_description
      , u.line_item_resource_id
      , u.reservation_reservation_a_r_n
      , u.savings_plan_savings_plan_a_r_n
      , u.product_product_name
      , u.product_instance_type
      , u.product_instance_type_family
      , u.pricing_public_on_demand_rate
      , u.pricing_unit
      , a.user_company  -- replaces resource_tags_user_company
      , u.resource_tags_user_product -- product stays the same
      , u.resource_tags_user_company_original
      , u.resource_tags_user_product_original
      , u.resource_tags_user_stage
      , u.resource_tags_user_name
      , u.line_item_unblended_cost * a.weight
      , u.pricing_public_on_demand_cost * a.weight
      , u.line_item_usage_amount * a.weight
      , 'REALLOCATED AD HOC USAGE' AS note
      , a.calendar_date AS usage_date_bkk -- temp col, will be deleted
      , a.hour AS hour_bkk -- temp col, will be deleted
      , a.weekday AS day_bkk -- temp col, will be deleted
    FROM usage_trx u
    JOIN adhoc_alloc a ON
    (
          a.account_id    = u.line_item_usage_account_id
      AND a.instance_name = u.resource_tags_user_name
      AND a.calendar_date = u.usage_date_bkk
      AND a.hour          = u.hour_bkk
    )
    WHERE u.line_item_line_item_type NOT IN ('RIFee', 'Fee', 'SavingsPlanRecurringFee')
    ;  
    
    -- delete original records
    DELETE usage_trx WHERE note = 'ORIGINAL AD HOC USAGE';

    -- drop work columns
    ALTER TABLE usage_trx DROP COLUMN usage_date_bkk;
    ALTER TABLE usage_trx DROP COLUMN hour_bkk;
    ALTER TABLE usage_trx DROP COLUMN day_bkk;

END IF;


-- ================================================================================================
-- (4) aggregate to daily grain
-- ================================================================================================
/*
  hourly grain was needed for ad hoc allocation above, we can now re-aggreagte to the daily grain
*/

DROP TABLE IF EXISTS    usage_agg;
CREATE TEMPORARY TABLE  usage_agg
AS
select
  invoice_month
  , bill_billing_entity
  , line_item_usage_account_id
  , usage_account_name
  , bill_invoice_id
  -- our standard is to keep AWS column names intact, howerever  we will deviate here to reflect this is now at the day grain
  , line_item_usage_start_date::DATE AS line_item_usage_date 
  , line_item_line_item_type
  , line_item_usage_type
  , line_item_unblended_rate
  , line_item_line_item_description
  , line_item_resource_id
  , reservation_reservation_a_r_n
  , savings_plan_savings_plan_a_r_n
  , product_product_name
  , product_instance_type
  , product_instance_type_family
  , pricing_public_on_demand_rate
  , pricing_unit
  , resource_tags_user_company
  , resource_tags_user_product
  , resource_tags_user_company_original
  , resource_tags_user_product_original
  , resource_tags_user_stage
  , resource_tags_user_name
  , SUM(line_item_unblended_cost) AS line_item_unblended_cost
  , SUM(pricing_public_on_demand_cost) AS pricing_public_on_demand_cost
  , SUM(line_item_usage_amount) AS line_item_usage_amount
  , note
from usage_trx
group by 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,28
;

-- drop trx table, not needed any longer (millions of rows large!)
DROP TABLE IF EXISTS usage_trx;

-- ================================================================================================
-- (4.a) update any zero on_demand_cost records
-- ================================================================================================

/*

  previous transformations took care of zero on demand costs for specific AWS conventions (like 
  Spot Instance). Remaining zero on demand costs  can be updated here (with unblended cost) 

  These only remaining records belong to 'AWS Marketplace' 
  
  =NOTE= we could have easily done this in previous aggregation. However I like to keep this is 
  a separate query step, so we can take a look at what's still zero from time to time (AWS is
  notorious for changing billing conventions in the CUR).
  
*/

UPDATE usage_agg
SET 
  pricing_public_on_demand_cost = line_item_unblended_cost
WHERE
  line_item_line_item_type NOT IN ('RIFee', 'Fee', 'SavingsPlanRecurringFee') -- always have on_demand_cost = 0
  and pricing_public_on_demand_cost = 0
;

-- ================================================================================================
-- (5) Allocate Kube costs
-- ================================================================================================
/*
resources tagged with user_product COMPANY.K8S.LOCAL or COMPANYDEV.K8S.LOCAL are used for
Kubernetes orchestration. we will re-allocate these costs to company user_company/user_products
according to Kubernetes config tables kube_monthly_namespace_usage and kube_namespace_product_mapping
*/

IF EXISTS (
    select * 
    from usage_agg  
    where 
      line_item_usage_account_id = '082404710867' -- Regional 
      and resource_tags_user_company = 'COMPANY REGIONAL'
      and resource_tags_user_product IN ('COMPANY.K8S.LOCAL', 'COMPANYDEV.K8S.LOCAL')
) THEN

    IF NOT EXISTS(select * from datawarehouse.kube_monthly_namespace_usage where month_id = (select invoice_month from parameters)) THEN

    	RAISE INFO 'WARN: No kube cluster/namespace records exist for invoice month %, skipping kube cost allocation', v_invoice_month;

    ELSE

        -- needed for this K8 section of processing, will be dropped
        ALTER TABLE usage_agg ADD COLUMN k8_note VARCHAR(50);
  
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
                    ELSE 'REALLOCATED K8 COSTS (' || UPPER(cluster_name) || ')'
                  END AS VARCHAR(100) 
                ) AS note
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

        -- flag original kube records for easier manipulation/deletion (later)
        UPDATE usage_agg
        SET k8_note = 'ORIGINAL K8 COSTS' 
        WHERE 
          line_item_usage_account_id      =  '082404710867' -- Regional
          and resource_tags_user_company  =  'COMPANY REGIONAL'
          and resource_tags_user_product  IN (select distinct kube_product from alloc_kube_weights)
        ;  

        -- join weights to kube line items and re-allocate
        DROP TABLE IF EXISTS    alloc_kube;
        CREATE TEMPORARY TABLE  alloc_kube
        AS
        select
          u.invoice_month
          , u.bill_billing_entity
          , u.line_item_usage_account_id
          , u.usage_account_name
          , u.bill_invoice_id
          , u.line_item_usage_date 
          , u.line_item_line_item_type
          , u.line_item_usage_type
          , u.line_item_unblended_rate
          , u.line_item_line_item_description
          , u.line_item_resource_id
          , u.reservation_reservation_a_r_n
          , u.savings_plan_savings_plan_a_r_n
          , u.product_product_name
          , u.product_instance_type
          , u.product_instance_type_family
          , u.pricing_public_on_demand_rate
          , u.pricing_unit
          , k.user_company AS resource_tags_user_company
          , k.user_product AS resource_tags_user_product
          , u.resource_tags_user_company_original
          , u.resource_tags_user_product_original
          , u.resource_tags_user_stage
          , u.resource_tags_user_name
          , u.line_item_unblended_cost      * k.weight as line_item_unblended_cost
          , u.pricing_public_on_demand_cost * k.weight as pricing_public_on_demand_cost
          , u.line_item_usage_amount        * k.weight as line_item_usage_amount
          , k.note AS note
        from usage_agg u
        join alloc_kube_weights k on (k.kube_product = u.resource_tags_user_product)
        where u.k8_note = 'ORIGINAL K8 COSTS' 
        ;  

        -- delete original kube records
        DELETE FROM usage_agg WHERE k8_note = 'ORIGINAL K8 COSTS';
        -- drop processing note
        ALTER TABLE usage_agg DROP COLUMN k8_note;

        -- insert new allocated kube records
        INSERT INTO usage_agg
        SELECT
          invoice_month
          , bill_billing_entity
          , line_item_usage_account_id
          , usage_account_name
          , bill_invoice_id
          , line_item_usage_date 
          , line_item_line_item_type
          , line_item_usage_type
          , line_item_unblended_rate
          , line_item_line_item_description
          , line_item_resource_id
          , reservation_reservation_a_r_n
          , savings_plan_savings_plan_a_r_n
          , product_product_name
          , product_instance_type
          , product_instance_type_family
          , pricing_public_on_demand_rate
          , pricing_unit
          , resource_tags_user_company
          , resource_tags_user_product
          , resource_tags_user_company_original
          , resource_tags_user_product_original
          , resource_tags_user_stage
          , resource_tags_user_name
          , line_item_unblended_cost
          , pricing_public_on_demand_cost
          , line_item_usage_amount
          , note
        FROM alloc_kube
        ;

    END IF;

 END IF;


-- ================================================================================================
-- (6) amortize UpFront RI and SavingsPlan Costs
-- ================================================================================================

/*

  AWS does NOT amortize Upfront RI & SP purchases. The fees arrives on the date of purchase (single 
  line item) as line line_item_line_item_type :
  
  Fee                   ==> reserved instance (RI) upfront fee
  SavingsPlanUpfrontFee ==> savings plan (SP) upfront fee
  
  We exclude these from our CUR processing (and copy their pertinent fields into our own config table
  named integration.aws_reserved_instance). We can then amortize these costs daily over their lifetime 
  which is found in integration.aws_upfront_purchases_amortization_schedule

  We DO NOT reallocate the costs, the costs stay with the usaage account (line_item_usage_account_id) 

*/

INSERT INTO  usage_agg
(
  invoice_month
  , bill_billing_entity
  , line_item_usage_account_id
  , usage_account_name
  , bill_invoice_id
  , line_item_usage_date 
  , line_item_line_item_type
  , reservation_reservation_a_r_n
  , product_product_name
  , pricing_unit
  , resource_tags_user_company
  , resource_tags_user_product
  , resource_tags_user_company_original
  , resource_tags_user_product_original
  , line_item_unblended_cost
  , pricing_public_on_demand_cost
  , line_item_usage_amount
  , note
)
select
  a.invoice_month
  , 'AWS' as bill_billing_entity
  , a.usage_account_id as line_item_usage_account_id 
  , c.account_display_name as usage_account_name
  , a.invoice_id
  , a.usage_date as line_item_usage_date 
  -- create our own item_type here to differentiate these fees 
  , CASE 
      WHEN a.product_name LIKE '%Savings Plan%' THEN 'SavingsPlanUpfrontFee'
      ELSE 'ReservedInstanceUpfrontFee' 
    END as line_item_line_item_type
  , a.reservation_arn as reservation_reservation_a_r_n
  , a.product_name as product_product_name
  , '' as pricing_unit
  , 'COMPANY REGIONAL' as resource_tags_user_company
  , '' as resource_tags_user_product
  , 'COMPANY REGIONAL' as resource_tags_user_company_original
  , '' as resource_tags_user_product_original
  , a.amount as line_item_unblended_cost
  , 0 as pricing_public_on_demand_cost
  , a.quantity as line_item_usage_amount
  , CASE 
      WHEN a.product_name LIKE '%Savings Plan%' THEN 'AMORTIZED UPFRONT SP FEE'
      ELSE 'AMORTIZED UPFRONT RI FEE' 
    END as note
from integration.aws_upfront_purchases_amortization_schedule a
join integration.aws_account_config c on (c.account_id = a.usage_account_id)
where 
  a.invoice_month = (select invoice_month from parameters)
  -- ensures estimated report doesn't include future amortized days in the month
  and a.usage_date <= (select last_trx_datetime::DATE from parameters) 
;

-- ================================================================================================
-- (7) redistribute INFRA costs to both AWS & AZURE clients
-- ================================================================================================
/*
  Re-allocated INFRA cost logic below will produce a record for each company in the 
  Hosting account as well as companies in Azure. These will be rolled up along with existing 
  costs in the next query (but will be carved out in the Jasper client facing report). 

  This means will have Azure (only) clients on the AWS report. Finance and other users will
  need to take this into account when consuming both reports


*/

DROP TABLE IF EXISTS    retail_weights;
CREATE TEMPORARY TABLE  retail_weights
AS
WITH company_costs AS
(
  SELECT
    bill_billing_entity AS cost_source
    , resource_tags_user_company
    , SUM(pricing_public_on_demand_cost)  AS pricing_public_on_demand_cost
  FROM usage_agg
  WHERE 
    bill_billing_entity = 'AWS'
    AND usage_account_name = 'Hosting' 
    AND resource_tags_user_company != 'COMPANY INFRASTRUCTURE'
  GROUP BY 1,2

  UNION ALL

  SELECT 
    'AZURE'::VARCHAR AS cost_source
    , tag_company AS resource_tags_user_company
    , SUM(retail_cost)  AS pricing_public_on_demand_cost
  FROM integration.azure_cost_summary
  WHERE billing_period = (select invoice_month from parameters)           
  GROUP BY 1,2
)
SELECT
  cost_source
  , resource_tags_user_company
  , SUM(pricing_public_on_demand_cost) AS pricing_public_on_demand_cost
  , SUM(pricing_public_on_demand_cost) / SUM(SUM(pricing_public_on_demand_cost)) OVER(PARTITION BY 1) AS retail_weight
FROM company_costs
GROUP BY
  cost_source
  , resource_tags_user_company
;

-- flag target records, for easier manipulation/deletion
UPDATE usage_agg
SET note = 'ORIGINAL INFRA COSTS'
WHERE 
  bill_billing_entity = 'AWS'
  AND usage_account_name = 'Hosting' 
  AND resource_tags_user_company = 'COMPANY INFRASTRUCTURE'
;

-- using weights, reallocate the infra costs
INSERT INTO usage_agg
SELECT
  u.invoice_month
  , u.bill_billing_entity
  , u.line_item_usage_account_id
  , u.usage_account_name
  , u.bill_invoice_id
  , u.line_item_usage_date 
  , u.line_item_line_item_type
  , u.line_item_usage_type
  , u.line_item_unblended_rate
  , u.line_item_line_item_description
  , u.line_item_resource_id
  , u.reservation_reservation_a_r_n
  , u.savings_plan_savings_plan_a_r_n
  , u.product_product_name
  , u.product_instance_type
  , u.product_instance_type_family
  , u.pricing_public_on_demand_rate
  , u.pricing_unit
  , w.resource_tags_user_company -- replaced by weights company
  , u.resource_tags_user_product -- product stays the same
  , u.resource_tags_user_company_original
  , u.resource_tags_user_product_original
  , u.resource_tags_user_stage
  , u.resource_tags_user_name
  , u.line_item_unblended_cost      * w.retail_weight as line_item_unblended_cost
  , u.pricing_public_on_demand_cost * w.retail_weight as pricing_public_on_demand_cost
  , u.line_item_usage_amount        * w.retail_weight as line_item_usage_amount
  , 'REALLOCATED INFRA COSTS (' || w.cost_source || ')' as note
FROM usage_agg u, retail_weights w
WHERE u.note = 'ORIGINAL INFRA COSTS'
;

-- delete original INFRA cost
DELETE FROM usage_agg WHERE note = 'ORIGINAL INFRA COSTS';

-- ================================================================================================
-- (999) INSERT 
-- ================================================================================================

-- delete existing data
DELETE FROM integration.aws_cost_usage_report_daily_aggregation 
WHERE invoice_month = (select invoice_month from parameters)
;

-- insert new data
INSERT INTO integration.aws_cost_usage_report_daily_aggregation
SELECT
  invoice_month
  , bill_billing_entity
  , line_item_usage_account_id
  , usage_account_name
  , bill_invoice_id
  , line_item_usage_date
  , line_item_line_item_type
  , line_item_usage_type
  , line_item_line_item_description
  , line_item_resource_id
  , reservation_reservation_a_r_n
  , savings_plan_savings_plan_a_r_n
  , product_product_name
  , product_instance_type
  , product_instance_type_family
  , resource_tags_user_company
  , resource_tags_user_product
  , resource_tags_user_company_original
  , resource_tags_user_product_original
  , resource_tags_user_stage
  , resource_tags_user_name
  , CAST(CASE WHEN line_item_unblended_rate = ''      THEN NULL ELSE line_item_unblended_rate      END AS DECIMAL(19,10))
  , CAST(CASE WHEN pricing_public_on_demand_rate = '' THEN NULL ELSE pricing_public_on_demand_rate END AS DECIMAL(19,10))
  , pricing_unit
  , CAST(line_item_unblended_cost AS DECIMAL(38,15))
  , CAST(pricing_public_on_demand_cost AS DECIMAL(38,15))
  , CAST(line_item_usage_amount AS DECIMAL(38,15))
  , note
  , GETDATE() AS t_created_date
FROM usage_agg
;

-- fill output parameters
select     
  min(case when NVL(bill_invoice_id, '') != '' then 1 else 0 end)
  , max(t_created_date) 
  , count(*) INTO p_is_invoiced, p_created_date, p_row_count
from integration.aws_cost_usage_report_daily_aggregation
where invoice_month = v_invoice_month
;

-- =NOTE= this is not the precise way to get the number of rows INSERTed. RedShift does expose some
-- STV/STL system tables that will retrieve the row count but it's a bit complicated to do (unlike MS SQL Server
-- which exposes a @@ROWCOUNT variable or pgsql which allows you to wrap a CTE around the INSERT/UPDATE/DELETE
-- and select count(*) from the target table)

SELECT COUNT(*) INTO v_row_count 
FROM integration.aws_cost_usage_report_daily_aggregation 
WHERE invoice_month = (select invoice_month from parameters);

SELECT TRIM(TO_CHAR(v_row_count, '999,999,999')) INTO v_row_count_char;

if v_row_count > 0 then
	RAISE INFO 'INFO: % records inserted into aws_cost_usage_report_daily_aggregation', v_row_count_char;
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
DROP TABLE IF EXISTS adhoc_alloc;
DROP TABLE IF EXISTS alloc_kube;
DROP TABLE IF EXISTS alloc_kube_weights;
DROP TABLE IF EXISTS amort_rifee;
DROP TABLE IF EXISTS calendar_dates;
DROP TABLE IF EXISTS calendar_days;
DROP TABLE IF EXISTS parameters;
DROP TABLE IF EXISTS retail_weights;
DROP TABLE IF EXISTS usage_agg;
DROP TABLE IF EXISTS usage_trx;

END;

$$ LANGUAGE plpgsql

SECURITY INVOKER
;

-- permissions
GRANT EXECUTE ON PROCEDURE datawarehouse.sp_aws_cost_usage_report_daily_aggregation__insert(INOUT INT, IN VARCHAR, OUT INT, OUT TIMESTAMP, OUT INT) TO GROUP engineering;
