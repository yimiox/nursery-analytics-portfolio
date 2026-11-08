-- =====================================================================================
-- 03_leads_funnel.sql   (JD #5: leads, conversion rates, lead sources vs targets and previous year)
-- DATA IS SIMULATED.
--
-- KEY IDEAS
--  * MATURITY: a lead from last week hasn't had time to convert, so including it makes the latest
--    months look artificially bad. We only measure conversion on "mature" leads (>= 60 days old,
--    flag is_mature in v_leads_clean). Like-for-like windows: Jan-Aug of both years.
--  * MIX vs RATE: blended conversion can fall even if every channel is stable, simply because the
--    lead mix shifts toward a low-converting channel. Q2 splits the change into the two effects.
--  * SIGNIFICANCE: with ~100-180 leads per nursery, a drop from 15% to 10% can be luck. Q3 uses a two-proportion
--    z-test so a nursery is only flagged when the drop is large AND unlikely to be noise.
-- =====================================================================================

-- Q1 Funnel by source, Jan-Aug 2026 vs Jan-Aug 2025 vs target (mature leads, whole network)
WITH f AS (
    SELECT lead_source,
           CAST(strftime('%Y', lead_date) AS INTEGER) AS yr,
           COUNT(*)           AS leads,
           SUM(tour_booked)   AS tours,
           SUM(is_enrolled)   AS enrolled
    FROM v_leads_clean
    WHERE strftime('%m', lead_date) <= '08' AND is_mature = 1
    GROUP BY lead_source, yr
),
tgt AS (
    SELECT segment AS lead_source, ROUND(AVG(target_value), 3) AS target_conv
    FROM targets
    WHERE metric = 'lead_conversion_rate' AND segment <> 'All'
    GROUP BY segment
)
SELECT f.lead_source,
       MAX(CASE WHEN yr = 2025 THEN leads END)    AS leads_2025,
       MAX(CASE WHEN yr = 2026 THEN leads END)    AS leads_2026,
       ROUND(100.0 * MAX(CASE WHEN yr = 2026 THEN leads END) / MAX(CASE WHEN yr = 2025 THEN leads END) - 100, 1) AS lead_volume_yoy_pct,
       ROUND(100.0 * MAX(CASE WHEN yr = 2026 THEN tours END)    / MAX(CASE WHEN yr = 2026 THEN leads END), 1) AS tour_rate_2026_pct,
       ROUND(100.0 * MAX(CASE WHEN yr = 2025 THEN enrolled END) / MAX(CASE WHEN yr = 2025 THEN leads END), 1) AS conv_2025_pct,
       ROUND(100.0 * MAX(CASE WHEN yr = 2026 THEN enrolled END) / MAX(CASE WHEN yr = 2026 THEN leads END), 1) AS conv_2026_pct,
       ROUND(100 * t.target_conv, 1)                                                                          AS target_conv_pct
FROM f JOIN tgt t USING (lead_source)
GROUP BY f.lead_source, t.target_conv
ORDER BY leads_2026 DESC;

-- Q2 Why did blended conversion move? Split into MIX effect and RATE effect (same window as Q1)
--    blended_conv = SUM(share_s * conv_s).   Change = MIX + RATE where
--      MIX  = SUM( (share26 - share25) * (conv25_s - blended25) )   <- gaining share of a below-average channel hurts
--      RATE = SUM( share26 * (conv26 - conv25) )                    <- the channel itself got better/worse
--    (Subtracting blended25 doesn't change the total because shares sum to 1, but it makes each row readable.)
WITH f AS (
    SELECT lead_source, CAST(strftime('%Y', lead_date) AS INTEGER) AS yr,
           COUNT(*) AS leads, SUM(is_enrolled) AS enrolled
    FROM v_leads_clean
    WHERE strftime('%m', lead_date) <= '08' AND is_mature = 1
    GROUP BY lead_source, yr
),
w AS (
    SELECT lead_source,
           1.0 * SUM(CASE WHEN yr = 2025 THEN leads END) / (SELECT SUM(leads) FROM f WHERE yr = 2025) AS share25,
           1.0 * SUM(CASE WHEN yr = 2026 THEN leads END) / (SELECT SUM(leads) FROM f WHERE yr = 2026) AS share26,
           1.0 * SUM(CASE WHEN yr = 2025 THEN enrolled END) / SUM(CASE WHEN yr = 2025 THEN leads END) AS conv25,
           1.0 * SUM(CASE WHEN yr = 2026 THEN enrolled END) / SUM(CASE WHEN yr = 2026 THEN leads END) AS conv26
    FROM f GROUP BY lead_source
)
SELECT lead_source,
       ROUND(100 * share25, 1) AS share25_pct, ROUND(100 * share26, 1) AS share26_pct,
       ROUND(100 * (share26 - share25) * (conv25 - b.blended25), 2) AS mix_effect_pts,
       ROUND(100 * share26 * (conv26 - conv25), 2)                    AS rate_effect_pts,
       ROUND(100 * ((share26 - share25) * (conv25 - b.blended25) + share26 * (conv26 - conv25)), 2) AS total_pts
FROM w CROSS JOIN (SELECT SUM(share25 * conv25) AS blended25 FROM w) b
UNION ALL
SELECT 'TOTAL (blended conv: ' || ROUND(100 * SUM(share25 * conv25), 1) || '% -> ' || ROUND(100 * SUM(share26 * conv26), 1) || '%)', 100, 100,
       ROUND(100 * SUM((share26 - share25) * (conv25 - (SELECT SUM(share25 * conv25) FROM w))), 2),
       ROUND(100 * SUM(share26 * (conv26 - conv25)), 2),
       ROUND(100 * (SUM(share26 * conv26) - SUM(share25 * conv25)), 2)
FROM w;

-- Q3 Which nurseries are deteriorating?  Jan-Aug conversion 2026 vs 2025 with a two-proportion z-test
--    Why a z-test: with ~50-150 leads per nursery, a swing from 17% to 10% can be pure luck. The z-score says how many
--    standard errors apart the two rates are.  |z| > 2 is roughly "less than 5% chance this is noise".
--    z = (p26 - p25) / SQRT( p_pool * (1 - p_pool) * (1/n25 + 1/n26) )
--    Flag = drop of more than 30% AND z < -2.  (Needs SQRT: built into T-SQL / PostgreSQL / SQLite 3.35+)
WITH f AS (
    SELECT nursery_id,
           SUM(CASE WHEN strftime('%Y', lead_date) = '2025' THEN 1 ELSE 0 END)          AS n25,
           SUM(CASE WHEN strftime('%Y', lead_date) = '2025' THEN is_enrolled ELSE 0 END) AS e25,
           SUM(CASE WHEN strftime('%Y', lead_date) = '2026' THEN 1 ELSE 0 END)          AS n26,
           SUM(CASE WHEN strftime('%Y', lead_date) = '2026' THEN is_enrolled ELSE 0 END) AS e26
    FROM v_leads_clean
    WHERE strftime('%m', lead_date) <= '08' AND is_mature = 1
    GROUP BY nursery_id
),
r AS (
    SELECT *, 1.0 * e25 / n25 AS p25, 1.0 * e26 / n26 AS p26, 1.0 * (e25 + e26) / (n25 + n26) AS pp
    FROM f
)
SELECT nursery_id, n25, n26,
       ROUND(100 * p25, 1) AS conv_2025_pct, ROUND(100 * p26, 1) AS conv_2026_pct,
       ROUND(100.0 * (p26 - p25) / p25, 0) AS change_pct,
       ROUND((p26 - p25) / SQRT(pp * (1 - pp) * (1.0 / n25 + 1.0 / n26)), 2) AS z_score,
       CASE WHEN p26 < 0.7 * p25 AND (p26 - p25) / SQRT(pp * (1 - pp) * (1.0 / n25 + 1.0 / n26)) < -2
            THEN 'RED FLAG' ELSE '' END AS flag
FROM r
ORDER BY z_score;

-- Q4 Shape of the decline: quarterly conversion, N02 vs the rest of the network (mature leads)
SELECT strftime('%Y', lead_date) || '-Q' || ((CAST(strftime('%m', lead_date) AS INTEGER) + 2) / 3) AS quarter,
       ROUND(100.0 * SUM(CASE WHEN nursery_id = 'N02' THEN is_enrolled END) / SUM(CASE WHEN nursery_id = 'N02' THEN 1 END), 1) AS n02_conv_pct,
       SUM(CASE WHEN nursery_id = 'N02' THEN 1 END) AS n02_leads,
       ROUND(100.0 * SUM(CASE WHEN nursery_id <> 'N02' THEN is_enrolled END) / SUM(CASE WHEN nursery_id <> 'N02' THEN 1 END), 1) AS rest_conv_pct
FROM v_leads_clean
WHERE is_mature = 1
GROUP BY quarter
ORDER BY quarter;

-- Q5 N02 vs rest of network: where do lost leads go?  (share of lost leads by reason, 2026)
SELECT CASE WHEN nursery_id = 'N02' THEN 'N02' ELSE 'Rest of network' END AS grp,
       lost_reason, COUNT(*) AS lost_leads,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY CASE WHEN nursery_id = 'N02' THEN 1 ELSE 0 END), 1) AS pct_of_group
FROM v_leads_clean
WHERE lead_status = 'Lost' AND lead_date >= '2026-01-01'
GROUP BY grp, lost_reason
ORDER BY grp, lost_leads DESC;
