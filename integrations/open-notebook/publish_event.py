#!/usr/bin/env python3
"""Publish a Terminal-2 event brief into open-notebook as a source.

POC publisher: pulls the read-only market data for one event, renders a
markdown brief, and POSTs it to an open-notebook instance via `POST /sources`.

This is one-directional and read-only against our DB. It never writes to
prod and never touches any upstream broker API (CLAUDE.md §1/§2).

Env:
  SUPABASE_URL              e.g. https://hzrizjeaxlqcxfrtczpq.supabase.co
  SUPABASE_SERVICE_KEY      service-role key (RPC/SELECT only here)
  OPEN_NOTEBOOK_URL         e.g. http://localhost:5055
  OPEN_NOTEBOOK_NOTEBOOK_ID target notebook id (e.g. one per team)
  OPEN_NOTEBOOK_API_KEY     optional, if the instance requires auth

Usage:
  python publish_event.py 3346012
  python publish_event.py 3346012 --dry-run   # render only, no POST
"""
import argparse
import os
import sys
import textwrap

import requests

SQL_TRENDS = """
SELECT event_id, days_to_event, snapshot_date, snapshot_slot,
       evo_retail_getin, evo_retail_median, evo_retail_max, evo_tickets_count,
       evo_owned_tickets, evo_owned_median, evo_owned_vs_market_pct, evo_owned_7d_velocity,
       evo_median_dod_delta, evo_median_wow_delta,
       amalgam_getin, amalgam_median, amalgam_median_dod_delta,
       amalgam_median_wow_delta, amalgam_source_count
FROM public.v_event_listing_trends
WHERE event_id = %(event_id)s
ORDER BY captured_at DESC NULLS LAST
LIMIT 1;
"""


def _sb_headers():
    key = os.environ["SUPABASE_SERVICE_KEY"]
    return {"apikey": key, "Authorization": f"Bearer {key}",
            "Content-Type": "application/json"}


def fetch(event_id: int) -> dict:
    """Pull the brief inputs via PostgREST RPCs / views (read-only)."""
    base = os.environ["SUPABASE_URL"].rstrip("/")
    h = _sb_headers()
    why = requests.get(f"{base}/rest/v1/v_event_why_context",
                       params={"event_id": f"eq.{event_id}", "select": "*"},
                       headers=h, timeout=30).json()
    trends = requests.get(f"{base}/rest/v1/v_event_listing_trends",
                          params={"event_id": f"eq.{event_id}", "select": "*",
                                  "order": "captured_at.desc.nullslast", "limit": "1"},
                          headers=h, timeout=30).json()
    if not why or not trends:
        sys.exit(f"No data for event {event_id} (why={bool(why)} trends={bool(trends)})")
    return {"why": why[0], "trends": trends[0]}


def _money(v):
    return f"${float(v):,.0f}" if v is not None else "—"


def _delta(v):
    if v is None:
        return "—"
    v = float(v)
    return f"{'+' if v >= 0 else '−'}${abs(v):,.0f}"


def render(data: dict) -> tuple[str, str]:
    w, t = data["why"], data["trends"]
    title = w["name"]
    body = textwrap.dedent(f"""\
    # {title}

    > Market brief · {t.get('snapshot_date')} ({t.get('snapshot_slot')} slot) · tevo_event_id {w['event_id']}
    > Source: Terminal-2 broker data. Read-only snapshot.

    ## The matchup
    - Venue: {w['venue_name']}, {w['venue_location']}
    - Tip-off: {w['occurs_at_local']} — {t.get('days_to_event')} days out

    ## Where the market is
    - Get-in (curated EVO retail floor): **{_money(t.get('evo_retail_getin'))}**
    - Median listing: **{_money(t.get('evo_retail_median'))}**
    - Top end: {_money(t.get('evo_retail_max'))}
    - Active tickets: {t.get('evo_tickets_count')}
    - Amalgam blended median: {_money(t.get('amalgam_median'))} ({t.get('amalgam_source_count')} source(s))

    ## What's moving
    - Median day-over-day: {_delta(t.get('evo_median_dod_delta'))}
    - Median week-over-week: {_delta(t.get('evo_median_wow_delta'))}

    ## Our position (owned inventory)
    - Owned tickets: {t.get('evo_owned_tickets')}
    - Owned median: {_money(t.get('evo_owned_median'))} ({t.get('evo_owned_vs_market_pct')}% of market)
    - 7-day owned velocity: {t.get('evo_owned_7d_velocity')}
    """)
    return title, body


def publish(title: str, body: str):
    base = os.environ["OPEN_NOTEBOOK_URL"].rstrip("/")
    payload = {
        "notebook_id": os.environ["OPEN_NOTEBOOK_NOTEBOOK_ID"],
        "type": "text",
        "title": title,
        "content": body,
        "async_processing": True,
    }
    headers = {"Content-Type": "application/json"}
    if os.environ.get("OPEN_NOTEBOOK_API_KEY"):
        headers["Authorization"] = f"Bearer {os.environ['OPEN_NOTEBOOK_API_KEY']}"
    r = requests.post(f"{base}/sources", json=payload, headers=headers, timeout=120)
    r.raise_for_status()
    print(f"Published source: {r.status_code} {r.json().get('id', '')}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("event_id", type=int)
    ap.add_argument("--dry-run", action="store_true", help="render only, do not POST")
    args = ap.parse_args()

    data = fetch(args.event_id)
    title, body = render(data)
    if args.dry_run:
        print(body)
        return
    publish(title, body)


if __name__ == "__main__":
    main()
