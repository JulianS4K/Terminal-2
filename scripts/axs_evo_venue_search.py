#!/usr/bin/env python3
"""Search unmapped AXS venues against TEvo's full venue catalog via EVO and keep
the US matches — the live counterpart to the in-DB trigram pass (which only sees
the ~554 venues we already hold). Read-only: only evo_client GET /v9/venues/search.

MUST run where EVO is reachable + creds are set (the Render service), NOT the
web sandbox (egress to api.ticketevolution.com is blocked there). Needs:
  TEVO_API_TOKEN / TEVO_API_SECRET   (or TEVO_TOKEN / TEVO_SECRET)

Input  : the unmapped AXS names (default scripts/axs_venues_unmapped.csv).
Output : scripts/axs_evo_candidates.csv — axs_name, tevo_venue_id, tevo_name,
         city, state, country, score (review-grade). US rows flagged is_us.

Promote good rows into axs_venues afterwards (match_method='evo_search'):
  UPDATE public.axs_venues a SET tevo_venue_id=:id, matched_name=:nm,
         match_method='evo_search' WHERE a.axs_name=:axs AND a.tevo_venue_id IS NULL;
"""
from __future__ import annotations
import argparse, csv, os, sys, time, pathlib
from difflib import SequenceMatcher

US = {"US", "USA", "UNITED STATES"}


def _client():
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
    from evo_client import EvoClient
    tok = os.environ.get("TEVO_API_TOKEN") or os.environ.get("TEVO_TOKEN")
    sec = os.environ.get("TEVO_API_SECRET") or os.environ.get("TEVO_SECRET")
    if not (tok and sec):
        sys.exit("TEVO_API_TOKEN / TEVO_API_SECRET not set — run where EVO creds exist.")
    return EvoClient(tok, sec, sandbox=os.environ.get("TEVO_SANDBOX", "false").lower() == "true")


def _addr(v: dict) -> tuple[str | None, str | None, str | None]:
    a = v.get("address") or {}
    city = a.get("locality") or v.get("city")
    state = a.get("region") or v.get("state")
    country = a.get("country_code") or a.get("country") or v.get("country")
    return city, state, country


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="infile", default="scripts/axs_venues_unmapped.csv")
    ap.add_argument("--out", dest="outfile", default="scripts/axs_evo_candidates.csv")
    ap.add_argument("--limit", type=int, default=200, help="max AXS venues to search")
    ap.add_argument("--min-score", type=float, default=0.55)
    ap.add_argument("--sleep", type=float, default=0.25, help="pause between calls (rate limit)")
    ap.add_argument("--us-only", action="store_true", help="write only US matches")
    args = ap.parse_args()

    client = _client()
    names = []
    with open(args.infile, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            n = (row.get("axs_name") or "").strip()
            if n:
                names.append(n)
    names = names[: args.limit]

    out_rows, hits, us_hits = [], 0, 0
    for i, name in enumerate(names, 1):
        try:
            res = client.search_venues(name, fuzzy=True, per_page=5)
        except Exception as e:
            print(f"  [{i}/{len(names)}] {name!r}: search error {e}")
            time.sleep(args.sleep); continue
        venues = (res or {}).get("venues") or []
        best, best_score = None, 0.0
        for v in venues:
            sc = SequenceMatcher(None, name.lower(), str(v.get("name", "")).lower()).ratio()
            if sc > best_score:
                best, best_score = v, sc
        if best and best_score >= args.min_score:
            city, state, country = _addr(best)
            is_us = str(country or "").upper() in US
            if args.us_only and not is_us:
                pass
            else:
                hits += 1; us_hits += int(is_us)
                out_rows.append({
                    "axs_name": name, "tevo_venue_id": best.get("id"),
                    "tevo_name": best.get("name"), "city": city, "state": state,
                    "country": country, "is_us": is_us, "score": round(best_score, 3),
                })
        time.sleep(args.sleep)

    with open(args.outfile, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["axs_name", "tevo_venue_id", "tevo_name",
                                          "city", "state", "country", "is_us", "score"])
        w.writeheader(); w.writerows(out_rows)

    print(f"searched {len(names)} AXS venues -> {hits} matches (>= {args.min_score}), "
          f"{us_hits} US -> {args.outfile}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
