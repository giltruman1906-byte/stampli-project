-- dim_customers
-- Core dimension — current state of all customers
-- Enrichments:
--   1. Null region recovered from country → NA / EMEA / APAC
--   2. customer_key: numeric ID for joins (CUST-001 → 1)
--   3. region_was_inferred flag: documents where region came from

WITH stg AS (
    SELECT * FROM {{ ref('stg_customers') }}
),

enriched AS (
    SELECT
        *,
        CASE
            WHEN region IS NOT NULL                      THEN region
            WHEN country IN (
                'United States', 'Canada', 'Mexico')     THEN 'NA'
            WHEN country IN (
                'United Kingdom', 'Germany', 'France',
                'Spain', 'Netherlands', 'Sweden', 'Italy',
                'Belgium', 'Switzerland', 'Norway',
                'Denmark', 'Finland', 'Poland', 'Portugal',
                'Austria', 'Ireland')                    THEN 'EMEA'
            WHEN country IN (
                'Japan', 'Australia', 'India', 'Singapore',
                'Hong Kong', 'South Korea', 'China',
                'New Zealand', 'Thailand', 'Indonesia',
                'Malaysia', 'Philippines')               THEN 'APAC'
            ELSE 'UNKNOWN'
        END                                              AS region_resolved,
        region IS NULL                                   AS region_was_inferred
    FROM stg
)

SELECT
    -- Keys
    customer_id,
    CAST(REPLACE(customer_id, 'CUST-', '') AS INTEGER)  AS customer_key,

    -- Identity
    company_name,
    industry,
    country,
    city,

    -- Region (enriched from country where null)
    region_resolved                                      AS region,
    region_was_inferred,

    -- Account
    account_owner,
    account_tier,
    status,
    employee_count,
    annual_revenue_usd,

    -- Dates
    signup_date,

    -- Metadata
    notes

FROM enriched
