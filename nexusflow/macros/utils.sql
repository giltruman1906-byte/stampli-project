-- utils.sql — general purpose utility macros

-- clamp: constrain a value between min and max bounds
{% macro clamp(value, min_val, max_val) %}
    GREATEST({{ min_val }}, LEAST({{ max_val }}, {{ value }}))
{% endmacro %}


-- risk_tier: map a 0–100 health score to a labelled risk tier
{% macro risk_tier(score_col) %}
    CASE
        WHEN ({{ score_col }}) <= 30 THEN 'critical'
        WHEN ({{ score_col }}) <= 60 THEN 'at_risk'
        ELSE                              'healthy'
    END
{% endmacro %}


-- risk_tier_emoji: same but with emoji for dashboard display
{% macro risk_tier_emoji(score_col) %}
    CASE
        WHEN ({{ score_col }}) <= 30 THEN '🔴 Critical'
        WHEN ({{ score_col }}) <= 60 THEN '🟡 At Risk'
        ELSE                              '🟢 Healthy'
    END
{% endmacro %}


-- months_since: number of full months between two dates
{% macro months_since(start_date, end_date) %}
    DATE_DIFF('month', ({{ start_date }}), ({{ end_date }}))
{% endmacro %}


-- nullif_zero: treat 0 as NULL (avoids skewing averages)
{% macro nullif_zero(col) %}
    NULLIF({{ col }}, 0)
{% endmacro %}
