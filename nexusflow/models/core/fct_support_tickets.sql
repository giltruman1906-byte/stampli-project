-- fct_support_tickets
-- Support ticket fact — one row per ticket
-- Deduplication NOTE: created_at is overwritten in each batch export with the export timestamp
--   → created_date must come from the EARLIEST batch (batch 1 = original creation)
--   → resolved_date, resolution_hours, satisfaction come from the LATEST batch (most current state)
-- is_resolved derived from resolved_date being non-null

WITH stg AS (
    SELECT * FROM {{ ref('stg_support_tickets') }}
),

-- Take created_date from earliest batch (original ticket creation time)
earliest AS (
    SELECT ticket_id, created_date
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY batch_id ASC) AS rn
        FROM stg
    )
    WHERE rn = 1
),

-- Take all other fields from latest batch (current status, resolution info)
deduped AS (
    SELECT
        t.ticket_id,
        t.customer_id,
        t.category,
        t.priority,
        e.created_date,          -- from earliest batch
        t.resolved_date,         -- from latest batch
        t.resolution_hours,
        t.satisfaction_score,
        t.agent_name,
        t.channel,
        t.description,
        t.batch_id
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY ticket_id
                ORDER BY batch_id DESC
            ) AS rn
        FROM stg
    ) t
    JOIN earliest e ON t.ticket_id = e.ticket_id
    WHERE t.rn = 1
),

enriched AS (
    SELECT
        t.ticket_id,
        t.customer_id,

        -- Customer context
        c.company_name,
        c.region,
        c.account_tier,
        c.status                                        AS customer_status,

        -- Ticket details
        t.category,
        t.priority,
        t.channel,
        t.agent_name,

        -- Dates and resolution
        t.created_date,
        t.resolved_date,
        t.resolution_hours,
        t.satisfaction_score,
        t.description,

        -- Batch tracking
        t.batch_id

    FROM deduped t
    LEFT JOIN {{ ref('dim_customers') }} c
        ON t.customer_id = c.customer_id
)

SELECT
    ticket_id,
    customer_id,

    -- Context
    company_name,
    region,
    account_tier,
    customer_status,

    -- Ticket details
    category,
    priority,
    channel,
    agent_name,

    -- Dates and resolution
    created_date,
    resolved_date,
    resolution_hours,
    satisfaction_score,
    description,

    -- Derived flags
    (resolved_date IS NOT NULL)                         AS is_resolved,
    (resolved_date IS NULL)                             AS is_open,
    (LOWER(priority) IN ('critical', 'high'))           AS is_high_priority,
    (customer_id IS NULL OR company_name IS NULL)       AS dq_unresolved_customer,
    (resolved_date IS NOT NULL
     AND resolved_date < created_date)                  AS dq_resolved_before_created,

    batch_id

FROM enriched
