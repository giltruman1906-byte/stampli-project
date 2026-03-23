-- dim_subscriptions
-- Subscription dimension with enrichments:
--   1. end_date_resolved: fills null end_date from billing_cycle for cancelled/expired
--   2. mrr_movement: upgrade / downgrade / new / unchanged via LAG on MRR per customer
--   3. cycle_movement: commitment change (monthly→annual = upgrade, etc.)
--   4. subscription_movement: combined signal
--   5. data_quality flags

WITH stg AS (
    SELECT * FROM {{ ref('stg_subscriptions') }}
),

with_cycle_rank AS (
    SELECT
        *,
        CASE billing_cycle
            WHEN 'monthly'   THEN 1
            WHEN 'quarterly' THEN 2
            WHEN 'annual'    THEN 3
            ELSE 0
        END AS cycle_rank
    FROM stg
),

with_lag AS (
    SELECT
        *,
        LAG(mrr) OVER (
            PARTITION BY customer_id ORDER BY start_date
        )                                               AS prev_mrr,

        LAG(plan_id) OVER (
            PARTITION BY customer_id ORDER BY start_date
        )                                               AS prev_plan_id,

        LAG(billing_cycle) OVER (
            PARTITION BY customer_id ORDER BY start_date
        )                                               AS prev_billing_cycle,

        LAG(cycle_rank) OVER (
            PARTITION BY customer_id ORDER BY start_date
        )                                               AS prev_cycle_rank
    FROM with_cycle_rank
)

SELECT
    -- Keys
    subscription_id,
    customer_id,
    plan_id,

    -- Status
    status,
    billing_cycle,
    cycle_rank,
    auto_renew,

    -- Dates
    start_date,
    end_date,

    CASE
        WHEN end_date IS NOT NULL        THEN end_date
        WHEN status = 'active'           THEN NULL
        WHEN status = 'suspended'        THEN NULL
        WHEN billing_cycle = 'monthly'   THEN start_date + INTERVAL 1 MONTH
        WHEN billing_cycle = 'quarterly' THEN start_date + INTERVAL 3 MONTHS
        WHEN billing_cycle = 'annual'    THEN start_date + INTERVAL 1 YEAR
        ELSE NULL
    END                                                 AS end_date_resolved,

    end_date IS NULL
    AND status IN ('cancelled', 'expired')              AS end_date_was_inferred,

    -- Revenue
    mrr,
    prev_mrr,
    ROUND(mrr - COALESCE(prev_mrr, 0), 2)              AS mrr_delta,

    -- MRR movement
    CASE
        WHEN prev_mrr IS NULL            THEN 'new'
        WHEN mrr > prev_mrr              THEN 'upgrade'
        WHEN mrr < prev_mrr              THEN 'downgrade'
        ELSE                                  'unchanged'
    END                                                 AS mrr_movement,

    -- Billing cycle commitment movement
    CASE
        WHEN prev_cycle_rank IS NULL     THEN 'new'
        WHEN cycle_rank > prev_cycle_rank THEN 'commitment_upgrade'
        WHEN cycle_rank < prev_cycle_rank THEN 'commitment_downgrade'
        ELSE                                  'unchanged'
    END                                                 AS cycle_movement,

    -- Combined upgrade / downgrade signal
    CASE
        WHEN prev_mrr IS NULL            THEN 'new'
        WHEN mrr > prev_mrr
          OR cycle_rank > prev_cycle_rank THEN 'upgrade'
        WHEN mrr < prev_mrr
          OR cycle_rank < prev_cycle_rank THEN 'downgrade'
        ELSE                                  'unchanged'
    END                                                 AS subscription_movement,

    -- Previous state (for audit trail)
    prev_plan_id,
    prev_billing_cycle,

    -- Data quality flags
    (status = 'cancelled'
     AND end_date IS NULL)                              AS dq_cancelled_no_end_date,

    (end_date IS NOT NULL
     AND end_date < start_date)                         AS dq_end_before_start

FROM with_lag
