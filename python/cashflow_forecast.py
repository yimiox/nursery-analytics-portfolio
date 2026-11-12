"""
cashflow_forecast.py  (JD #3: parent payment patterns -> collections and cash-flow forecasting)
DATA IS SIMULATED.

IDEA IN ONE LINE
    Billing is not cash. Each invoice is paid some number of days after its due date, and that delay
    has a stable distribution. Learn the distribution from history, then apply it to (a) invoices that
    are already open and (b) invoices we expect to issue, to get expected cash by month.

METHOD
 1. Collection curve. From 2025 invoices (all fully matured) build, per season, the share of billed AED
    that is paid N days after the due date. Two seasons, as in sql/06 Q2: peak-late months (Jul-Sep,
    Dec-Jan) and normal months. Whatever is never paid is the leakage (write-offs).
 2. Open invoices. An invoice that is already `a` days past due and still unpaid will not follow the
    raw curve; it has survived that long. Use the CONDITIONAL probability:
        P(paid on future day t | unpaid at age a) = pmf[a + t] / (1 - cdf[a])
 3. Future invoices. Forecast billing = same month last year x year-on-year growth (trailing 2 months),
    because billing is seasonal (August dip, September intake). Spread each future invoice over the
    curve for its season.
 4. Backtest. Pretend it is 31 Jul 2026, forecast Aug-Oct 2026 cash, compare with what actually happened.
    The curves are learned on 2025 only, so the backtest is out of sample. Actual billing is used in the
    backtest so it tests the collection-timing model on its own (billing forecast is checked separately).
 5. Scenario. "Slow-pay stress": every family pays 7 days later than usual. Shows how exposed cash is.

OUTPUTS (../report/)
    cashflow_forecast_monthly.csv   base and stress forecast by month, split open vs future invoices
    cashflow_backtest.csv           forecast vs actual cash by month
    cashflow_forecast.png           chart for the memo / README

RUN:  python cashflow_forecast.py        (from the python/ folder)
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"
OUT = HERE.parent / "report"
OUT.mkdir(exist_ok=True)

ASOF = pd.Timestamp("2026-10-31")
HORIZON_MONTHS = 6                  # Nov 2026 - Apr 2027
PEAK_MONTHS = {7, 8, 9, 12, 1}
OFFSET_MIN, OFFSET_MAX = -15, 400   # days relative to due date (negative = paid early)
SHIFT = OFFSET_MIN                  # array index = offset - OFFSET_MIN
N = OFFSET_MAX - OFFSET_MIN + 1
SEASONS = ("peak", "normal")


def season_of(month_no: int) -> str:
    return "peak" if month_no in PEAK_MONTHS else "normal"


def load() -> pd.DataFrame:
    df = pd.read_csv(DATA / "invoices.csv",
                     parse_dates=["invoice_month", "issue_date", "due_date", "paid_date"])
    df["season"] = df["invoice_month"].dt.month.map(season_of)
    df["offset"] = (df["paid_date"] - df["due_date"]).dt.days
    return df


def build_curves(train: pd.DataFrame) -> dict:
    """pmf[season][i] = share of billed AED paid at offset i+OFFSET_MIN days from due date.
    The pmf sums to less than 1; the gap is the never-collected share."""
    curves = {}
    for s in SEASONS:
        t = train[train["season"] == s]
        total = t["amount_aed"].sum()
        paid = t[t["offset"].between(OFFSET_MIN, OFFSET_MAX)]
        pmf = np.zeros(N)
        by_offset = paid.groupby("offset")["amount_aed"].sum()
        for off, aed in by_offset.items():
            pmf[int(off) - SHIFT] = aed / total
        curves[s] = pmf
    return curves


def shift_pmf(pmf: np.ndarray, days: int) -> np.ndarray:
    """Stress test: everybody pays `days` later. Mass moved past the array end is lost (never paid)."""
    if days == 0:
        return pmf
    out = np.zeros_like(pmf)
    out[days:] = pmf[:-days]
    return out


def month_end_index(asof: pd.Timestamp, months: int) -> list:
    """First day of each forecast month."""
    start = (asof + pd.offsets.MonthBegin(1)).normalize()
    return [start + pd.DateOffset(months=i) for i in range(months)]


def cash_forecast(open_inv: pd.DataFrame, future_inv: pd.DataFrame, curves: dict,
                  asof: pd.Timestamp, months: int, delay_days: int = 0) -> pd.DataFrame:
    """Expected cash per calendar month. Daily resolution, then summed to months."""
    first_days = month_end_index(asof, months)
    horizon_end = first_days[-1] + pd.offsets.MonthEnd(0)
    days = pd.date_range(asof + pd.Timedelta(days=1), horizon_end)
    cash_open = pd.Series(0.0, index=days)
    cash_future = pd.Series(0.0, index=days)

    # (2) open invoices: conditional curve given age
    for s in SEASONS:
        pmf = shift_pmf(curves[s], delay_days)
        cdf = np.cumsum(pmf)
        sub = open_inv[open_inv["season"] == s]
        for _, r in sub.iterrows():
            age = (asof - r["due_date"]).days                    # days past due now
            a_idx = int(np.clip(age - SHIFT, 0, N - 1))
            remaining = 1.0 - cdf[a_idx]
            if remaining < 1e-9:
                continue
            for d in days:
                off = (d - r["due_date"]).days
                i = off - SHIFT
                if 0 <= i < N:
                    cash_open[d] += r["amount_aed"] * pmf[i] / remaining

    # (3) future invoices: unconditional curve from the due date
    for _, r in future_inv.iterrows():
        pmf = shift_pmf(curves[r["season"]], delay_days)
        due = r["due_date"]
        offs = (days - due).days
        idx = offs - SHIFT
        ok = (idx >= 0) & (idx < N)
        cash_future[days[ok]] += r["amount_aed"] * pmf[idx[ok]]

    res = pd.DataFrame({"from_open_invoices": cash_open, "from_future_invoices": cash_future})
    res = res.groupby(res.index.to_period("M")).sum()
    res["total_cash"] = res["from_open_invoices"] + res["from_future_invoices"]
    return res.round(0)


def split_open_future(df: pd.DataFrame, asof: pd.Timestamp):
    """Invoices known at `asof`: issued by then and unpaid at that date."""
    issued = df[df["issue_date"] <= asof]
    unpaid = issued[issued["paid_date"].isna() | (issued["paid_date"] > asof)].copy()
    age = (asof - unpaid["due_date"]).dt.days
    # written-off status is only treated as known once the invoice is > 90 days past due
    unpaid = unpaid[~((unpaid["status"] == "Written off") & (age > 90))]
    return unpaid


def backtest(df: pd.DataFrame, train: pd.DataFrame) -> pd.DataFrame:
    asof = pd.Timestamp("2026-07-31")
    months = 3
    curves = build_curves(train)
    open_inv = split_open_future(df, asof)
    fut = df[df["issue_date"] > asof]
    fut = fut[fut["issue_date"] <= asof + pd.offsets.MonthEnd(months)]
    fut = fut.groupby(["invoice_month", "due_date", "season"], as_index=False)["amount_aed"].sum()
    fc = cash_forecast(open_inv, fut, curves, asof, months)
    act = df[df["paid_date"] > asof].copy()
    act["m"] = act["paid_date"].dt.to_period("M")
    actual = act.groupby("m")["amount_aed"].sum().reindex(fc.index)
    out = pd.DataFrame({"forecast_cash": fc["total_cash"], "actual_cash": actual})
    out["error_aed"] = out["forecast_cash"] - out["actual_cash"]
    out["error_pct"] = (100 * out["error_aed"] / out["actual_cash"]).round(1)
    return out


def forecast_billing(df: pd.DataFrame) -> pd.DataFrame:
    """Future invoices = same month last year x trailing 2-month YoY growth. Split by nursery to keep
    the nursery_id on each future line, in case you want a nursery-level view later."""
    m = df.groupby("invoice_month")["amount_aed"].sum()
    last2 = m.iloc[-2:].sum()
    prev2 = m.loc[m.index[-2] - pd.DateOffset(years=1): m.index[-1] - pd.DateOffset(years=1)].sum()
    growth = last2 / prev2
    rows = []
    for i in range(1, HORIZON_MONTHS + 1):
        month = m.index[-1] + pd.DateOffset(months=i)
        base = m.loc[month - pd.DateOffset(years=1)]
        rows.append({"invoice_month": month,
                     "issue_date": month,
                     "due_date": month + pd.Timedelta(days=10),
                     "season": season_of(month.month),
                     "amount_aed": base * growth})
    fut = pd.DataFrame(rows)
    fut.attrs["growth"] = growth
    return fut


def main():
    df = load()
    train = df[df["invoice_month"].dt.year == 2025]

    # ---- curve summary (the thing you can explain in an interview)
    curves = build_curves(train)
    print("COLLECTION CURVE (cumulative % of billed AED collected, by days after due date)")
    rows = []
    for s in SEASONS:
        cdf = np.cumsum(curves[s])
        row = {"season": s}
        for lab, d in [("on/before due", 0), ("<=7d", 7), ("<=14d", 14), ("<=30d", 30), ("<=60d", 60),
                       ("<=90d", 90), ("<=400d", 400)]:
            row[lab] = round(100 * cdf[d - SHIFT], 1)
        row["never collected"] = round(100 * (1 - cdf[-1]), 1)
        rows.append(row)
    print(pd.DataFrame(rows).to_string(index=False))

    # ---- backtest
    bt = backtest(df, train)
    print("\nBACKTEST  (as of 31 Jul 2026, forecast Aug-Oct 2026 cash, actual billing used)")
    print(bt.to_string())
    mape = bt["error_pct"].abs().mean()
    print(f"mean absolute % error: {mape:.1f}%")
    bt.to_csv(OUT / "cashflow_backtest.csv")

    # ---- live forecast
    open_inv = split_open_future(df, ASOF)
    fut = forecast_billing(df)
    growth = fut.attrs["growth"]
    print(f"\nOPEN RECEIVABLES at {ASOF.date()}: AED {open_inv['amount_aed'].sum():,.0f} "
          f"({len(open_inv)} invoices)")
    print(f"BILLING FORECAST: same month last year x {growth:.3f} (trailing 2-month YoY growth)")
    base = cash_forecast(open_inv, fut, curves, ASOF, HORIZON_MONTHS, 0)
    stress = cash_forecast(open_inv, fut, curves, ASOF, HORIZON_MONTHS, 7)

    billed = fut.set_index(fut["invoice_month"].dt.to_period("M"))["amount_aed"].round(0)
    out = pd.DataFrame({"forecast_billing": billed,
                        "cash_base": base["total_cash"],
                        "cash_from_open_invoices": base["from_open_invoices"],
                        "cash_from_future_invoices": base["from_future_invoices"],
                        "cash_slow_pay_stress": stress["total_cash"]})
    out["stress_vs_base"] = out["cash_slow_pay_stress"] - out["cash_base"]
    out["cash_minus_billing_base"] = out["cash_base"] - out["forecast_billing"]
    out["cum_receivables_change_base"] = (-out["cash_minus_billing_base"]).cumsum()
    print("\nCASH FORECAST (AED)")
    print(out.round(0).to_string())
    out.to_csv(OUT / "cashflow_forecast_monthly.csv")

    # ---- chart
    fig, ax = plt.subplots(figsize=(9, 4.8))
    x = [str(p) for p in out.index]
    ax.bar(x, out["cash_from_open_invoices"] / 1e6, label="Cash from invoices already open", color="#4c78a8")
    ax.bar(x, out["cash_from_future_invoices"] / 1e6, bottom=out["cash_from_open_invoices"] / 1e6,
           label="Cash from invoices not yet issued", color="#9ecae9")
    ax.plot(x, out["forecast_billing"] / 1e6, color="#e45756", marker="o", label="Forecast billing")
    ax.plot(x, out["cash_slow_pay_stress"] / 1e6, color="#333", ls="--", marker="x",
            label="Cash if everyone pays 7 days later")
    ax.set_ylabel("AED million")
    ax.set_title("Expected monthly cash vs billing (SIMULATED DATA)")
    ax.legend(frameon=False, fontsize=8, loc="lower right")
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(OUT / "cashflow_forecast.png", dpi=150)


if __name__ == "__main__":
    main()
