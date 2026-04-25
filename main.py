"""Simple CLI: search events, pick one, dump listings + authoritative stats.

Usage:
    $env:TEVO_TOKEN   = "..."
    $env:TEVO_SECRET  = "..."
    $env:TEVO_SANDBOX = "false"   # or "true"
    py main.py
"""

from __future__ import annotations

import os
import sys

from evo_client import EvoClient


def money(x) -> str:
    return f"${x:,.2f}" if x is not None else "—"


def pick_event(client: EvoClient) -> dict:
    q = input("Search events: ").strip()
    if not q:
        sys.exit("No query.")

    events = client.search_events_all(
        q=q,
        only_with_available_tickets=True,
        order_by="events.popularity_score DESC",
    )
    if not events:
        sys.exit("No events found.")

    print(f"\nFound {len(events)} events:\n")
    for i, ev in enumerate(events, 1):
        venue = ev.get("venue") or {}
        when = ev.get("occurs_at_local", "?")
        print(f"{i:>3}. [{ev['id']}] {ev['name']}")
        print(f"      {when}  {venue.get('name', '')} — {venue.get('location', '')}")
        print(f"      available: {ev.get('available_count', 0)}")

    choice = input("\nPick row # or event ID: ").strip()
    try:
        n = int(choice)
    except ValueError:
        sys.exit("Invalid choice.")

    if 1 <= n <= len(events):
        return events[n - 1]
    for ev in events:
        if ev["id"] == n:
            return ev
    sys.exit(f"Event {n} not in results.")


def show_listings(client: EvoClient, event: dict) -> None:
    listings = client.get_listings(event["id"], order_by="retail_price ASC")
    groups = listings.get("ticket_groups", [])

    # Authoritative stats (event-level available_count is deprecated)
    stats = client.get_event_stats(event["id"])
    stats_event_only = client.get_event_stats(event["id"], inventory_type="event")

    sum_avail = sum(tg.get("available_quantity", 0) for tg in groups)
    sum_qty   = sum(tg.get("quantity", 0) for tg in groups)

    print(f"\n{event['name']}")
    print(f"  {len(groups)} ticket groups listed  |  available: {sum_avail}  |  quantity: {sum_qty}")
    print(
        f"  stats (all):         {stats['ticket_groups_count']:>5} groups  "
        f"{stats['tickets_count']:>6} tickets  "
        f"retail ${stats['retail_price_min']:,.0f}–${stats['retail_price_max']:,.0f} "
        f"(avg ${stats['retail_price_avg']:,.0f})"
    )
    print(
        f"  stats (event only):  {stats_event_only['ticket_groups_count']:>5} groups  "
        f"{stats_event_only['tickets_count']:>6} tickets"
    )
    print(f"  legacy event.available_count (deprecated): {event.get('available_count', 0)}")
    print()

    header = f"{'section':<14} {'row':<6} {'qty':>4} {'price':>10}  {'splits':<14} format"
    print(header)
    print("-" * len(header))
    for tg in groups:
        splits = ",".join(str(s) for s in tg.get("splits") or [])
        print(
            f"{(tg.get('section') or ''):<14.14} "
            f"{(tg.get('row') or ''):<6.6} "
            f"{tg.get('available_quantity', 0):>4} "
            f"{money(tg.get('retail_price')):>10}  "
            f"{splits:<14.14} "
            f"{tg.get('format') or ''}"
        )


def main() -> None:
    token = os.environ.get("TEVO_TOKEN")
    secret = os.environ.get("TEVO_SECRET")
    sandbox = os.environ.get("TEVO_SANDBOX", "true").lower() == "true"

    if not token or not secret:
        sys.exit("Set TEVO_TOKEN and TEVO_SECRET environment variables.")

    client = EvoClient(token, secret, sandbox=sandbox)
    event = pick_event(client)
    show_listings(client, event)


if __name__ == "__main__":
    main()
