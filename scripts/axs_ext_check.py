#!/usr/bin/env python3
"""Check a capture the AXS extension's "Test one event" downloaded: what our server would make of it.

    python scripts/axs_ext_check.py ~/Downloads/axs-capture-1636873.json

Prints the outcome the database would record, the answers captured, the order limits and every listing with its
price, fees and all-in. Reads the file only: nothing is sent anywhere. (core/axs_ext_doc.build_record is the same
code the web service runs on POST /api/axs/ext/record.)
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import axs_ext_doc  # noqa: E402


def main(path: str) -> int:
    cap = json.loads(Path(path).read_text(encoding="utf-8"))
    rec = axs_ext_doc.build_record(cap)
    found = axs_ext_doc.classify([c.get("json") for c in cap.get("captures") or []])
    print(f"event {cap.get('event_id')} · {cap.get('outcome')} · {cap.get('elapsed_s')} s · landed on {cap.get('final_url')}")
    print(f"answers kept: {len(cap.get('captures') or [])} · seat offers {len(found['offers'])} · price book entries "
          f"{len(found['offer_prices'])} · fee definitions {len(found['fee_defs'])} · delivery methods {len(found['delivery'])}")
    if cap.get("cancelled"):
        print("writes cancelled in the tab:", *cap["cancelled"], sep="\n  ")
    if rec["p_content"] is None:
        print(f"recorded as a failed read: status {rec['p_status_code']} · {rec['p_error_msg']}")
        return 1
    body = rec["p_content"]["body"]
    if body.get("status") != "ok":
        print(f"recorded as {body.get('status')}: {body.get('error')}")
        return 1
    print(f"on sale: {body['onsale']} · order limits: {body['groups']}")
    rows = body["listings"]
    print(f"{len(rows)} listings, {sum(int(r.get('quantity') or 0) for r in rows)} seats")
    for r in rows:
        p = r.get("pricing") or {}
        seats = ",".join(r.get("seats") or []) or "-"
        print(f"  {r['kind']:<7} {str(r.get('section')):<12} row {str(r.get('row') or '-'):<5} seats {seats:<14} "
              f"qty {r['quantity']:<3} face {p.get('face')!s:<8} fees {p.get('fees_total')!s:<7} all-in {p.get('all_in')!s:<8} "
              f"{r.get('seat_type') or ''} {r.get('status') or ''} {r.get('seller_notes') or ''}".rstrip())
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
