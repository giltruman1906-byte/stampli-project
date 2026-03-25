"""
NexusFlow Analytics Dashboard
Streamlit app with RBAC — 4 roles, 3 tabs, DuckDB backend
"""
import streamlit as st
import plotly.graph_objects as go
import plotly.express as px
import pandas as pd

from auth import authenticate, can_see_tab, can_export, ROLE_LABELS
from db import (
    get_mrr_trend, get_nrr_waterfall, get_expansion_breakdown,
    get_arr_by_region,
    get_health_score_table, get_risk_summary,
    get_support_summary, get_open_tickets, get_support_by_category,
    get_usage_kpis, get_usage_monthly_trend,
    get_usage_customer_detail, get_post_ticket_engagement,
    get_feature_breadth_dist_by_month,
)

st.set_page_config(
    page_title="NexusFlow Analytics",
    page_icon="📊",
    layout="wide",
    initial_sidebar_state="expanded",
)

# ── Login ─────────────────────────────────────────────────────────────────────

def login_screen():
    st.title("📊 NexusFlow Analytics")
    st.markdown("---")
    col1, col2, col3 = st.columns([1, 2, 1])
    with col2:
        st.subheader("Sign in")
        username = st.text_input("Username")
        password = st.text_input("Password", type="password")
        if st.button("Login", use_container_width=True, type="primary"):
            user = authenticate(username, password)
            if user:
                st.session_state["user"] = user
                st.rerun()
            else:
                st.error("Invalid username or password")
        st.markdown("---")
        st.caption("Demo credentials: admin/admin123 · analyst/analyst123 · mgr_na/na123 · viewer/viewer123")


if "user" not in st.session_state:
    login_screen()
    st.stop()

user = st.session_state["user"]
role = user["role"]
region = user["region"]

# ── Sidebar ───────────────────────────────────────────────────────────────────

with st.sidebar:
    st.markdown(f"### 📊 NexusFlow")
    st.markdown(f"**{user['name']}**")
    st.markdown(f"{ROLE_LABELS[role]}")
    if role == "regional_manager":
        st.markdown(f"🌍 Region: **{region}**")
    st.markdown("---")
    if st.button("Logout", use_container_width=True):
        del st.session_state["user"]
        st.rerun()

# ── Tab routing ───────────────────────────────────────────────────────────────

available_tabs = []
tab_labels = []

if can_see_tab(role, "revenue"):
    available_tabs.append("revenue")
    tab_labels.append("💰 Revenue")
if can_see_tab(role, "customers"):
    available_tabs.append("customers")
    tab_labels.append("🏢 Customers")
if can_see_tab(role, "support"):
    available_tabs.append("support")
    tab_labels.append("🎫 Support")
if can_see_tab(role, "product"):
    available_tabs.append("product")
    tab_labels.append("📈 Product")

tabs = st.tabs(tab_labels)

# ── REVENUE TAB ───────────────────────────────────────────────────────────────

