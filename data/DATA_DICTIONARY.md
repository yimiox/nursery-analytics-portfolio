# Data dictionary  (ALL DATA SIMULATED)

Currency: AED (Doha sites shown as AED-equivalent). Dates: ISO `YYYY-MM-DD`. Period: Jan 2025 - Oct 2026 (as-of 31 Oct 2026).

## nurseries (10 rows) - one row per site
`nursery_id`, `nursery_name`, `city`, `country`, `area`, `capacity` (seats), `monthly_rent_aed` (2025 rate; +3% from Jan 2026), `open_date`

## parents (~1,400 rows) - one row per family  *(contains deliberate mess)*
`parent_id`, `nationality`, `employer`, `employer_sector` (clean), `residential_area`
Known issues: nationality spelling variants, employer case/whitespace, ~3% blank employer/area, area aliases.

## children (~1,600 rows) - one row per child
`child_id`, `parent_id`, `nursery_id`, `date_of_birth`, `class_at_enrolment`, `enrol_date`, `leave_date` (blank = still active),
`leave_reason`, `enrol_source` (`Existing` = already enrolled before Jan 2025 / `Lead` / `Camp`),
`lead_id` (if from a lead), `camp_id` (if from a camp), `fee_discount_rate` (sibling/corporate), `status` (Active/Left)

## leads (~4,100 rows) - one row per enquiry  *(lead_source has deliberate mess)*
`lead_id`, `nursery_id`, `lead_date`, `lead_source` (Website, Social Media, Aggregator Portal, Referral, Walk-in, Corporate Partnership + variants),
`tour_booked` (0/1), `lead_status` (Enrolled / Lost / Open = still undecided), `lost_reason`, `child_id`, `enrol_date`

## camps (70 rows) - one row per camp
`camp_id`, `nursery_id`, `camp_name`, `season` (Spring/Summer/Winter), `start_date`, `end_date`, `places_available`,
`external_registrations` (attendees not yet enrolled), `converted_children` (later enrolled), `camp_price_aed`, `camp_revenue_aed`

## invoices (~20,800 rows) - one row per child per month
`invoice_id`, `child_id`, `parent_id`, `nursery_id`, `class_name` (class in that month: Infant/Toddler/Nursery/FS1/FS2),
`invoice_month` (first of month), `issue_date` (the 1st), `due_date` (issue + 10 days), `gross_fee_aed`, `discount_aed`, `amount_aed` (net),
`paid_date` (blank = unpaid), `status` (Paid / Open / Overdue / Written off), `payment_method`
Headcount in a month = number of invoices that month.

## pnl_monthly (220 rows) - nursery x month
`nursery_id`, `month`, `children_billed`, `tuition_revenue_aed` (= sum of invoices, reconciles exactly), `other_revenue_aed`
(registration fees, meals, activities), `camp_revenue_aed`, `total_revenue_aed`, costs: `staff_cost_aed`, `rent_aed`, `utilities_aed`,
`food_consumables_aed`, `marketing_aed`, `other_opex_aed`, `central_allocation_aed`, `bad_debt_provision_aed`, `total_cost_aed`,
`ebitda_aed`, `ebitda_per_child_aed`
Note: camp revenue has no direct cost line (staff are already on payroll), so camps are pure margin in this simulation - a simplification.

## targets (4,690 rows) - budget, long format
`nursery_id`, `month`, `metric`, `segment`, `target_value`

| metric | segment | meaning |
|---|---|---|
| headcount | class name | target children billed |
| leads | lead source | target enquiries |
| lead_conversion_rate | lead source or `All` | target enquiry -> enrolment rate |
| new_enrolments | All | target new children |
| camp_conversion_rate | All | only in months a camp starts |
| tuition_revenue_aed | All | target tuition revenue |
| ebitda_margin | All | target margin (22%) |
