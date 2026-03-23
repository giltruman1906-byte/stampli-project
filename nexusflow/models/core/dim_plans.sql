-- dim_plans
-- Plan reference dimension
-- Note: PLN-LEGACY exists in subscriptions but not in plans source.
-- Handled downstream with LEFT JOIN — not fabricated here.

WITH stg AS (
    SELECT * FROM {{ ref('stg_plans') }}
)

SELECT
    plan_id,
    plan_name,

    CASE
        WHEN plan_id = 'PLN-FREE'  THEN 'free'
        WHEN plan_id = 'PLN-START' THEN 'starter'
        WHEN plan_id = 'PLN-PRO'   THEN 'professional'
        WHEN plan_id = 'PLN-BIZ'   THEN 'business'
        WHEN plan_id = 'PLN-ENT'   THEN 'enterprise'
        ELSE                            'legacy'
    END                                                 AS plan_tier,

    base_price,
    billing_model,
    api_limit,
    storage_gb,
    features,
    ARRAY_LENGTH(
        STRING_SPLIT(COALESCE(features, ''), ',')
    )                                                   AS feature_count,
    effective_date,
    is_active,
    NOT is_active                                       AS is_legacy

FROM stg
