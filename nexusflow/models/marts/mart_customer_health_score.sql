-- mart_customer_health_score
-- Composite customer health score (0–100) + churn risk tier
-- Higher score = healthier customer
--
-- Scoring components (max points each):
--   Usage signals      → 40 pts  (most predictive — product engagement)
--   Support signals    → 30 pts  (ticket health + post-ticket recovery)
--   Financial signals  → 30 pts  (payment health + MRR direction)
--
-- Risk tiers:
--   🔴 Critical  (0–30):  Multiple red flags, likely churning this month
--   🟡 At Risk   (31–60): Declining signals, needs CSM attention
--   🟢 Healthy   (61–100): Engaged, paying, stable or growing

WITH usage AS (
    SELECT * FROM {{ ref('int_customer_usage_stats') }}
),

support AS (
    SELECT * FROM {{ ref('int_customer_support_signals') }}
),

financial AS (
    SELECT * FROM {{ ref('int_customer_financial_signals') }}
),

all_customers AS (
    SELECT customer_id FROM {{ ref('dim_customers') }}
),

-- ── USAGE SCORE (0–40) ──────────────────────────────────────────────────────
usage_score AS (
    SELECT
        customer_id,

        -- Base: has any usage at all (0 or 10)
        CASE WHEN total_events_3m > 0 THEN 10 ELSE 0 END

        -- Trend: growing usage = positive signal (+15 / neutral / -15)
        + CASE
            WHEN usage_slope > 0 AND feb_to_mar_delta > 0 THEN 15  -- consistently growing
            WHEN usage_slope > 0                          THEN 8   -- net positive
            WHEN usage_slope = 0                          THEN 5   -- flat
            WHEN is_consistently_declining                THEN 0   -- consistent decline
            ELSE 3                                                  -- slight decline
          END

        -- Feature breadth: using more features = stickier (+0 to +10)
        + CASE
            WHEN max_feature_breadth >= 4 THEN 10
            WHEN max_feature_breadth = 3  THEN 7
            WHEN max_feature_breadth = 2  THEN 4
            WHEN max_feature_breadth = 1  THEN 1
            ELSE 0
          END

        -- Recency: active in March = good (+5 / 0)
        + CASE WHEN mar_events > 0 THEN 5 ELSE 0 END

        AS usage_score,

        -- Usage risk flags for explanation
        is_silent_churn,
        is_consistently_declining,
        has_sparse_usage,
        sharp_drop_last_month,
        total_events_3m,
        usage_slope,
        max_feature_breadth,
        feb_mar_pct_change

    FROM usage
),

-- ── SUPPORT SCORE (0–30) ────────────────────────────────────────────────────
support_score AS (
    SELECT
        customer_id,

        -- Base: no tickets at all = neutral (15), having tickets starts at 20
        CASE WHEN total_tickets = 0 THEN 15
             ELSE 20
        END

        -- Open high-priority ticket = big penalty
        - CASE WHEN has_open_critical_ticket THEN 10 ELSE 0 END

        -- Satisfaction score
        + CASE
            WHEN avg_satisfaction_score >= 4.5 THEN 8
            WHEN avg_satisfaction_score >= 3.5 THEN 5
            WHEN avg_satisfaction_score >= 2.5 THEN 2
            WHEN avg_satisfaction_score IS NOT NULL THEN -3
            ELSE 0
          END

        -- Post-ticket engagement recovery
        + CASE
            WHEN avg_engagement_recovery >= 1.0 THEN 5   -- fully recovered or better
            WHEN avg_engagement_recovery >= 0.7 THEN 3   -- mostly recovered
            WHEN avg_engagement_recovery >= 0.4 THEN 0   -- partial recovery
            WHEN avg_engagement_recovery IS NOT NULL THEN -3  -- did not recover
            ELSE 0
          END

        -- Billing friction = strong churn signal
        - CASE WHEN has_billing_friction THEN 5 ELSE 0 END

        AS support_score,

        total_tickets,
        open_tickets,
        open_high_priority_tickets,
        avg_satisfaction_score,
        avg_engagement_recovery,
        tickets_not_recovered,
        has_open_critical_ticket,
        poor_post_ticket_recovery,
        has_billing_friction

    FROM support
),

