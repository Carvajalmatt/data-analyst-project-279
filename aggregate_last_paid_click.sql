WITH paid_sessions AS (
    SELECT visitor_id, visit_date, source, medium, campaign
    FROM sessions
    WHERE medium IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

visitor_last_touch AS (
    SELECT
        visitor_id,
        visit_date,
        source AS utm_source,
        medium AS utm_medium,
        campaign AS utm_campaign,
        ROW_NUMBER() OVER (
            PARTITION BY visitor_id
            ORDER BY visit_date DESC
        ) AS rn
    FROM paid_sessions
),

agg_metrics AS (
    SELECT
        DATE(v.visit_date) AS visit_date,
        v.utm_source,
        v.utm_medium,
        v.utm_campaign,
        COUNT(DISTINCT v.visitor_id) AS visitors_count,
        COUNT(l.lead_id) AS leads_count,
        COUNT(l.lead_id) FILTER (WHERE l.closing_reason = 'Успешная продажа' OR l.status_id = 142) AS purchases_count,
        SUM(l.amount) FILTER (WHERE l.closing_reason = 'Успешная продажа' OR l.status_id = 142) AS revenue
    FROM visitor_last_touch AS v
    LEFT JOIN leads AS l
        ON v.visitor_id = l.visitor_id 
        AND v.visit_date <= l.created_at
    WHERE v.rn = 1
    GROUP BY DATE(v.visit_date), v.utm_source, v.utm_medium, v.utm_campaign
),

ads_union AS (
    SELECT utm_source, utm_medium, utm_campaign, DATE(campaign_date) AS campaign_date, daily_spent FROM vk_ads
    UNION ALL
    SELECT utm_source, utm_medium, utm_campaign, DATE(campaign_date) AS campaign_date, daily_spent FROM ya_ads
),

ads_agg AS (
    SELECT
        campaign_date AS visit_date,
        utm_source, utm_medium, utm_campaign,
        SUM(daily_spent) AS total_cost
    FROM ads_union
    GROUP BY campaign_date, utm_source, utm_medium, utm_campaign
)

SELECT
    agg.visit_date,
    agg.visitors_count,
    agg.utm_source,
    agg.utm_medium,
    agg.utm_campaign,
    a.total_cost,
    agg.leads_count,
    agg.purchases_count,
    agg.revenue
FROM agg_metrics AS agg
LEFT JOIN ads_agg AS a
    ON agg.visit_date = a.visit_date
    AND agg.utm_source = a.utm_source
    AND agg.utm_medium = a.utm_medium
    AND agg.utm_campaign = a.utm_campaign
ORDER BY
    agg.revenue DESC NULLS LAST,
    agg.visit_date ASC,
    agg.visitors_count DESC,
    agg.utm_source ASC,
    agg.utm_medium ASC,
    agg.utm_campaign ASC
LIMIT 15;