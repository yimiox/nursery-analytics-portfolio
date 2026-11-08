#!/usr/bin/env python3
"""
generate_data.py - synthetic nursery data for the KFG-style analytics portfolio project.

*** ALL DATA IS SIMULATED. Nurseries, parents, employers and numbers are fictional. ***

Usage:  python generate_data.py --out ../data --seed 9

Design principle: simulate the REAL PROCESS (leads -> tours -> enrolments -> monthly
invoices -> payments -> P&L) instead of drawing each table independently. That way the
tables reconcile with each other (e.g. P&L tuition revenue == sum of invoices), which is
exactly what a real analyst gets to rely on when joining systems.

SEEDED PATTERNS (the "answer key" - the analysis should find these):
  P1  N02 (JVC): lead->enrolment conversion decays from Jun 2025 (follow-up problem)
  P2  "Aggregator Portal": ~30% of leads, ~5% conversion; its share grows in 2026
      (blended conversion falls partly because of MIX, not only rate)
  P3  Seasonal late payments: Jul/Aug/Sep (summer travel) and Dec/Jan (term-start)
  P4  N01 (Dubai Marina): very high rent -> thin EBITDA
  P5  N10 (Lusail): ramp-up site, low occupancy early 2025
  P6  Parents working in Hospitality & Retail pay later than Government & Education
  P7  Camp conversion is generated INDEPENDENTLY of the N02 lead decline. But site-level camp samples are tiny
      (~60-90 attendees/yr, i.e. 5-15 conversions), so site-level camp conversion is mostly noise - the
      analysis should say so rather than over-interpret it.
KNOWN DATA-QUALITY MESS (for the cleaning step):
  parents: nationality spelling variants, employer case/whitespace, ~3% missing
           employer/area, area alias variants
  leads:   lead_source casing/whitespace/alias variants (~5% of rows)
All money in AED (Doha sites shown as AED-equivalent).
"""
import argparse
import math
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

ASOF = date(2026, 10, 31)
START = date(2025, 1, 1)
CLASSES = ["Infant", "Toddler", "Nursery", "FS1", "FS2"]  # age on 31 Aug: 0..4
MAX_OCC = 0.97
LEAD_BASE = 0.155      # leads per month per seat (before seasonality)
CHURN_SCALE = 1.05     # multiplies each nursery's monthly early-leaver hazard

# id, name, city, country, area, capacity, monthly_rent, fee_mult, init_occ, churn_hazard, lead_mult, conv_mult, camp_mult, open_date
NURSERIES = [
    ("N01", "Little Dune Marina",     "Dubai",     "UAE",   "Dubai Marina",           120, 192000, 1.16, 0.80, 0.009, 1.00, 1.05, 1.00, "2019-09-01"),
    ("N02", "Olive Branch JVC",       "Dubai",     "UAE",   "Jumeirah Village Circle", 140,  62000, 1.00, 0.86, 0.011, 1.05, 1.00, 1.00, "2018-09-01"),
    ("N03", "Acorn Al Barsha",        "Dubai",     "UAE",   "Al Barsha",              110,  58000, 1.00, 0.82, 0.009, 1.00, 0.95, 0.95, "2017-09-01"),
    ("N04", "Pebble Ranches",         "Dubai",     "UAE",   "Arabian Ranches",        100,  70000, 1.12, 0.84, 0.008, 0.95, 1.10, 1.10, "2020-01-15"),
    ("N05", "Sprout Mirdif",          "Dubai",     "UAE",   "Mirdif",                 125,  55000, 0.95, 0.83, 0.010, 1.00, 1.00, 1.05, "2016-09-01"),
    ("N06", "Meadow Khalifa City",    "Abu Dhabi", "UAE",   "Khalifa City",           120,  52000, 0.92, 0.80, 0.010, 1.00, 0.95, 0.90, "2018-01-10"),
    ("N07", "Starfish Yas",           "Abu Dhabi", "UAE",   "Yas Island",             100,  66000, 1.00, 0.82, 0.009, 1.00, 1.05, 1.10, "2021-09-01"),
    ("N08", "Maple West Bay",         "Doha",      "Qatar", "West Bay",               110,  74000, 1.02, 0.78, 0.010, 1.00, 1.00, 0.95, "2019-01-20"),
    ("N09", "Kite Al Waab",           "Doha",      "Qatar", "Al Waab",                105,  54000, 0.94, 0.78, 0.010, 0.95, 0.95, 0.90, "2020-09-01"),
    ("N10", "Lantern Lusail",         "Doha",      "Qatar", "Lusail",                  90,  48000, 0.92, 0.48, 0.009, 1.45, 1.00, 0.90, "2024-09-01"),
]
CATCHMENT = {
    "N01": ["Dubai Marina", "JLT", "JBR", "Palm Jumeirah", "Al Sufouh", "Dubai Media City"],
    "N02": ["Jumeirah Village Circle", "Jumeirah Village Triangle", "Dubai Sports City", "Motor City", "Arjan", "Al Barsha South"],
    "N03": ["Al Barsha", "Al Barsha South", "Tecom", "Al Sufouh", "Umm Suqeim", "Dubai Hills"],
    "N04": ["Arabian Ranches", "Dubai Hills", "Damac Hills", "Mudon", "Dubailand", "Town Square"],
    "N05": ["Mirdif", "Uptown Mirdif", "Al Warqa", "Rashidiya", "Dubai Silicon Oasis", "Al Twar"],
    "N06": ["Khalifa City", "Al Raha", "Mohammed Bin Zayed City", "Masdar City", "Shakhbout City", "Al Reef"],
    "N07": ["Yas Island", "Saadiyat Island", "Al Raha", "Al Reem Island", "Al Raha Beach", "Khalifa City"],
    "N08": ["West Bay", "The Pearl-Qatar", "Al Dafna", "Corniche", "Msheireb", "Al Sadd"],
    "N09": ["Al Waab", "Aspire Zone", "Al Aziziya", "Al Gharrafa", "Al Luqta", "Muaither"],
    "N10": ["Lusail", "Fox Hills", "Al Kheesa", "Umm Salal", "Al Daayen", "The Pearl-Qatar"],
}
AREA_W = [0.40, 0.22, 0.14, 0.10, 0.08, 0.06]

