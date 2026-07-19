-- ============================================================
-- dashboard.sql
-- Consultas usadas para construir el dashboard de marketing
-- y las conclusiones de la presentación final.
-- Base de datos: marketingdb (PostgreSQL)
-- ============================================================


-- ------------------------------------------------------------
-- 1. LAST PAID CLICK ATTRIBUTION
-- Atribuye cada lead al último clic pagado antes de la conversión.
-- (también usada como base para las consultas 2, 3 y 4)
-- ------------------------------------------------------------

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
        lead_id, visitor_id, created_at, amount, closing_reason, status_id,
        visit_date, utm_source, utm_medium, utm_campaign
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
)

SELECT
    visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
    NULL::varchar AS lead_id, NULL::timestamp AS created_at,
    NULL::integer AS amount, NULL::varchar AS closing_reason, NULL::bigint AS status_id
FROM non_lead_visitors
WHERE rn = 1

UNION ALL

SELECT
    visitor_id, visit_date, utm_source, utm_medium, utm_campaign,
    lead_id, created_at, amount, closing_reason, status_id
FROM lead_attributed

ORDER BY
    amount DESC NULLS LAST,
    visit_date ASC,
    utm_source ASC,
    utm_medium ASC,
    utm_campaign ASC;


-- ------------------------------------------------------------
-- 2. AGGREGATE LAST PAID CLICK
-- Tabla resumen por día + UTM tags: visitas, gasto, leads,
-- ventas e ingresos. Es la fuente principal del dashboard de Power BI.
-- ------------------------------------------------------------

WITH paid_sessions AS (
    SELECT
        visitor_id, visit_date, source, medium, campaign
    FROM sessions
    WHERE medium IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

visits_agg AS (
    SELECT
        DATE(visit_date) AS visit_date,
        source AS utm_source,
        medium AS utm_medium,
        campaign AS utm_campaign,
        COUNT(DISTINCT visitor_id) AS visitors_count
    FROM paid_sessions
    GROUP BY DATE(visit_date), source, medium, campaign
),

lead_last_click AS (
    SELECT
        l.lead_id, l.amount, l.closing_reason, l.status_id,
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
        DATE(visit_date) AS visit_date,
        utm_source, utm_medium, utm_campaign,
        lead_id, amount, closing_reason, status_id
    FROM lead_last_click
    WHERE rn = 1
),

leads_agg AS (
    SELECT
        visit_date, utm_source, utm_medium, utm_campaign,
        COUNT(lead_id) AS leads_count,
        COUNT(*) FILTER (
            WHERE closing_reason = 'Успешная продажа' OR status_id = 142
        ) AS purchases_count,
        SUM(amount) FILTER (
            WHERE closing_reason = 'Успешная продажа' OR status_id = 142
        ) AS revenue
    FROM lead_attributed
    GROUP BY visit_date, utm_source, utm_medium, utm_campaign
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
    revenue DESC NULLS LAST;


-- ------------------------------------------------------------
-- 3. TIEMPO HASTA LA CONVERSIÓN (percentil 90)
-- ¿Cuántos días pasan, desde el último clic pagado hasta que el
-- visitante se vuelve lead, para que se cierre el 90% de los leads?
-- Usada para responder: "¿cuándo puede el equipo empezar a
-- analizar una campaña con el dashboard?"
-- ------------------------------------------------------------

WITH paid_sessions AS (
    SELECT visitor_id, visit_date
    FROM sessions
    WHERE medium IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
),

lead_click AS (
    SELECT
        l.lead_id,
        l.created_at,
        MAX(ps.visit_date) AS last_click
    FROM leads AS l
    INNER JOIN paid_sessions AS ps
        ON ps.visitor_id = l.visitor_id AND ps.visit_date <= l.created_at
    GROUP BY l.lead_id, l.created_at
),

dias AS (
    SELECT
        lead_id,
        EXTRACT(EPOCH FROM (created_at - last_click)) / 86400.0 AS dias_hasta_lead
    FROM lead_click
)

SELECT
    PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY dias_hasta_lead) AS dias_percentil_90
FROM dias;


-- ------------------------------------------------------------
-- 4. TRÁFICO ORGÁNICO POR DÍA
-- Visitas diarias de canales NO pagados, para comparar contra el
-- gasto/tráfico pagado y evaluar si existe correlación con el
-- lanzamiento de campañas.
-- ------------------------------------------------------------

SELECT
    DATE(visit_date) AS visit_date,
    COUNT(DISTINCT visitor_id) AS organic_visitors
FROM sessions
WHERE medium NOT IN ('cpc', 'cpm', 'cpa', 'youtube', 'cpp', 'tg', 'social')
   OR medium IS NULL
GROUP BY DATE(visit_date)
ORDER BY visit_date;