-- =====================================================================================
-- 08_red_flags.sql   (JD #6: red flags, trends and actionable insights for management)
-- DATA IS SIMULATED.
--
-- KEY IDEAS
--  * One row per issue, with the metric, the threshold and a plain-English message. This is the
--    table a non-technical stakeholder reads - the other scripts are the evidence behind each row.
--  * Every flag is rule-based and the thresholds sit in the query, so they can be debated and changed.
--  * Each block is a CTE with the same columns, combined with UNION ALL.
--  * Statistical flags (conversion) use the z-test from 03 so noise doesn't create false alarms.
--    Rule of thumb: with 10 nurseries tested, expect ~1 false positive at |z| > 2 - hence 'Medium', not 'High'.
-- =====================================================================================

-- Q1 Red-flag register (as of 31 Oct 2026)
WITH conv AS (          -- lead conversion Jan-Aug, 2026 vs 2025, mature leads
    SELECT nursery_id,
           SUM(CASE WHEN strftime('%Y', lead_date) = '2025' THEN 1 ELSE 0 END) AS n25,
           SUM(CASE WHEN strftime('%Y', lead_date) = '2025' THEN is_enrolled ELSE 0 END) AS e25,
           SUM(CASE WHEN strftime('%Y', lead_date) = '2026' THEN 1 ELSE 0 END) AS n26,
           SUM(CASE WHEN strftime('%Y', lead_date) = '2026' THEN is_enrolled ELSE 0 END) AS e26
    FROM v_leads_clean
    WHERE strftime('%m', lead_date) <= '08' AND is_mature = 1
    GROUP BY nursery_id
),
conv_z AS (
    SELECT nursery_id, 1.0 * e25 / n25 AS p25, 1.0 * e26 / n26 AS p26,
           (1.0 * e26 / n26 - 1.0 * e25 / n25) /
           SQRT((1.0 * (e25 + e26) / (n25 + n26)) * (1 - 1.0 * (e25 + e26) / (n25 + n26)) * (1.0 / n25 + 1.0 / n26)) AS z
    FROM conv
),
hc AS (                 -- latest-month headcount vs target
    SELECT a.nursery_id, a.headcount, t.target, n.capacity
    FROM (SELECT nursery_id, COUNT(*) AS headcount FROM invoices WHERE invoice_month = '2026-10-01' GROUP BY nursery_id) a
    JOIN (SELECT nursery_id, SUM(target_value) AS target FROM targets WHERE metric = 'headcount' AND month = '2026-10-01' GROUP BY nursery_id) t USING (nursery_id)
    JOIN nurseries n USING (nursery_id)
),
fin AS (                -- YTD 2026 profitability
    SELECT p.nursery_id, 100.0 * SUM(ebitda_aed) / SUM(total_revenue_aed) AS margin,
           100.0 * SUM(rent_aed) / SUM(total_revenue_aed) AS rent_pct, n.open_date
    FROM pnl_monthly p JOIN nurseries n USING (nursery_id)
    WHERE p.month BETWEEN '2026-01-01' AND '2026-10-01'
    GROUP BY p.nursery_id, n.open_date
),
agg AS (                -- NETWORK-level: share of leads from the Aggregator Portal, Jan-Oct 2026 vs Jan-Oct 2025
    SELECT 100.0 * SUM(CASE WHEN strftime('%Y', lead_date) = '2026' AND lead_source = 'Aggregator Portal' THEN 1 ELSE 0 END)
                 / SUM(CASE WHEN strftime('%Y', lead_date) = '2026' THEN 1 ELSE 0 END) AS share26,
           100.0 * SUM(CASE WHEN strftime('%Y', lead_date) = '2025' AND lead_source = 'Aggregator Portal' THEN 1 ELSE 0 END)
                 / SUM(CASE WHEN strftime('%Y', lead_date) = '2025' AND strftime('%m', lead_date) <= '10' THEN 1 ELSE 0 END) AS share25
    FROM v_leads_clean
    WHERE strftime('%m', lead_date) <= '10'
),
old_debt AS (           -- AED unpaid more than 60 days past due, as % of the last 12 months of billing
    SELECT i.nursery_id,
           100.0 * SUM(CASE WHEN i.paid_date IS NULL AND i.days_past_due_asof > 60 THEN i.amount_aed ELSE 0 END)
                 / SUM(CASE WHEN i.invoice_month >= '2025-11-01' THEN i.amount_aed ELSE 0 END) AS pct_old_debt
    FROM v_invoices i GROUP BY i.nursery_id
),
flags AS (
    SELECT nursery_id, 'Lead conversion falling' AS flag,
           CASE WHEN z < -2.3 THEN 'High' ELSE 'Medium' END AS severity,
           ROUND(100 * p26, 1) AS value, ROUND(100 * p25, 1) AS benchmark,
           'Conversion Jan-Aug ' || ROUND(100 * p26, 1) || '% vs ' || ROUND(100 * p25, 1) || '% last year (z=' || ROUND(z, 2) || ')' AS message
    FROM conv_z WHERE p26 < 0.7 * p25 AND z < -2
    UNION ALL
    SELECT nursery_id, 'Headcount below target',
           CASE WHEN headcount < 0.90 * target THEN 'High' ELSE 'Medium' END,
           headcount, ROUND(target, 0),
           'Oct headcount ' || headcount || ' vs target ' || ROUND(target, 0) || ' (' || ROUND(100.0 * (headcount - target) / target, 1) || '%)'
    FROM hc WHERE headcount < 0.95 * target
    UNION ALL
    SELECT nursery_id, 'Low occupancy', 'Medium',
           ROUND(100.0 * headcount / capacity, 1), 80,
           'Occupancy ' || ROUND(100.0 * headcount / capacity, 1) || '% - below 80% the fixed staff and rent base is under-used'
    FROM hc WHERE 100.0 * headcount / capacity < 80
    UNION ALL
    SELECT nursery_id, 'Thin EBITDA margin',
           CASE WHEN open_date > date('2026-10-31', '-36 month') THEN 'Watch (site < 3 yrs old)' ELSE 'High' END,
           ROUND(margin, 1), 15,
           'YTD EBITDA margin ' || ROUND(margin, 1) || '% vs 15% internal floor'
    FROM fin WHERE margin < 10
    UNION ALL
    SELECT nursery_id, 'Rent burden', 'High', ROUND(rent_pct, 1), 18,
           'Rent is ' || ROUND(rent_pct, 1) || '% of revenue (network ~17%) - needs renegotiation, sublet or higher yield per seat'
    FROM fin WHERE rent_pct > 25
    UNION ALL
    SELECT 'NETWORK', 'Lead mix shifting to aggregator portal', 'Medium', ROUND(share26, 1), ROUND(share25, 1),
           'Aggregator share of leads ' || ROUND(share26, 1) || '% (was ' || ROUND(share25, 1) || '%) - high volume, ~3% conversion, highest cost per lead'
    FROM agg WHERE share26 - share25 > 4
    UNION ALL
    SELECT nursery_id, 'Old receivables', 'Medium', ROUND(pct_old_debt, 2), 0.8,
           'Unpaid > 60 days past due = ' || ROUND(pct_old_debt, 2) || '% of last-12-month billing (network ~0.8%)'
    FROM old_debt WHERE pct_old_debt > 1.0
)
SELECT nursery_id, flag, severity, value, benchmark, message
FROM flags
ORDER BY CASE severity WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END, nursery_id, flag;