# nationality mix by country (not by nursery)
NATIONALITY = {
    "Dubai":     {"Indian": .26, "British": .12, "Emirati": .08, "Pakistani": .09, "Egyptian": .08, "Filipino": .07,
                  "Lebanese": .06, "Jordanian": .05, "Russian": .04, "Syrian": .03, "Other": .12},
    "Abu Dhabi": {"Emirati": .15, "Indian": .22, "Egyptian": .12, "Pakistani": .09, "British": .09, "Jordanian": .08,
                  "Filipino": .07, "Lebanese": .06, "Other": .12},
    "Doha":      {"Qatari": .15, "Indian": .20, "Egyptian": .14, "Lebanese": .08, "Filipino": .08, "British": .08,
                  "Jordanian": .08, "Syrian": .06, "American": .04, "Other": .09},
}
NAT_DIRTY = {"British": ["UK", "U.K.", "United Kingdom", "british"], "Indian": ["India", "indian "],
             "Filipino": ["Philippines", "Phillipino"], "Emirati": ["UAE", "emirati", "Emirati "],
             "Egyptian": ["egyptian", "Egypt"], "Pakistani": ["Pakistan"]}

EMPLOYERS = {
    "Banking & Finance": ["Meridian Bank", "Gulf Crescent Bank", "Harbour Capital"],
    "Healthcare": ["Palm Health Group", "Cedar Medical Centre"],
    "Aviation & Logistics": ["Skyline Aviation", "Crescent Logistics"],
    "Hospitality & Retail": ["Desert Rose Hospitality", "Souk & Co Retail"],
    "Tech & Telecom": ["Orbit Telecom", "Zenith Tech"],
    "Real Estate & Construction": ["Pinnacle Properties", "Oasis Developments"],
    "Energy": ["Oasis Energy"],
    "Government & Education": ["Government Entity", "Education Authority"],
    "Self-employed / Other": ["Self-employed"],
}
SECTOR_W = {"Banking & Finance": .15, "Healthcare": .14, "Aviation & Logistics": .12, "Hospitality & Retail": .13,
            "Tech & Telecom": .13, "Real Estate & Construction": .09, "Energy": .05,
            "Government & Education": .11, "Self-employed / Other": .08}
PROPENSITY = ["reliable", "occasional", "chronic"]
PROP_PROBS = {"default": [.70, .22, .08], "Hospitality & Retail": [.52, .31, .17],
              "Government & Education": [.84, .14, .02]}

