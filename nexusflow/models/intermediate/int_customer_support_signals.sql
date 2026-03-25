-- int_customer_support_signals
-- Support health signals per customer
-- Key feature: post-ticket engagement window
--   For each resolved ticket, compare product usage 14 days before vs 14 days after
--   If usage drops after resolution → the fix didn't re-engage the customer → churn risk

WITH tickets AS (
    SELECT * FROM {{ ref('fct_support_tickets') }}
),

usage AS (
    SELECT * FROM {{ ref('fct_usage_events') }}
),

-- For each resolved ticket, measure usage before and after
ticket_engagement AS (
    SELECT
        t.ticket_id,
        t.customer_id,
        t.created_date,
        t.resolved_date,
        t.priority,
        t.category,
        t.satisfaction_score,
        t.resolution_hours,

        -- Usage in 14 days BEFORE ticket was created
        COUNT(DISTINCT CASE
            WHEN u.event_date >= t.created_date - INTERVAL 14 DAYS
             AND u.event_date <  t.created_date
            THEN u.event_date || u.metric_name
        END)                                            AS pre_ticket_usage_days,

        SUM(CASE
            WHEN u.event_date >= t.created_date - INTERVAL 14 DAYS
             AND u.event_date <  t.created_date
            THEN u.quantity ELSE 0
        END)                                            AS pre_ticket_quantity,

        -- Usage in 14 days AFTER ticket was resolved
        COUNT(DISTINCT CASE
            WHEN t.resolved_date IS NOT NULL
             AND u.event_date >  t.resolved_date
             AND u.event_date <= t.resolved_date + INTERVAL 14 DAYS
            THEN u.event_date || u.metric_name
        END)                                            AS post_ticket_usage_days,

        SUM(CASE
            WHEN t.resolved_date IS NOT NULL
             AND u.event_date >  t.resolved_date
             AND u.event_date <= t.resolved_date + INTERVAL 14 DAYS
            THEN u.quantity ELSE 0
        END)                                            AS post_ticket_quantity

    FROM tickets t
    LEFT JOIN usage u ON t.customer_id = u.customer_id
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),

-- Compute recovery ratio per ticket
ticket_recovery AS (
    SELECT
        *,
        CASE
            WHEN pre_ticket_quantity > 0 AND resolved_date IS NOT NULL
                THEN ROUND(post_ticket_quantity::DECIMAL / pre_ticket_quantity, 2)
            WHEN pre_ticket_quantity = 0 AND post_ticket_quantity > 0
                THEN 2.0   -- no prior usage but engaged after → positive signal
            WHEN resolved_date IS NULL
                THEN NULL  -- can't measure unresolved tickets
            ELSE 0.0
        END                                             AS engagement_recovery_ratio,

        -- Did engagement recover? ratio >= 0.7 = mostly back to normal
        CASE
            WHEN pre_ticket_quantity > 0 AND resolved_date IS NOT NULL
                THEN (post_ticket_quantity::DECIMAL / pre_ticket_quantity) >= 0.7
            ELSE NULL
        END                                             AS engagement_recovered

    FROM ticket_engagement
),

-- Roll up to customer level
customer_support AS (
    SELECT
        customer_id,

        COUNT(*)                                        AS total_tickets,
        SUM(CASE WHEN is_open THEN 1 ELSE 0 END)        AS open_tickets,
        SUM(CASE WHEN is_resolved THEN 1 ELSE 0 END)    AS resolved_tickets,

        -- Priority breakdown
        SUM(CASE WHEN priority = 'critical' THEN 1 ELSE 0 END) AS critical_tickets,
        SUM(CASE WHEN priority = 'high'     THEN 1 ELSE 0 END) AS high_tickets,

        -- Category signals
        SUM(CASE WHEN category = 'billing'  THEN 1 ELSE 0 END) AS billing_tickets,
        SUM(CASE WHEN category = 'account'  THEN 1 ELSE 0 END) AS account_tickets,

        -- Open critical/high tickets = most urgent churn signal
        SUM(CASE WHEN is_open
                  AND priority IN ('critical', 'high')
                 THEN 1 ELSE 0 END)                     AS open_high_priority_tickets,

        -- Satisfaction
        ROUND(AVG(satisfaction_score), 2)               AS avg_satisfaction_score,
        MIN(satisfaction_score)                         AS min_satisfaction_score,

        -- Resolution speed
        ROUND(AVG(resolution_hours), 1)                 AS avg_resolution_hours,
        MAX(resolution_hours)                           AS max_resolution_hours

    FROM {{ ref('fct_support_tickets') }}
    GROUP BY 1
),

-- Post-ticket engagement rollup
customer_engagement AS (
    SELECT
        customer_id,
        COUNT(*)                                        AS measured_tickets,
        ROUND(AVG(engagement_recovery_ratio), 2)        AS avg_engagement_recovery,
        SUM(CASE WHEN engagement_recovered = false
                 THEN 1 ELSE 0 END)                     AS tickets_not_recovered,
        SUM(CASE WHEN engagement_recovered = true
                 THEN 1 ELSE 0 END)                     AS tickets_recovered,

        -- Worst single ticket recovery (most alarming signal)
        MIN(engagement_recovery_ratio)                  AS min_recovery_ratio

    FROM ticket_recovery
    WHERE resolved_date IS NOT NULL
      AND pre_ticket_quantity > 0
    GROUP BY 1
)

SELECT
    s.customer_id,
    s.total_tickets,
    s.open_tickets,
    s.resolved_tickets,
    s.critical_tickets,
    s.high_tickets,
    s.billing_tickets,
    s.account_tickets,
    s.open_high_priority_tickets,
    s.avg_satisfaction_score,
    s.min_satisfaction_score,
    s.avg_resolution_hours,
    s.max_resolution_hours,

    -- Post-ticket engagement signals
    COALESCE(e.avg_engagement_recovery, 1.0)            AS avg_engagement_recovery,
    COALESCE(e.tickets_not_recovered, 0)                AS tickets_not_recovered,
    COALESCE(e.tickets_recovered, 0)                    AS tickets_recovered,
    e.min_recovery_ratio,

    -- Risk flags
    (s.open_high_priority_tickets > 0)                  AS has_open_critical_ticket,
    (s.min_satisfaction_score <= 2)                     AS has_very_low_satisfaction,
    (s.billing_tickets + s.account_tickets >= 2)        AS has_billing_friction,
    (COALESCE(e.avg_engagement_recovery, 1.0) < 0.5)    AS poor_post_ticket_recovery,
    (COALESCE(e.tickets_not_recovered, 0) > 0
     AND s.open_tickets > 0)                            AS unresolved_with_no_recovery

FROM customer_support s
LEFT JOIN customer_engagement e
    ON s.customer_id = e.customer_id
