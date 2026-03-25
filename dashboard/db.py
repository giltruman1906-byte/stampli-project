"""
db.py — DuckDB connection + query helpers
All queries go through here. Region filter is applied automatically based on user role.
"""
import duckdb
import pandas as pd
from pathlib import Path

DB_PATH = Path(__file__).parent.parent / "nexusflow.duckdb"


def get_conn():
    return duckdb.connect(str(DB_PATH), read_only=True)


def query(sql: str, params: list = None) -> pd.DataFrame:
    with get_conn() as con:
        if params:
            return con.execute(sql, params).df()
        return con.execute(sql).df()


def region_filter(role: str, region: str, alias: str = "") -> str:
    """
    Returns a SQL WHERE clause fragment for region-based RLS.
    regional_manager role is restricted to their assigned region.
    All other roles see all data.
    alias: optional table alias prefix e.g. 'c.' → 'c.region'
    """
    col = f"{alias}region" if alias else "region"
    if role == "regional_manager":
        return f"{col} = '{region}'"
    return "1=1"


# ── Revenue queries ───────────────────────────────────────────────────────────

def get_mrr_trend(role: str, region: str) -> pd.DataFrame:
    rf = region_filter(role, region)
    return query(f"""
        SELECT
            mrr_month,
            SUM(mrr)            AS total_mrr,
            SUM(new_mrr_amount) AS new_mrr,
            SUM(expansion_mrr)  AS expansion_mrr,
            SUM(contraction_mrr) AS contraction_mrr,
            SUM(churn_mrr_amount) AS churn_mrr,
            COUNT(DISTINCT CASE WHEN mrr > 0 THEN customer_id END) AS active_customers
        FROM main_marts.mart_mrr
        WHERE {rf}
        GROUP BY 1 ORDER BY 1
    """)


def get_arr_by_region(role: str, region: str) -> pd.DataFrame:
    """ARR by region = March MRR × 12. Used for the revenue overview chart."""
    rf = region_filter(role, region)
    return query(f"""
        SELECT
            region,
            ROUND(SUM(mrr) * 12, 0)  AS arr,
            ROUND(SUM(mrr), 0)        AS mrr
        FROM main_marts.mart_mrr
        WHERE mrr_month = '2024-03-01'
          AND {rf}
        GROUP BY region
        ORDER BY arr DESC
    """)


def get_nrr_waterfall(role: str, region: str) -> pd.DataFrame:
    r = f"'{region}'" if role == "regional_manager" else "'ALL'"
    return query(f"""
        SELECT mrr_month, region,
               starting_mrr, new_mrr, expansion_mrr,
               contraction_mrr, churn_mrr, ending_mrr,
               nrr_pct, grr_pct, churn_rate_pct,
               active_customers, new_customers, churned_customers
        FROM main_marts.mart_nrr
        WHERE region = {r}
        ORDER BY mrr_month
    """)


def get_expansion_breakdown(role: str, region: str) -> pd.DataFrame:
    rf = region_filter(role, region)
    return query(f"""
        SELECT
            DATE_TRUNC('month', effective_date)         AS month,
            amendment_type,
            COUNT(*)                                    AS deals,
            ROUND(SUM(CASE WHEN mrr_delta > 0 THEN mrr_delta ELSE 0 END), 0) AS mrr_gained,
            ROUND(SUM(CASE WHEN mrr_delta < 0 THEN ABS(mrr_delta) ELSE 0 END), 0) AS mrr_lost,
            ROUND(SUM(mrr_delta), 0)                   AS net_delta
        FROM main_core.fct_contract_amendments
        WHERE effective_date BETWEEN '2024-01-01' AND '2024-03-31'
          AND {rf}
        GROUP BY 1, 2
        ORDER BY 1, net_delta DESC
    """)


# ── Customer / health score queries ──────────────────────────────────────────

