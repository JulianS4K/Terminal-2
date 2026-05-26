#!/usr/bin/env python3
"""TicketsData MVP smoke test — budget-guarded.

Exercises the TicketsData client against a tiny, explicit set of calls so we
can confirm auth + connectivity + parsing WITHOUT burning through the plan.

Plan context (Starter): 10,000 API credits/mo + 250 Market-Intelligence
reports/mo. Cost: /fetch = 1 credit, /events = 1 credit, /match = 12 credits
AND 1 report.

The guard: this script projects the WORST-CASE credit cost of the requested
actions up front and refuses to make any call if that exceeds --max-credits.
After every call it reads `quota_remaining` (and `reports_remaining` for
/match) from the response and aborts the rest of the plan if either drops
below its floor. /match is OFF unless you pass --allow-match.

Credentials come from TICKETSDATA_USERNAME / TICKETSDATA_PASSWORD env vars.

Examples:
  # dry run — print the plan + projected cost, make zero calls
  python scripts/ticketsdata_mvp.py --platform seatgeek \\
      --event-url https://seatgeek.com/concert/17762666 --dry-run

  # one /fetch (1 credit)
  python scripts/ticketsdata_mvp.py --platform seatgeek \\
      --event-url https://seatgeek.com/concert/17762666

  # one /events discovery + one /fetch on the first result (<= 2 credits)
  python scripts/ticketsdata_mvp.py --platform seatgeek \\
      --performer-url https://seatgeek.com/cardi-b-tickets --then-fetch

  # cross-market report (12 credits + 1 report) — must opt in AND raise cap
  python scripts/ticketsdata_mvp.py --allow-match --max-credits 12 \\
      --match-url https://seatgeek.com/concert/17762666
"""
from __future__ import annotations

import argparse
import os
import sys

# Allow running as `python scripts/ticketsdata_mvp.py` from repo root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ticketsdata_client import (  # noqa: E402
    CREDIT_COST,
    TicketsDataClient,
    TicketsDataError,
)


class BudgetExceeded(RuntimeError):
    pass


class Budget:
    """Hard credit ceiling for one MVP run. Refuses spend over the cap and
    tracks the live `quota_remaining` floor reported by the API."""

    def __init__(self, max_credits: int, min_quota_floor: int):
        self.max_credits = max_credits
        self.min_quota_floor = min_quota_floor
        self.spent = 0
        self.last_quota_remaining: int | None = None

    def check(self, cost: int) -> None:
        if self.spent + cost > self.max_credits:
            raise BudgetExceeded(
                f"would spend {self.spent + cost} credits > cap {self.max_credits}"
            )
        if (
            self.last_quota_remaining is not None
            and self.last_quota_remaining - cost < self.min_quota_floor
        ):
            raise BudgetExceeded(
                f"quota_remaining {self.last_quota_remaining} would drop below "
                f"floor {self.min_quota_floor}"
            )

    def record(self, cost: int, quota_remaining: int | None) -> None:
        self.spent += cost
        if isinstance(quota_remaining, int):
            self.last_quota_remaining = quota_remaining


def _maybe_supabase():
    """Best-effort service-role Supabase client for the Vault credential
    fallback. Returns None if env/lib unavailable (then env creds are used)."""
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not (url and key):
        return None
    try:
        from supabase import create_client
        return create_client(url, key)
    except Exception as e:
        print(f"(supabase client unavailable, using env creds: {e})", file=sys.stderr)
        return None


def _q(env: dict) -> int | None:
    v = env.get("quota_remaining")
    return v if isinstance(v, int) else None


def _summarize_fetch(env: dict) -> str:
    plat = env.get("platform", "?")
    body = env.get("body")
    n = None
    if isinstance(body, list):
        n = len(body)
    elif isinstance(body, dict):
        emb = body.get("_embedded")
        if isinstance(emb, dict) and isinstance(emb.get("offer"), list):
            n = len(emb["offer"])
        elif isinstance(body.get("listings"), list):
            n = len(body["listings"])
        elif isinstance(body.get("offers"), list):
            n = len(body["offers"])
    listings = f"{n} listings" if n is not None else "listings (shape varies)"
    return f"  /fetch {plat}: status={env.get('status')} {listings} in {env.get('response_s')}s"


def _summarize_match(env: dict) -> str:
    intel = (env.get("fetch_results") or {}).get("intelligence") or {}
    snap = intel.get("cross_market_snapshot") or {}
    best = snap.get("best_entry_total") or {}
    deep = snap.get("deepest_market") or {}
    arb = intel.get("section_arbitrage") or []
    top = arb[0] if arb else {}
    lines = [
        f"  /match: confidence={env.get('match_confidence')} "
        f"markets={snap.get('marketplaces_compared')}",
        f"    best entry: {best.get('marketplace')} ${best.get('price')} "
        f"({best.get('section')})",
        f"    deepest:    {deep.get('marketplace')} {deep.get('listing_count')} listings",
    ]
    if top:
        lines.append(
            f"    top spread: {top.get('section')} ${top.get('spread')} "
            f"({top.get('spread_pct_vs_best')}% vs best)"
        )
    lines.append(f"    reports_remaining={env.get('reports_remaining')}")
    return "\n".join(lines)


