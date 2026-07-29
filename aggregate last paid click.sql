-- Gastos publicitarios agregados según el modelo Last Paid Click (CORREGIDA v4)
-- Cambio v4: los leads ahora se atribuyen usando el ÚLTIMO TOQUE PAGADO
-- ABSOLUTO del visitante (la misma tabla usada para contar visitantes),
-- no el último clic "antes de la creación de ese lead específico".
-- Antes, un visitante que volvía a visitar por otro canal DESPUÉS de dejar
-- sus datos seguía dándole crédito al canal viejo; ahora el crédito es
-- siempre para el canal de su verdadero último contacto pagado.

WITH paid_sessions AS (
    SELECT
        visitor_id, visit_date, source, medium, campaign
    FROM sessions
    WHERE medium IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

-- Último clic pagado ABSOLUTO de cada visitante (una sola fila por visitante)
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

visits_agg AS (
    SELECT
        DATE(visit_date) AS visit_date,
        utm_source, utm_medium, utm_campaign,
        COUNT(DISTINCT visitor_id) AS visitors_count
    FROM visitor_last_touch
    WHERE rn = 1
    GROUP BY DATE(visit_date), utm_source, utm_medium, utm_campaign
),

-- Los leads se atribuyen al ÚLTIMO TOQUE PAGADO ABSOLUTO del visitante
leads_agg AS (
    SELECT
        DATE(vlt.visit_date) AS visit_date,
        vlt.utm_source, vlt.utm_medium, vlt.utm_campaign,
        COUNT(l.lead_id) AS leads_count,
        COUNT(*) FILTER (
            WHERE l.closing_reason = 'Успешная продажа' OR l.status_id = 142
        ) AS purchases_count,
        SUM(l.amount) FILTER (
            WHERE l.closing_reason = 'Успешная продажа' OR l.status_id = 142
        ) AS revenue
    FROM leads AS l
    INNER JOIN visitor_last_touch AS vlt
        ON vlt.visitor_id = l.visitor_id AND vlt.rn = 1
    GROUP BY DATE(vlt.visit_date), vlt.utm_source, vlt.utm_medium, vlt.utm_campaign
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
    revenue DESC NULLS LAST,
    v.visit_date ASC,
    v.visitors_count DESC,
    v.utm_source ASC,
    v.utm_medium ASC,
    v.utm_campaign ASC
LIMIT 15;