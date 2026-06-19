#!/usr/bin/env python3
"""
gen_inventory.py — regenerate RESOURCES_INVENTORY.generated.md from the live DB.

WHY THIS EXISTS
  RESOURCES_BIBLE.md is hand-maintained and drifts: its counts said "~132 tables /
  152 views / 75+ crons / ~25 RPCs" while the live DB had 212 tables / 178 views /
  164 crons / 536 functions. A bot that can't see what exists rebuilds it. This
  script emits the COMPLETE, current catalog (every table/view/matview/function/
  cron/edge-fn) so "don't recreate what already exists" becomes checkable instead
  of memory-dependent. Hand-written ownership/landmine context stays in
  RESOURCES_BIBLE.md §3 etc.; this file is the objective, regenerable index.

WHAT IT IS NOT
  - It never prints secret VALUES. It lists vault/env secret NAMES only (so a bot
    knows TEVO_API_TOKEN exists, never its value). Read-only by construction:
    the only statements issued are SELECTs against catalog views (RULE 1 safe).

USAGE
  SUPABASE_DB_URL=postgres://... python3 scripts/gen_inventory.py
  # writes ./RESOURCES_INVENTORY.generated.md
  # --check : exit 1 if the file is out of date (for CI drift detection)

CONNECTION
  Matches the repo convention (tests/test_views_and_helpers.py): psycopg2 +
  SUPABASE_DB_URL. Edge functions are read from supabase/functions/ on disk
  (they are not a DB object).
"""
from __future__ import annotations

import os
import sys
import datetime
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = REPO / "RESOURCES_INVENTORY.generated.md"
FUNCTIONS_DIR = REPO / "supabase" / "functions"

# --- read-only catalog queries -------------------------------------------------
Q_COUNTS = """
SELECT
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='r')                               AS tables,
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='v')                               AS views,
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public' AND c.relkind='m')                               AS matviews,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.prokind='f')                               AS functions,
  (SELECT count(*) FROM cron.job)                                              AS crons,
  (SELECT count(*) FROM cron.job WHERE active)                                 AS crons_active;
"""

Q_RELATIONS = """
SELECT c.relkind,
       c.relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS size,
       COALESCE(replace(obj_description(c.oid,'pg_class'), E'\n', ' '), '') AS cmt
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relkind IN ('r','v','m')
ORDER BY c.relkind, c.relname;
"""

Q_FUNCTIONS = """
SELECT p.proname,
       pg_get_function_identity_arguments(p.oid) AS args,
       pg_get_function_result(p.oid)             AS ret,
       COALESCE(replace(obj_description(p.oid,'pg_proc'), E'\n', ' '), '') AS cmt
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.prokind='f'
ORDER BY p.proname, args;
"""

Q_CRONS = """
SELECT jobname, schedule, active
FROM cron.job
ORDER BY jobname;
"""


def fetch(cur, q):
    cur.execute(q)
    return cur.fetchall()


def md_table(header, rows):
    sep = "|" + "|".join("---" for _ in header) + "|"
    out = ["| " + " | ".join(header) + " |", sep]
    out.extend(rows)
    return "\n".join(out)


