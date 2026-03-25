-- finance.sql — reusable financial calculation macros

-- safe_divide: returns default (NULL by default) instead of crashing on division by zero
{% macro safe_divide(numerator, denominator, default_value='NULL') %}
    CASE WHEN ({{ denominator }}) = 0 OR ({{ denominator }}) IS NULL
         THEN {{ default_value }}
         ELSE ({{ numerator }})::DECIMAL / ({{ denominator }})
    END
{% endmacro %}


-- pct_change: safe month-over-month % change, rounded to 1 decimal
{% macro pct_change(current_val, prior_val) %}
    CASE WHEN ({{ prior_val }}) = 0 OR ({{ prior_val }}) IS NULL
         THEN NULL
         ELSE ROUND(100.0 * (({{ current_val }}) - ({{ prior_val }})) / ({{ prior_val }}), 1)
    END
{% endmacro %}


-- nrr: canonical NRR formula
--   (starting_mrr + expansion - contraction - churn) / starting_mrr
{% macro calc_nrr(starting_mrr, expansion_mrr, contraction_mrr, churn_mrr) %}
    {{ safe_divide(
        '(' ~ starting_mrr ~ ') + (' ~ expansion_mrr ~ ') - (' ~ contraction_mrr ~ ') - (' ~ churn_mrr ~ ')',
        starting_mrr,
        'NULL'
    ) }}
{% endmacro %}


-- mrr_movement: classify a subscription's MRR change
--   prev_status param lets us catch reactivations (cancelled → new MRR)
{% macro mrr_movement(curr_mrr, prev_mrr, prev_status=None) %}
    CASE
        WHEN ({{ prev_mrr }}) IS NULL                        THEN 'new'
        {% if prev_status %}
        WHEN ({{ prev_status }}) = 'cancelled'
             AND ({{ curr_mrr }}) > 0                        THEN 'reactivation'
        {% endif %}
        WHEN ({{ curr_mrr }}) > ({{ prev_mrr }})             THEN 'expansion'
        WHEN ({{ curr_mrr }}) < ({{ prev_mrr }})             THEN 'contraction'
        WHEN ({{ curr_mrr }}) = 0                            THEN 'churn'
        ELSE                                                      'unchanged'
    END
{% endmacro %}
