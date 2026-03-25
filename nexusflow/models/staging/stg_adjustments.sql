-- stg_adjustments
-- Staging: cast types, normalize customer_id to CUST-NNN
-- customer_id source formats: plain integer ('197') or already CUST-prefix ('CUST-406') → unified to 'CUST-NNN'
-- effective_date and created_at are in MM/DD/YYYY format
{{ config(materialized='table') }}

WITH source AS (
    SELECT * FROM {{ source('rds', 'adjustments') }}
)

SELECT
    adjustment_id,
    CASE
        WHEN NULLIF(TRIM(customer_id), '') IS NULL THEN NULL
        WHEN TRIM(customer_id) LIKE 'CUST-%' THEN TRIM(customer_id)
        ELSE 'CUST-' || LPAD(TRIM(customer_id), 3, '0')
    END                                                 AS customer_id,
    NULLIF(TRIM(invoice_id), '')                        AS invoice_id,
    LOWER(TRIM(adjustment_type))                        AS adjustment_type,
    TRY_CAST(amount AS DECIMAL(12, 2))                  AS amount,
    NULLIF(TRIM(reason), '')                            AS reason,

    -- MM/DD/YYYY → DATE
    TRY_CAST(STRPTIME(TRIM(effective_date), '%m/%d/%Y') AS DATE)    AS effective_date,
    TRY_CAST(STRPTIME(TRIM(created_at), '%m/%d/%Y') AS DATE)        AS created_date,

    NULLIF(TRIM(approved_by), '')                       AS approved_by,
    LOWER(TRIM(status))                                 AS status,
    NULLIF(TRIM(reverses_adjustment_id), '')            AS reverses_adjustment_id,
    TRY_CAST(_batch_id AS INTEGER)                      AS batch_id

FROM source
