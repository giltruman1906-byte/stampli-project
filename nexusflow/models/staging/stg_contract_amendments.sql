-- stg_contract_amendments
-- Staging: cast types
-- customer_id is CUST-NNN format — no identity resolution needed
-- effective_date is ISO date; created_at is ISO 8601 UTC datetime
{{ config(materialized='table') }}

WITH source AS (
    SELECT * FROM {{ source('rds', 'contract_amendments') }}
)

SELECT
    amendment_id,
    NULLIF(TRIM(customer_id), '')                       AS customer_id,
    NULLIF(TRIM(subscription_id), '')                   AS subscription_id,
    LOWER(TRIM(amendment_type))                         AS amendment_type,
    NULLIF(TRIM(old_plan_id), '')                       AS old_plan_id,
    NULLIF(TRIM(new_plan_id), '')                       AS new_plan_id,
    TRY_CAST(old_mrr AS DECIMAL(12, 2))                 AS old_mrr,
    TRY_CAST(new_mrr AS DECIMAL(12, 2))                 AS new_mrr,
    TRY_CAST(effective_date AS DATE)                    AS effective_date,
    TRY_CAST(
        TRY_CAST(created_at AS TIMESTAMPTZ) AS DATE
    )                                                   AS created_date,
    NULLIF(TRIM(reason), '')                            AS reason,
    NULLIF(TRIM(approved_by), '')                       AS approved_by,
    TRY_CAST(_batch_id AS INTEGER)                      AS batch_id

FROM source
