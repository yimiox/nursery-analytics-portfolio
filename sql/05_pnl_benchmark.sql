-- =====================================================================================
-- 05_pnl_benchmark.sql   (JD #2: nursery P&L benchmarking, EBITDA per child, profitability opportunities)
-- DATA IS SIMULATED.
--
-- KEY IDEAS
--  * Benchmark on RATIOS (% of revenue, AED per child-month), never raw AED - a 140-seat site will always
--    have bigger absolute numbers than a 90-seat site.
--  * "Child-month" = one child billed for one month. EBITDA per child = EBITDA / child-months.
--  * Network benchmark must be REVENUE-WEIGHTED (SUM(cost)/SUM(revenue)), not the average of site percentages.
--  * Staffing and rent are step-fixed: margin is highly sensitive to occupancy (operating leverage). So a low
--    margin is not automatically a cost problem - Q3 separates "empty seats" from "expensive cost base".
-- =====================================================================================

-- Q1 EBITDA league table, Jan-Oct 2026 (vs Jan-Oct 2025)
WITH y AS (
    SELECT nursery_id, CAST(strftime('%Y', month) AS INTEGER) AS yr,
           SUM(total_revenue_aed) AS revenue, SUM(ebitda_aed) AS ebitda, SUM(children_billed) AS child_months,
           SUM(staff_cost_aed) AS staff, SUM(rent_aed) AS rent
    FROM pnl_monthly
    WHERE strftime('%m', month) <= '10'
    GROUP BY nursery_id, yr
),
cur AS (
    SELECT c.nursery_id, c.revenue, c.ebitda, c.child_months,
           100.0 * c.ebitda / c.revenue AS margin_pct,
           100.0 * p.ebitda / p.revenue AS margin_py_pct,
           1.0 * c.ebitda / c.child_months AS ebitda_per_child,
           1.0 * p.ebitda / p.child_months AS ebitda_per_child_py,
           100.0 * c.rent / c.revenue  AS rent_pct,
           100.0 * c.staff / c.revenue AS staff_pct
    FROM y c JOIN y p ON p.nursery_id = c.nursery_id AND p.yr = 2025
    WHERE c.yr = 2026
)
SELECT nursery_id,
       ROUND(revenue / 1000.0) AS revenue_k, ROUND(ebitda / 1000.0) AS ebitda_k,
       ROUND(margin_pct, 1) AS margin_pct, ROUND(margin_py_pct, 1) AS margin_py_pct,
       ROUND(ebitda_per_child) AS ebitda_per_child_month, ROUND(ebitda_per_child_py) AS per_child_py,
       ROUND(rent_pct, 1) AS rent_pct, ROUND(staff_pct, 1) AS staff_pct,
       ROUND(margin_pct - 100.0 * SUM(ebitda) OVER () / SUM(revenue) OVER (), 1) AS vs_network_pts,
       RANK() OVER (ORDER BY margin_pct DESC) AS margin_rank
FROM cur
ORDER BY margin_rank;

-- Q2 Profitability opportunities: AED/year if each cost line matched the network ratio (only lines ABOVE network)
--    Opportunity = (site cost% - network cost%) x site revenue, annualised from Jan-Oct (x 12/10)
WITH base AS (
    SELECT nursery_id, SUM(total_revenue_aed) AS rev,
           SUM(staff_cost_aed) AS staff, SUM(rent_aed) AS rent, SUM(utilities_aed) AS utilities,
           SUM(food_consumables_aed) AS food, SUM(marketing_aed) AS marketing, SUM(other_opex_aed) AS other_opex
    FROM pnl_monthly
    WHERE month BETWEEN '2026-01-01' AND '2026-10-01'
    GROUP BY nursery_id
),
long AS (
    SELECT nursery_id, rev, 'Staff' AS cost_line, staff AS cost FROM base
    UNION ALL SELECT nursery_id, rev, 'Rent', rent FROM base
    UNION ALL SELECT nursery_id, rev, 'Utilities', utilities FROM base
    UNION ALL SELECT nursery_id, rev, 'Food & consumables', food FROM base
    UNION ALL SELECT nursery_id, rev, 'Marketing', marketing FROM base
    UNION ALL SELECT nursery_id, rev, 'Other opex', other_opex FROM base
),
bench AS (
    SELECT *, 1.0 * SUM(cost) OVER (PARTITION BY cost_line) / SUM(rev) OVER (PARTITION BY cost_line) AS network_pct
    FROM long
)
SELECT nursery_id, cost_line,
       ROUND(100.0 * cost / rev, 1)  AS site_pct_of_rev,
       ROUND(100.0 * network_pct, 1) AS network_pct,
       ROUND((1.0 * cost / rev - network_pct) * rev * 12 / 10 / 1000.0) AS annual_opportunity_k_aed
FROM bench
WHERE 1.0 * cost / rev > network_pct
ORDER BY (1.0 * cost / rev - network_pct) * rev DESC
LIMIT 8;

-- Q3 Operating leverage: when a site is fuller than ITS OWN normal, how much better is its margin?
--    Pooling all sites would be misleading: a structurally high-margin site (N02) sitting at low occupancy would
--    hide the effect (confounding). So compare each nursery-month with that nursery's own average
--    (AVG() OVER (PARTITION BY nursery_id)) and bucket by the occupancy deviation. N10 excluded (ramp-up trend).
--    Margin is measured EXCLUDING camp revenue: camps run in Jul/Aug exactly when occupancy dips, and would mask the effect.
WITH nm AS (
    SELECT p.nursery_id, p.month,
           100.0 * p.children_billed / n.capacity AS occ,
           100.0 * (p.ebitda_aed - p.camp_revenue_aed) / (p.total_revenue_aed - p.camp_revenue_aed) AS margin
    FROM pnl_monthly p JOIN nurseries n USING (nursery_id)
    WHERE p.nursery_id <> 'N10'
),
dev AS (
    SELECT *, occ    - AVG(occ)    OVER (PARTITION BY nursery_id) AS occ_dev,
              margin - AVG(margin) OVER (PARTITION BY nursery_id) AS margin_dev
    FROM nm
)
SELECT CASE WHEN occ_dev < -8 THEN '1) 8+ pts below own avg' WHEN occ_dev < -3 THEN '2) 3-8 pts below'
            WHEN occ_dev <= 3 THEN '3) within +/-3 pts'     WHEN occ_dev <= 8 THEN '4) 3-8 pts above'
            ELSE '5) 8+ pts above own avg' END AS occupancy_vs_own_normal,
       COUNT(*) AS nursery_months,
       ROUND(AVG(margin_dev), 1) AS avg_margin_diff_pts
FROM dev
GROUP BY occupancy_vs_own_normal
ORDER BY occupancy_vs_own_normal;

-- Q4 Why is N01 (Dubai Marina) thin?  Per child-month economics: N01 vs rest of network, Jan-Oct 2026
WITH g AS (
    SELECT CASE WHEN nursery_id = 'N01' THEN 'N01 Marina' ELSE 'Rest of network' END AS grp,
           SUM(children_billed) AS cm,
           SUM(total_revenue_aed) AS rev, SUM(staff_cost_aed) AS staff, SUM(rent_aed) AS rent,
           SUM(total_cost_aed - staff_cost_aed - rent_aed) AS other_cost, SUM(ebitda_aed) AS ebitda
    FROM pnl_monthly
    WHERE month BETWEEN '2026-01-01' AND '2026-10-01'
    GROUP BY grp
)
SELECT grp,
       ROUND(1.0 * rev / cm)        AS revenue_per_child,
       ROUND(1.0 * staff / cm)      AS staff_per_child,
       ROUND(1.0 * rent / cm)       AS rent_per_child,
       ROUND(1.0 * other_cost / cm) AS other_cost_per_child,
       ROUND(1.0 * ebitda / cm)     AS ebitda_per_child
FROM g;
