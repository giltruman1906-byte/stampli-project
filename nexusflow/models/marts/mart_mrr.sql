-- mart_mrr
-- Monthly MRR movements — one row per customer per month with movement classification
-- Sources:
--   new/churn     → dim_subscriptions (start_date / end_date_resolved)
--   expansion/contraction → fct_contract_amendments (effective_date, mrr_delta)
--   base MRR      → dim_subscriptions active in that month
-- Uses: finance macros (mrr_movement, safe_divide, pct_change)

WITH months AS (
    SELECT UNNEST(['2024-01-01', '2024-02-01', '2024-03-01']::DATE[]) AS mrr_month
),

-- ── Step 1: base MRR per customer per month ──────────────────────────────────
-- A subscription contributes MRR to a month based on DATE RANGE only (not current status)
-- This ensures cancelled/expired subscriptions appear in months they were active
-- so LAG() correctly captures their prev_mrr and churn is detected
sub_monthly AS (
    SELECT
        s.customer_id,
        m.mrr_month,
        SUM(s.mrr)                                      AS mrr,
        SUM(CASE WHEN s.status IN ('active','suspended') THEN 1 ELSE 0 END) AS active_sub_count
    FROM {{ ref('dim_subscriptions') }} s
    CROSS JOIN months m
    WHERE s.start_date <= (m.mrr_month + INTERVAL 1 MONTH - INTERVAL 1 DAY)
      AND (s.end_date_resolved IS NULL
           OR s.end_date_resolved > m.mrr_month)
    GROUP BY 1, 2
),

-- ── Step 2: new MRR — subscriptions that STARTED this month ──────────────────
new_mrr AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', start_date)                 AS mrr_month,
        SUM(mrr)                                        AS new_mrr_amount
    FROM {{ ref('dim_subscriptions') }}
    WHERE start_date BETWEEN '2024-01-01' AND '2024-03-31'
      AND status IN ('active', 'suspended', 'cancelled', 'expired')
    GROUP BY 1, 2
),

-- ── Step 3: churn MRR — subscriptions that ENDED this month ──────────────────
churn_mrr AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', end_date_resolved)          AS mrr_month,
        SUM(mrr)                                        AS churn_mrr_amount
    FROM {{ ref('dim_subscriptions') }}
    WHERE end_date_resolved BETWEEN '2024-01-01' AND '2024-03-31'
      AND status IN ('cancelled', 'expired')
    GROUP BY 1, 2
),

-- ── Step 4: expansion / contraction from contract amendments ─────────────────
-- Use mrr_delta sign (not amendment_type flags) so ALL amendment effects are captured:
-- cancellation of add-ons (negative delta) → contraction, discount removals (positive) → expansion
-- This ensures starting + new + expansion − contraction − churn = ending (no residual gap)
amendment_movements AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', effective_date)             AS mrr_month,
        SUM(CASE WHEN mrr_delta > 0 THEN mrr_delta  ELSE 0 END) AS expansion_mrr,
        SUM(CASE WHEN mrr_delta < 0 THEN ABS(mrr_delta) ELSE 0 END) AS contraction_mrr,
        COUNT(CASE WHEN mrr_delta > 0 THEN 1 END)      AS expansion_count,
        COUNT(CASE WHEN mrr_delta < 0 THEN 1 END)      AS contraction_count
    FROM {{ ref('fct_contract_amendments') }}
    WHERE effective_date BETWEEN '2024-01-01' AND '2024-03-31'
    GROUP BY 1, 2
),

-- ── Step 5: all customers × all months skeleton ──────────────────────────────
all_customer_months AS (
    SELECT c.customer_id, m.mrr_month
    FROM {{ ref('dim_customers') }} c
    CROSS JOIN months m
),

