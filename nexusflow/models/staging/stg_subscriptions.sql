-- stg_subscriptions
-- Staging layer: cast types, handle nulls, no business logic

WITH source AS (
    SELECT * FROM {{ source('rds', 'subscriptions') }}
),

cleaned AS (
    SELECT
        subscription_id,
        customer_id,
        plan_id,
        TRY_CAST(start_date AS DATE)            AS start_date,
        TRY_CAST(end_date AS DATE)              AS end_date,
        TRY_CAST(mrr AS DECIMAL(10, 2))         AS mrr,
        NULLIF(TRIM(billing_cycle), '')          AS billing_cycle,
        CAST(auto_renew AS BOOLEAN)              AS auto_renew,
        LOWER(TRIM(status))                     AS status
    FROM source
)

SELECT * FROM cleaned