if "revenue" in available_tabs:
    with tabs[available_tabs.index("revenue")]:

        # Load data
        nrr_df  = get_nrr_waterfall(role, region)
        arr_df  = get_arr_by_region(role, region)

        # Use last meaningful NRR month (skip Jan baseline which has no prior period)
        nrr_meaningful = nrr_df[nrr_df["starting_mrr"] > 0] if not nrr_df.empty else nrr_df
        latest = nrr_meaningful.iloc[-1] if not nrr_meaningful.empty else None
        prev   = nrr_meaningful.iloc[-2] if len(nrr_meaningful) > 1 else None

        def calc_nrr(row):
            """Ending-based NRR: (ending - new) / starting. More reliable than amendment formula."""
            s = float(row["starting_mrr"])
            if s <= 0:
                return None
            return round((float(row["ending_mrr"]) - float(row["new_mrr"])) / s * 100, 1)

        latest_month = pd.to_datetime(latest["mrr_month"]).strftime("%b %Y") if latest is not None else "—"

        # ── KPI row ──────────────────────────────────────────────────────────
        k1, k2, k3, k4 = st.columns(4)
        if latest is not None:
            # MRR delta — sign must come BEFORE $ so Streamlit reads direction correctly
            mrr_delta   = latest["ending_mrr"] - prev["ending_mrr"] if prev is not None else None
            churn_delta = latest["churn_mrr"]  - prev["churn_mrr"]  if prev is not None else None
            cust_delta  = int(latest["churned_customers"]) - int(prev["churned_customers"]) if prev is not None else None

            k1.metric(
                f"Ending MRR ({latest_month})",
                f"${latest['ending_mrr']:,.0f}",
                delta=f"{'-' if mrr_delta < 0 else '+'}${abs(mrr_delta):,.0f}" if mrr_delta is not None else None,
            )
            latest_nrr = calc_nrr(latest)
            prev_nrr   = calc_nrr(prev) if prev is not None else None
            k2.metric(
                f"NRR ({latest_month})",
                f"{latest_nrr:.1f}%" if latest_nrr is not None else "—",
                delta=f"{latest_nrr - prev_nrr:+.1f}pp" if (latest_nrr is not None and prev_nrr is not None) else None,
                delta_color="normal",
            )
            k3.metric(
                f"Churn MRR ({latest_month})",
                f"${latest['churn_mrr']:,.0f}",
                delta=f"{'-' if churn_delta < 0 else '+'}${abs(churn_delta):,.0f}" if churn_delta is not None else None,
                delta_color="inverse",
            )
            k4.metric(
                f"Churned Customers ({latest_month})",
                f"{int(latest['churned_customers'])}",
                delta=f"{cust_delta:+d}" if cust_delta is not None else None,
                delta_color="inverse",
            )

        # Revenue narrative
        if not nrr_df.empty:
            feb = nrr_df[nrr_df["mrr_month"].astype(str).str.startswith("2024-02")]
            mar = nrr_df[nrr_df["mrr_month"].astype(str).str.startswith("2024-03")]
            if not mar.empty and not feb.empty:
                mar_row = mar.iloc[0]; feb_row = feb.iloc[0]
                feb_nrr = calc_nrr(feb_row)
                mar_nrr = calc_nrr(mar_row)
                churn_pct = (mar_row["churn_mrr"] - feb_row["churn_mrr"]) / feb_row["churn_mrr"] * 100 if feb_row["churn_mrr"] > 0 else 0
                st.info(
                    f"**Revenue Snapshot (Jan–Mar 2024):** "
                    f"Feb NRR **{feb_nrr:.1f}%** (upgrades drove "
                    f"${feb_row['expansion_mrr']:,.0f} in amendments, zero new logos). "
                    f"March NRR **{mar_nrr:.1f}%** — churn MRR jumped "
                    f"**+{churn_pct:.0f}%** to ${mar_row['churn_mrr']:,.0f} "
                    f"({int(mar_row['churned_customers'])} customers lost). "
                    f"No new logos in Feb or Mar — all growth is upsell."
                )

        st.markdown("---")
        col_left, col_right = st.columns(2)

        # ARR by Region (replaces flat MRR trend)
        with col_left:
            st.subheader("ARR by Region (Mar 2024 run-rate)")
            st.caption("Annual Run-Rate Revenue = March MRR × 12")
            if not arr_df.empty:
                total_arr = arr_df["arr"].sum()
                fig = px.bar(
                    arr_df, x="region", y="arr",
                    color="region",
                    text=arr_df["arr"].apply(lambda x: f"${x/1e6:.2f}M"),
                    color_discrete_map={"NA": "#2563eb", "EMEA": "#7c3aed", "APAC": "#0891b2"},
                    labels={"arr": "ARR ($)", "region": "Region"},
                    height=320,
                )
                fig.update_traces(textposition="outside")
                fig.update_layout(
                    margin=dict(l=0, r=0, t=10, b=0),
                    yaxis_tickformat="$,.0f",
                    showlegend=False,
                    yaxis_title="ARR ($)",
                )
                st.plotly_chart(fig, use_container_width=True)
                st.caption(f"Total ARR: **${total_arr/1e6:.2f}M**")

        # NRR Waterfall chart — latest month
        with col_right:
            st.subheader(f"MRR Waterfall ({latest_month})")
            if not nrr_df.empty and latest is not None:
                s        = float(latest["starting_mrr"])
                n        = float(latest["new_mrr"])
                exp      = float(latest["expansion_mrr"])
                con      = float(latest["contraction_mrr"])
                chu      = float(latest["churn_mrr"])
                end_act  = float(latest["ending_mrr"])
                # Timing adjustment bridges the gap between amendment-based movements
                # and actual subscription MRR (LIM-004)
                adj = end_act - (s + n + exp - con - chu)

                x_vals = ["Starting", "New", "Expansion", "Contraction", "Churn"]
                m_vals = ["absolute", "relative", "relative", "relative", "relative"]
                y_vals = [s, n, exp, -con, -chu]

                if abs(adj) > 1:          # only show if non-trivial
                    x_vals.append("Timing Adj")
                    m_vals.append("relative")
                    y_vals.append(adj)

                x_vals.append("Ending")
                m_vals.append("total")
                y_vals.append(end_act)

                fig = go.Figure(go.Waterfall(
                    orientation="v",
                    measure=m_vals, x=x_vals, y=y_vals,
                    connector={"line": {"color": "rgb(63,63,63)"}},
                    increasing={"marker": {"color": "#22c55e"}},
                    decreasing={"marker": {"color": "#ef4444"}},
                    totals={"marker": {"color": "#2563eb"}},
                    texttemplate="$%{y:,.0f}",
                    textposition="outside",
                ))
                fig.update_layout(
                    height=320, margin=dict(l=0, r=0, t=10, b=0),
                    yaxis_tickformat="$,.0f", showlegend=False,
                )
                st.plotly_chart(fig, use_container_width=True)
                if abs(adj) > 1:
                    st.caption(f"*Timing Adj ${adj:+,.0f}: gap between contract amendment dates and subscription MRR records (LIM-004).")

        # ── NRR table ─────────────────────────────────────────────────────────
        st.subheader("NRR Waterfall by Month")
        st.caption(
            "**Starting MRR** = prior month ending MRR. "
            "**New** = subscriptions started this month. "
            "**Expansion** = upgrades + add-ons + discount removals. "
            "**Contraction** = downgrades + price reductions. "
            "**Churn** = subscriptions fully ended. "
            "**Ending** = Starting + New + Expansion − Contraction − Churn. "
            "January is the opening baseline — NRR not applicable (no prior month)."
        )
        if not nrr_df.empty:
            tbl = nrr_df.copy()
            tbl["month"] = pd.to_datetime(tbl["mrr_month"]).dt.strftime("%b %Y")

            def fmt_usd(x): return f"${x:,.0f}" if pd.notna(x) else "—"
            def fmt_pct(x): return f"{x:.1f}%" if pd.notna(x) else "—"

            rows = []
            for _, r in tbl.iterrows():
                is_jan = r["month"] == "Jan 2024"
                if is_jan:
                    row_start = 0.0
                    row_new   = float(r["ending_mrr"])
                    row_exp = row_con = row_chu = 0.0
                    row_end   = float(r["ending_mrr"])
                    nrr_disp  = "—"
                    grr_disp  = "—"
                    chr_disp  = "—"
                    adj = 0.0
                else:
                    row_start = float(r["starting_mrr"])
                    row_new   = float(r["new_mrr"])
                    row_exp   = float(r["expansion_mrr"])
                    row_con   = float(r["contraction_mrr"])
                    row_chu   = float(r["churn_mrr"])
                    row_end   = float(r["ending_mrr"])
                    adj = row_end - (row_start + row_new + row_exp - row_con - row_chu)
                    # NRR/GRR from actual subscription MRR (not amendment-formula)
                    # dim_subscriptions.mrr stores current price so amendment formula double-counts
                    if row_start > 0:
                        nrr_val = (row_end - row_new) / row_start * 100
                        grr_val = (row_start - row_con - row_chu) / row_start * 100
                        chr_val = row_chu / row_start * 100
                        nrr_disp = f"{nrr_val:.1f}%"
                        grr_disp = f"{grr_val:.1f}%"
                        chr_disp = f"{chr_val:.2f}%"
                    else:
                        nrr_disp = grr_disp = chr_disp = "—"

                row = {
                    "Period":       r["month"] + (" (opening)" if is_jan else ""),
                    "Starting MRR": fmt_usd(row_start),
                    "New MRR":      fmt_usd(row_new),
                    "Expansion":    fmt_usd(row_exp),
                    "Contraction":  fmt_usd(row_con),
                    "Churn MRR":    fmt_usd(row_chu),
                    "Timing Adj":   f"{adj:+,.0f}" if abs(adj) > 10 else "—",
                    "Ending MRR":   fmt_usd(row_end),
                    "NRR %":        nrr_disp,
                    "GRR %":        grr_disp,
                    "Churn Rate %": chr_disp,
                }
                rows.append(row)

            st.dataframe(pd.DataFrame(rows), use_container_width=True, hide_index=True)
            st.caption(
                "NRR = (Ending − New) ÷ Starting. "
                "GRR = (Ending − New − Expansion) ÷ Starting. "
                "**Timing Adj** = gap between amendment effective dates and subscription MRR records "
                "(dim_subscriptions.mrr stores current plan price, not historical). "
                "Jan = opening baseline."
            )

        # Expansion breakdown
        st.subheader("MRR Movement by Amendment Type")
        st.caption(
            "**upgrade** = customer moved to higher plan tier · "
            "**add_on** = customer added a new product/feature · "
            "**cancellation** = a previously granted discount was removed (net positive) · "
            "**downgrade** = customer moved to a lower plan tier · "
            "**price_override** = manual price reduction · "
            "**renewal** = contract renewal with term adjustments. "
            "Note: 'cancellation' here is a CONTRACT AMENDMENT (removing a concession), not subscription churn."
        )
        exp_df = get_expansion_breakdown(role, region)
        if not exp_df.empty:
            exp_df["month"] = pd.to_datetime(exp_df["month"]).dt.strftime("%b %Y")

            # Build lookup from nrr_df so summary cards match the NRR table exactly
            nrr_lookup = {
                pd.to_datetime(r["mrr_month"]).strftime("%b %Y"): r
                for _, r in nrr_df.iterrows()
            }

            ALL_MONTHS = ["Jan 2024", "Feb 2024", "Mar 2024"]
            summary_cols = st.columns(3)
            for i, mon in enumerate(ALL_MONTHS):
                mon_df = exp_df[exp_df["month"] == mon]
                nrr_row = nrr_lookup.get(mon)
                with summary_cols[i]:
                    st.markdown(f"**{mon}**")
                    if mon == "Jan 2024":
                        # Jan is the opening baseline — no prior month so waterfall movements are undefined.
                        # Amendments DID occur but can't be placed in the waterfall (no starting MRR).
                        st.caption("Opening baseline — not in NRR waterfall")
                        if not mon_df.empty:
                            jan_exp = mon_df["mrr_gained"].sum()
                            jan_con = mon_df["mrr_lost"].sum()
                            st.markdown(f"*Amendments: +${jan_exp:,.0f} / −${jan_con:,.0f}*")
                    elif nrr_row is not None:
                        # Use mart_nrr values — same source as the NRR table above
                        expansion_total   = float(nrr_row["expansion_mrr"])
                        contraction_total = float(nrr_row["contraction_mrr"])
                        top_exp = mon_df.loc[mon_df["mrr_gained"].idxmax(), "amendment_type"] if not mon_df.empty and expansion_total > 0 else "—"
                        top_con = mon_df.loc[mon_df["mrr_lost"].idxmax(),   "amendment_type"] if not mon_df.empty and contraction_total > 0 else "—"
                        st.markdown(f"↑ Expansion: **${expansion_total:,.0f}** (led by *{top_exp}*)")
                        st.markdown(f"↓ Contraction: **${contraction_total:,.0f}** (led by *{top_con}*)")
                    else:
                        st.markdown("*No data*")

            fig = px.bar(
                exp_df, x="month", y="net_delta", color="amendment_type",
                barmode="group",
                category_orders={"month": ALL_MONTHS},
                color_discrete_map={
                    "upgrade": "#16a34a", "add_on": "#86efac",
                    "downgrade": "#dc2626", "cancellation": "#2563eb",
                    "renewal": "#94a3b8", "price_override": "#f59e0b",
                },
                labels={"net_delta": "Net MRR Impact ($)", "month": "Month", "amendment_type": "Amendment Type"},
                height=350,
            )
            fig.add_hline(y=0, line_dash="solid", line_color="black", line_width=1)
            fig.update_layout(margin=dict(l=0, r=0, t=10, b=0), yaxis_tickformat="$,.0f")
            st.plotly_chart(fig, use_container_width=True)

