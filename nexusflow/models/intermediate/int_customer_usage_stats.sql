-- int_customer_usage_stats
-- 3-month usage stats per customer with month-over-month trends
-- Signals: total usage, feature breadth, MoM velocity, silent churn flag
-- Ref date: 2024-03-31 (end of last batch)

WITH monthly_usage AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', event_date)                 AS usage_month,
        COUNT(*)                                        AS event_count,
        SUM(quantity)                                   AS total_quantity,
        COUNT(DISTINCT metric_name)                     AS distinct_metrics,
        SUM(CASE WHEN metric_name = 'api_calls'
                  OR metric_name = 'api_requests'
                 THEN quantity ELSE 0 END)              AS api_usage,
        SUM(CASE WHEN metric_name = 'active_users'
                 THEN quantity ELSE 0 END)              AS active_users,
        SUM(CASE WHEN metric_name = 'workflow_executions'
                 THEN quantity ELSE 0 END)              AS workflow_executions,
        SUM(CASE WHEN metric_name = 'storage_used_gb'
                 THEN quantity ELSE 0 END)              AS storage_gb
    FROM {{ ref('fct_usage_events') }}
    GROUP BY 1, 2
),

-- Pivot into jan/feb/mar columns for easy comparison
pivoted AS (
    SELECT
        customer_id,

        -- January
        MAX(CASE WHEN usage_month = '2024-01-01' THEN event_count    ELSE 0 END) AS jan_events,
        MAX(CASE WHEN usage_month = '2024-01-01' THEN total_quantity  ELSE 0 END) AS jan_quantity,
        MAX(CASE WHEN usage_month = '2024-01-01' THEN distinct_metrics ELSE 0 END) AS jan_feature_breadth,
        MAX(CASE WHEN usage_month = '2024-01-01' THEN api_usage        ELSE 0 END) AS jan_api,
        MAX(CASE WHEN usage_month = '2024-01-01' THEN active_users     ELSE 0 END) AS jan_users,

        -- February
        MAX(CASE WHEN usage_month = '2024-02-01' THEN event_count    ELSE 0 END) AS feb_events,
        MAX(CASE WHEN usage_month = '2024-02-01' THEN total_quantity  ELSE 0 END) AS feb_quantity,
        MAX(CASE WHEN usage_month = '2024-02-01' THEN distinct_metrics ELSE 0 END) AS feb_feature_breadth,
        MAX(CASE WHEN usage_month = '2024-02-01' THEN api_usage        ELSE 0 END) AS feb_api,
        MAX(CASE WHEN usage_month = '2024-02-01' THEN active_users     ELSE 0 END) AS feb_users,

        -- March
        MAX(CASE WHEN usage_month = '2024-03-01' THEN event_count    ELSE 0 END) AS mar_events,
        MAX(CASE WHEN usage_month = '2024-03-01' THEN total_quantity  ELSE 0 END) AS mar_quantity,
        MAX(CASE WHEN usage_month = '2024-03-01' THEN distinct_metrics ELSE 0 END) AS mar_feature_breadth,
        MAX(CASE WHEN usage_month = '2024-03-01' THEN api_usage        ELSE 0 END) AS mar_api,
        MAX(CASE WHEN usage_month = '2024-03-01' THEN active_users     ELSE 0 END) AS mar_users

    FROM monthly_usage
    GROUP BY 1
),

with_trends AS (
    SELECT
        *,

        -- Total 3-month usage
        (jan_events + feb_events + mar_events)          AS total_events_3m,
        (jan_quantity + feb_quantity + mar_quantity)    AS total_quantity_3m,

        -- Peak feature breadth across 3 months (stickiness indicator)
        GREATEST(jan_feature_breadth,
                 feb_feature_breadth,
                 mar_feature_breadth)                   AS max_feature_breadth,

        -- MoM event trend: positive = growing, negative = declining
        (feb_events - jan_events)                       AS jan_to_feb_delta,
        (mar_events - feb_events)                       AS feb_to_mar_delta,

        -- Overall 3-month slope: positive means usage growing overall
        (mar_events - jan_events)                       AS usage_slope,

        -- MoM % change Jan→Feb (null-safe)
        CASE WHEN jan_events > 0
             THEN ROUND(100.0 * (feb_events - jan_events) / jan_events, 1)
             ELSE NULL
        END                                             AS jan_feb_pct_change,

        -- MoM % change Feb→Mar
        CASE WHEN feb_events > 0
             THEN ROUND(100.0 * (mar_events - feb_events) / feb_events, 1)
             ELSE NULL
        END                                             AS feb_mar_pct_change,

        -- Months with zero usage out of 3
        (CASE WHEN jan_events = 0 THEN 1 ELSE 0 END +
         CASE WHEN feb_events = 0 THEN 1 ELSE 0 END +
         CASE WHEN mar_events = 0 THEN 1 ELSE 0 END)   AS zero_usage_months

    FROM pivoted
)

SELECT
    u.customer_id,
    c.company_name,
    c.region,
    c.account_tier,

    -- Monthly breakdown
    jan_events,
    feb_events,
    mar_events,
    jan_quantity,
    feb_quantity,
    mar_quantity,
    jan_api,
    feb_api,
    mar_api,
    jan_users,
    feb_users,
    mar_users,

    -- Totals
    total_events_3m,
    total_quantity_3m,
    max_feature_breadth,

    -- Trend signals
    jan_to_feb_delta,
    feb_to_mar_delta,
    usage_slope,
    jan_feb_pct_change,
    feb_mar_pct_change,
    zero_usage_months,

    -- Derived risk flags
    (mar_events = 0 AND total_events_3m > 0)            AS is_silent_churn,
    (usage_slope < 0 AND feb_to_mar_delta < 0)          AS is_consistently_declining,
    (zero_usage_months >= 2)                            AS has_sparse_usage,
    (max_feature_breadth = 1)                           AS is_single_feature,
    (feb_mar_pct_change < -50)                          AS sharp_drop_last_month

FROM with_trends u
LEFT JOIN {{ ref('dim_customers') }} c
    ON u.customer_id = c.customer_id