def get_health_score_table(role: str, region: str) -> pd.DataFrame:
    rf = region_filter(role, region)
    return query(f"""
        SELECT
            customer_id,
            company_name,
            region,
            account_tier,
            health_score,
            risk_tier,
            current_mrr,
            mrr_at_risk,
            usage_score,
            support_score,
            financial_score,
            is_silent_churn,
            has_open_critical_ticket,
            has_overdue_invoices,
            has_recent_downgrade,
            is_expansion_candidate,
            total_events_3m,
            feb_mar_pct_change,
            avg_satisfaction_score,
            open_tickets
        FROM main_marts.mart_customer_health_score
        WHERE {rf}
        ORDER BY health_score ASC, mrr_at_risk DESC
    """)


def get_risk_summary(role: str, region: str) -> pd.DataFrame:
    rf = region_filter(role, region)
    return query(f"""
        SELECT
            risk_tier,
            COUNT(*)                        AS customers,
            ROUND(SUM(current_mrr), 0)      AS total_mrr,
            ROUND(SUM(mrr_at_risk), 0)      AS mrr_at_risk,
            ROUND(AVG(health_score), 1)     AS avg_score
        FROM main_marts.mart_customer_health_score
        WHERE {rf}
        GROUP BY 1
        ORDER BY avg_score ASC
    """)


# ── Support queries ───────────────────────────────────────────────────────────

def get_support_summary(role: str, region: str) -> pd.DataFrame:
    r = f"'{region}'" if role == "regional_manager" else "'ALL'"
    return query(f"""
        SELECT ticket_month, region,
               total_tickets, open_tickets, resolved_tickets,
               high_priority_tickets, billing_tickets,
               avg_resolution_hours, avg_satisfaction,
               resolution_rate_pct, low_satisfaction_count,
               unique_customers_with_tickets
        FROM main_marts.mart_support_summary
        WHERE region = {r}
        ORDER BY ticket_month
    """)


def get_open_tickets(role: str, region: str) -> pd.DataFrame:
    rf = region_filter(role, region)
    return query(f"""
        SELECT
            ticket_id, customer_id, company_name, region,
            category, priority, channel,
            created_date, resolution_hours,
            satisfaction_score, is_high_priority
        FROM main_core.fct_support_tickets
        WHERE is_open = true
          AND {rf}
        ORDER BY is_high_priority DESC, created_date ASC
    """)


# ── Product / Usage queries ────────────────────────────────────────────────────

def get_usage_monthly_trend(role: str, region: str) -> pd.DataFrame:
    """Monthly totals per metric — for the trend line chart."""
    rf = region_filter(role, region)
    return query(f"""
        SELECT
            DATE_TRUNC('month', event_date)   AS month,
            metric_name,
            COUNT(DISTINCT customer_id)        AS active_customers,
            ROUND(SUM(quantity), 0)            AS total_quantity,
            ROUND(AVG(quantity), 1)            AS avg_quantity
        FROM main_core.fct_usage_events
        WHERE {rf}
        GROUP BY 1, 2
        ORDER BY 1, 2
    """)


def get_usage_kpis(role: str, region: str) -> pd.DataFrame:
    """Latest-month product KPIs: MAU, avg feature breadth, silent churn count."""
    rf = region_filter(role, region, alias="u.")
    return query(f"""
        SELECT
            COUNT(DISTINCT u.customer_id)                              AS mau,
            ROUND(AVG(u.max_feature_breadth), 1)                      AS avg_feature_breadth,
            SUM(CASE WHEN u.is_silent_churn  THEN 1 ELSE 0 END)       AS silent_churn_customers,
            SUM(CASE WHEN u.is_consistently_declining THEN 1 ELSE 0 END) AS declining_customers,
            ROUND(AVG(u.total_events_3m), 0)                          AS avg_events_per_customer,
            ROUND(AVG(u.mar_users), 1)                                AS avg_active_users_mar
        FROM main_intermediate.int_customer_usage_stats u
        LEFT JOIN main_core.dim_customers c ON u.customer_id = c.customer_id
        WHERE {rf}
    """)


