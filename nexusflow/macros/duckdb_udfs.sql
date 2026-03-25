-- duckdb_udfs.sql
-- DuckDB native SQL macros (UDFs) registered as persistent functions
-- These are called as regular SQL functions in any model: health_score_label(75)
-- Run once via: dbt run-operation register_udfs

{% macro register_udfs() %}

    {{ log("Registering DuckDB UDFs...", info=True) }}

    -- health_score_label: turn a 0–100 score into a display label
    CREATE OR REPLACE MACRO health_score_label(score) AS
        CASE
            WHEN score IS NULL  THEN 'Unknown'
            WHEN score <= 30    THEN '🔴 Critical'
            WHEN score <= 60    THEN '🟡 At Risk'
            WHEN score <= 80    THEN '🟢 Healthy'
            ELSE                     '⭐ Champion'
        END;

    -- mrr_at_risk_pct: what fraction of MRR is exposed given a score
    CREATE OR REPLACE MACRO mrr_at_risk_pct(score) AS
        CASE
            WHEN score <= 30 THEN 1.0    -- 100% at risk
            WHEN score <= 45 THEN 0.75
            WHEN score <= 60 THEN 0.5
            WHEN score <= 75 THEN 0.25
            ELSE 0.0
        END;

    -- normalize_to_cust_id: unify customer_id formats to CUST-NNN
    -- Handles: '203' → 'CUST-203', 'C302' → 'CUST-302', 'CUST-203' → 'CUST-203'
    CREATE OR REPLACE MACRO normalize_to_cust_id(raw_id) AS
        CASE
            WHEN raw_id IS NULL OR TRIM(raw_id) = '' THEN NULL
            WHEN TRIM(raw_id) LIKE 'CUST-%'          THEN TRIM(raw_id)
            WHEN TRIM(raw_id) LIKE 'C%'
                THEN 'CUST-' || LPAD(SUBSTRING(TRIM(raw_id), 2), 3, '0')
            ELSE 'CUST-' || LPAD(TRIM(raw_id), 3, '0')
        END;

    {{ log("UDFs registered successfully.", info=True) }}

{% endmacro %}