def _first_event_url(env: dict) -> str | None:
    """Best-effort extraction of the first event URL from an /events body."""
    body = env.get("body")
    items = body if isinstance(body, list) else (
        body.get("events") if isinstance(body, dict) else None
    )
    if not isinstance(items, list):
        return None
    for it in items:
        if isinstance(it, dict):
            for key in ("event_url", "url", "link"):
                if it.get(key):
                    return it[key]
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="TicketsData MVP smoke test (budget-guarded)")
    ap.add_argument("--platform", help="marketplace for --event-url / --performer-url")
    ap.add_argument("--event-url", help="event URL for a single /fetch")
    ap.add_argument("--performer-url", help="performer/venue page for a single /events")
    ap.add_argument("--then-fetch", action="store_true",
                    help="after /events, run one /fetch on the first discovered event")
    ap.add_argument("--match-url", help="event URL for /match (cross-market report)")
    ap.add_argument("--allow-match", action="store_true",
                    help="permit the 12-credit + 1-report /match call (off by default)")
    ap.add_argument("--max-credits", type=int, default=5,
                    help="hard ceiling on credits this run may spend (default 5)")
    ap.add_argument("--min-quota-floor", type=int, default=50,
                    help="abort if quota_remaining would drop below this (default 50)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan + projected worst-case cost, make NO calls")
    args = ap.parse_args()

    # Build the plan.
    plan: list[tuple[str, int]] = []
    if args.event_url:
        plan.append(("fetch", CREDIT_COST["fetch"]))
    if args.performer_url:
        plan.append(("events", CREDIT_COST["events"]))
        if args.then_fetch:
            plan.append(("fetch-discovered", CREDIT_COST["fetch"]))
    if args.match_url:
        if not args.allow_match:
            print("ERROR: --match-url requires --allow-match "
                  "(12 credits + 1 report).", file=sys.stderr)
            return 2
        plan.append(("match", CREDIT_COST["match"]))

    if not plan:
        print("Nothing to do. Provide --event-url, --performer-url, and/or "
              "--match-url. See --help.", file=sys.stderr)
        return 2

    worst_case = sum(cost for _, cost in plan)
    print(f"Plan: {[name for name, _ in plan]}")
    print(f"Projected worst-case cost: {worst_case} credits "
          f"(cap --max-credits={args.max_credits})")
    if args.match_url:
        print("  note: /match also consumes 1 Market-Intelligence report")

    if worst_case > args.max_credits:
        print(f"REFUSING: projected {worst_case} credits exceeds cap "
              f"{args.max_credits}. Raise --max-credits to proceed.", file=sys.stderr)
        return 3

    if args.dry_run:
        print("Dry run — no calls made.")
        return 0

    try:
        # Pass a service-role db (if Supabase env is set) so creds can resolve
        # from Vault; otherwise TICKETSDATA_* env vars are used directly.
        client = TicketsDataClient(db=_maybe_supabase())
    except TicketsDataError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    budget = Budget(args.max_credits, args.min_quota_floor)

    try:
        if args.event_url:
            if not args.platform:
                print("ERROR: --event-url needs --platform", file=sys.stderr)
                return 2
            budget.check(CREDIT_COST["fetch"])
            env = client.fetch(args.platform, args.event_url)
            budget.record(CREDIT_COST["fetch"], _q(env))
            print(_summarize_fetch(env))
            print(f"  quota_remaining={_q(env)}  (spent {budget.spent})")

        if args.performer_url:
            if not args.platform:
                print("ERROR: --performer-url needs --platform", file=sys.stderr)
                return 2
            budget.check(CREDIT_COST["events"])
            env = client.events(args.platform, performer_url=args.performer_url)
            budget.record(CREDIT_COST["events"], _q(env))
            first = _first_event_url(env)
            print(f"  /events {args.platform}: discovered first event = {first}")
            print(f"  quota_remaining={_q(env)}  (spent {budget.spent})")
            if args.then_fetch and first:
                budget.check(CREDIT_COST["fetch"])
                env2 = client.fetch(args.platform, first)
                budget.record(CREDIT_COST["fetch"], _q(env2))
                print(_summarize_fetch(env2))
                print(f"  quota_remaining={_q(env2)}  (spent {budget.spent})")

        if args.match_url:
            budget.check(CREDIT_COST["match"])
            env = client.match(args.match_url)
            budget.record(CREDIT_COST["match"], _q(env))
            print(_summarize_match(env))
            print(f"  quota_remaining={_q(env)}  (spent {budget.spent})")

    except BudgetExceeded as e:
        print(f"ABORTED mid-plan (budget guard): {e}", file=sys.stderr)
        return 3
    except TicketsDataError as e:
        print(f"API error: {e}", file=sys.stderr)
        return 1

    print(f"Done. Total credits spent this run: {budget.spent}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
