-- stg_payments
-- Staging: cast types, handle sentinels, normalize customer_id to CUST-NNN
-- customer_id source formats: plain integer (e.g. '481') or C-prefix (e.g. 'C302') → 'CUST-481', 'CUST-302'
-- Note: payment_date is ISO 8601 datetime with timezone offset — cast to TIMESTAMP then truncate to DATE
{{ config(materialized='table') }}

WITH source AS (
    SELECT * FROM {{ source('rds', 'payments') }}
)

SELECT
    payment_id,
    NULLIF(TRIM(invoice_id), '')                        AS invoice_id,
    CASE
        WHEN NULLIF(TRIM(customer_id), '') IS NULL THEN NULL
        WHEN TRIM(customer_id) LIKE 'C%'
            THEN 'CUST-' || LPAD(SUBSTRING(TRIM(customer_id), 2), 3, '0')
        ELSE 'CUST-' || LPAD(TRIM(customer_id), 3, '0')
    END                                                 AS customer_id,

    TRY_CAST(amount AS DECIMAL(12, 2))                  AS amount,
    LOWER(TRIM(payment_method))                         AS payment_method,

    -- ISO 8601 with timezone offset → TIMESTAMPTZ → DATE
    TRY_CAST(
        TRY_CAST(payment_date AS TIMESTAMPTZ) AS DATE
    )                                                   AS payment_date,

    LOWER(TRIM(status))                                 AS status,
    NULLIF(TRIM(transaction_ref), '')                   AS transaction_ref,
    TRY_CAST(processor_fee AS DECIMAL(10, 4))           AS processor_fee,
    TRY_CAST(net_amount AS DECIMAL(12, 2))              AS net_amount,
    TRY_CAST(_batch_id AS INTEGER)                      AS batch_id

FROM source
