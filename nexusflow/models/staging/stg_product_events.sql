-- stg_product_events
-- Staging: cast types, normalize feature names (inconsistent source: api_gateway vs apiGateway)
-- customer_id is CUST-NNN format — no identity resolution needed
-- timestamp is ISO 8601 UTC
{{ config(materialized='table') }}

WITH source AS (
    SELECT * FROM {{ source('rds', 'product_events') }}
)

SELECT
    event_id,
    NULLIF(TRIM(customer_id), '')                       AS customer_id,

    -- Normalize feature names to snake_case
    CASE LOWER(TRIM(feature))
        WHEN 'apigateway'         THEN 'api_gateway'
        WHEN 'api_gateway'        THEN 'api_gateway'
        WHEN 'workflow-builder'   THEN 'workflow_builder'
        WHEN 'workflow_builder'   THEN 'workflow_builder'
        ELSE LOWER(TRIM(feature))
    END                                                 AS feature,

    LOWER(TRIM(action))                                 AS action,

    TRY_CAST(
        TRY_CAST(timestamp AS TIMESTAMPTZ) AS DATE
    )                                                   AS event_date,

    NULLIF(TRIM(session_id), '')                        AS session_id,
    NULLIF(TRIM(user_agent), '')                        AS user_agent,
    TRY_CAST(_batch_id AS INTEGER)                      AS batch_id

FROM source
