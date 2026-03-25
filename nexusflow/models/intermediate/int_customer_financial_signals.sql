-- int_customer_financial_signals
-- Financial health signals per customer
-- Signals: payment failures, overdue invoices, MRR movement, contraction

WITH invoices AS (
    SELECT * FROM {{ ref('fct_invoices') }}
),

payments AS (
    SELECT * FROM {{ ref('fct_payments') }}
),

subs AS (
    SELECT * FROM {{ ref('dim_subscriptions') }}
),

-- Invoice health per customer
invoice_signals AS (
    SELECT
        customer_id,
        COUNT(*)                                        AS total_invoices,
        SUM(total_amount)                               AS total_billed,
        SUM(CASE WHEN is_paid    THEN total_amount ELSE 0 END) AS total_paid,
        SUM(CASE WHEN is_overdue THEN total_amount ELSE 0 END) AS total_overdue,
        COUNT(CASE WHEN is_overdue THEN 1 END)          AS overdue_invoice_count,
        COUNT(CASE WHEN invoice_status = 'disputed' THEN 1 END) AS disputed_invoice_count,
        COUNT(CASE WHEN invoice_status = 'void'     THEN 1 END) AS void_invoice_count,

        -- Most recent invoice date
        MAX(invoice_date)                               AS last_invoice_date
    FROM invoices
    GROUP BY 1
),

-- Payment health per customer
payment_signals AS (
    SELECT
        customer_id,
        COUNT(*)                                        AS total_payments,
        SUM(CASE WHEN is_completed THEN amount ELSE 0 END) AS total_collected,
        SUM(CASE WHEN is_failed    THEN 1      ELSE 0 END) AS failed_payment_count,
        SUM(CASE WHEN is_refunded  THEN amount ELSE 0 END) AS total_refunded,
        SUM(CASE WHEN is_refunded  THEN 1      ELSE 0 END) AS refund_count,

        -- Collection rate
        CASE WHEN SUM(amount) > 0
             THEN ROUND(100.0 * SUM(CASE WHEN is_completed THEN amount ELSE 0 END)
                  / SUM(amount), 1)
             ELSE NULL
        END                                             AS collection_rate_pct

    FROM payments
    GROUP BY 1
),

-- Subscription MRR signals — latest sub per customer
sub_signals AS (
    SELECT
        customer_id,
        SUM(CASE WHEN status = 'active' THEN mrr ELSE 0 END)    AS current_mrr,
        COUNT(CASE WHEN status = 'active' THEN 1 END)           AS active_sub_count,
        COUNT(CASE WHEN status = 'cancelled' THEN 1 END)        AS cancelled_sub_count,
        -- Latest MRR movement across all subs
        MAX(CASE WHEN mrr_movement = 'downgrade'  THEN 1 ELSE 0 END) AS has_recent_downgrade,
        MAX(CASE WHEN mrr_movement = 'upgrade'    THEN 1 ELSE 0 END) AS has_recent_upgrade,
        MAX(CASE WHEN cycle_movement = 'commitment_downgrade'
                 THEN 1 ELSE 0 END)                             AS has_commitment_downgrade,
        -- auto_renew off = planning to leave
        MAX(CASE WHEN status = 'active'
                  AND auto_renew = false
                 THEN 1 ELSE 0 END)                             AS has_auto_renew_off
    FROM subs
    GROUP BY 1
)

SELECT
    i.customer_id,

    -- Invoice signals
    i.total_invoices,
    i.total_billed,
    i.total_paid,
    i.total_overdue,
    i.overdue_invoice_count,
    i.disputed_invoice_count,
    i.last_invoice_date,

    -- Payment signals
    COALESCE(p.total_payments, 0)                       AS total_payments,
    COALESCE(p.total_collected, 0)                      AS total_collected,
    COALESCE(p.failed_payment_count, 0)                 AS failed_payment_count,
    COALESCE(p.total_refunded, 0)                       AS total_refunded,
    COALESCE(p.refund_count, 0)                         AS refund_count,
    p.collection_rate_pct,

    -- Subscription signals
    COALESCE(s.current_mrr, 0)                          AS current_mrr,
    COALESCE(s.active_sub_count, 0)                     AS active_sub_count,
    COALESCE(s.cancelled_sub_count, 0)                  AS cancelled_sub_count,
    COALESCE(s.has_recent_downgrade, 0) = 1             AS has_recent_downgrade,
    COALESCE(s.has_recent_upgrade, 0) = 1               AS has_recent_upgrade,
    COALESCE(s.has_commitment_downgrade, 0) = 1         AS has_commitment_downgrade,
    COALESCE(s.has_auto_renew_off, 0) = 1               AS has_auto_renew_off,

    -- Risk flags
    (i.overdue_invoice_count > 0)                       AS has_overdue_invoices,
    (COALESCE(p.failed_payment_count, 0) >= 2)          AS has_repeated_payment_failures,
    (COALESCE(p.collection_rate_pct, 100) < 80)         AS low_collection_rate,
    (i.disputed_invoice_count > 0)                      AS has_disputed_invoices,
    (COALESCE(s.active_sub_count, 0) = 0)               AS no_active_subscription

FROM invoice_signals i
LEFT JOIN payment_signals p ON i.customer_id = p.customer_id
LEFT JOIN sub_signals s     ON i.customer_id = s.customer_id
