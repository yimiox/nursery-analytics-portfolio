-- =====================================================================================
-- 06_collections_cashflow.sql   (JD #3: parent payment patterns -> collections and cash-flow forecasting)
-- DATA IS SIMULATED.
--
-- KEY IDEAS
--  * Cash flow is about TIMING, not just amounts. Invoices are issued on the 1st and due 10 days later.
--    The question for a forecast is: of each AED billed, how much arrives by day X after the due date?
--    That "collection curve" (Q2) is the input to the Python cash-flow forecast.
--  * Seasonality matters: summer (Jul-Sep) and Dec-Jan pay later, so use separate curves for them.
--  * Ageing (Q3) is a snapshot as of 31 Oct 2026 - it measures risk in what is still unpaid.
--  * Pareto (Q5): payment problems are usually concentrated in a small group of families - find them.
-- =====================================================================================

-- Q1 Late-payment seasonality by calendar month (2025 and 2026 pooled, paid invoices)
SELECT inv_mon AS month_no,
       COUNT(*) AS paid_invoices,
       ROUND(100.0 * AVG(1 - paid_on_time), 1)                                  AS pct_paid_late,
       ROUND(AVG(CASE WHEN days_after_due > 0 THEN days_after_due END), 1)      AS avg_days_late_when_late,
       ROUND(100.0 * AVG(CASE WHEN days_after_due > 30 THEN 1.0 ELSE 0 END), 1) AS pct_over_30_days
FROM v_invoices
WHERE paid_date IS NOT NULL
GROUP BY inv_mon
ORDER BY inv_mon;

-- Q2 Collection curve: cumulative % of billed AED collected by N days after due date (2025 invoices = fully matured)
WITH b AS (
    SELECT CASE WHEN inv_mon IN (7, 8, 9, 12, 1) THEN 'Peak-late months (Jul-Sep, Dec-Jan)' ELSE 'Normal months' END AS season,
           amount_aed,
           CASE WHEN days_after_due IS NULL THEN 99
                WHEN days_after_due <= 0   THEN 0
                WHEN days_after_due <= 7   THEN 7
                WHEN days_after_due <= 14  THEN 14
                WHEN days_after_due <= 30  THEN 30
                WHEN days_after_due <= 60  THEN 60
                ELSE 90 END AS bucket          -- 99 = never collected (written off or still open)
    FROM v_invoices
    WHERE inv_year = 2025
),
agg AS (
    SELECT season, bucket, SUM(amount_aed) AS aed FROM b GROUP BY season, bucket
)
SELECT season,
       CASE bucket WHEN 0 THEN 'on/before due date' WHEN 99 THEN 'not collected' ELSE '<= ' || bucket || ' days after due' END AS collected_by,
       aed,
       ROUND(100.0 * SUM(aed) OVER (PARTITION BY season ORDER BY bucket ROWS UNBOUNDED PRECEDING)
                   / SUM(aed) OVER (PARTITION BY season), 1) AS cumulative_pct
FROM agg
ORDER BY season, bucket;

-- Q3 Ageing of unpaid invoices as of 31 Oct 2026, by nursery (AED). d90_plus includes invoices already written off
SELECT nursery_id,
       SUM(CASE WHEN days_past_due_asof BETWEEN 1 AND 30 THEN amount_aed ELSE 0 END)              AS d1_30,
       SUM(CASE WHEN days_past_due_asof BETWEEN 31 AND 60 THEN amount_aed ELSE 0 END)             AS d31_60,
       SUM(CASE WHEN days_past_due_asof BETWEEN 61 AND 90 THEN amount_aed ELSE 0 END)             AS d61_90,
       SUM(CASE WHEN days_past_due_asof > 90 THEN amount_aed ELSE 0 END)                          AS d90_plus,
       SUM(amount_aed)                                                                            AS total_unpaid
FROM v_invoices
WHERE paid_date IS NULL
GROUP BY nursery_id
ORDER BY d90_plus DESC, total_unpaid DESC;

-- Q4 Billed vs cash received by month (cash is dated by paid_date). Running gap = cash tied up in receivables
WITH billed AS (
    SELECT strftime('%Y-%m', invoice_month) AS ym, SUM(amount_aed) AS billed FROM invoices GROUP BY ym
),
cash AS (
    SELECT strftime('%Y-%m', paid_date) AS ym, SUM(amount_aed) AS collected FROM invoices WHERE paid_date IS NOT NULL GROUP BY ym
)
SELECT b.ym, b.billed, COALESCE(c.collected, 0) AS collected,
       SUM(b.billed - COALESCE(c.collected, 0)) OVER (ORDER BY b.ym) AS receivables_outstanding
FROM billed b LEFT JOIN cash c USING (ym)
ORDER BY b.ym;

-- Q5 Pareto: how concentrated are late payments?  Families grouped into deciles by number of late invoices
WITH per_parent AS (
    SELECT parent_id,
           COUNT(*) AS invoices,
           SUM(CASE WHEN paid_date IS NULL OR paid_on_time = 0 THEN 1 ELSE 0 END) AS late_invoices
    FROM v_invoices
    WHERE due_date < '2026-10-31'
    GROUP BY parent_id
    HAVING COUNT(*) >= 6                    -- need enough history to judge behaviour
),
ranked AS (
    SELECT *, NTILE(10) OVER (ORDER BY late_invoices DESC, parent_id) AS decile
    FROM per_parent
)
SELECT decile, COUNT(*) AS families, SUM(late_invoices) AS late_invoices,
       ROUND(100.0 * SUM(late_invoices) / SUM(SUM(late_invoices)) OVER (), 1)                         AS pct_of_all_late,
       ROUND(100.0 * SUM(SUM(late_invoices)) OVER (ORDER BY decile) / SUM(SUM(late_invoices)) OVER (), 1) AS cumulative_pct
FROM ranked
GROUP BY decile
ORDER BY decile;

-- Q6 Payment method vs lateness (paid invoices)
SELECT payment_method, COUNT(*) AS invoices,
       ROUND(100.0 * AVG(1 - paid_on_time), 1) AS pct_late,
       ROUND(AVG(CASE WHEN days_after_due > 0 THEN days_after_due END), 1) AS avg_days_late_when_late
FROM v_invoices
WHERE paid_date IS NOT NULL
GROUP BY payment_method
ORDER BY pct_late DESC;