SOURCES = ["Website", "Social Media", "Aggregator Portal", "Referral", "Walk-in", "Corporate Partnership"]
MIX_2025 = [.22, .15, .28, .11, .14, .10]
MIX_2026 = [.21, .15, .34, .09, .12, .09]
CONV_SCALE = 0.62   # enquiry->enrolment: ~13% blended; Aggregator ~3%, Referral/Walk-in ~25-28%
CONV = {k: v * CONV_SCALE for k, v in {"Website": .22, "Social Media": .14, "Aggregator Portal": .055, "Referral": .45,
        "Walk-in": .40, "Corporate Partnership": .33}.items()}
P_TOUR = {"Website": .55, "Social Media": .45, "Aggregator Portal": .30, "Referral": .80, "Walk-in": 1.0,
          "Corporate Partnership": .75}
SRC_DIRTY = {"Website": ["website", "Website ", "WEBSITE"], "Social Media": ["Instagram/Facebook", "social media", "Social media"],
             "Aggregator Portal": ["aggregator portal", "Aggregator"], "Referral": ["referral", "Referral "],
             "Walk-in": ["Walk in", "walk-in"], "Corporate Partnership": ["Corporate", "corporate partnership"]}
CPL = {"Website": 90, "Social Media": 180, "Aggregator Portal": 420, "Referral": 250, "Walk-in": 0,
       "Corporate Partnership": 60}  # marketing cost per lead (AED)
LEAD_SEAS = {1: 1.25, 2: 1.0, 3: 0.95, 4: 1.0, 5: 0.9, 6: 0.85, 7: 0.8, 8: 1.1, 9: 1.45, 10: 1.2, 11: 0.9, 12: 0.7}
LOST_REASONS = ["Price", "Location", "Chose competitor", "No response", "Timing"]
LOST_W = np.array([.27, .15, .26, .17, .15])

BASE_FEE = {"Infant": 5400, "Toddler": 4800, "Nursery": 4200, "FS1": 3800, "FS2": 3500}
CLASS_SHARE = dict(zip(CLASSES, [.10, .17, .23, .26, .24]))   # planned class mix used in targets
STOCK_W = [.10, .17, .23, .26, .24]    # class mix of children already enrolled (Infant..FS2)
INTAKE_W = [.30, .25, .25, .15, .05]   # class mix of NEW joiners - younger, because kids stay for years
CAMP_PRICE = {"Spring": 1650, "Summer": 2100, "Winter": 1500}
LATE_SEASON = {7, 8, 9, 12, 1}