def build(cur) -> str:
    import psycopg2.extras  # noqa

    counts = fetch(cur, Q_COUNTS)[0]
    rels = fetch(cur, Q_RELATIONS)
    fns = fetch(cur, Q_FUNCTIONS)
    crons = fetch(cur, Q_CRONS)

    tables = [r for r in rels if r["relkind"] == "r"]
    views = [r for r in rels if r["relkind"] == "v"]
    mviews = [r for r in rels if r["relkind"] == "m"]

    edge = sorted(
        p.name for p in FUNCTIONS_DIR.iterdir()
        if p.is_dir() and not p.name.startswith("_")
    ) if FUNCTIONS_DIR.is_dir() else []

    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    L = []
    L.append("# RESOURCES_INVENTORY.generated.md")
    L.append("")
    L.append("> **Doc version:** v1.0.0 · **GENERATED FILE — DO NOT HAND-EDIT.**")
    L.append("> Regenerate with `python3 scripts/gen_inventory.py` (read-only catalog")
    L.append("> queries; never prints secret values). Hand-written ownership, landmines,")
    L.append("> and cross-source rules live in `RESOURCES_BIBLE.md` — this file is the")
    L.append("> objective index of *what physically exists* so nothing gets rebuilt.")
    L.append("")
    L.append(f"**Snapshot:** {now} · "
             f"{counts['tables']} tables · {counts['views']} views · "
             f"{counts['matviews']} matviews · {counts['functions']} functions · "
             f"{counts['crons']} crons ({counts['crons_active']} active) · "
             f"{len(edge)} edge functions")
    L.append("")
    L.append("Before authoring a new table/view/RPC/cron, **Ctrl-F this file first.**")
    L.append("")

    # Functions — the section RESOURCES_BIBLE.md never had.
    L.append("---")
    L.append("")
    L.append(f"## Functions / RPCs ({counts['functions']})")
    L.append("")
    L.append("_The complete list. `RESOURCES_BIBLE.md`/`PROJECT_BIBLE §4` only cover the hot subset._")
    L.append("")
    L.append(md_table(["Function (signature)", "Returns", "Comment"],
                      [f"| `{r['proname']}({r['args'] or ''})` | {r['ret'] or ''} | {r['cmt']} |"
                       for r in fns]))
    L.append("")

    L.append("---")
    L.append("")
    L.append(f"## Tables ({counts['tables']})")
    L.append("")
    L.append(md_table(["Table", "Size", "Comment"],
                      [f"| `{r['relname']}` | {r['size']} | {r['cmt']} |" for r in tables]))
    L.append("")

    L.append("---")
    L.append("")
    L.append(f"## Views ({counts['views']}) + Materialized views ({counts['matviews']})")
    L.append("")
    L.append(md_table(["View", "Comment"],
                      [f"| `{r['relname']}` | {r['cmt']} |" for r in views]))
    L.append("")
    L.append("**Materialized views:**")
    L.append("")
    L.append(md_table(["Matview", "Size", "Comment"],
                      [f"| `{r['relname']}` | {r['size']} | {r['cmt']} |" for r in mviews]))
    L.append("")

    L.append("---")
    L.append("")
    L.append(f"## Cron jobs ({counts['crons']}, {counts['crons_active']} active)")
    L.append("")
    L.append(md_table(["Job", "Schedule", "State"],
                      [f"| `{r['jobname']}` | `{r['schedule']}` | {'ON' if r['active'] else 'OFF'} |"
                       for r in crons]))
    L.append("")

    L.append("---")
    L.append("")
    L.append(f"## Edge functions ({len(edge)})")
    L.append("")
    L.append("_From `supabase/functions/` (excludes `_shared`)._")
    L.append("")
    L.append(", ".join(f"`{e}`" for e in edge))
    L.append("")
    return "\n".join(L)


def main():
    check = "--check" in sys.argv
    db_url = os.environ.get("SUPABASE_DB_URL")
    if not db_url:
        sys.exit("SUPABASE_DB_URL is not set (postgres connection string required).")
    try:
        import psycopg2
        import psycopg2.extras
    except ImportError:
        sys.exit("psycopg2 is required: pip install psycopg2-binary")

    with psycopg2.connect(db_url) as conn:
        # Belt-and-suspenders: this script only ever reads.
        conn.set_session(readonly=True, autocommit=True)
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            content = build(cur)

    if check:
        current = OUT.read_text() if OUT.exists() else ""
        # Ignore the volatile snapshot timestamp line when comparing.
        def strip_ts(s):
            return "\n".join(l for l in s.splitlines() if not l.startswith("**Snapshot:**"))
        if strip_ts(current) != strip_ts(content):
            sys.exit(f"DRIFT: {OUT.name} is stale. Run: python3 scripts/gen_inventory.py")
        print(f"{OUT.name} is up to date.")
        return

    OUT.write_text(content)
    print(f"wrote {OUT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
