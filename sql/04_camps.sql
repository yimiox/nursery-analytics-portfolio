-- =====================================================================================
-- 04_camps.sql   (JD #1: camp conversions)
-- DATA IS SIMULATED.
--
-- KEY IDEAS
--  * Camp conversion = share of EXTERNAL camp attendees (not yet enrolled) who later enrol. The camps table
--    stores the count (converted_children), and children.camp_id lets us verify it row by row.
--  * Compare like-for-like seasons: Spring and Summer exist in both years. Winter camp only ran in Dec 2025
--    (Dec 2026 hasn't happened), so it has no prior-year comparison.
-- =====================================================================================

-- Q1 Camp conversion by season and year vs target (whole network)
WITH c AS (
    SELECT season, CAST(strftime('%Y', start_date) AS INTEGER) AS yr,
           COUNT(*)                   AS camps_run,
           SUM(external_registrations) AS attendees,
           SUM(converted_children)     AS converted,
           SUM(camp_revenue_aed)       AS camp_revenue
    FROM camps
    GROUP BY season, yr
),
tgt AS (
    SELECT AVG(target_value) AS target_rate FROM targets WHERE metric = 'camp_conversion_rate'
)
SELECT season, yr, camps_run, attendees, converted,
       ROUND(100.0 * converted / attendees, 1) AS conversion_pct,
       ROUND(100 * (SELECT target_rate FROM tgt), 1) AS target_pct,
       camp_revenue,
       ROUND(100.0 * converted / attendees
             - LAG(100.0 * converted / attendees) OVER (PARTITION BY season ORDER BY yr), 1) AS change_vs_py_pts
FROM c
ORDER BY season, yr;

-- Q2 Camp conversion by nursery, 2026 vs 2025 (Spring + Summer only, like-for-like)
SELECT n.nursery_id, n.nursery_name,
       SUM(CASE WHEN strftime('%Y', c.start_date) = '2025' THEN c.external_registrations END) AS attendees_2025,
       SUM(CASE WHEN strftime('%Y', c.start_date) = '2026' THEN c.external_registrations END) AS attendees_2026,
       ROUND(100.0 * SUM(CASE WHEN strftime('%Y', c.start_date) = '2025' THEN c.converted_children END)
                   / SUM(CASE WHEN strftime('%Y', c.start_date) = '2025' THEN c.external_registrations END), 1) AS conv_2025_pct,
       ROUND(100.0 * SUM(CASE WHEN strftime('%Y', c.start_date) = '2026' THEN c.converted_children END)
                   / SUM(CASE WHEN strftime('%Y', c.start_date) = '2026' THEN c.external_registrations END), 1) AS conv_2026_pct
FROM camps c JOIN nurseries n USING (nursery_id)
WHERE c.season IN ('Spring', 'Summer')
GROUP BY n.nursery_id, n.nursery_name
ORDER BY n.nursery_id;

-- Q3 Reconciliation check: camps.converted_children must equal children rows with that camp_id
SELECT COUNT(*) AS camps_checked,
       SUM(c.converted_children <> COALESCE(k.n, 0)) AS mismatches
FROM camps c
LEFT JOIN (SELECT camp_id, COUNT(*) AS n FROM children WHERE camp_id IS NOT NULL GROUP BY camp_id) k USING (camp_id);
