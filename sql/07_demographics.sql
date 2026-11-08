-- =====================================================================================
-- 07_demographics.sql   (JD #4: parent demographics - nationality, workplace, residential area)
-- DATA IS SIMULATED. Parent attributes are fictional and carry no personal data.
--
-- KEY IDEAS
--  * Always use the CLEANED view (v_parents_clean). On raw data, "UK", "U.K." and "British" would be three groups.
--  * Unit = ACTIVE CHILD (not family) so numbers tie to headcount. A family with 2 children counts twice.
--  * Top-N per group = ROW_NUMBER() OVER (PARTITION BY group ORDER BY count DESC) then filter rn <= N.
--  * Demographics are only useful if they change a decision: where to market, which employers to partner with,
--    which segments pay late. So Q4 links demographics back to payments.
-- =====================================================================================

-- Q1 Top 3 nationalities per nursery (active children, 31 Oct 2026)
WITH kids AS (
    SELECT c.nursery_id, p.nationality
    FROM children c JOIN v_parents_clean p USING (parent_id)
    WHERE c.leave_date IS NULL
),
cnt AS (
    SELECT nursery_id, nationality, COUNT(*) AS kids FROM kids GROUP BY nursery_id, nationality
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY nursery_id ORDER BY kids DESC, nationality) AS rn,
              ROUND(100.0 * kids / SUM(kids) OVER (PARTITION BY nursery_id), 1) AS pct_of_nursery
    FROM cnt
)
SELECT nursery_id, rn AS rank_in_nursery, nationality, kids, pct_of_nursery
FROM ranked
WHERE rn <= 3
ORDER BY nursery_id, rn;

-- Q2 Where do families live?  Share living in the nursery's own area, and the top 3 areas per nursery
WITH kids AS (
    SELECT c.nursery_id, n.area AS nursery_area, p.residential_area
    FROM children c
    JOIN v_parents_clean p USING (parent_id)
    JOIN nurseries n USING (nursery_id)
    WHERE c.leave_date IS NULL
),
cnt AS (
    SELECT nursery_id, nursery_area, residential_area, COUNT(*) AS kids FROM kids GROUP BY nursery_id, nursery_area, residential_area
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY nursery_id ORDER BY kids DESC) AS rn,
              ROUND(100.0 * kids / SUM(kids) OVER (PARTITION BY nursery_id), 1) AS pct_of_nursery,
              ROUND(100.0 * SUM(CASE WHEN residential_area = nursery_area THEN kids ELSE 0 END) OVER (PARTITION BY nursery_id)
                          / SUM(kids) OVER (PARTITION BY nursery_id), 1) AS pct_living_in_own_area
    FROM cnt
)
SELECT nursery_id, rn, residential_area, kids, pct_of_nursery, pct_living_in_own_area
FROM ranked
WHERE rn <= 3
ORDER BY nursery_id, rn;

-- Q3 Workplace: top employers by active children (network) - candidates for corporate partnerships
SELECT employer, employer_sector, COUNT(*) AS kids,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_network,
       ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY COUNT(*) DESC, employer) / SUM(COUNT(*)) OVER (), 1) AS cumulative_pct
FROM children c JOIN v_parents_clean p USING (parent_id)
WHERE c.leave_date IS NULL AND p.employer <> 'Unknown'
GROUP BY employer, employer_sector
ORDER BY kids DESC, employer
LIMIT 10;

-- Q4 Do demographics predict payment behaviour?  Late-payment rate by employer sector (paid invoices, all months)
SELECT p.employer_sector,
       COUNT(*) AS paid_invoices,
       ROUND(100.0 * AVG(1 - i.paid_on_time), 1) AS pct_paid_late,
       ROUND(AVG(CASE WHEN i.days_after_due > 0 THEN i.days_after_due END), 1) AS avg_days_late_when_late,
       ROUND(100.0 * AVG(1 - i.paid_on_time) - 100.0 * (SELECT AVG(1 - paid_on_time) FROM v_invoices WHERE paid_date IS NOT NULL), 1) AS vs_network_pts
FROM v_invoices i JOIN v_parents_clean p USING (parent_id)
WHERE i.paid_date IS NOT NULL
GROUP BY p.employer_sector
ORDER BY pct_paid_late DESC;

-- Q5 Data quality: how complete are the parent attributes? (tells management how far to trust Q1-Q4)
SELECT COUNT(*) AS parents,
       ROUND(100.0 * SUM(employer = 'Unknown') / COUNT(*), 1)         AS pct_employer_missing,
       ROUND(100.0 * SUM(residential_area = 'Unknown') / COUNT(*), 1) AS pct_area_missing
FROM v_parents_clean;
