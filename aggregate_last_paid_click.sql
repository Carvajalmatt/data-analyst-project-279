WITH paid_sessions AS (
    SELECT
        visitor_id, visit_date, source, medium, campaign
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
        ON ps.visitor_id = l.visitor_id
        AND ps.visit_date <= l.created_at
),

lead_attributed AS (
    SELECT
        lead_id, visitor_id, created_at, amount, closing_reason, status_id,
        visit_date, utm_source, utm_medium, utm_campaign
    FROM lead_last_click
    WHERE rn = 1
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

attribution_model AS (
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

agg_metrics AS (
    SELECT
        DATE(visit_date) AS visit_date,
        utm_source,
        utm_medium,
        utm_campaign,
        COUNT(visitor_id) AS visitors_count,
        COUNT(lead_id) AS leads_count,
        COUNT(lead_id) FILTER (WHERE closing_reason = 'Успешная продажа' OR status_id = 142) AS purchases_count,
        SUM(amount) FILTER (WHERE closing_reason = 'Успешная продажа' OR status_id = 142) AS revenue
    FROM attribution_model
    GROUP BY DATE(visit_date), utm_source, utm_medium, utm_campaign
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
    ads.total_cost,
    agg.leads_count,
    agg.purchases_count,
    agg.revenue
FROM agg_metrics AS agg
LEFT JOIN ads_agg AS ads
    ON agg.visit_date = ads.visit_date
    AND agg.utm_source = ads.utm_source
    AND agg.utm_medium = ads.utm_medium
    AND agg.utm_campaign = ads.utm_campaign
ORDER BY
    agg.revenue DESC NULLS LAST,
    agg.visit_date ASC,
    agg.visitors_count DESC,
    agg.utm_source ASC,
    agg.utm_medium ASC,
    agg.utm_campaign ASC
LIMIT 15;