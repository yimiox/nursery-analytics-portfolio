#!/usr/bin/env python3
"""Run every statement in a .sql file against kfg.db and print the result of each SELECT.

Usage: python run_sql.py ../sql/03_leads_funnel.sql [max_rows]
Comment lines are stripped before statements are split on ';' (keep ';' out of string literals).
"""
import re
import sqlite3
import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
if __name__ == "__main__":
    sql_path = Path(sys.argv[1])
    max_rows = int(sys.argv[2]) if len(sys.argv) > 2 else 15
    con = sqlite3.connect(ROOT / "kfg.db")
    # views first (so any file can use them)
    views = (ROOT / "sql" / "00_clean_views.sql")
    if views.exists() and sql_path.resolve() != views.resolve():
        con.executescript(views.read_text())
    pd.set_option("display.width", 220, "display.max_columns", 40, "display.max_colwidth", 60)
    text = sql_path.read_text()
    text = re.sub(r"^--\s*(Q\d.*)$", r"/*TITLE: \1 */", text, flags=re.M)   # keep query titles
    text = "\n".join(l for l in text.splitlines() if not l.strip().startswith("--"))  # drop other comment lines
    for i, stmt in enumerate(s.strip() for s in text.split(";")):
        m = re.search(r"/\*TITLE: (.*?) \*/", stmt)
        title = m.group(1) if m else f"statement {i}"
        body = re.sub(r"/\*TITLE:.*?\*/", "", stmt).strip()
        if not body:
            continue
        if body.upper().startswith(("SELECT", "WITH")):
            df = pd.read_sql_query(body, con)
            print(f"\n### {title}  ({len(df)} rows)")
            print(df.head(max_rows).to_string(index=False))
        else:
            con.execute(body)
    con.commit()
