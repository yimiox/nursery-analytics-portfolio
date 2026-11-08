-- =====================================================================================
-- 00_clean_views.sql  -  data cleaning layer (run this first)
-- DATA IS SIMULATED. Dialect: SQLite (see README_dialects.md for T-SQL / PostgreSQL).
--
-- METHOD: never edit raw tables. Fix mess in VIEWS so (a) raw data stays auditable and
-- (b) every downstream query uses the same cleaned definition. Same idea as a Power Query
-- "staging" step in Excel.
--
-- Mess injected on purpose (see python/generate_data.py header):
--   parents.nationality       spelling variants (UK / United Kingdom / british ...)
--   parents.employer          case + stray whitespace, ~3% NULL
--   parents.residential_area  alias variants (JVC / Marina / Barsha), ~3% NULL
--   leads.lead_source         casing / whitespace / aliases ('Instagram/Facebook' = Social Media)
-- =====================================================================================

DROP VIEW IF EXISTS v_parents_clean;
DROP VIEW IF EXISTS v_leads_clean;
DROP VIEW IF EXISTS v_invoices;

-- Employer: variants differ only by case/whitespace. Key = UPPER(TRIM()). For each key we keep the
-- MOST FREQUENT spelling as the canonical name (the clean spelling massively outnumbers the dirty ones).
CREATE VIEW v_parents_clean AS
WITH emp_variants AS (
    SELECT UPPER(TRIM(employer)) AS emp_key, TRIM(employer) AS emp_spelling, COUNT(*) AS n
    FROM parents
    WHERE employer IS NOT NULL
    GROUP BY UPPER(TRIM(employer)), TRIM(employer)
),
emp_canonical AS (
    SELECT emp_key, emp_spelling AS employer_clean
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY emp_key ORDER BY n DESC, emp_spelling) AS rn
        FROM emp_variants
    )
    WHERE rn = 1
)
SELECT
    p.parent_id,
    CASE LOWER(TRIM(p.nationality))
        WHEN 'uk' THEN 'British'            WHEN 'u.k.' THEN 'British'     WHEN 'united kingdom' THEN 'British'
        WHEN 'british' THEN 'British'
        WHEN 'india' THEN 'Indian'          WHEN 'indian' THEN 'Indian'
        WHEN 'philippines' THEN 'Filipino'  WHEN 'phillipino' THEN 'Filipino' WHEN 'filipino' THEN 'Filipino'
        WHEN 'uae' THEN 'Emirati'           WHEN 'emirati' THEN 'Emirati'
        WHEN 'egypt' THEN 'Egyptian'        WHEN 'egyptian' THEN 'Egyptian'
        WHEN 'pakistan' THEN 'Pakistani'    WHEN 'pakistani' THEN 'Pakistani'
        ELSE TRIM(p.nationality)
    END AS nationality,
    COALESCE(e.employer_clean, 'Unknown')            AS employer,
    p.employer_sector,
    CASE TRIM(p.residential_area)
        WHEN 'JVC'    THEN 'Jumeirah Village Circle'
        WHEN 'Marina' THEN 'Dubai Marina'
        WHEN 'Barsha' THEN 'Al Barsha'
        ELSE COALESCE(TRIM(p.residential_area), 'Unknown')
    END AS residential_area
FROM parents p
LEFT JOIN emp_canonical e ON UPPER(TRIM(p.employer)) = e.emp_key;

-- Lead source: lower/trim then map every variant to the 6 official names.
CREATE VIEW v_leads_clean AS
SELECT
    l.lead_id, l.nursery_id, l.lead_date, l.tour_booked, l.lead_status, l.lost_reason, l.child_id, l.enrol_date,
    CASE LOWER(TRIM(l.lead_source))
        WHEN 'website' THEN 'Website'
        WHEN 'social media' THEN 'Social Media'   WHEN 'instagram/facebook' THEN 'Social Media'
        WHEN 'aggregator portal' THEN 'Aggregator Portal' WHEN 'aggregator' THEN 'Aggregator Portal'
        WHEN 'referral' THEN 'Referral'
        WHEN 'walk-in' THEN 'Walk-in'             WHEN 'walk in' THEN 'Walk-in'
        WHEN 'corporate partnership' THEN 'Corporate Partnership' WHEN 'corporate' THEN 'Corporate Partnership'
        ELSE 'UNMAPPED'
    END AS lead_source,
    CASE WHEN l.lead_status = 'Enrolled' THEN 1 ELSE 0 END AS is_enrolled,
    -- Leads younger than 60 days may still convert, so "mature" = safe to measure conversion on.
    CASE WHEN l.lead_date <= date('2026-10-31', '-60 day') THEN 1 ELSE 0 END AS is_mature
FROM leads l;

-- Invoices + payment-behaviour columns used by the collections queries.
CREATE VIEW v_invoices AS
SELECT
    i.*,
    CAST(strftime('%Y', i.invoice_month) AS INTEGER)  AS inv_year,
    CAST(strftime('%m', i.invoice_month) AS INTEGER)  AS inv_mon,
    CASE WHEN i.paid_date IS NOT NULL THEN CAST(julianday(i.paid_date) - julianday(i.due_date) AS INTEGER) END AS days_after_due,
    CASE WHEN i.paid_date IS NOT NULL AND i.paid_date <= i.due_date THEN 1 ELSE 0 END AS paid_on_time,
    CASE WHEN i.paid_date IS NULL AND i.due_date < '2026-10-31'
         THEN CAST(julianday('2026-10-31') - julianday(i.due_date) AS INTEGER) END AS days_past_due_asof
FROM invoices i;
