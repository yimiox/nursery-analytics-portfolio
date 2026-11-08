# SQL dialect notes

The scripts were written and **tested on SQLite** (`python/load_sqlite.py` builds `kfg.db` from the CSVs).
The logic (CTEs, window functions, conditional aggregation) is standard SQL. Only the items below differ by database.
If KFG uses SQL Server (common in the UAE) these are the swaps:

| Used here (SQLite) | SQL Server (T-SQL) | PostgreSQL |
|---|---|---|
| `strftime('%Y', d)` | `YEAR(d)` | `EXTRACT(YEAR FROM d)` |
| `strftime('%m', d) <= '10'` | `MONTH(d) <= 10` | `EXTRACT(MONTH FROM d) <= 10` |
| `date('2026-10-31', '-60 day')` | `DATEADD(day, -60, '2026-10-31')` | `DATE '2026-10-31' - INTERVAL '60 days'` |
| `julianday(a) - julianday(b)` | `DATEDIFF(day, b, a)` | `a - b` (date minus date = days) |
| `a \|\| b` (string concat) | `CONCAT(a, b)` | `a \|\| b` |
| `LIMIT 10` | `SELECT TOP 10 ...` | `LIMIT 10` |
| `CROSS JOIN (subquery)` | same | same |

Everything else (`WITH`, `ROW_NUMBER`, `RANK`, `NTILE`, `LAG`, `SUM() OVER`, `SQRT`, `CASE`) works unchanged.

Dates are stored as ISO text (`YYYY-MM-DD`) in SQLite; in a real warehouse they would be `DATE` columns.
