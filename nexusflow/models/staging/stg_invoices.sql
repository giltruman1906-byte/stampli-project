-- stg_invoices
-- Staging: cast types, handle sentinels, normalize customer_id to CUST-NNN
-- Note: materialized as table (not view) to avoid DuckDB type-binding bug
-- when used as CTE inside CREATE TABLE AS SELECT downstream
-- customer_id source format: plain integer (e.g. '203') → 'CUST-203'
{{ config(materialized='table') }}

WITH source AS (
    SELECT * FROM {{ source('rds', 'invoices') }}
)

SELECT
    invoice_id,
    CASE
        WHEN NULLIF(TRIM(customer_id), '') IS NULL THEN NULL
        ELSE 'CUST-' || LPAD(TRIM(customer_id), 3, '0')
    END                                                 AS customer_id,
    NULLIF(TRIM(subscription_id), '')                   AS subscription_id,
    TRY_CAST(invoice_date AS DATE)                      AS invoice_date,
    TRY_CAST(due_date AS DATE)                          AS due_date,
    TRY_CAST(amount AS DECIMAL(12, 2))                  AS amount,
    NULLIF(TRIM(currency), '')                          AS currency,
    LOWER(TRIM(status))                                 AS status,
    TRY_CAST(line_items_count AS INTEGER)               AS line_items_count,
    TRY_CAST(tax_amount AS DECIMAL(12, 2))              AS tax_amount,
    TRY_CAST(total_amount AS DECIMAL(12, 2))            AS total_amount,
    TRY_CAST(period_start AS DATE)                      AS period_start,
    TRY_CAST(period_end AS DATE)                        AS period_end,
    TRY_CAST(created_at AS DATE)                        AS created_at,
    TRY_CAST(_batch_id AS INTEGER)                      AS batch_id

FROM source
