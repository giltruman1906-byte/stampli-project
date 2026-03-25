-- fct_contract_amendments
-- Contract amendment fact — upgrades, downgrades, cancellations, renewals, add-ons
-- Key input for NRR: captures actual MRR changes with effective dates
-- Uses mrr_movement macro to classify each amendment

WITH stg AS (
    SELECT * FROM {{ ref('stg_contract_amendments') }}
),

enriched AS (
    SELECT
        a.amendment_id,
        a.customer_id,
        a.subscription_id,
        a.amendment_type,
        a.old_plan_id,
        a.new_plan_id,
        a.old_mrr,
        a.new_mrr,
        ROUND(a.new_mrr - a.old_mrr, 2)                 AS mrr_delta,
        a.effective_date,
        a.created_date,
        a.reason,
        a.approved_by,
        a.batch_id,

        -- Customer context
        c.company_name,
        c.region,
        c.account_tier,

        -- Plan context (new plan)
        p.plan_name,
        p.plan_tier

    FROM stg a
    LEFT JOIN {{ ref('dim_customers') }} c
        ON a.customer_id = c.customer_id
    LEFT JOIN {{ ref('dim_plans') }} p
        ON a.new_plan_id = p.plan_id
)

SELECT
    amendment_id,
    customer_id,
    subscription_id,
    old_plan_id,
    new_plan_id,

    -- Context
    company_name,
    region,
    account_tier,
    plan_name     AS new_plan_name,
    plan_tier     AS new_plan_tier,

    -- Amendment details
    amendment_type,
    old_mrr,
    new_mrr,
    mrr_delta,
    effective_date,
    created_date,
    reason,
    approved_by,

    -- MRR movement classification using macro
    {{ mrr_movement('new_mrr', 'old_mrr') }}             AS mrr_movement,

    -- Retroactive flag: effective before it was recorded
    (effective_date < created_date)                      AS is_retroactive,

    -- Flags
    (amendment_type = 'cancellation')                   AS is_cancellation,
    (amendment_type IN ('upgrade', 'add_on'))            AS is_expansion,
    (amendment_type = 'downgrade')                      AS is_contraction,
    (mrr_delta > 0)                                     AS is_mrr_increase,
    (mrr_delta < 0)                                     AS is_mrr_decrease,
    (customer_id IS NULL OR company_name IS NULL)        AS dq_unresolved_customer,

    batch_id

FROM enriched
