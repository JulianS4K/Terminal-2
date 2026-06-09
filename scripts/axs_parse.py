#!/usr/bin/env python3
"""CLI over axs_client.distill — render a raw AXS event payload (the ~1.8MB
endpoint JSON) as a compact, storable summary + per-section table.

The parsing contract lives in axs_client.distill (single source of truth);
this is just a thin viewer. Read-only: reads a document, no network I/O.

Usage: python scripts/axs_parse.py <axs_event.json>
"""
from __future__ import annotations
import json, sys, pathlib

# axs_client lives at the repo root; make it importable when run from anywhere.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from axs_client import distill  # noqa: E402

if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "axs_sample.json"
    doc = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    out = distill(doc)
    secs = out.pop("sections")
    print(json.dumps(out, indent=2, ensure_ascii=False))
    print("\nPER-SECTION:")
    print(f"{'section':<14}{'neigh':<13}{'avail':>6}{'min$':>8}{'max$':>8}{'resale':>8}  seat_types")
    for r in secs:
        print(f"{(r['section'] or ''):<14}{(r['neighborhood'] or ''):<13}"
              f"{r['avail_qty']:>6}{(r['price_min'] or 0):>8.0f}{(r['price_max'] or 0):>8.0f}"
              f"{('yes' if r['has_resale'] else '-'):>8}  {','.join(r['seat_types'] or [])}")