# ── CUSTOMERS TAB ─────────────────────────────────────────────────────────────

if "customers" in available_tabs:
    with tabs[available_tabs.index("customers")]:

        risk_df = get_risk_summary(role, region)
        health_df = get_health_score_table(role, region)

        # KPI tiles per risk tier
        if not risk_df.empty:
            cols = st.columns(len(risk_df))
            tier_emoji = {"critical": "🔴", "at_risk": "🟡", "healthy": "🟢"}
            for i, row in risk_df.iterrows():
                emoji = tier_emoji.get(row["risk_tier"], "")
                cols[i].metric(
                    f"{emoji} {row['risk_tier'].replace('_',' ').title()}",
                    f"{int(row['customers'])} customers",
                    f"${row['total_mrr']:,.0f} MRR",
                )

        mrr_at_risk_total = risk_df["mrr_at_risk"].sum() if not risk_df.empty else 0
        if mrr_at_risk_total > 0:
            st.error(f"⚠️ Total MRR at risk: **${mrr_at_risk_total:,.0f}**")

        st.markdown("---")
        col_left, col_right = st.columns(2)

        # Health score distribution
        with col_left:
            st.subheader("Health Score Distribution")
            if not health_df.empty:
                fig = px.histogram(
                    health_df, x="health_score", nbins=20,
                    color_discrete_sequence=["#2563eb"],
                    labels={"health_score": "Health Score", "count": "Customers"},
                    height=280,
                )
                fig.add_vline(x=30, line_dash="dash", line_color="red",    annotation_text="Critical")
                fig.add_vline(x=60, line_dash="dash", line_color="orange", annotation_text="At Risk")
                fig.update_layout(margin=dict(l=0, r=0, t=10, b=0), showlegend=False)
                st.plotly_chart(fig, use_container_width=True)

        # MRR at risk by region
        with col_right:
            st.subheader("MRR at Risk by Region")
            if not health_df.empty:
                region_risk = (
                    health_df[health_df["mrr_at_risk"] > 0]
                    .groupby("region")["mrr_at_risk"].sum()
                    .reset_index()
                    .sort_values("mrr_at_risk", ascending=False)
                )
                if not region_risk.empty:
                    fig = px.bar(
                        region_risk, x="region", y="mrr_at_risk",
                        color="region",
                        color_discrete_map={"NA": "#2563eb", "EMEA": "#7c3aed", "APAC": "#0891b2"},
                        labels={"mrr_at_risk": "MRR at Risk ($)", "region": "Region"},
                        height=280,
                    )
                    fig.update_layout(margin=dict(l=0, r=0, t=10, b=0),
                                      yaxis_tickformat="$,.0f", showlegend=False)
                    st.plotly_chart(fig, use_container_width=True)

        # Health score model explanation
        with st.expander("ℹ️ How the Health Score is calculated (0–100)", expanded=False):
            c1, c2, c3 = st.columns(3)
            c1.markdown(
                "**Usage Score (max 40 pts)**\n"
                "- Active in March: +10\n"
                "- Usage trend Jan→Mar: 0–15 pts\n"
                "  *(+15 growing · 0 flat · −15 declining)*\n"
                "- Feature breadth (≥4 metrics): +10\n"
                "- Used product within 14 days: +5\n"
                "- Silent churn (zero usage): −10\n"
            )
            c2.markdown(
                "**Support Score (max 30 pts)**\n"
                "- Base (no open critical): 15–20\n"
                "- Open critical ticket: −10\n"
                "- CSAT score 4–5: +8 · CSAT 1–2: −3\n"
                "- Post-ticket recovery ≥1×: +5\n"
                "- Poor post-ticket recovery: −3\n"
                "- Billing-related tickets: −5\n"
            )
            c3.markdown(
                "**Financial Score (max 30 pts)**\n"
                "- Active subscription: +15\n"
                "- Collection rate: 0–10 pts\n"
                "  *(≥95% full · <80% zero)*\n"
                "- MRR direction (upgrade): +5\n"
                "- Overdue invoices: −5\n"
                "- Repeated payment failures: −5\n"
                "- Recent downgrade: −3\n"
                "- Auto-renew off: −3\n"
            )
            st.caption(
                "**Risk tiers:** 🔴 Critical (≤30) · 🟡 At Risk (31–60) · 🟢 Healthy (61–100). "
                "**MRR at risk:** Critical = 100% of MRR · At Risk = 50% · Healthy = 0. "
                "**Expansion candidate:** score ≥70 AND feature breadth ≥4 AND no recent upgrade."
            )

        # Customer health table
        st.subheader("Customer Health Scores")
        st.caption("Sorted by risk — riskiest first. Click column headers to sort.")

        # Filters
        f1, f2, f3 = st.columns(3)
        tier_filter = f1.multiselect("Risk Tier", ["critical","at_risk","healthy"],
                                      default=["critical","at_risk","healthy"])
        region_opts = sorted(health_df["region"].dropna().unique()) if not health_df.empty else []
        region_filter_val = f2.multiselect("Region", region_opts, default=region_opts)
        show_expansion = f3.checkbox("Expansion candidates only", value=False)

        filtered = health_df.copy()
        if tier_filter:
            filtered = filtered[filtered["risk_tier"].isin(tier_filter)]
        if region_filter_val:
            filtered = filtered[filtered["region"].isin(region_filter_val)]
        if show_expansion:
            filtered = filtered[filtered["is_expansion_candidate"] == True]

        # Coerce nullable / numpy types that break Streamlit column rendering
        for bool_col in ["is_silent_churn", "has_open_critical_ticket", "has_overdue_invoices"]:
            if bool_col in filtered.columns:
                filtered[bool_col] = filtered[bool_col].fillna(False).astype(bool)
        # int32 → int64 so ProgressColumn renders correctly
        if "health_score" in filtered.columns:
            filtered["health_score"] = filtered["health_score"].astype(int)

        # Format for display
        display_cols = {
            "customer_id": "Customer ID",
            "company_name": "Company",
            "region": "Region",
            "account_tier": "Tier",
            "health_score": "Score",
            "risk_tier": "Risk",
            "current_mrr": "MRR",
            "mrr_at_risk": "MRR at Risk",
            "is_silent_churn": "Silent Churn",
            "has_open_critical_ticket": "Open Critical",
            "has_overdue_invoices": "Overdue Invoice",
            "feb_mar_pct_change": "Usage Trend %",
        }
        disp = filtered[list(display_cols.keys())].rename(columns=display_cols)
        disp["MRR"] = disp["MRR"].apply(lambda x: f"${x:,.0f}" if pd.notna(x) else "—")
        disp["MRR at Risk"] = disp["MRR at Risk"].apply(lambda x: f"${x:,.0f}" if pd.notna(x) else "—")
        disp["Usage Trend %"] = disp["Usage Trend %"].apply(lambda x: f"{x:+.1f}%" if pd.notna(x) else "—")

        st.dataframe(
            disp,
            use_container_width=True,
            hide_index=True,
            height=400,
            column_config={
                "Score": st.column_config.ProgressColumn("Score", min_value=0, max_value=100, format="%d"),
                "Silent Churn": st.column_config.CheckboxColumn("Silent Churn"),
                "Open Critical": st.column_config.CheckboxColumn("Open Critical"),
                "Overdue Invoice": st.column_config.CheckboxColumn("Overdue Invoice"),
            }
        )

        if can_export(role):
            csv = filtered.to_csv(index=False)
            st.download_button("⬇ Export CSV", csv, "customer_health.csv", "text/csv")