-- ── Step 6: assemble with LAG for prev_mrr ───────────────────────────────────
assembled AS (
    SELECT
        a.customer_id,
        a.mrr_month,
        COALESCE(s.mrr, 0)                              AS mrr,
        COALESCE(s.active_sub_count, 0)                 AS active_sub_count,
        COALESCE(n.new_mrr_amount, 0)                   AS new_mrr_amount,
        COALESCE(ch.churn_mrr_amount, 0)                AS churn_mrr_amount,
        COALESCE(am.expansion_mrr, 0)                   AS expansion_mrr,
        COALESCE(am.contraction_mrr, 0)                 AS contraction_mrr,
        COALESCE(am.expansion_count, 0)                 AS expansion_count,
        COALESCE(am.contraction_count, 0)               AS contraction_count,

        LAG(COALESCE(s.mrr, 0)) OVER (
            PARTITION BY a.customer_id ORDER BY a.mrr_month
        )                                               AS prev_mrr

    FROM all_customer_months a
    LEFT JOIN sub_monthly       s  ON a.customer_id = s.customer_id AND a.mrr_month = s.mrr_month
    LEFT JOIN new_mrr           n  ON a.customer_id = n.customer_id AND a.mrr_month = n.mrr_month
    LEFT JOIN churn_mrr         ch ON a.customer_id = ch.customer_id AND a.mrr_month = ch.mrr_month
    LEFT JOIN amendment_movements am ON a.customer_id = am.customer_id AND a.mrr_month = am.mrr_month
),

-- ── Step 7: classify movement ────────────────────────────────────────────────
classified AS (
    SELECT
        *,
        ROUND(mrr - COALESCE(prev_mrr, 0), 2)           AS mrr_delta,
        {{ pct_change('mrr', 'prev_mrr') }}              AS mrr_pct_change,

        -- Movement classification: amendment signals take precedence over base MRR diff
        CASE
            WHEN new_mrr_amount > 0 AND COALESCE(prev_mrr, 0) = 0  THEN 'new'
            WHEN churn_mrr_amount > 0 AND mrr = 0                  THEN 'churn'
            WHEN expansion_mrr > 0 AND contraction_mrr = 0         THEN 'expansion'
            WHEN contraction_mrr > 0 AND expansion_mrr = 0         THEN 'contraction'
            WHEN expansion_mrr > 0 AND contraction_mrr > 0         THEN 'mixed'
            -- NOTE: prev_mrr IS NULL means "first month in dataset" — do NOT classify as 'new'
            -- Only the explicit new_mrr_amount > 0 path above catches truly new customers
            WHEN mrr = 0 AND prev_mrr > 0                          THEN 'churn'
            ELSE                                                        'unchanged'
        END                                             AS mrr_movement

    FROM assembled
    -- Only include customers with any MRR activity
    WHERE mrr > 0 OR prev_mrr > 0 OR new_mrr_amount > 0 OR churn_mrr_amount > 0
)

SELECT
    c.customer_id,
    cu.company_name,
    cu.region,
    cu.account_tier,
    cu.status                                           AS customer_status,

    c.mrr_month,
    c.mrr,
    c.prev_mrr,
    c.mrr_delta,
    c.mrr_pct_change,
    c.mrr_movement,
    c.active_sub_count,

    -- Movement detail
    c.new_mrr_amount,
    c.churn_mrr_amount,
    c.expansion_mrr,
    c.contraction_mrr,
    c.expansion_count,
    c.contraction_count,

    -- Convenience flags
    (c.mrr_movement = 'new')           AS is_new,
    (c.mrr_movement = 'expansion')     AS is_expansion,
    (c.mrr_movement = 'contraction')   AS is_contraction,
    (c.mrr_movement = 'churn')         AS is_churn,
    (c.mrr_movement = 'unchanged')     AS is_unchanged,
    (c.mrr_movement = 'mixed')         AS is_mixed,

    -- Health score context
    h.health_score,
    {{ risk_tier('h.health_score') }}  AS risk_tier,
    h.mrr_at_risk

FROM classified c
LEFT JOIN {{ ref('dim_customers') }}         cu ON c.customer_id = cu.customer_id
LEFT JOIN {{ ref('mart_customer_health_score') }} h ON c.customer_id = h.customer_id
