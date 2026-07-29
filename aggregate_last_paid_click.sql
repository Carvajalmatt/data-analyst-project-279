WITH paid_sessions AS (
    SELECT visitor_id, visit_date, source, medium, campaign
    FROM sessions
    WHERE medium IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

lead_last_click AS (
    SELECT
        l.lead_id, l.visitor_id, l.created_at, l.amount, l.closing_reason, l.status_id,
        ps.visit_date, ps.source AS utm_source, ps.medium AS utm_medium, ps.campaign AS utm_campaign,
        ROW_NUMBER() OVER (
            PARTITION BY l.lead_id
            ORDER BY ps.visit_date DESC
        ) AS rn
    FROM leads AS l
    INNER JOIN paid_sessions AS ps
        ON ps.visitor_id = l.visitor_id AND ps.visit_date <= l.created_at
),

lead_attributed AS (
    SELECT * FROM lead_last_click WHERE rn = 1
),

non_lead_visitors AS (
    SELECT
        ps.visitor_id, ps.visit_date, ps.source AS utm_source, ps.medium AS utm_medium, ps.campaign AS utm_campaign,
        ROW_NUMBER() OVER (
            PARTITION BY ps.visitor_id
            ORDER BY ps.visit_date DESC
        ) AS rn
    FROM paid_sessions AS ps
    WHERE ps.visitor_id NOT IN (SELECT visitor_id FROM lead_attributed)
),

-- 1. Armamos la tabla idéntica a tu archivo que pasó la prueba
combined_traffic AS (
    SELECT
        visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
        NULL::varchar AS lead_id, NULL::integer AS amount, NULL::varchar AS closing_reason, NULL::bigint AS status_id
    FROM non_lead_visitors
    WHERE rn = 1

    UNION ALL

    SELECT
        visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
        lead_id, amount, closing_reason, status_id
    FROM lead_attributed
),

-- 2. Agrupamos TODO desde esa base perfecta
traffic_agg AS (
    SELECT
        DATE(visit_date) AS visit_date,
        utm_source, utm_medium, utm_campaign,
        COUNT(visitor_id) AS visitors_count,
        COUNT(lead_id) AS leads_count,
        COUNT(lead_id) FILTER (WHERE closing_reason = 'Успешная продажа' OR status_id = 142) AS purchases_count,
        SUM(amount) FILTER (WHERE closing_reason = 'Успешная продажа' OR status_id = 142) AS revenue
    FROM combined_traffic
    GROUP BY DATE(visit_date), utm_source, utm_medium, utm_campaign
),

ads_union AS (
    SELECT utm_source, utm_medium, utm_campaign, campaign_date, daily_spent FROM vk_ads
    UNION ALL
    SELECT utm_source, utm_medium, utm_campaign, campaign_date, daily_spent FROM ya_ads
),

ads_agg AS (
    SELECT
        DATE(campaign_date) AS visit_date,
        utm_source, utm_medium, utm_campaign,
        SUM(daily_spent) AS total_cost
    FROM ads_union
    GROUP BY DATE(campaign_date), utm_source, utm_medium, utm_campaign
)

-- 3. Hacemos el cruce final con la tabla de costos
SELECT
    t.visit_date, t.visitors_count, t.utm_source, t.utm_medium, t.utm_campaign,
    a.total_cost,
    t.leads_count,
    t.purchases_count,
    t.revenue
FROM traffic_agg AS t
LEFT JOIN ads_agg AS a
    ON t.visit_date = a.visit_date
    AND t.utm_source = a.utm_source
    AND t.utm_medium = a.utm_medium
    AND t.utm_campaign = a.utm_campaign
ORDER BY
    t.revenue DESC NULLS LAST,
    t.visit_date ASC,
    t.visitors_count DESC,
    t.utm_source ASC,
    t.utm_medium ASC,
    t.utm_campaign ASC
LIMIT 15;