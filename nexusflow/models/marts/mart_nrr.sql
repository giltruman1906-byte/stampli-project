-- mart_nrr
-- Net Revenue Retention — monthly waterfall aggregated across all customers
-- Canonical definition (decision_log MRR section):
--   NRR = (starting + expansion - contraction - churn) / starting
-- One row per month per region (+ totals)
-- Uses: calc_nrr, safe_divide, pct_change macros

WITH mrr AS (
    SELECT * FROM {{ ref('mart_mrr') }}
),

-- Monthly waterfall by region
-- Uses pre-computed movement columns from mart_mrr for accuracy
monthly_region AS (
    SELECT
        mrr_month,
        region,

        SUM(new_mrr_amount)                                      AS new_mrr,
        SUM(expansion_mrr)                                       AS expansion_mrr,
        SUM(contraction_mrr)                                     AS contraction_mrr,
        SUM(churn_mrr_amount)                                    AS churn_mrr,
        SUM(CASE WHEN mrr_movement = 'reactivation' THEN mrr ELSE 0 END) AS reactivation_mrr,
        -- Use 0 (not mrr) when prev_mrr is NULL — first month has no prior cohort
        SUM(COALESCE(prev_mrr, 0))                               AS starting_mrr,
        SUM(mrr)                                                 AS ending_mrr,

        COUNT(DISTINCT CASE WHEN mrr > 0 THEN customer_id END)   AS active_customers,
        -- Count customers with ANY cancellation this month (is_churn requires mrr=0 which churn month doesn't have)
        COUNT(DISTINCT CASE WHEN churn_mrr_amount > 0 THEN customer_id END) AS churned_customers,
        -- Only count customers with a subscription that genuinely STARTED this month (not baseline Jan customers)
        COUNT(DISTINCT CASE WHEN new_mrr_amount > 0 AND COALESCE(prev_mrr, 0) = 0 THEN customer_id END) AS new_customers

    FROM mrr
    GROUP BY 1, 2
),

-- Total (all regions combined)
monthly_total AS (
    SELECT
        mrr_month,
        'ALL'                                                    AS region,
        SUM(new_mrr)          AS new_mrr,
        SUM(expansion_mrr)    AS expansion_mrr,
        SUM(contraction_mrr)  AS contraction_mrr,
        SUM(churn_mrr)        AS churn_mrr,
        SUM(reactivation_mrr) AS reactivation_mrr,
        SUM(starting_mrr)     AS starting_mrr,
        SUM(ending_mrr)       AS ending_mrr,
        SUM(active_customers) AS active_customers,
        SUM(churned_customers) AS churned_customers,
        SUM(new_customers)    AS new_customers
    FROM monthly_region
    GROUP BY 1, 2
),

combined AS (
    SELECT * FROM monthly_region
    UNION ALL
    SELECT * FROM monthly_total
)

SELECT
    mrr_month,
    region,

    -- Waterfall components
    ROUND(starting_mrr,    2)   AS starting_mrr,
    ROUND(new_mrr,         2)   AS new_mrr,
    ROUND(expansion_mrr,   2)   AS expansion_mrr,
    ROUND(contraction_mrr, 2)   AS contraction_mrr,
    ROUND(churn_mrr,       2)   AS churn_mrr,
    ROUND(reactivation_mrr,2)   AS reactivation_mrr,
    ROUND(ending_mrr,      2)   AS ending_mrr,

    -- NRR using macro
    ROUND(
        {{ calc_nrr('starting_mrr', 'expansion_mrr', 'contraction_mrr', 'churn_mrr') }} * 100
    , 1)                                                        AS nrr_pct,

    -- Gross Revenue Retention (no expansion, only losses)
    ROUND(
        {{ safe_divide(
            'starting_mrr - contraction_mrr - churn_mrr',
            'starting_mrr',
            'NULL'
        ) }} * 100
    , 1)                                                        AS grr_pct,

    -- MoM ending MRR % change
    ROUND(
        {{ pct_change('ending_mrr', 'starting_mrr') }}
    , 1)                                                        AS ending_mrr_pct_change,

    -- Churn rate
    ROUND(
        {{ safe_divide('churn_mrr', 'starting_mrr', 'NULL') }} * 100
    , 2)                                                        AS churn_rate_pct,

    -- Customer counts
    active_customers,
    new_customers,
    churned_customers

FROM combined
ORDER BY mrr_month, region
