#!/usr/bin/env python3
"""Ephemeral migration-version de-duplication for the from-zero CI gate.

WHY: the committed migration set has ~35 duplicate version prefixes — many
migrations were authored in batches sharing a `YYYYMMDDHHMMSS` timestamp and
applied to prod via Supabase MCP, which (unlike the `supabase db start` CLI
runner) doesn't enforce `supabase_migrations.schema_migrations.version` as a
primary key. So `supabase db start` dies on the FIRST duplicate, before it can
validate the rest of the SQL.

WHAT: this rewrites every migration filename in supabase/migrations to a unique,
strictly-increasing 14-digit synthetic version IN THE CI CHECKOUT ONLY (the
committed files are never touched — run this on an ephemeral runner). Apply
ORDER is preserved (files are processed in their existing lexicographic order,
which is the order supabase would apply them). This lets `supabase db start`
validate what actually matters from zero — every migration's SQL, the schema it
builds, ordering dependencies, and missing-table drift — WITHOUT choking on the
version-bookkeeping artifact.

It is NOT a mask: it prints every duplicate version it resolved so the collision
finding stays visible in the CI log for A1 to reconcile in the committed set.

Usage (in CI, before `supabase db start`):
    python scripts/ci_dedupe_migrations.py supabase/migrations
"""
from __future__ import annotations

import sys
from datetime import datetime, timedelta
from pathlib import Path


def main(argv: list[str]) -> int:
    mig_dir = Path(argv[1] if len(argv) > 1 else "supabase/migrations")
    files = sorted(p for p in mig_dir.glob("*.sql"))
    if not files:
        print(f"no migrations in {mig_dir}", file=sys.stderr)
        return 1

    # Report duplicates (the finding) before rewriting.
    seen: dict[str, list[str]] = {}
    for p in files:
        version = p.name.split("_", 1)[0]
        seen.setdefault(version, []).append(p.name)
    dups = {v: names for v, names in seen.items() if len(names) > 1}
    if dups:
        total = sum(len(n) for n in dups.values())
        print(f"::warning::migrations-from-zero: {len(dups)} duplicate version "
              f"prefixes ({total} files) — should be reconciled in the committed "
              f"set by A1. Resolving ephemerally for this run only:")
        for v in sorted(dups):
            print(f"  {v}: {', '.join(dups[v])}")
    else:
        print("no duplicate migration versions found.")

    # Re-sequence to unique 14-digit synthetic versions, order preserved. Base
    # in the migrations' real era (2026-01-01) — NOT an early year: the CLI
    # treats sufficiently-early versions specially and would skip them.
    base = datetime(2026, 1, 1, 0, 0, 0)
    renamed = 0
    for i, p in enumerate(files):
        rest = p.name.split("_", 1)[1] if "_" in p.name else p.name
        # The CLI SKIPS any migration named `<version>_init.sql` ("replace
        # 'init' with a different file name to apply this migration"). Our
        # first migration is literally `_init.sql` and CREATES core tables
        # (watchlist, events, …) that later migrations insert into — skipping
        # it breaks the whole from-zero apply. Rename the reserved name.
        if rest == "init.sql":
            rest = "initial_schema.sql"
        new_version = (base + timedelta(seconds=i)).strftime("%Y%m%d%H%M%S")
        new_name = f"{new_version}_{rest}"
        if new_name != p.name:
            p.rename(p.with_name(new_name))
            renamed += 1
    print(f"re-sequenced {renamed}/{len(files)} migration filenames "
          f"(ephemeral; committed files unchanged).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