-- ── FINANCIAL SCORE (0–30) ──────────────────────────────────────────────────
financial_score AS (
    SELECT
        customer_id,

        -- Base: active subscription (0 or 15)
        CASE WHEN NOT no_active_subscription THEN 15 ELSE 0 END

        -- Payment health
        + CASE
            WHEN collection_rate_pct >= 95 THEN 10
            WHEN collection_rate_pct >= 80 THEN 6
            WHEN collection_rate_pct >= 60 THEN 2
            WHEN collection_rate_pct IS NOT NULL THEN 0
            ELSE 5  -- no payments yet, neutral
          END

        -- MRR direction
        + CASE
            WHEN has_recent_upgrade           THEN 5
            WHEN has_recent_downgrade         THEN -3
            WHEN has_commitment_downgrade     THEN -2
            ELSE 3
          END

        -- Overdue / failed signals
        - CASE WHEN has_overdue_invoices          THEN 5 ELSE 0 END
        - CASE WHEN has_repeated_payment_failures THEN 3 ELSE 0 END
        - CASE WHEN has_disputed_invoices         THEN 2 ELSE 0 END
        - CASE WHEN has_auto_renew_off            THEN 3 ELSE 0 END

        AS financial_score,

        current_mrr,
        has_overdue_invoices,
        has_repeated_payment_failures,
        has_disputed_invoices,
        has_recent_downgrade,
        has_recent_upgrade,
        has_auto_renew_off,
        no_active_subscription,
        collection_rate_pct

    FROM financial
),

-- ── COMPOSITE SCORE ─────────────────────────────────────────────────────────
composite AS (
    SELECT
        a.customer_id,

        -- Clamp each component to its valid range before summing
        GREATEST(0, LEAST(40, COALESCE(u.usage_score,    20))) AS usage_score,
        GREATEST(0, LEAST(30, COALESCE(s.support_score,  15))) AS support_score,
        GREATEST(0, LEAST(30, COALESCE(f.financial_score, 15))) AS financial_score

    FROM all_customers a
    LEFT JOIN usage_score    u ON a.customer_id = u.customer_id
    LEFT JOIN support_score  s ON a.customer_id = s.customer_id
    LEFT JOIN financial_score f ON a.customer_id = f.customer_id
),

scored AS (
    SELECT
        *,
        (usage_score + support_score + financial_score)         AS health_score
    FROM composite
)

SELECT
    sc.customer_id,
    c.company_name,
    c.region,
    c.account_tier,
    c.status                                                    AS customer_status,

    -- Scores
    sc.usage_score,
    sc.support_score,
    sc.financial_score,
    sc.health_score,

    -- Risk tier
    CASE
        WHEN sc.health_score <= 30 THEN 'critical'
        WHEN sc.health_score <= 60 THEN 'at_risk'
        ELSE                            'healthy'
    END                                                         AS risk_tier,

    -- MRR at risk (prioritization tool: risk × revenue)
    CASE
        WHEN sc.health_score <= 30 THEN COALESCE(f.current_mrr, 0)
        WHEN sc.health_score <= 60 THEN ROUND(COALESCE(f.current_mrr, 0) * 0.5, 2)
        ELSE 0
    END                                                         AS mrr_at_risk,

    -- Usage signals
    u.total_events_3m,
    u.usage_slope,
    u.max_feature_breadth,
    u.feb_mar_pct_change,
    u.is_silent_churn,
    u.is_consistently_declining,
    u.sharp_drop_last_month,

    -- Support signals
    s.total_tickets,
    s.open_tickets,
    s.open_high_priority_tickets,
    s.avg_satisfaction_score,
    s.avg_engagement_recovery,
    s.tickets_not_recovered,
    s.has_open_critical_ticket,
    s.poor_post_ticket_recovery,
    s.has_billing_friction,

    -- Financial signals
    f.current_mrr,
    f.collection_rate_pct,
    f.has_overdue_invoices,
    f.has_repeated_payment_failures,
    f.has_recent_downgrade,
    f.has_recent_upgrade,
    f.has_auto_renew_off,
    f.no_active_subscription,

    -- Expansion readiness (opposite of churn risk)
    (sc.health_score >= 70
     AND COALESCE(u.max_feature_breadth, 0) >= 4
     AND COALESCE(f.has_recent_upgrade, false) = false) AS is_expansion_candidate

FROM scored sc
LEFT JOIN {{ ref('dim_customers') }}         c ON sc.customer_id = c.customer_id
LEFT JOIN usage_score                        u ON sc.customer_id = u.customer_id
LEFT JOIN support_score                      s ON sc.customer_id = s.customer_id
LEFT JOIN financial_score                    f ON sc.customer_id = f.customer_id
ORDER BY sc.health_score ASC  -- riskiest customers first
