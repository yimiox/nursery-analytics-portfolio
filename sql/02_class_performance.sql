-- =====================================================================================
-- 02_class_performance.sql   (JD #1: class-wise performance vs targets and previous year)
-- DATA IS SIMULATED.
--
-- KEY IDEAS
--  * Class (Infant ... FS2) is stored on each invoice - a child changes class every September,
--    so class must be taken from the month being billed, not from the child's enrolment record.
--  * Compare AVERAGE monthly headcount over the same months in both years (Jan-Oct), because a single
--    month is distorted by the Sept intake / July graduation cycle.
--  * SUM() OVER () gives a total next to each row, so we can show share of network without a second query.
-- =====================================================================================

-- Q1 Class-wise average headcount, Jan-Oct 2026 vs target vs Jan-Oct 2025 (whole network)
WITH monthly AS (
    SELECT inv_year AS yr, invoice_month AS month, class_name, COUNT(*) AS kids
    FROM v_invoices
    WHERE inv_mon <= 10
    GROUP BY inv_year, invoice_month, class_name
),
avg_by_year AS (
    SELECT class_name,
           ROUND(AVG(CASE WHEN yr = 2026 THEN kids END), 1) AS avg_2026,
           ROUND(AVG(CASE WHEN yr = 2025 THEN kids END), 1) AS avg_2025
    FROM (SELECT yr, class_name, month, kids FROM monthly)
    GROUP BY class_name
),
tgt AS (
    SELECT segment AS class_name, SUM(target_value) / 10.0 AS target_2026_avg    -- 10 months, summed over nurseries
    FROM targets
    WHERE metric = 'headcount' AND month BETWEEN '2026-01-01' AND '2026-10-01'
    GROUP BY segment
)
SELECT a.class_name, a.avg_2025, a.avg_2026, ROUND(t.target_2026_avg, 1) AS target_2026,
       ROUND(100.0 * (a.avg_2026 - t.target_2026_avg) / t.target_2026_avg, 1) AS vs_target_pct,
       ROUND(100.0 * (a.avg_2026 - a.avg_2025) / a.avg_2025, 1)               AS vs_py_pct,
       ROUND(100.0 * a.avg_2026 / SUM(a.avg_2026) OVER (), 1)                 AS share_of_network_pct
FROM avg_by_year a
JOIN tgt t USING (class_name)
ORDER BY CASE a.class_name WHEN 'Infant' THEN 1 WHEN 'Toddler' THEN 2 WHEN 'Nursery' THEN 3 WHEN 'FS1' THEN 4 ELSE 5 END;

-- Q2 Nursery x class shortfall vs target, Jan-Oct 2026 avg: the 10 biggest gaps (RANK picks them)
WITH act AS (
    SELECT nursery_id, class_name, SUM(kids) / 10.0 AS avg_actual
    FROM (SELECT nursery_id, class_name, invoice_month, COUNT(*) AS kids
          FROM v_invoices WHERE inv_year = 2026 AND inv_mon <= 10
          GROUP BY nursery_id, class_name, invoice_month)
    GROUP BY nursery_id, class_name
),
tgt AS (
    SELECT nursery_id, segment AS class_name, SUM(target_value) / 10.0 AS avg_target
    FROM targets
    WHERE metric = 'headcount' AND month BETWEEN '2026-01-01' AND '2026-10-01'
    GROUP BY nursery_id, segment
),
gap AS (
    SELECT a.nursery_id, a.class_name, ROUND(a.avg_actual, 1) AS avg_actual, ROUND(t.avg_target, 1) AS avg_target,
           ROUND(a.avg_actual - t.avg_target, 1) AS gap_children,
           ROUND(100.0 * (a.avg_actual - t.avg_target) / t.avg_target, 1) AS gap_pct
    FROM act a JOIN tgt t USING (nursery_id, class_name)
)
SELECT *, RANK() OVER (ORDER BY gap_children) AS shortfall_rank
FROM gap
ORDER BY shortfall_rank
LIMIT 10;

-- Q3 Class mix by nursery (is a site over-reliant on one class?) - latest month
SELECT nursery_id, class_name, COUNT(*) AS kids,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY nursery_id), 1) AS pct_of_nursery
FROM v_invoices
WHERE invoice_month = '2026-10-01'
GROUP BY nursery_id, class_name
ORDER BY nursery_id, CASE class_name WHEN 'Infant' THEN 1 WHEN 'Toddler' THEN 2 WHEN 'Nursery' THEN 3 WHEN 'FS1' THEN 4 ELSE 5 END;
