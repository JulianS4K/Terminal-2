#!/usr/bin/env python3
"""scripts/broadway_live_smoke.py — live Broadway.com scraper smoke test.

Hits www.broadway.com + checkout.broadway.com for a handful of long-run
shows, prints pass/fail per slug, exits non-zero if any failed. Intended
for an admin PC with unrestricted egress; on an egress-blocked
environment (e.g. Claude Code on web's default network policy) it will
fail fast with the host_not_allowed signature.

RULE 2: read-only. Every request goes through BroadwayClient._get which
hard-asserts GET via _assert_readonly_method.

Usage:
    python scripts/broadway_live_smoke.py

Override:
    BROADWAY_SMOKE_SLUGS="hamilton the-lion-king wicked" \\
        python scripts/broadway_live_smoke.py
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# Make repo root importable when run from anywhere.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from broadway_client import BroadwayClient, BroadwayError  # noqa: E402

DEFAULT_SLUGS = [
    "the-25th-annual-putnam-county-spelling-bee",
    "hamilton",
    "the-lion-king",
]


def main() -> int:
    raw = os.environ.get("BROADWAY_SMOKE_SLUGS")
    slugs = raw.split() if raw else DEFAULT_SLUGS

    cli = BroadwayClient()
    passed = 0
    failed = 0

    for slug in slugs:
        print(f"=== {slug} ===", flush=True)
        try:
            perfs = cli.discover_performances(slug)
        except BroadwayError as e:
            print(f"  DISCOVER_FAIL: {e}")
            failed += 1
            continue
        if not perfs:
            print("  NO_PERFS (show may have closed)")
            failed += 1
            continue
        p = perfs[0]
        try:
            snap = cli.fetch_sections(p.slug, p.show_id, p.event_id)
        except BroadwayError as e:
            print(f"  FETCH_FAIL ({p.event_id}): {e}")
            failed += 1
            continue
        title = snap.show.title if snap.show else "?"
        print(
            f"  OK title={title!r} event_id={snap.event_id} "
            f"sections={len(snap.sections)} perf={snap.performance_time}"
        )
        passed += 1

    print()
    print(f"summary: {passed} passed, {failed} failed (of {len(slugs)})")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
