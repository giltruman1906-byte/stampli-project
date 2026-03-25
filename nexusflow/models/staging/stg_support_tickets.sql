-- stg_support_tickets
-- Staging: cast types, derive is_resolved flag
-- customer_id is CUST-NNN format — no identity resolution needed
-- created_at / resolved_at are ISO 8601 UTC (Z suffix)
{{ config(materialized='table') }}

WITH source AS (
    SELECT * FROM {{ source('rds', 'support_tickets') }}
)

SELECT
    ticket_id,
    NULLIF(TRIM(customer_id), '')                               AS customer_id,
    LOWER(TRIM(category))                                       AS category,
    LOWER(TRIM(priority))                                       AS priority,

    TRY_CAST(
        TRY_CAST(created_at AS TIMESTAMPTZ) AS DATE
    )                                                           AS created_date,

    TRY_CAST(
        TRY_CAST(resolved_at AS TIMESTAMPTZ) AS DATE
    )                                                           AS resolved_date,

    TRY_CAST(resolution_hours AS DECIMAL(10, 2))                AS resolution_hours,
    TRY_CAST(satisfaction_score AS DECIMAL(3, 1))               AS satisfaction_score,
    NULLIF(TRIM(agent_name), '')                                AS agent_name,
    LOWER(TRIM(channel))                                        AS channel,
    NULLIF(TRIM(description), '')                               AS description,
    TRY_CAST(_batch_id AS INTEGER)                              AS batch_id

FROM source
