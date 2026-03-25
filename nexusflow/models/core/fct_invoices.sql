-- fct_invoices
-- Invoice fact table — one row per invoice across all 3 batches
-- customer_id is unified to CUST-NNN in staging — direct join to dim_customers
-- Deduplication: same invoice_id appears in each batch snapshot → keep latest batch

WITH stg AS (
    SELECT * FROM {{ ref('stg_invoices') }}
),

-- Deduplication: keep latest batch version per invoice
deduped AS (
    SELECT
        invoice_id,
        customer_id,
        subscription_id,
        invoice_date,
        due_date,
        amount,
        currency,
        status,
        line_items_count,
        tax_amount,
        total_amount,
        period_start,
        period_end,
        created_at,
        batch_id
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY invoice_id
                ORDER BY batch_id DESC
            ) AS rn
        FROM stg
    )
    WHERE rn = 1
),

-- Enrich with customer, subscription, and plan context
enriched AS (
    SELECT
        inv.invoice_id,
        inv.customer_id,
        inv.subscription_id,

        -- Customer context
        c.company_name,
        c.region,
        c.account_tier,
        c.status                                        AS customer_status,

        -- Plan context
        s.plan_id,
        p.plan_name,
        p.plan_tier,
        s.billing_cycle,

        -- Dates
        inv.invoice_date,
        inv.due_date,
        inv.period_start,
        inv.period_end,
        inv.created_at,

        -- Amounts
        inv.amount,
        inv.tax_amount,
        inv.total_amount,
        inv.currency,

        -- Invoice details
        inv.status                                      AS invoice_status,
        inv.line_items_count,

        -- Batch tracking
        inv.batch_id

    FROM deduped inv
    LEFT JOIN {{ ref('dim_customers') }} c
        ON inv.customer_id = c.customer_id
    LEFT JOIN {{ ref('dim_subscriptions') }} s
        ON inv.subscription_id = s.subscription_id
    LEFT JOIN {{ ref('dim_plans') }} p
        ON s.plan_id = p.plan_id
)

SELECT
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

    -- Dates
    invoice_date,
    due_date,
    period_start,
    period_end,
    created_at,

    -- Amounts
    amount,
    tax_amount,
    total_amount,
    currency,

    -- Status & flags
    invoice_status,
    line_items_count,
    (invoice_status = 'paid')                           AS is_paid,
    (invoice_status = 'overdue')                        AS is_overdue,
    (due_date < invoice_date)                           AS dq_due_before_invoice,
    (customer_id IS NULL)                               AS dq_unresolved_customer,

    batch_id

FROM enriched