def get_usage_customer_detail(role: str, region: str) -> pd.DataFrame:
    """Per-customer usage stats joined with MRR and health score — for scatter + risk table."""
    rf = region_filter(role, region, alias="c.")
    return query(f"""
        SELECT
            u.customer_id,
            u.company_name,
            c.region,
            u.account_tier,
            u.jan_events, u.feb_events, u.mar_events,
            u.total_events_3m,
            u.max_feature_breadth,
            u.jan_feb_pct_change,
            u.feb_mar_pct_change,
            u.is_silent_churn,
            u.is_consistently_declining,
            u.sharp_drop_last_month,
            u.zero_usage_months,
            COALESCE(h.current_mrr, 0)          AS current_mrr,
            COALESCE(h.health_score, 0)          AS health_score,
            COALESCE(h.risk_tier, 'unknown')     AS risk_tier,
            COALESCE(h.mrr_at_risk, 0)           AS mrr_at_risk,
            ROUND(u.mar_users, 0)                AS mar_active_users,
            ROUND(u.mar_api, 0)                  AS mar_api_calls
        FROM main_intermediate.int_customer_usage_stats u
        LEFT JOIN main_core.dim_customers              c ON u.customer_id = c.customer_id
        LEFT JOIN main_marts.mart_customer_health_score h ON u.customer_id = h.customer_id
        WHERE {rf}
        ORDER BY u.total_events_3m ASC
    """)


def get_support_by_category(role: str, region: str) -> pd.DataFrame:
    """Ticket counts, avg resolution hours, avg satisfaction — per category × region."""
    rf = region_filter(role, region)
    return query(f"""
        SELECT
            category,
            region,
            COUNT(*)                                                      AS total_tickets,
            ROUND(AVG(resolution_hours), 1)                              AS avg_resolution_hours,
            ROUND(AVG(satisfaction_score), 2)                            AS avg_satisfaction,
            SUM(CASE WHEN is_high_priority THEN 1 ELSE 0 END)            AS high_priority_tickets
        FROM main_core.fct_support_tickets
        WHERE {rf}
        GROUP BY 1, 2
        ORDER BY total_tickets DESC
    """)


def get_feature_breadth_dist_by_month(role: str, region: str) -> pd.DataFrame:
    """Per-month histogram: how many customers used N distinct metrics."""
    rf = region_filter(role, region, alias="c.")
    return query(f"""
        WITH per_customer AS (
            SELECT
                u.customer_id,
                DATE_TRUNC('month', u.event_date)    AS month,
                COUNT(DISTINCT u.metric_name)         AS feature_breadth
            FROM main_core.fct_usage_events u
            LEFT JOIN main_core.dim_customers c ON u.customer_id = c.customer_id
            WHERE u.event_date BETWEEN '2024-01-01' AND '2024-03-31'
              AND {rf}
            GROUP BY 1, 2
        )
        SELECT month,
               feature_breadth,
               COUNT(*) AS customers
        FROM per_customer
        GROUP BY 1, 2
        ORDER BY 1, 2
    """)


def get_post_ticket_engagement(role: str, region: str) -> pd.DataFrame:
    """Avg product usage before vs after ticket resolution — per customer."""
    rf = region_filter(role, region, alias="c.")
    return query(f"""
        SELECT
            s.customer_id,
            c.company_name,
            c.region,
            s.total_tickets,
            ROUND(s.avg_engagement_recovery, 2)   AS recovery_ratio,
            ROUND(s.tickets_not_recovered, 0)      AS tickets_not_recovered,
            s.has_open_critical_ticket,
            s.poor_post_ticket_recovery,
            s.unresolved_with_no_recovery,
            ROUND(s.avg_satisfaction_score, 1)     AS avg_satisfaction,
            COALESCE(h.current_mrr, 0)             AS current_mrr,
            COALESCE(h.risk_tier, 'unknown')        AS risk_tier
        FROM main_intermediate.int_customer_support_signals s
        LEFT JOIN main_core.dim_customers               c ON s.customer_id = c.customer_id
        LEFT JOIN main_marts.mart_customer_health_score h ON s.customer_id = h.customer_id
        WHERE s.total_tickets > 0
          AND {rf}
        ORDER BY s.avg_engagement_recovery ASC NULLS LAST
    """)