# ---------------------------------------------------------------- date helpers
def month_start(d): return date(d.year, d.month, 1)
def add_months(d, n):
    m = d.year * 12 + (d.month - 1) + n
    return date(m // 12, m % 12 + 1, 1)
def month_end(d): return add_months(month_start(d), 1) - timedelta(days=1)
def month_range(a, b):
    out, cur = [], month_start(a)
    while cur <= b:
        out.append(cur); cur = add_months(cur, 1)
    return out
MONTHS = month_range(START, ASOF)

# ---------------------------------------------------------------- class logic
def academic_year(d): return d.year if d.month >= 9 else d.year - 1
def age_at_ref(dob, ay): return int(math.floor((date(ay, 8, 31) - dob).days / 365.25))
def class_for(dob, d):
    """Class on date d, using age on the 31 Aug before the academic year (UK-style cut-off)."""
    a = max(age_at_ref(dob, academic_year(d)), 0)
    return CLASSES[a] if a <= 4 else None
def grad_date(dob, d0):
    """Children leave for school at end of July in the year they are FS2 (age 4 on 31 Aug)."""
    ay0 = academic_year(d0)
    for ay in range(ay0, ay0 + 8):
        if age_at_ref(dob, ay) >= 4:
            return date(ay + 1, 7, 31)
def price_factor(m): return 1.04 if m >= date(2025, 9, 1) else 1.0   # 4% fee indexation from Sep 2025


def build(seed: int):
    rng = np.random.default_rng(seed)
    nur = pd.DataFrame(NURSERIES, columns=["nursery_id", "nursery_name", "city", "country", "area", "capacity",
                                           "monthly_rent_aed", "fee_mult", "init_occ", "churn", "lead_mult",
                                           "conv_mult", "camp_mult", "open_date"])
    N = {r.nursery_id: r for r in nur.itertuples()}

    # ----------------------------------------------------------- parents / children factories
    parents, children = [], []
    def new_parent(nid):
        n = N[nid]
        nat = NATIONALITY[n.city]
        nat_name = rng.choice(list(nat), p=np.array(list(nat.values())) / sum(nat.values()))
        sector = rng.choice(list(SECTOR_W), p=np.array(list(SECTOR_W.values())) / sum(SECTOR_W.values()))
        employer = rng.choice(EMPLOYERS[sector])
        area = rng.choice(CATCHMENT[nid], p=AREA_W)
        pk = PROP_PROBS.get(sector, PROP_PROBS["default"])
        prop = rng.choice(PROPENSITY, p=pk)
        pid = f"P{len(parents) + 1:05d}"
        parents.append(dict(parent_id=pid, nationality=nat_name, employer=employer, employer_sector=sector,
                            residential_area=area, _nid=nid, _prop=prop, _n_children=0))
        return parents[-1]

    def sample_dob(ref, weights):
        """Pick a class by weight, then a birth date inside that class's window for the academic year of `ref`.
        Needs age >= ~5 months at `ref`. Opening stock and new intake use DIFFERENT weights on purpose:
        children stay for years, so the stock is older than the intake (steady-state logic)."""
        w = np.array(weights, dtype=float); w = w / w.sum()
        ref_aug = date(academic_year(ref), 8, 31)
        for _ in range(200):
            k = int(rng.choice(5, p=w))
            dob = ref_aug - timedelta(days=int(rng.uniform(k * 365.25, (k + 1) * 365.25)))
            if (ref - dob).days >= 150 and class_for(dob, ref) == CLASSES[k]:
                return dob
        raise RuntimeError("dob sampling failed")

    def new_child(nid, enrol, source, lead_id=None, camp_id=None, initial=False):
        n = N[nid]
        # siblings: 12% of new children join an existing single-child family at the same nursery
        pool = [p for p in parents if p["_nid"] == nid and p["_n_children"] == 1]
        if pool and rng.random() < 0.12:
            par = pool[rng.integers(len(pool))]
        else:
            par = new_parent(nid)
        par["_n_children"] += 1
        ref = START if initial else enrol
        while True:
            dob = sample_dob(ref, STOCK_W if initial else INTAKE_W)
            if initial:   # enrolled at least ~5 months after birth, and before the data window starts
                enrol = min(max(enrol, dob + timedelta(days=150)), START - timedelta(days=1))
            grad = grad_date(dob, ref)
            if grad > ref + timedelta(days=30):   # an Aug joiner sampled as 'FS2' would already have graduated
                break
        # early churn: geometric months-of-stay (memoryless, so initial cohort restarts at Jan 2025)
        h = n.churn * CHURN_SCALE
        k = int(rng.geometric(h))
        early = month_end(add_months(START if initial else enrol, k - 1 if initial else k))
        if early < grad:
            leave, reason = early, rng.choice(["Relocation", "Moved to another nursery", "Fees", "Other"],
                                              p=[.40, .30, .15, .15])
        else:
            leave, reason = grad, "Graduated to school"
        if leave > ASOF:
            leave, reason = None, None
        disc = rng.choice([0, .05, .10, .15], p=[.78, .06, .12, .04])
        c = dict(child_id=f"C{len(children) + 1:05d}", parent_id=par["parent_id"], nursery_id=nid,
                 date_of_birth=dob, enrol_date=enrol, leave_date=leave, leave_reason=reason,
                 enrol_source=source, lead_id=lead_id, camp_id=camp_id, fee_discount_rate=disc,
                 class_at_enrolment=class_for(dob, max(enrol, START)))
        children.append(c)
        return c

    # ----------------------------------------------------------- initial cohort (existing at Jan 2025)
    for nid, n in N.items():
        n_init = int(round(n.capacity * n.init_occ))
        for _ in range(n_init):
            enrol = START - timedelta(days=int(rng.integers(30, 700)))
            new_child(nid, enrol, "Existing", initial=True)

    # ----------------------------------------------------------- leads (funnel decision made here)
    leads, events = [], []   # events = (enrol_date, kind, payload)
    for nid, n in N.items():
        for m in MONTHS:
            lam = n.capacity * LEAD_BASE * LEAD_SEAS[m.month] * n.lead_mult * (1.06 if m.year == 2026 else 1.0)
            for _ in range(rng.poisson(lam)):
                last = min(month_end(m), ASOF)
                ld = m + timedelta(days=int(rng.integers(0, (last - m).days + 1)))
                mix = MIX_2026 if ld.year == 2026 else MIX_2025
                src = rng.choice(SOURCES, p=mix)
                f = n.conv_mult
                decline = 1.0
                if nid == "N02" and ld >= date(2025, 6, 1):          # P1: decay to 35% of normal by Oct 2026
                    t = min((ld - date(2025, 6, 1)).days / (date(2026, 10, 31) - date(2025, 6, 1)).days, 1)
                    decline = 1 - 0.65 * t
                p_enrol = min(CONV[src] * f * decline, 0.9)
                p_tour = P_TOUR[src]
                toured = rng.random() < p_tour
                converted = toured and rng.random() < min(p_enrol / p_tour, 0.95)
                lid = f"L{len(leads) + 1:06d}"
                row = dict(lead_id=lid, nursery_id=nid, lead_date=ld, lead_source=src, tour_booked=int(toured),
                           lead_status=None, lost_reason=None, child_id=None, enrol_date=None,
                           _decline=decline)
                leads.append(row)
                if converted:
                    if ld.month in (4, 5, 6, 7, 8) and rng.random() < 0.65:   # September intake
                        ed = date(ld.year, 9, 1) + timedelta(days=int(rng.integers(0, 15)))
                    else:
                        ed = ld + timedelta(days=int(rng.integers(10, 51)))
                    if ed > ASOF:
                        row["lead_status"] = "Open"
                    else:
                        events.append((ed, "lead", row))
                else:
                    age = (ASOF - ld).days
                    row["lead_status"] = "Lost" if (age > 45 or rng.random() < 0.4) else "Open"

    # ----------------------------------------------------------- camps
    camps = []
    def add_camp(nid, season, start, days):
        n = N[nid]
        end = start + timedelta(days=days - 1)
        if end > ASOF:
            return
        base = {"Spring": .14, "Summer": .22, "Winter": .12}[season]
        reg = int(rng.poisson(n.capacity * base))
        p = 0.12 * n.camp_mult * (1.15 if season == "Summer" else 1.0)   # P7: not affected by N02 decline
        conv = int(rng.binomial(reg, min(p, .5)))
        price = round(CAMP_PRICE[season] * n.fee_mult / 10) * 10
        cid = f"K{len(camps) + 1:03d}"
        camps.append(dict(camp_id=cid, nursery_id=nid, camp_name=f"{season} Camp {start.year}", season=season,
                          start_date=start, end_date=end, places_available=int(n.capacity * base * 1.4),
                          external_registrations=reg, camp_price_aed=price, _conv=conv))
        for _ in range(conv):
            if season == "Summer" and rng.random() < 0.7:
                ed = date(start.year, 9, 1) + timedelta(days=int(rng.integers(0, 10)))
            else:
                ed = end + timedelta(days=int(rng.integers(10, 46)))
            if ed <= ASOF:
                events.append((ed, "camp", camps[-1]))
    for nid in N:
        for y in (2025, 2026):
            add_camp(nid, "Spring", date(y, 4, 6) + timedelta(days=int(rng.integers(0, 6))), 10)
            add_camp(nid, "Summer", date(y, 7, 6) + timedelta(days=int(rng.integers(0, 5))), 14)
            add_camp(nid, "Summer", date(y, 8, 3) + timedelta(days=int(rng.integers(0, 5))), 14)
        add_camp(nid, "Winter", date(2025, 12, 22), 8)

    # ----------------------------------------------------------- process enrolment events in date order (capacity check)
    events.sort(key=lambda e: e[0])   # stable sort: ties keep creation order (deterministic)
    def active_on(nid, d):
        return sum(1 for c in children if c["nursery_id"] == nid and c["enrol_date"] <= d
                   and (c["leave_date"] is None or c["leave_date"] >= d))
    for ed, kind, obj in events:
        nid = obj["nursery_id"]
        full = active_on(nid, ed) >= MAX_OCC * N[nid].capacity
        if kind == "lead":
            if full:
                obj["lead_status"], obj["lost_reason"] = "Lost", "No capacity"
            else:
                c = new_child(nid, ed, "Lead", lead_id=obj["lead_id"])
                obj.update(lead_status="Enrolled", child_id=c["child_id"], enrol_date=ed)
        else:
            if not full:
                new_child(nid, ed, "Camp", camp_id=obj["camp_id"])

    # lost reasons for remaining Lost leads (N02 decay -> more 'No response' / 'Chose competitor')
    for r in leads:
        if r["lead_status"] == "Lost" and r["lost_reason"] is None:
            w = LOST_W.copy()
            if r["_decline"] < 1:
                w[2] *= 1 + 2.5 * (1 - r["_decline"]) * 2; w[3] *= 1 + 3.0 * (1 - r["_decline"]) * 2
            if not r["tour_booked"]:
                w[3] *= 2.0
            r["lost_reason"] = rng.choice(LOST_REASONS, p=w / w.sum())

    # ----------------------------------------------------------- invoices + payments
    P = {p["parent_id"]: p for p in parents}
    invoices = []
    ON_TIME = {"reliable": .93, "occasional": .55, "chronic": .22}
    MEAN_LATE = {"reliable": 4, "occasional": 10, "chronic": 28}
    NEVER = {"reliable": .0005, "occasional": .004, "chronic": .025}
    METHOD = {"reliable": [.50, .35, .05, .10], "occasional": [.30, .35, .25, .10], "chronic": [.15, .35, .40, .10]}
    METHODS = ["Card", "Bank Transfer", "Cheque", "Direct Debit"]
    for c in children:
        par = P[c["parent_id"]]
        prop = par["_prop"]
        nid = c["nursery_id"]
        first = max(month_start(c["enrol_date"]), START)
        last = min(month_start(c["leave_date"]) if c["leave_date"] else month_start(ASOF), month_start(ASOF))
        m = first
        while m <= last:
            cls = class_for(c["date_of_birth"], m)
            if cls is None:
                break
            gross = round(BASE_FEE[cls] * N[nid].fee_mult * price_factor(m) / 10) * 10
            net = round(gross * (1 - c["fee_discount_rate"]))
            issue, due = m, m + timedelta(days=10)
            p_on = ON_TIME[prop] * (0.78 if m.month in LATE_SEASON else 1.0) * (0.93 if par["employer_sector"] == "Hospitality & Retail" else 1.0)
            ml = MEAN_LATE[prop] * (1.5 if m.month in LATE_SEASON else 1.0)
            never = rng.random() < NEVER[prop]
            if rng.random() < p_on:
                paid = due - timedelta(days=int(rng.integers(0, 6)))
            else:
                paid = due + timedelta(days=1 + int(min(rng.exponential(ml), 120)))
            if never:
                paid, status = None, ("Written off" if due + timedelta(days=90) <= ASOF else ("Overdue" if due < ASOF else "Open"))
            elif paid <= ASOF:
                status = "Paid"
            else:
                paid, status = None, ("Overdue" if due < ASOF else "Open")
            invoices.append(dict(invoice_id=f"I{len(invoices) + 1:07d}", child_id=c["child_id"], parent_id=c["parent_id"],
                                 nursery_id=nid, class_name=cls, invoice_month=m, issue_date=issue, due_date=due,
                                 gross_fee_aed=gross, discount_aed=gross - net, amount_aed=net, paid_date=paid,
                                 status=status, payment_method=rng.choice(METHODS, p=METHOD[prop]) if paid else None))
            m = add_months(m, 1)
    inv = pd.DataFrame(invoices)

    # ----------------------------------------------------------- dataframes + dirt
    ch = pd.DataFrame(children)
    ld = pd.DataFrame(leads)
    cp = pd.DataFrame(camps)
    cp["converted_children"] = cp["camp_id"].map(ch[ch.camp_id.notna()].groupby("camp_id").size()).fillna(0).astype(int)
    cp["camp_revenue_aed"] = cp["external_registrations"] * cp["camp_price_aed"]
    pa = pd.DataFrame(parents)

    # P&L ----------------------------------------------------------
    inv["invoice_month"] = pd.to_datetime(inv["invoice_month"])
    ten = inv.groupby(["nursery_id", "invoice_month"]).agg(tuition=("amount_aed", "sum"), kids=("invoice_id", "count")).reset_index()
    ch["enrol_month"] = pd.to_datetime(ch["enrol_date"]).dt.to_period("M").dt.to_timestamp()
    newk = ch[ch.enrol_source != "Existing"].groupby(["nursery_id", "enrol_month"]).size().rename("new_kids").reset_index() \
        .rename(columns={"enrol_month": "invoice_month"})
    cp["start_month"] = pd.to_datetime(cp["start_date"]).dt.to_period("M").dt.to_timestamp()
    campm = cp.groupby(["nursery_id", "start_month"])["camp_revenue_aed"].sum().rename("camp_rev").reset_index() \
        .rename(columns={"start_month": "invoice_month"})
    ld["lm"] = pd.to_datetime(ld["lead_date"]).dt.to_period("M").dt.to_timestamp()
    ld["cpl"] = ld["lead_source"].map(CPL)
    mk = ld.groupby(["nursery_id", "lm"])["cpl"].sum().rename("lead_cost").reset_index().rename(columns={"lm": "invoice_month"})
    pl = ten.merge(newk, how="left", on=["nursery_id", "invoice_month"]).merge(campm, how="left", on=["nursery_id", "invoice_month"]) \
        .merge(mk, how="left", on=["nursery_id", "invoice_month"]).fillna(0)
    rows = []
    for r in pl.itertuples():
        n = N[r.nursery_id]
        mth = r.invoice_month
        tuition, kids = r.tuition, int(r.kids)
        other_rev = round(kids * rng.normal(150, 12) + r.new_kids * 1500)
        camp_rev = r.camp_rev
        revenue = tuition + other_rev + camp_rev
        teachers = max(math.ceil(0.62 * n.capacity / 5.0), math.ceil(kids / 5.0))
        sal = 7700 if n.country == "Qatar" else 7600
        staff = round((teachers * sal + 3 * 12500) * rng.normal(1.0, 0.012))
        rent = round(n.monthly_rent_aed * (1.03 if mth.year == 2026 else 1.0))
        util = round((10000 + 60 * kids) * (1.25 if mth.month in (6, 7, 8, 9) else 1.0) * rng.normal(1, .03))
        food = round(300 * kids * rng.normal(1, .03))
        marketing = round(5000 + r.lead_cost)
        other_opex = round(16000 + 0.03 * revenue)
        central = round(0.04 * revenue)
        bad = round(0.012 * tuition)
        total = staff + rent + util + food + marketing + other_opex + central + bad
        rows.append(dict(nursery_id=r.nursery_id, month=mth.date(), children_billed=kids, tuition_revenue_aed=int(tuition),
                         other_revenue_aed=other_rev, camp_revenue_aed=int(camp_rev), total_revenue_aed=int(revenue),
                         staff_cost_aed=staff, rent_aed=rent, utilities_aed=util, food_consumables_aed=food,
                         marketing_aed=marketing, other_opex_aed=other_opex, central_allocation_aed=central,
                         bad_debt_provision_aed=bad, total_cost_aed=int(total), ebitda_aed=int(revenue - total),
                         ebitda_per_child_aed=round((revenue - total) / kids)))
    pnl = pd.DataFrame(rows).sort_values(["nursery_id", "month"])

    # TARGETS (budget) ---------------------------------------------------------
    TARGET_OCC = {"Dubai": .86, "Abu Dhabi": .84, "Doha": .80}
    SEAS_T = {1: 1.00, 2: 1.00, 3: 1.01, 4: 1.01, 5: 1.0, 6: .99, 7: .93, 8: .86, 9: 1.0, 10: 1.03, 11: 1.03, 12: 1.02}
    PLAN_CONV = {k: round(v * CONV_SCALE, 3) for k, v in {"Website": .24, "Social Media": .15, "Aggregator Portal": .08,
                 "Referral": .48, "Walk-in": .42, "Corporate Partnership": .35}.items()}
    t = []
    for nid, n in N.items():
        for m in MONTHS:
            mix = MIX_2026 if m.year == 2026 else MIX_2025
            leads_t = n.capacity * LEAD_BASE * LEAD_SEAS[m.month] * n.lead_mult * (1.06 if m.year == 2026 else 1.0) * 1.03
            hc = n.capacity * (TARGET_OCC[n.city] + (0.04 if m.year == 2026 else 0)) * SEAS_T[m.month]
            if nid == "N10":  # ramp-up site gets a ramp-up budget
                hc *= min(1.0, 0.62 + 0.02 * MONTHS.index(m))
            for cls in CLASSES:
                t.append((nid, m, "headcount", cls, round(hc * CLASS_SHARE[cls], 1)))
            for s, w in zip(SOURCES, mix):
                t.append((nid, m, "leads", s, round(leads_t * w, 1)))
                t.append((nid, m, "lead_conversion_rate", s, PLAN_CONV[s]))
            conv_all = sum(PLAN_CONV[s] * w for s, w in zip(SOURCES, MIX_2025))
            t.append((nid, m, "lead_conversion_rate", "All", round(conv_all, 3)))
            seas_enrol = {9: 2.2, 10: .9, 1: 1.1}.get(m.month, 0.8)
            t.append((nid, m, "new_enrolments", "All", round(n.capacity * 0.027 * seas_enrol, 1)))
            avg_fee = sum(CLASS_SHARE[c] * BASE_FEE[c] for c in CLASSES) * n.fee_mult * price_factor(m) * 0.96
            t.append((nid, m, "tuition_revenue_aed", "All", round(hc * avg_fee, -2)))
            t.append((nid, m, "ebitda_margin", "All", 0.22))
            if cp[(cp.nursery_id == nid) & (cp.start_month == pd.Timestamp(m))].shape[0]:
                t.append((nid, m, "camp_conversion_rate", "All", 0.16))
    targets = pd.DataFrame(t, columns=["nursery_id", "month", "metric", "segment", "target_value"])

    # dirt ---------------------------------------------------------------------
    pa_out = pa[["parent_id", "nationality", "employer", "residential_area"]].copy()
    for i in pa_out.index:
        x = rng.random()
        nat = pa_out.at[i, "nationality"]
        if x < 0.06 and nat in NAT_DIRTY:
            pa_out.at[i, "nationality"] = rng.choice(NAT_DIRTY[nat])
        y = rng.random()
        emp = pa_out.at[i, "employer"]
        if y < 0.03:
            pa_out.at[i, "employer"] = None
        elif y < 0.08:
            pa_out.at[i, "employer"] = rng.choice([emp.upper(), emp.lower(), "  " + emp + " "])
        z = rng.random()
        if z < 0.03:
            pa_out.at[i, "residential_area"] = None
        elif z < 0.05:
            pa_out.at[i, "residential_area"] = {"Jumeirah Village Circle": "JVC", "Dubai Marina": "Marina", "Al Barsha": "Barsha"}.get(
                pa_out.at[i, "residential_area"], pa_out.at[i, "residential_area"])
    pa_out["employer_sector"] = pa["employer_sector"]
    pa_out = pa_out[["parent_id", "nationality", "employer", "employer_sector", "residential_area"]]

    ld_out = ld[["lead_id", "nursery_id", "lead_date", "lead_source", "tour_booked", "lead_status", "lost_reason",
                 "child_id", "enrol_date"]].copy()
    for i in ld_out.index:
        if rng.random() < 0.05:
            ld_out.at[i, "lead_source"] = rng.choice(SRC_DIRTY[ld_out.at[i, "lead_source"]])

    ch_out = ch[["child_id", "parent_id", "nursery_id", "date_of_birth", "class_at_enrolment", "enrol_date", "leave_date",
                 "leave_reason", "enrol_source", "lead_id", "camp_id", "fee_discount_rate"]].copy()
    ch_out["status"] = np.where(ch_out["leave_date"].isna(), "Active", "Left")

    nur_out = nur[["nursery_id", "nursery_name", "city", "country", "area", "capacity", "monthly_rent_aed", "open_date"]]
    cp_out = cp[["camp_id", "nursery_id", "camp_name", "season", "start_date", "end_date", "places_available",
                 "external_registrations", "converted_children", "camp_price_aed", "camp_revenue_aed"]]
    inv_out = inv.copy(); inv_out["invoice_month"] = inv_out["invoice_month"].dt.date
    return dict(nurseries=nur_out, parents=pa_out, children=ch_out, leads=ld_out, camps=cp_out, invoices=inv_out,
                pnl_monthly=pnl, targets=targets)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="../data")
    ap.add_argument("--seed", type=int, default=9)  # seed picked by scanning 40 seeds so the planted patterns dominate the noise
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    for name, df in build(a.seed).items():
        df.to_csv(out / f"{name}.csv", index=False)
        print(f"{name:12s} {len(df):>7,} rows")
