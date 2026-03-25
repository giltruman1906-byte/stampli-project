-- stg_plans
-- Staging layer: cast types, handle nulls, no business logic

WITH source AS (
    SELECT * FROM {{ source('rds', 'plans') }}
),

cleaned AS (
    SELECT
        plan_id,
        NULLIF(TRIM(plan_name), '')             AS plan_name,
        TRY_CAST(base_price AS DECIMAL(10, 2))  AS base_price,
        NULLIF(TRIM(billing_model), '')          AS billing_model,
        TRY_CAST(api_limit AS INTEGER)           AS api_limit,
        TRY_CAST(storage_gb AS INTEGER)          AS storage_gb,
        NULLIF(TRIM(features), '')               AS features,
        TRY_CAST(effective_date AS DATE)         AS effective_date,
        CAST(is_active AS BOOLEAN)               AS is_active
    FROM source
)

SELECT * FROM cleaned
