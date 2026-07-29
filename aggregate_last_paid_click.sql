WITH paid_sessions AS (
    SELECT visitor_id, visit_date, source, medium, campaign
    FROM sessions
    WHERE medium IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

-- 1. Visitantes (Último toque global)
visitor_last_touch AS (
    SELECT
        visitor_id,
        visit_date,
        source AS utm_source,
        medium AS utm_medium,
        campaign AS utm_campaign,
        ROW_NUMBER() OVER (PARTITION BY visitor_id ORDER BY visit_date DESC) AS rn
    FROM paid_sessions
),
visits_agg AS (
    SELECT
        DATE(visit_date) AS visit_date,
        utm_source, utm_medium, utm_campaign,
        COUNT(visitor_id) AS visitors_count
    FROM visitor_last_touch
    WHERE rn = 1
    GROUP BY DATE(visit_date), utm_source, utm_medium, utm_campaign
),

-- 2. Leads (Último toque antes de conversión)
lead_last_click AS (
    SELECT
        l.lead_id, l.amount, l.closing_reason, l.status_id,
        ps.visit_date,
        ps.source AS utm_source, ps.medium AS utm_medium, ps.campaign AS utm_campaign,
        ROW_NUMBER() OVER (PARTITION BY l.lead_id ORDER BY ps.visit_date DESC) AS rn
    FROM leads AS l
    INNER JOIN paid_sessions AS ps
        ON ps.visitor_id = l.visitor_id AND ps.visit_date <= l.created_at
),
leads_agg AS (
    SELECT
        DATE(visit_date) AS visit_date,
        utm_source, utm_medium, utm_campaign,
        COUNT(lead_id) AS leads_count,
        COUNT(lead_id) FILTER (WHERE closing_reason = 'Успешная продажа' OR status_id = 142) AS purchases_count,
        SUM(amount) FILTER (WHERE closing_reason = 'Успешная продажа' OR status_id = 142) AS revenue
    FROM lead_last_click
    WHERE rn = 1
    GROUP BY DATE(visit_date), utm_source, utm_medium, utm_campaign
),

-- 3. Costos de Ads
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
),

-- 4. Puente Maestro: Unimos todas las dimensiones para no perder ningún dato con los LEFT JOIN
campaign_dates AS (
    SELECT visit_date, utm_source, utm_medium, utm_campaign FROM visits_agg
    UNION
    SELECT visit_date, utm_source, utm_medium, utm_campaign FROM leads_agg
    UNION
    SELECT visit_date, utm_source, utm_medium, utm_campaign FROM ads_agg
)

-- 5. Select Final Cruzado
SELECT
    cd.visit_date,
    COALESCE(v.visitors_count, 0) AS visitors_count,
    cd.utm_source,
    cd.utm_medium,
    cd.utm_campaign,
    a.total_cost,
    COALESCE(l.leads_count, 0) AS leads_count,
    COALESCE(l.purchases_count, 0) AS purchases_count,
    l.revenue
FROM campaign_dates AS cd
LEFT JOIN visits_agg AS v
    ON cd.visit_date = v.visit_date AND cd.utm_source = v.utm_source AND cd.utm_medium = v.utm_medium AND cd.utm_campaign = v.utm_campaign
LEFT JOIN ads_agg AS a
    ON cd.visit_date = a.visit_date AND cd.utm_source = a.utm_source AND cd.utm_medium = a.utm_medium AND cd.utm_campaign = a.utm_campaign
LEFT JOIN leads_agg AS l
    ON cd.visit_date = l.visit_date AND cd.utm_source = l.utm_source AND cd.utm_medium = l.utm_medium AND cd.utm_campaign = l.utm_campaign
ORDER BY
    revenue DESC NULLS LAST,
    cd.visit_date ASC,
    visitors_count DESC,
    cd.utm_source ASC,
    cd.utm_medium ASC,
    cd.utm_campaign ASC
LIMIT 15;