-- stg_customers
-- Staging layer: cast types, handle nulls, no business logic
-- customer_id stays as-is (CUST-NNN) — normalization happens in intermediate

WITH source AS (
    SELECT * FROM {{ source('rds', 'customers') }}
),

cleaned AS (
    SELECT
        customer_id,
        NULLIF(TRIM(company_name), '')                          AS company_name,
        NULLIF(TRIM(industry), '')                              AS industry,
        NULLIF(TRIM(UPPER(region)), '')                         AS region,
        NULLIF(TRIM(country), '')                               AS country,
        NULLIF(TRIM(city), '')                                  AS city,
        TRY_CAST(signup_date AS DATE)                           AS signup_date,
        NULLIF(TRIM(account_owner), '')                         AS account_owner,
        LOWER(TRIM(status))                                     AS status,
        NULLIF(LOWER(TRIM(email)), '')                          AS email,
        NULLIF(TRIM(phone), '')                                 AS phone,
        TRY_CAST(employee_count AS INTEGER)                     AS employee_count,
        TRY_CAST(annual_revenue_usd AS BIGINT)                  AS annual_revenue_usd,
        CASE
            WHEN TRIM(notes) IN ('-', 'N/A', 'n/a', 'NA', '')  THEN NULL
            ELSE NULLIF(TRIM(notes), '')
        END                                                     AS notes,
        NULLIF(TRIM(account_tier), '')                          AS account_tier
    FROM source
)

SELECT * FROM cleaned
