-- Gastos publicitarios agregados según el modelo Last Paid Click (CORREGIDA)
-- Une visitas, leads atribuidos y gastos de ads (VK + Yandex) por día y UTM tags.
--
-- FIX: visitors_count y leads_count ahora se calculan sobre la MISMA tabla de
-- atribución deduplicada (un registro por visitante = su único último clic
-- pagado), no directamente sobre "sessions". Antes, un visitante que pasaba
-- por varios canales se contaba en cada uno; ahora solo cuenta en el canal
-- que realmente se le atribuye bajo el modelo Last Paid Click.

WITH paid_sessions AS (
    SELECT
        visitor_id, visit_date, source, medium, campaign
    FROM sessions
    WHERE medium IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

lead_last_click AS (
    SELECT
        l.lead_id, l.amount, l.closing_reason, l.status_id,
        ps.visitor_id,
        ps.visit_date,
        ps.source AS utm_source, ps.medium AS utm_medium, ps.campaign AS utm_campaign,
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
        visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
        lead_id, amount, closing_reason, status_id
    FROM lead_last_click
    WHERE rn = 1
),

non_lead_visitors AS (
    SELECT
        ps.visitor_id, ps.visit_date,
        ps.source AS utm_source, ps.medium AS utm_medium, ps.campaign AS utm_campaign,
        ROW_NUMBER() OVER (
            PARTITION BY ps.visitor_id
            ORDER BY ps.visit_date DESC
        ) AS rn
    FROM paid_sessions AS ps
    WHERE ps.visitor_id NOT IN (SELECT visitor_id FROM lead_attributed)
),

-- Un solo registro por visitante: su último clic pagado atribuido,
-- haya convertido en lead o no. Esta es la base única de la vitrina.
attribution AS (
    SELECT
        visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
        NULL::varchar AS lead_id, NULL::integer AS amount,
        NULL::varchar AS closing_reason, NULL::bigint AS status_id
    FROM non_lead_visitors
    WHERE rn = 1

    UNION ALL

    SELECT
        visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
        lead_id, amount, closing_reason, status_id
    FROM lead_attributed
),

visits_agg AS (
    SELECT
        DATE(visit_date) AS visit_date,
        utm_source, utm_medium, utm_campaign,
        COUNT(DISTINCT visitor_id) AS visitors_count
    FROM attribution
    GROUP BY DATE(visit_date), utm_source, utm_medium, utm_campaign
),

leads_agg AS (
    SELECT
        DATE(visit_date) AS visit_date,
        utm_source, utm_medium, utm_campaign,
        COUNT(lead_id) AS leads_count,
        COUNT(*) FILTER (
            WHERE closing_reason = 'Успешная продажа' OR status_id = 142
        ) AS purchases_count,
        SUM(amount) FILTER (
            WHERE closing_reason = 'Успешная продажа' OR status_id = 142
        ) AS revenue
    FROM attribution
    WHERE lead_id IS NOT NULL
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

SELECT
    v.visit_date, v.visitors_count, v.utm_source, v.utm_medium, v.utm_campaign,
    a.total_cost,
    COALESCE(l.leads_count, 0) AS leads_count,
    COALESCE(l.purchases_count, 0) AS purchases_count,
    l.revenue
FROM visits_agg AS v
LEFT JOIN ads_agg AS a
    ON
        a.visit_date = v.visit_date AND a.utm_source = v.utm_source
        AND a.utm_medium = v.utm_medium AND a.utm_campaign = v.utm_campaign
LEFT JOIN leads_agg AS l
    ON
        l.visit_date = v.visit_date AND l.utm_source = v.utm_source
        AND l.utm_medium = v.utm_medium AND l.utm_campaign = v.utm_campaign

ORDER BY
    v.visit_date ASC,
    v.visitors_count DESC,
    v.utm_source ASC,
    v.utm_medium ASC,
    v.utm_campaign ASC,
    revenue DESC NULLS LAST
LIMIT 15;