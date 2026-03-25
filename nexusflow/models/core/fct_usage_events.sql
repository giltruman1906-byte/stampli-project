-- fct_usage_events
-- Usage event fact table — one row per customer/date/metric observation
-- Includes late_usage_jan (merged in staging via UNION ALL)
-- customer_id is already CUST-NNN — direct join to dim_customers
-- Deduplication: same (customer, date, metric) may appear in multiple batches
--   (corrections or late-arriving updates) — keep latest batch version
-- Subscription fanout: customers with multiple active subs get the latest-started one

WITH stg AS (
    SELECT * FROM {{ ref('stg_usage_events') }}
),

-- Step 1: Deduplicate on (customer_id, event_date, metric_name) — keep max batch_id
deduped AS (
    SELECT
        customer_id,
        event_date,
        metric_name,
        quantity,
        unit,
        batch_id
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY customer_id, event_date, metric_name
                ORDER BY batch_id DESC
            ) AS rn
        FROM stg
    )
    WHERE rn = 1
),

-- Step 2: Enrich with customer and subscription context
joined AS (
    SELECT
        d.customer_id,
        d.event_date,
        d.metric_name,
        d.quantity,
        d.unit,
        d.batch_id,

        -- Customer context
        c.company_name,
        c.region,
        c.account_tier,
        c.status                                        AS customer_status,

        -- Subscription at event time — pick latest-started active sub to avoid fanout
        sub.subscription_id,
        sub.plan_id,
        p.plan_name,
        p.plan_tier,
        sub.billing_cycle,

        ROW_NUMBER() OVER (
            PARTITION BY d.customer_id, d.event_date, d.metric_name
            ORDER BY sub.start_date DESC NULLS LAST
        )                                               AS _sub_rn

    FROM deduped d
    LEFT JOIN {{ ref('dim_customers') }} c
        ON d.customer_id = c.customer_id
    LEFT JOIN {{ ref('dim_subscriptions') }} sub
        ON d.customer_id = sub.customer_id
        AND d.event_date >= sub.start_date
        AND (sub.end_date_resolved IS NULL OR d.event_date <= sub.end_date_resolved)
        AND sub.status IN ('active', 'suspended')
    LEFT JOIN {{ ref('dim_plans') }} p
        ON sub.plan_id = p.plan_id
)

SELECT
    customer_id,
    event_date,
    metric_name,
    quantity,
    unit,

    -- Context
    company_name,
    region,
    account_tier,
    customer_status,
    subscription_id,
    plan_id,
    plan_name,
    plan_tier,
    billing_cycle,

    -- DQ
    (company_name IS NULL)                              AS dq_unresolved_customer,
    (subscription_id IS NULL)                           AS dq_no_active_subscription,

    batch_id

FROM joined
WHERE _sub_rn = 1
