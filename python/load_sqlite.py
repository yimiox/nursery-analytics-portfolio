#!/usr/bin/env python3
"""Load the 8 CSVs into a local SQLite database (kfg.db) so the SQL scripts can be run and tested.

Usage:  python load_sqlite.py            # builds ../kfg.db
        python run_sql.py ../sql/01_enrolment_vs_target_py.sql

SQLite stores dates as TEXT in ISO format (YYYY-MM-DD). That sorts and compares correctly,
and date()/strftime() work on it. The SQL is written to be portable (CTEs + window functions);
only the date functions (strftime / julianday / date) are SQLite-specific -
see sql/README_dialects.md for the T-SQL / PostgreSQL equivalents.
"""
import sqlite3
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "kfg.db"
TABLES = ["nurseries", "parents", "children", "leads", "camps", "invoices", "pnl_monthly", "targets"]
INDEXES = [
    "CREATE INDEX ix_inv_nur_month ON invoices(nursery_id, invoice_month)",
    "CREATE INDEX ix_inv_parent ON invoices(parent_id)",
    "CREATE INDEX ix_leads_nur_date ON leads(nursery_id, lead_date)",
    "CREATE INDEX ix_children_nur ON children(nursery_id, enrol_date)",
    "CREATE INDEX ix_targets ON targets(nursery_id, month, metric)",
]

if __name__ == "__main__":
    if DB.exists():
        DB.unlink()
    con = sqlite3.connect(DB)
    for t in TABLES:
        df = pd.read_csv(ROOT / "data" / f"{t}.csv")
        df.to_sql(t, con, index=False)
        print(f"{t:12s} {len(df):>7,} rows")
    for ddl in INDEXES:
        con.execute(ddl)
    con.commit()
    con.close()
    print(f"-> {DB}")
