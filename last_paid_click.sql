-- Last Paid Click Attribution
-- Identifica el último clic pagado antes de la conversión (o la última
-- sesión pagada de visitantes que no se convirtieron en lead).

WITH paid_sessions AS (
    SELECT
        visitor_id,
        visit_date,
        source,
        medium,
        campaign
    FROM sessions
    WHERE medium IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

lead_last_click AS (
    SELECT
        l.lead_id,
        l.visitor_id,
        l.created_at,
        l.amount,
        l.closing_reason,
        l.status_id,
        ps.visit_date,
        ps.source AS utm_source,
        ps.medium AS utm_medium,
        ps.campaign AS utm_campaign,
        ROW_NUMBER() OVER (
            PARTITION BY l.lead_id
            ORDER BY ps.visit_date DESC
        ) AS rn
    FROM leads AS l
    INNER JOIN paid_sessions AS ps
        ON
            ps.visitor_id = l.visitor_id
            AND ps.visit_date <= l.created_at
),

lead_attributed AS (
    SELECT
        lead_id,
        visitor_id,
        created_at,
        amount,
        closing_reason,
        status_id,
        visit_date,
        utm_source,
        utm_medium,
        utm_campaign
    FROM lead_last_click
    WHERE rn = 1
),

non_lead_visitors AS (
    SELECT
        ps.visitor_id,
        ps.visit_date,
        ps.source AS utm_source,
        ps.medium AS utm_medium,
        ps.campaign AS utm_campaign,
        ROW_NUMBER() OVER (
            PARTITION BY ps.visitor_id
            ORDER BY ps.visit_date DESC
        ) AS rn
    FROM paid_sessions AS ps
    WHERE ps.visitor_id NOT IN (
        SELECT visitor_id FROM lead_attributed
    )
)

SELECT
    visitor_id,
    visit_date,
    utm_source,
    utm_medium,
    utm_campaign,
    NULL::varchar AS lead_id,
    NULL::timestamp AS created_at,
    NULL::integer AS amount,
    NULL::varchar AS closing_reason,
    NULL::bigint AS status_id
FROM non_lead_visitors
WHERE rn = 1

UNION ALL

SELECT
    visitor_id,
    visit_date,
    utm_source,
    utm_medium,
    utm_campaign,
    lead_id,
    created_at,
    amount,
    closing_reason,
    status_id
FROM lead_attributed

ORDER BY
    amount DESC NULLS LAST,
    visit_date ASC,
    utm_source ASC,
    utm_medium ASC,
    utm_campaign ASC
LIMIT 10;