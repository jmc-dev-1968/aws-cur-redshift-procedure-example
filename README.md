# AWS CUR Redshift Stored Procedure Example

Sample Redshift stored procedures used for processing a client's daily-downloaded AWS Current Usage Report (CUR) data — from raw hourly-grain ingestion through to reporting-ready monthly cost summaries.

## Overview

These three procedures represent the core transformation logic of a production AWS cost-allocation pipeline, originally built to support client billing, internal chargeback, and Finance/DevOps reporting from AWS CUR data. Raw CUR exports (dropped daily to S3 by AWS, loaded into Redshift via a separate Python/Airflow ELT process) are processed at their native hourly grain and progressively aggregated into daily, then monthly, reporting structures.

## Procedure Summary

### sp_aws_cost_usage_report_daily_aggregation__insert
Processes raw hourly-grain CUR data: normalizes cost fields across line item types (Usage, RIFee, SavingsPlanCoveredUsage, Credit, etc.), applies resource-tag-based cost allocation, handles ad hoc/off-hours billing rules, amortizes upfront RI/Savings Plan fees, and redistributes shared infrastructure costs across clients (including cross-cloud AWS/Azure weighting).

### sp_aws_monthly_cost_detail__insert
Inserts aggregated data into a monthly historical detail table, preserving line-item-level granularity for audit and drill-down reporting, and the ability to rerun monthly reports on demand (e.g. via reporting platforms). DevOps frequently ran ad hoc queries at this granularity — for example, spotting a cost spike in a rolled-up EC2 category and needing to identify exactly which resource(s) drove the increase.

### sp_aws_monthly_cost_summary__insert
Aggregates daily data up to report-level segmentation (account, client/company, product), producing the summary tables that feed downstream BI/reporting tools. Populates both ESTIMATED costs (daily running totals prior to AWS invoicing) and ACTUAL costs (post-invoice), which converge as the billing month closes.

## Key Technical Patterns

- Hourly-to-daily-to-monthly progressive aggregation over large CUR datasets
- Line-item-type-specific cost normalization (handling AWS's inconsistent cost field behavior across Usage, RIFee, SavingsPlanCoveredUsage, Credit, and Support line items)
- Resource-tag-based cost allocation with fallback to AWS account default cost centers
- Timezone-aware off-hours/ad hoc billing allocation
- Upfront Reserved Instance / Savings Plan fee amortization schedules
- Weighted cross-cloud (AWS + Azure) shared infrastructure cost redistribution — Azure cost data was a newer addition at the time, manually uploaded into a Redshift table pending full pipeline integration, so this piece was far simpler than the AWS CUR processing itself
- Spot Instance on-demand rate backfilling

## Note on Redaction and Completeness

Client and company names referenced in the original procedures have been replaced with generic placeholders (e.g., `CLIENT A`, `COMPANY`) to protect confidential business information. Dependent table DDL (source and target table definitions) is intentionally not included, as this is not a deployable, standalone solution — it is provided solely to illustrate Redshift SQL and stored procedure development skills: complex transformation logic, cost allocation modeling, and large-scale data aggregation patterns.
