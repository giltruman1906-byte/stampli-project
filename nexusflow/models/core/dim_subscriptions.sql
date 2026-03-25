-- dim_subscriptions
-- Subscription dimension with enrichments:
--   1. end_date_resolved:
--        - already has end_date              → pass through (method = 'source')
--        - cancelled/expired, null end_date  → start_date + 1 billing cycle (method = 'cycle_estimate')
--        - active/suspended, null end_date   → next upcoming renewal from ref date (method = 'next_renewal')
--          ref date = 2024-03-31 (end of last loaded batch)
--          note: data does NOT create renewal rows per period — one row per subscription lifetime
--   2. mrr_movement:  revenue signal via LAG on MRR per customer
--   3. cycle_movement: commitment signal via LAG on billing_cycle rank
--      kept separate from mrr_movement — combining creates misleading signals
--      (e.g. MRR down + cycle up is neither a clean upgrade nor downgrade)
--   4. data quality flags

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
        -- Source has end_date → use it
        WHEN end_date IS NOT NULL
            THEN end_date

        -- Cancelled / expired, no end_date → original contract term end (start + 1 cycle)
        WHEN status IN ('cancelled', 'expired') AND billing_cycle = 'monthly'
            THEN start_date + INTERVAL 1 MONTH
        WHEN status IN ('cancelled', 'expired') AND billing_cycle = 'quarterly'
            THEN start_date + INTERVAL 3 MONTHS
        WHEN status IN ('cancelled', 'expired') AND billing_cycle = 'annual'
            THEN start_date + INTERVAL 1 YEAR

        -- Active / suspended → next upcoming renewal from last batch date
        WHEN status IN ('active', 'suspended') AND billing_cycle = 'monthly'
            THEN start_date
                + CAST(DATEDIFF('month', start_date, DATE '2024-03-31') + 1 AS INT)
                * INTERVAL 1 MONTH
        WHEN status IN ('active', 'suspended') AND billing_cycle = 'quarterly'
            THEN start_date
                + CAST(DATEDIFF('quarter', start_date, DATE '2024-03-31') + 1 AS INT)
                * INTERVAL 3 MONTHS
        WHEN status IN ('active', 'suspended') AND billing_cycle = 'annual'
            THEN start_date
                + CAST(DATEDIFF('year', start_date, DATE '2024-03-31') + 1 AS INT)
                * INTERVAL 1 YEAR

        ELSE NULL
    END                                                 AS end_date_resolved,

    CASE
        WHEN end_date IS NOT NULL               THEN 'source'
        WHEN status IN ('cancelled', 'expired') THEN 'cycle_estimate'
        WHEN status IN ('active', 'suspended')  THEN 'next_renewal'
        ELSE                                         'unknown'
    END                                                 AS end_date_method,

    -- Revenue
    mrr,
    prev_mrr,
    ROUND(mrr - COALESCE(prev_mrr, 0), 2)              AS mrr_delta,

    -- MRR movement: pure revenue signal
    CASE
        WHEN prev_mrr IS NULL               THEN 'new'
        WHEN mrr > prev_mrr                 THEN 'upgrade'
        WHEN mrr < prev_mrr                 THEN 'downgrade'
        ELSE                                     'unchanged'
    END                                                 AS mrr_movement,

    -- Cycle movement: commitment signal (kept separate from MRR)
    CASE
        WHEN prev_cycle_rank IS NULL        THEN 'new'
        WHEN cycle_rank > prev_cycle_rank   THEN 'commitment_upgrade'
        WHEN cycle_rank < prev_cycle_rank   THEN 'commitment_downgrade'
        ELSE                                     'unchanged'
    END                                                 AS cycle_movement,

    -- Previous state (audit trail)
    prev_plan_id,
    prev_billing_cycle,

    -- Data quality flags
    (status = 'cancelled'
     AND end_date IS NULL)                              AS dq_cancelled_no_end_date,

    (end_date IS NOT NULL
     AND end_date < start_date)                         AS dq_end_before_start

FROM with_lag
