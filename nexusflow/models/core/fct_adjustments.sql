-- fct_adjustments
-- Financial adjustments fact — credits, refunds, write-offs, corrections
-- customer_id already unified to CUST-NNN in staging

WITH stg AS (
    SELECT * FROM {{ ref('stg_adjustments') }}
),

enriched AS (
    SELECT
        a.adjustment_id,
        a.customer_id,
        a.invoice_id,
        a.adjustment_type,
        a.amount,
        a.reason,
        a.effective_date,
        a.created_date,
        a.approved_by,
        a.status,
        a.reverses_adjustment_id,
        a.batch_id,

        -- Customer context
        c.company_name,
        c.region,
        c.account_tier,

        -- Invoice context
        inv.subscription_id,
        inv.plan_id,
        inv.invoice_status

    FROM stg a
    LEFT JOIN {{ ref('dim_customers') }} c
        ON a.customer_id = c.customer_id
    LEFT JOIN {{ ref('fct_invoices') }} inv
        ON a.invoice_id = inv.invoice_id
)

SELECT
    adjustment_id,
    customer_id,
    invoice_id,
    subscription_id,
    plan_id,

    -- Context
    company_name,
    region,
    account_tier,
    invoice_status,

    -- Adjustment details
    adjustment_type,
    amount,

    -- Net impact: credits/refunds reduce revenue, write-offs are losses
    CASE
        WHEN adjustment_type IN ('credit', 'refund') THEN -amount
        WHEN adjustment_type = 'write_off'           THEN -amount
        WHEN adjustment_type = 'correction'          THEN  amount
        WHEN adjustment_type = 'reversal'            THEN  amount
        ELSE amount
    END                                                 AS revenue_impact,

    reason,
    effective_date,
    created_date,
    approved_by,
    status,
    reverses_adjustment_id,

    -- Flags
    (status = 'approved')                               AS is_approved,
    (adjustment_type IN ('credit', 'refund'))           AS is_customer_relief,
    (adjustment_type = 'write_off')                     AS is_write_off,
    (reverses_adjustment_id IS NOT NULL)                AS is_reversal,
    (customer_id IS NULL OR company_name IS NULL)       AS dq_unresolved_customer,

    batch_id

FROM enriched
