-- mart_support_summary
-- Support operations metrics per month and region
-- Connects to health score to show support volume vs churn risk correlation
-- Uses: safe_divide macro

WITH tickets AS (
    SELECT * FROM {{ ref('fct_support_tickets') }}
),

monthly_region AS (
    SELECT
        DATE_TRUNC('month', created_date)               AS ticket_month,
        region,

        COUNT(*)                                        AS total_tickets,
        COUNT(CASE WHEN is_open           THEN 1 END)   AS open_tickets,
        COUNT(CASE WHEN is_resolved       THEN 1 END)   AS resolved_tickets,
        COUNT(CASE WHEN is_high_priority  THEN 1 END)   AS high_priority_tickets,

        -- Category breakdown
        COUNT(CASE WHEN category = 'billing'  THEN 1 END) AS billing_tickets,
        COUNT(CASE WHEN category = 'technical' THEN 1 END) AS technical_tickets,
        COUNT(CASE WHEN category = 'account'   THEN 1 END) AS account_tickets,

        -- Resolution metrics
        ROUND(AVG(CASE WHEN is_resolved
                       THEN resolution_hours END), 1)   AS avg_resolution_hours,
        ROUND(AVG(CASE WHEN is_high_priority AND is_resolved
                       THEN resolution_hours END), 1)   AS avg_critical_resolution_hours,

        -- Satisfaction
        ROUND(AVG(satisfaction_score), 2)               AS avg_satisfaction,
        COUNT(CASE WHEN satisfaction_score <= 2 THEN 1 END) AS low_satisfaction_count,

        -- Resolution rate using macro
        ROUND(
            {{ safe_divide(
                'COUNT(CASE WHEN is_resolved THEN 1 END)::DECIMAL',
                'COUNT(*)',
                '0'
            ) }} * 100
        , 1)                                            AS resolution_rate_pct,

        COUNT(DISTINCT customer_id)                     AS unique_customers_with_tickets

    FROM tickets
    WHERE created_date IS NOT NULL
    GROUP BY 1, 2
),

-- All regions combined
monthly_total AS (
    SELECT
        ticket_month,
        'ALL'                                           AS region,
        SUM(total_tickets)                              AS total_tickets,
        SUM(open_tickets)                               AS open_tickets,
        SUM(resolved_tickets)                           AS resolved_tickets,
        SUM(high_priority_tickets)                      AS high_priority_tickets,
        SUM(billing_tickets)                            AS billing_tickets,
        SUM(technical_tickets)                          AS technical_tickets,
        SUM(account_tickets)                            AS account_tickets,
        ROUND(AVG(avg_resolution_hours), 1)             AS avg_resolution_hours,
        ROUND(AVG(avg_critical_resolution_hours), 1)    AS avg_critical_resolution_hours,
        ROUND(AVG(avg_satisfaction), 2)                 AS avg_satisfaction,
        SUM(low_satisfaction_count)                     AS low_satisfaction_count,
        ROUND(
            {{ safe_divide('SUM(resolved_tickets)::DECIMAL', 'SUM(total_tickets)', '0') }} * 100
        , 1)                                            AS resolution_rate_pct,
        SUM(unique_customers_with_tickets)              AS unique_customers_with_tickets
    FROM monthly_region
    GROUP BY 1, 2
)

SELECT * FROM monthly_region
UNION ALL
SELECT * FROM monthly_total
ORDER BY ticket_month, region
