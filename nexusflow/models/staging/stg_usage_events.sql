-- stg_usage_events
-- Staging: cast types, union with late_usage_jan
-- customer_id is already in CUST-NNN format — no identity resolution needed
-- No unique event_id — deduplication is not applicable (all rows are distinct events)
-- late_usage_jan: January 2024 events submitted late in batch_003 — verified no overlap with usage_events
{{ config(materialized='table') }}

WITH main_events AS (
    SELECT * FROM {{ source('rds', 'usage_events') }}
),

late_events AS (
    SELECT * FROM {{ source('rds', 'late_usage_jan') }}
),

combined AS (
    SELECT * FROM main_events
    UNION ALL
    SELECT * FROM late_events
)

SELECT
    NULLIF(TRIM(customer_id), '')                       AS customer_id,
    TRY_CAST(event_date AS DATE)                        AS event_date,
    LOWER(TRIM(metric_name))                            AS metric_name,
    TRY_CAST(quantity AS DECIMAL(14, 4))                AS quantity,
    LOWER(TRIM(unit))                                   AS unit,
    TRY_CAST(_batch_id AS INTEGER)                      AS batch_id

FROM combined