# ── SUPPORT TAB ───────────────────────────────────────────────────────────────

if "support" in available_tabs:
    with tabs[available_tabs.index("support")]:

        sup_df  = get_support_summary(role, region)
        open_df = get_open_tickets(role, region)
        cat_df  = get_support_by_category(role, region)

        # KPI row — total, open, high priority, avg satisfaction (no resolution rate)
        if not sup_df.empty:
            latest_sup = sup_df.iloc[-1]
            k1, k2, k3, k4 = st.columns(4)
            k1.metric("Total Tickets",       int(latest_sup["total_tickets"]))
            k2.metric("Open Tickets",        int(latest_sup["open_tickets"]))
            k3.metric("High Priority",       int(latest_sup["high_priority_tickets"]))
            k4.metric("Avg Satisfaction",    f"{latest_sup['avg_satisfaction']:.1f} / 10")

        st.markdown("---")

        # ── Category charts — shared region filter ─────────────────────────────
        st.subheader("Tickets by Category")
        region_opts_sup = sorted(cat_df["region"].dropna().unique()) if not cat_df.empty else []
        sel_region = st.selectbox(
            "Filter by Region",
            ["All regions"] + region_opts_sup,
            key="sup_region_filter",
        )

        cat_filtered = cat_df.copy()
        if sel_region != "All regions":
            cat_filtered = cat_filtered[cat_filtered["region"] == sel_region]

        # Aggregate across regions after filter
        if not cat_filtered.empty:
            cat_agg = (
                cat_filtered.groupby("category")
                .agg(
                    total_tickets=("total_tickets", "sum"),
                    avg_resolution_hours=("avg_resolution_hours", "mean"),
                    avg_satisfaction=("avg_satisfaction", "mean"),
                )
                .reset_index()
                .sort_values("total_tickets", ascending=False)
            )
            cat_agg["avg_resolution_hours"] = cat_agg["avg_resolution_hours"].round(1)
            cat_agg["avg_satisfaction"]      = cat_agg["avg_satisfaction"].round(2)

            col_left, col_right = st.columns(2)

            with col_left:
                st.caption("Ticket volume + avg resolution time per category")
                fig = go.Figure()
                fig.add_trace(go.Bar(
                    x=cat_agg["category"],
                    y=cat_agg["total_tickets"],
                    name="Tickets",
                    marker_color="#93c5fd",
                    yaxis="y",
                    text=cat_agg["total_tickets"],
                    textposition="outside",
                ))
                fig.add_trace(go.Scatter(
                    x=cat_agg["category"],
                    y=cat_agg["avg_resolution_hours"],
                    mode="lines+markers",
                    name="Avg Resolution Hrs",
                    line=dict(color="#ef4444", width=2),
                    yaxis="y2",
                ))
                fig.update_layout(
                    height=320,
                    margin=dict(l=0, r=0, t=10, b=0),
                    yaxis=dict(title="Tickets"),
                    yaxis2=dict(title="Avg Hrs", overlaying="y", side="right"),
                    legend=dict(orientation="h", y=1.12),
                    xaxis_tickangle=-30,
                )
                st.plotly_chart(fig, use_container_width=True)

            with col_right:
                st.caption("Ticket volume + avg customer satisfaction per category (1–10 scale)")
                fig = go.Figure()
                fig.add_trace(go.Bar(
                    x=cat_agg["category"],
                    y=cat_agg["total_tickets"],
                    name="Tickets",
                    marker_color="#93c5fd",
                    yaxis="y",
                    text=cat_agg["total_tickets"],
                    textposition="outside",
                ))
                fig.add_trace(go.Scatter(
                    x=cat_agg["category"],
                    y=cat_agg["avg_satisfaction"],
                    mode="lines+markers",
                    name="Avg Satisfaction",
                    line=dict(color="#f59e0b", width=2),
                    yaxis="y2",
                ))
                fig.update_layout(
                    height=320,
                    margin=dict(l=0, r=0, t=10, b=0),
                    yaxis=dict(title="Tickets"),
                    yaxis2=dict(title="Satisfaction (1–10)", overlaying="y", side="right", range=[0, 10]),
                    legend=dict(orientation="h", y=1.12),
                    xaxis_tickangle=-30,
                )
                st.plotly_chart(fig, use_container_width=True)

        # Open tickets table
        st.markdown("---")
        st.subheader(f"Open Tickets ({len(open_df)})")
        if not open_df.empty:
            # Add days open (using last date in dataset as reference)
            ref_date = pd.Timestamp("2024-03-31")
            open_df["days_open"] = (ref_date - pd.to_datetime(open_df["created_date"])).dt.days

            priority_filter = st.multiselect(
                "Priority", ["critical","high","medium","low"],
                default=["critical","high"]
            )
            filtered_tickets = open_df[open_df["priority"].isin(priority_filter)] if priority_filter else open_df
            st.dataframe(
                filtered_tickets[[
                    "ticket_id","company_name","region","category",
                    "priority","channel","created_date","days_open"
                ]].rename(columns={
                    "ticket_id": "Ticket", "company_name": "Company",
                    "region": "Region", "category": "Category",
                    "priority": "Priority", "channel": "Channel",
                    "created_date": "Created", "days_open": "Days Open",
                }),
                use_container_width=True, hide_index=True, height=350,
            )
        else:
            st.success("No open tickets matching filter.")

