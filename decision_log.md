# Decision Log

All data modeling and engineering decisions made during this project, including alternatives considered and rejected.

---

## Architecture Decisions

### ADR-001: DuckDB over PostgreSQL
**Decision:** Use DuckDB as the analytical database instead of PostgreSQL.
**Reason:** DuckDB is free, serverless, requires zero infrastructure setup, and is optimized for analytical queries. For a take-home exercise with CSV source data, it eliminates connection/auth complexity while delivering the same modeling capabilities.
**Rejected alternative:** PostgreSQL — would require a running server, user management, and connection config. Adds operational overhead with no analytical benefit at this scale.

### ADR-002: dbt-core + dbt-duckdb for transformations
**Decision:** Use dbt-core for all transforms instead of raw Python/pandas.
**Reason:** dbt provides a layered model structure, built-in testing, lineage documentation, and idempotent runs — all of which are explicit requirements of this exercise.
**Rejected alternative:** Pure pandas transforms — no lineage, no testing framework, harder to maintain.

### ADR-003: Layered architecture (rds → staging → core → marts)
**Decision:** Four-layer architecture:
- `rds`: raw operational tables loaded by Python
- `staging`: views, type casting, sentinel handling only — no business logic
- `core`: dimension and fact tables with enrichments
- `marts`: aggregated KPI tables for the dashboard
**Reason:** Clear separation of concerns. If a metric is wrong, you can trace back through each layer to find where it broke. Staging stays as close to bronze as possible.
**Rejected:** Collapsing staging + core — loses the ability to audit raw vs cleaned values.

### ADR-004: Python UPSERT for dimensions, incremental append for facts
**Decision:** Dimension tables (customers, plans, subscriptions) use full UPSERT — current state only in `rds`. Fact tables (invoices, payments, usage_events) use incremental append with `_batch_id` tracking.
**Reason:** Dimensions represent entities that change over time — only current state belongs in the operational layer. Facts are immutable events — they accumulate. Corrections (batch_003) are applied as patches at the `rds` level.
**Rejected:** Loading all batches as full snapshots — would require deduplication logic in every downstream model.

### ADR-005: dbt Snapshot for SCD Type 2 on customers
**Decision:** Use dbt's native snapshot feature (`strategy='check', check_cols='all'`) on `rds.customers` to maintain full SCD2 history.
**Reason:** dbt snapshots handle `dbt_valid_from` / `dbt_valid_to` automatically. Any column change creates a new version. This gives time-travel capability without custom code.
**Rejected:** Custom CDC columns in `rds` — redundant once dbt snapshots are in place. Adds complexity at the ingestion layer.

---

## Data Quality Decisions

### DQ-001: Region enrichment from country
**Decision:** Recover null `region` values (46% of customers) from the `country` column using a country→region mapping in `dim_customers`. A `region_was_inferred` flag is added to distinguish sourced vs derived values.
**Reason:** Region is required for regional manager access control (CR-1). 46% null is too high to leave unresolved.
**Rejected:** Leaving nulls — would exclude 230 customers from regional dashboards and break RLS.

### DQ-002: PLN-LEGACY not fabricated in dim_plans
**Decision:** `PLN-LEGACY` appears in 16 subscriptions but has no corresponding row in `plans.csv`. We do NOT add a synthetic row to `dim_plans`.
**Reason:** We have no knowledge of its pricing, limits, or features. Fabricating it would introduce false data. Downstream models use `LEFT JOIN` to preserve those 16 subscriptions.
**Rejected:** Adding a placeholder row — misleading and introduces unknown values.

### DQ-003: end_date completion for cancelled/expired subscriptions
**Decision:** Null `end_date` on cancelled/expired subscriptions is estimated as `start_date + billing_cycle_interval` in `dim_subscriptions`. An `end_date_was_inferred` flag marks these rows.
**Reason:** 11 cancelled subscriptions have no end_date. For MRR churn calculations, we need an approximate termination date.
**Active subscriptions are NOT assigned an end_date** — they are still running.

### DQ-004: Corrections applied at rds layer
**Decision:** `corrections.csv` (batch_003) patches are applied directly to `rds` fact tables via SQL `UPDATE` during ingestion. This means corrections are transparent to all downstream dbt models.
**Reason:** Corrections represent "the data was wrong from the source" — not a business event. Applying them at the raw layer means dbt models always see the corrected truth.
**Rejected:** Applying corrections in dbt staging — would require a complex correction JOIN in every model that touches corrected entities.

---

## Metric Definitions (Section 5 — Conflicting Business Rules)

Three teams provided conflicting KPI definitions. Below are the canonical definitions chosen and the rationale.

### MRR
**Canonical definition:** Active subscription base amounts only. Overages excluded.
**Recognized on:** Invoice date (Finance definition).
**Rationale:** Subscription MRR is the most consistent and comparable metric across periods. Including overage (Product's definition) introduces volatility that obscures underlying growth. Revenue recognized on invoice date aligns with Finance's accounting treatment.
**Rejected:** Product's trailing 3-month overage average — useful for forecasting but not for board-level MRR reporting. Sales' overage growth inclusion conflates recurring and variable revenue.

### Churn MRR
**Canonical definition:** Full cancellations only. Downgrades tracked separately as "Contraction MRR."
**Rationale:** Aligns with Finance definition. Separating churn from contraction allows the board to distinguish lost customers from shrinking customers — two different problems requiring different responses.
**Rejected:** Product's "silent churn" (zero usage 90+ days) — operationally interesting but not a financial metric. Sales' "has any active sub = retained" — masks real revenue loss from downgrades.

### NRR (Net Revenue Retention)
**Canonical definition:** `(Starting MRR + Expansion MRR - Contraction MRR - Churn MRR) / Starting MRR`
**Rationale:** Includes contraction (Product + aligned with SaaS industry standard). Finance's exclusion of contraction overstates NRR and is not comparable to industry benchmarks. This is the definition VCs and public market investors use.
**Rejected:** Finance's NRR excluding contraction — inflates the metric. Sales' approach (no contraction tracking) — masks revenue deterioration.

### Customer Count
**Canonical definition:** All customers with an active subscription (paid or free), aligned with Finance.
**Rationale:** Free tier customers are potential expansion targets. Excluding them (Sales definition) understates the addressable base.
**Rejected:** Sales' paid-only count — useful as a secondary metric but not the primary customer count.

---

## Change Request Impact Analysis (Section 6)

### CR-1: Regional Manager Role with Row-Level Security
**Impact:** Implemented at the application layer (Streamlit). Each role is assigned a region; all dashboard queries are filtered by `WHERE region = :user_region`. Company-wide KPIs are available only to admin and analyst roles.
**DB layer:** `dim_customers.region` is the enforcement column. All fact models join back to `dim_customers` for region context.

### CR-2: NRR by Contract Effective Date
**Impact:** Would require adding `effective_date` from `contract_amendments` to the MRR movement fact. Historical data would need restatement for retroactive amendments. Amendments with `effective_date < subscription start_date` would be treated as adjustments to the subscription start.
**Effort:** Medium — requires a new join in `fct_mrr_movements` and a restatement flag.

### CR-3: New Partner Referral Source
**Impact:** `partner_referrals.csv` has no `customer_id`. Matching strategy:
1. Exact match on normalized email
2. Fuzzy match on company name (Jaro-Winkler or trigram similarity)
3. Unmatched records quarantined in a `stg_partner_referrals_unmatched` table for manual review
**Effort:** Medium-high — fuzzy matching requires Python preprocessing before dbt can consume it.

---

*Last updated: 2026-03-23*
