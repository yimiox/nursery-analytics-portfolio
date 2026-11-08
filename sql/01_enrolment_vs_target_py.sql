-- =====================================================================================
-- 01_enrolment_vs_target_py.sql   (JD #1: enrolments vs targets and vs previous year)
-- DATA IS SIMULATED.
--
-- KEY IDEAS
--  * "Headcount" in a month = number of children BILLED that month (one invoice per child-month).
--  * Targets are stored in LONG format (metric / segment / value). To compare with actuals we pivot
--    them with CONDITIONAL AGGREGATION: SUM(CASE WHEN metric = 'x' THEN value END).
--  * Previous year = the same nursery 12 months earlier. LAG(x, 12) OVER (PARTITION BY nursery ORDER BY month)
--    works because every nursery has exactly one row per month (no gaps). If months could be missing you
--    would self-join on date(month, '-12 month') instead.
-- =====================================================================================

-- Q1 Headcount, latest month (Oct 2026): actual vs target vs same month last year, by nursery
WITH actual AS (
    SELECT nursery_id, invoice_month AS month, COUNT(*) AS headcount
    FROM invoices
    GROUP BY nursery_id, invoice_month
),
target AS (
    SELECT nursery_id, month, SUM(target_value) AS target_headcount
    FROM targets
    WHERE metric = 'headcount'
    GROUP BY nursery_id, month
),
joined AS (
    SELECT a.nursery_id, a.month, a.headcount, t.target_headcount,
           LAG(a.headcount, 12) OVER (PARTITION BY a.nursery_id ORDER BY a.month) AS headcount_py
    FROM actual a
    JOIN target t ON t.nursery_id = a.nursery_id AND t.month = a.month
)
SELECT j.nursery_id, n.nursery_name, n.capacity,
       j.headcount, ROUND(j.target_headcount, 0) AS target, j.headcount_py,
       ROUND(100.0 * (j.headcount - j.target_headcount) / j.target_headcount, 1) AS vs_target_pct,
       ROUND(100.0 * (j.headcount - j.headcount_py) / j.headcount_py, 1)        AS vs_py_pct,
       ROUND(100.0 * j.headcount / n.capacity, 1)                               AS occupancy_pct
FROM joined j
JOIN nurseries n USING (nursery_id)
WHERE j.month = '2026-10-01'
ORDER BY vs_target_pct;

-- Q2 New enrolments YTD (Jan-Oct): 2026 vs target vs 2025, split by how the child arrived
WITH new_kids AS (
    SELECT nursery_id,
           CAST(strftime('%Y', enrol_date) AS INTEGER) AS yr,
           COUNT(*)                                     AS new_enrolments,
           SUM(CASE WHEN enrol_source = 'Lead' THEN 1 ELSE 0 END) AS from_leads,
           SUM(CASE WHEN enrol_source = 'Camp' THEN 1 ELSE 0 END) AS from_camps
    FROM children
    WHERE enrol_source <> 'Existing'                  -- 'Existing' = children already enrolled before Jan 2025
      AND strftime('%m', enrol_date) <= '10'          -- like-for-like: Jan-Oct in both years
    GROUP BY nursery_id, yr
),
tgt AS (
    SELECT nursery_id, SUM(target_value) AS target_new_2026
    FROM targets
    WHERE metric = 'new_enrolments' AND month BETWEEN '2026-01-01' AND '2026-10-01'
    GROUP BY nursery_id
)
SELECT c.nursery_id,
       MAX(CASE WHEN yr = 2025 THEN new_enrolments END) AS new_2025_ytd,
       MAX(CASE WHEN yr = 2026 THEN new_enrolments END) AS new_2026_ytd,
       MAX(CASE WHEN yr = 2026 THEN from_leads END)     AS from_leads_2026,
       MAX(CASE WHEN yr = 2026 THEN from_camps END)     AS from_camps_2026,
       ROUND(t.target_new_2026, 0)                      AS target_2026_ytd,
       ROUND(100.0 * MAX(CASE WHEN yr = 2026 THEN new_enrolments END) / t.target_new_2026 - 100, 1) AS vs_target_pct,
       ROUND(100.0 * (MAX(CASE WHEN yr = 2026 THEN new_enrolments END) * 1.0 /
                      MAX(CASE WHEN yr = 2025 THEN new_enrolments END) - 1), 1)                       AS vs_py_pct
FROM new_kids c
JOIN tgt t USING (nursery_id)
GROUP BY c.nursery_id, t.target_new_2026
ORDER BY vs_target_pct;

-- Q3 Network headcount trend with 12-month comparison and the leavers/joiners behind it
WITH monthly AS (
    SELECT invoice_month AS month, COUNT(*) AS headcount
    FROM invoices GROUP BY invoice_month
)
SELECT month, headcount,
       LAG(headcount, 12) OVER (ORDER BY month)                      AS headcount_py,
       headcount - LAG(headcount, 1) OVER (ORDER BY month)           AS change_vs_prev_month,
       ROUND(AVG(headcount) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0) AS rolling_3m_avg
FROM monthly
ORDER BY month;