# ── PRODUCT TAB ───────────────────────────────────────────────────────────────

if "product" in available_tabs:
    with tabs[available_tabs.index("product")]:

        kpi_df      = get_usage_kpis(role, region)
        cust_df     = get_usage_customer_detail(role, region)
        pt_df       = get_post_ticket_engagement(role, region)
        breadth_df  = get_feature_breadth_dist_by_month(role, region)

        # Coerce nullable dtypes once
        for bool_col in ["is_silent_churn", "is_consistently_declining", "sharp_drop_last_month"]:
            if bool_col in cust_df.columns:
                cust_df[bool_col] = cust_df[bool_col].fillna(False).astype(bool)

        # ── KPI row ──────────────────────────────────────────────────────────
        if not kpi_df.empty:
            row = kpi_df.iloc[0]
            total_custs = len(cust_df)
            k1, k2, k3, k4 = st.columns(4)
            k1.metric(
                "Monthly Active Customers (Mar)",
                f"{int(row['mau'])} / {total_custs}",
                delta=f"{int(row['mau'])/total_custs*100:.1f}% engagement",
                delta_color="off",
            )
            k2.metric(
                "Avg Active Users / Customer",
                f"{row['avg_active_users_mar']:,.0f}",
            )
            k3.metric(
                "Silent Churn Risk",
                f"{int(row['silent_churn_customers'])} customers",
                delta="≥1 month with zero usage",
                delta_color="off",
            )
            k4.metric(
                "Consistently Declining Usage",
                f"{int(row['declining_customers'])} customers",
                delta=f"{int(row['declining_customers'])/total_custs*100:.0f}% of base",
                delta_color="inverse",
            )

        # Narrative
        if not kpi_df.empty:
            row = kpi_df.iloc[0]
            silent = int(row["silent_churn_customers"])
            declining = int(row["declining_customers"])
            breadth = row["avg_feature_breadth"]
            st.info(
                f"**Product Health Snapshot:** {int(row['mau'])}/{len(cust_df)} customers active in March. "
                f"Avg feature adoption: **{breadth:.1f} / 5 metrics**. "
                f"**{silent} customers** had at least one zero-usage month (silent churn risk). "
                f"**{declining} customers** show a consistently declining usage trend — "
                f"cross-reference with churn MRR for early warning signals."
            )

        st.markdown("---")

        # ── Feature Breadth by Month ──────────────────────────────────────────
        st.subheader("Feature Adoption by Month")
        st.caption(
            "Each bar = one month. Colours = how many distinct product metrics (features) each customer used. "
            "Customers using more features are stickier and less likely to churn."
        )
        if not breadth_df.empty:
            breadth_df["month"] = pd.to_datetime(breadth_df["month"]).dt.strftime("%b %Y")
            breadth_df["feature_breadth"] = breadth_df["feature_breadth"].astype(str) + " feature(s)"
            MONTH_ORDER = ["Jan 2024", "Feb 2024", "Mar 2024"]
            fig = px.bar(
                breadth_df,
                x="month", y="customers",
                color="feature_breadth",
                barmode="stack",
                category_orders={
                    "month": MONTH_ORDER,
                    "feature_breadth": [f"{i} feature(s)" for i in range(1, 6)],
                },
                color_discrete_sequence=px.colors.sequential.Blues[1:],
                labels={"customers": "Customers", "month": "", "feature_breadth": "Features Used"},
                text="customers",
                height=340,
            )
            fig.update_traces(textposition="inside", textfont_size=11)
            fig.update_layout(margin=dict(l=0, r=0, t=10, b=0), legend_title="Features Used")
            st.plotly_chart(fig, use_container_width=True)

        # ── Engagement vs MRR scatter ─────────────────────────────────────────
        st.subheader("Engagement vs MRR — Quadrant View")
        st.caption(
            "Each dot = one customer. "
            "**Top-right** (high MRR, high usage) = safe. "
            "**Bottom-right** (high MRR, low usage) = 🚨 danger zone — paying customers not using the product. "
            "**Color** = health risk tier."
        )
        if not cust_df.empty:
            scatter_df = cust_df.copy()
            scatter_df["total_events_3m"] = scatter_df["total_events_3m"].fillna(0).astype(int)
            med_mrr    = scatter_df["current_mrr"].median()
            med_events = scatter_df["total_events_3m"].median()

            fig = px.scatter(
                scatter_df,
                x="current_mrr", y="total_events_3m",
                color="risk_tier",
                hover_data=["company_name", "account_tier", "health_score", "mar_active_users"],
                color_discrete_map={"at_risk": "#ef4444", "healthy": "#22c55e", "critical": "#7f1d1d", "unknown": "#94a3b8"},
                labels={"current_mrr": "Current MRR ($)", "total_events_3m": "Total Events (3 months)", "risk_tier": "Risk"},
                height=380,
                opacity=0.75,
            )
            # Quadrant lines at medians
            fig.add_vline(x=med_mrr,    line_dash="dash", line_color="gray", line_width=1)
            fig.add_hline(y=med_events, line_dash="dash", line_color="gray", line_width=1)
            fig.update_layout(margin=dict(l=0, r=0, t=10, b=0), xaxis_tickformat="$,.0f")
            st.plotly_chart(fig, use_container_width=True)

        # ── Post-ticket engagement recovery ───────────────────────────────────
        st.markdown("---")
        col_l2, col_r2 = st.columns(2)

        with col_l2:
            st.subheader("Post-Ticket Engagement Recovery")
            st.caption(
                "**Recovery ratio** = product usage in 14 days AFTER ticket resolution ÷ usage in 14 days BEFORE. "
                "Ratio < 1.0 = customer used the product LESS after support resolved their issue. "
                "Ratio = 0 = customer went completely dark — ticket did not fix the underlying problem."
            )
            if not pt_df.empty:
                # Bucket recovery ratios
                def recovery_label(r):
                    if pd.isna(r):  return "No data"
                    if r >= 1.0:    return "✅ Recovered (≥1x)"
                    if r >= 0.5:    return "⚠️ Partial (0.5–1x)"
                    return "🚨 Not recovered (<0.5x)"

                pt_df["recovery_bucket"] = pt_df["recovery_ratio"].apply(recovery_label)
                bucket_summary = pt_df.groupby("recovery_bucket").agg(
                    customers=("customer_id", "count"),
                    total_mrr=("current_mrr", "sum"),
                ).reset_index().sort_values("customers", ascending=False)
                bucket_summary["total_mrr"] = bucket_summary["total_mrr"].apply(lambda x: f"${x:,.0f}")

                fig = px.bar(
                    bucket_summary, x="recovery_bucket", y="customers",
                    color="recovery_bucket",
                    color_discrete_map={
                        "✅ Recovered (≥1x)": "#22c55e",
                        "⚠️ Partial (0.5–1x)": "#f59e0b",
                        "🚨 Not recovered (<0.5x)": "#ef4444",
                        "No data": "#94a3b8",
                    },
                    labels={"recovery_bucket": "", "customers": "Customers"},
                    height=280,
                    text="customers",
                )
                fig.update_traces(textposition="outside")
                fig.update_layout(margin=dict(l=0, r=0, t=10, b=0), showlegend=False)
                st.plotly_chart(fig, use_container_width=True)

        with col_r2:
            st.subheader("At-Risk: No Recovery After Support")
            if not pt_df.empty:
                danger = pt_df[
                    (pt_df["poor_post_ticket_recovery"] == True) |
                    (pt_df["unresolved_with_no_recovery"] == True)
                ].copy()
                if not danger.empty:
                    danger_disp = danger[[
                        "company_name", "region", "total_tickets",
                        "recovery_ratio", "avg_satisfaction", "current_mrr", "risk_tier"
                    ]].rename(columns={
                        "company_name": "Company", "region": "Region",
                        "total_tickets": "Tickets", "recovery_ratio": "Recovery",
                        "avg_satisfaction": "CSAT", "current_mrr": "MRR",
                        "risk_tier": "Risk",
                    })
                    danger_disp["Recovery"] = danger_disp["Recovery"].apply(
                        lambda x: f"{x:.2f}x" if pd.notna(x) else "—"
                    )
                    danger_disp["MRR"] = danger_disp["MRR"].apply(lambda x: f"${x:,.0f}")
                    danger_disp["CSAT"] = danger_disp["CSAT"].apply(
                        lambda x: f"{x:.1f}/5" if pd.notna(x) else "—"
                    )
                    st.dataframe(danger_disp, use_container_width=True, hide_index=True, height=280)
                else:
                    st.success("No customers with poor post-ticket recovery.")

        # ── Usage risk table ──────────────────────────────────────────────────
        st.markdown("---")
        st.subheader("Customer Usage Risk Signals")
        st.caption("Customers flagged with at least one usage risk signal. Cross-reference with MRR to prioritise outreach.")

        if not cust_df.empty:
            risk_only = cust_df[
                cust_df["is_silent_churn"] |
                cust_df["is_consistently_declining"] |
                cust_df["sharp_drop_last_month"]
            ].copy()

            uc1, uc2 = st.columns(2)
            sig_filter = uc1.multiselect(
                "Signal",
                ["Silent Churn", "Consistently Declining", "Sharp Drop Last Month"],
                default=["Silent Churn", "Consistently Declining", "Sharp Drop Last Month"],
            )
            min_mrr = uc2.slider("Min MRR ($)", 0, int(cust_df["current_mrr"].max() or 1000), 0, step=50)

            if "Silent Churn" not in sig_filter:
                risk_only = risk_only[~risk_only["is_silent_churn"]]
            if "Consistently Declining" not in sig_filter:
                risk_only = risk_only[~risk_only["is_consistently_declining"]]
            if "Sharp Drop Last Month" not in sig_filter:
                risk_only = risk_only[~risk_only["sharp_drop_last_month"]]
            risk_only = risk_only[risk_only["current_mrr"] >= min_mrr]

            risk_disp = risk_only[[
                "company_name", "region", "account_tier",
                "jan_events", "feb_events", "mar_events",
                "feb_mar_pct_change", "current_mrr", "risk_tier",
                "is_silent_churn", "is_consistently_declining", "sharp_drop_last_month",
            ]].rename(columns={
                "company_name": "Company", "region": "Region", "account_tier": "Tier",
                "jan_events": "Jan", "feb_events": "Feb", "mar_events": "Mar",
                "feb_mar_pct_change": "Feb→Mar %", "current_mrr": "MRR",
                "risk_tier": "Risk", "is_silent_churn": "Silent",
                "is_consistently_declining": "Declining", "sharp_drop_last_month": "Sharp Drop",
            })
            risk_disp["MRR"] = risk_disp["MRR"].apply(lambda x: f"${x:,.0f}")
            risk_disp["Feb→Mar %"] = risk_disp["Feb→Mar %"].apply(
                lambda x: f"{x:+.0f}%" if pd.notna(x) else "—"
            )
            st.dataframe(
                risk_disp,
                use_container_width=True, hide_index=True, height=380,
                column_config={
                    "Silent": st.column_config.CheckboxColumn("Silent"),
                    "Declining": st.column_config.CheckboxColumn("Declining"),
                    "Sharp Drop": st.column_config.CheckboxColumn("Sharp Drop"),
                }
            )
            st.caption(f"Showing {len(risk_disp)} flagged customers out of {len(cust_df)} total.")
