-- fct_payments
-- Payment fact table — one row per payment across all 3 batches
-- customer_id unified to CUST-NNN in staging — direct join to dim_customers
-- Deduplication: keep latest batch per payment_id

WITH stg AS (
    SELECT * FROM {{ ref('stg_payments') }}
),

deduped AS (
    SELECT
        payment_id,
        invoice_id,
        customer_id,
        amount,
        payment_method,
        payment_date,
        status,
        transaction_ref,
        processor_fee,
        net_amount,
        batch_id
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY payment_id
                ORDER BY batch_id DESC
            ) AS rn
        FROM stg
    )
    WHERE rn = 1
),

enriched AS (
    SELECT
        p.payment_id,
        p.invoice_id,
        p.customer_id,

        -- Customer context
        c.company_name,
        c.region,
        c.account_tier,
        c.status                                        AS customer_status,

        -- Invoice context
        inv.subscription_id,
        inv.plan_id,
        inv.plan_name,
        inv.plan_tier,
        inv.billing_cycle,
        inv.invoice_status,

        -- Payment details
        p.payment_date,
        p.amount,
        p.payment_method,
        p.status                                        AS payment_status,
        p.transaction_ref,
        p.processor_fee,
        p.net_amount,

        -- Batch tracking
        p.batch_id

    FROM deduped p
    LEFT JOIN {{ ref('dim_customers') }} c
        ON p.customer_id = c.customer_id
    LEFT JOIN {{ ref('fct_invoices') }} inv
        ON p.invoice_id = inv.invoice_id
)

SELECT
    payment_id,
    invoice_id,
    customer_id,
    subscription_id,
    plan_id,

    -- Context
    company_name,
    region,
    account_tier,
    customer_status,
    plan_name,
    plan_tier,
    billing_cycle,
    invoice_status,

    -- Payment details
    payment_date,
    amount,
    payment_method,
    payment_status,
    transaction_ref,
    processor_fee,
    net_amount,

    -- Derived flags
    (payment_status = 'completed')                      AS is_completed,
    (payment_status = 'failed')                         AS is_failed,
    (payment_status = 'refunded')                       AS is_refunded,
    (customer_id IS NULL)                               AS dq_unresolved_customer,
    (invoice_id IS NULL OR invoice_status IS NULL)      AS dq_no_invoice_match,

    batch_id

FROM enriched
