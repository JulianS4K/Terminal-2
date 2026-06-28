"""Trip-planner payload builders — extracted from server.py (BR-CODE-1 core/
pass).

Shared bodies for the per-performer trip-plan / tour-package / multi-tour /
reverse-discover routes (consumed by both the D0 broker router and the D1 store
router). Each is a thin orchestrator: clamp the request params, resolve the live
db, and call into the `trip_planner` package (where the optimizer lives). Pure
read + compute — no writes, no upstream API.

`require_sb` (the live Supabase getter) is injected by the server wrappers so the
app-module monkeypatch keeps binding; the pure helpers (tour_dates, clean_section)
come from core.helpers directly.
"""
from __future__ import annotations

from datetime import date, timedelta

from fastapi import HTTPException

from core.helpers import clean_section as _clean_section, tour_dates as _tour_dates

# Geographic center of the contiguous US — the neutral "home" used when a caller
# plans location-free (ticket-budget only). Paired with an unlimited travel budget
# so the travel-km dimension never binds and the plan is driven purely by spend.
_US_CENTER_LAT, _US_CENTER_LON = 39.8283, -98.5795


def trip_plan_payload(performer_id: int, home_lat: float, home_lon: float,
                      budget_km: float, home_name: str, days: int,
                      max_events: int | None,
                      budget_usd: float | None = None, qty: int = 1,
                      *, require_sb) -> dict:
    """Shared body for the D0/D1 per-performer trip-plan routes.

    Plans the maximum-value multi-city itinerary around a performer's upcoming dates within
    a round-trip km budget — and, when `budget_usd` is given, also within a ticket-spend
    budget (get-in x max(0, qty - owned), owned tickets free). Pure read (v_event_base +
    event_listing_snapshot_daily) + compute — no writes, no upstream API.
    """
    from trip_planner import plan_performer_trip

    db = require_sb()
    start = date.today()
    end = start + timedelta(days=max(1, min(int(days), 730)))
    budget = max(100.0, min(float(budget_km), 50000.0))
    spend = None if budget_usd is None else max(0.0, min(float(budget_usd), 10_000_000.0))
    return plan_performer_trip(
        db, int(performer_id), float(home_lat), float(home_lon), budget,
        start, end, home_name=(home_name or "Home").strip()[:60], max_events=max_events,
        budget_usd=spend, qty=max(1, min(int(qty), 50)),
    )


def tour_package_payload(performer_id: int, home_lat: float | None, home_lon: float | None,
                         qty: int, budget_km: float, home_name: str, days: int,
                         budget_usd: float | None, side: str, clear_at: float,
                         away_margin: float, section_like: str | None = None,
                         prefer_owned: bool = False, max_events: int | None = None,
                         start_date: str | None = None, end_date: str | None = None,
                         *, require_sb) -> dict:
    """Shared body for the retail 'tour with the artist' routes (D0 + store).

    Dual-mode: owned-splits where we hold inventory (concerts), market-sourced buy-to-fulfill
    for a team's away games (road owned ~ 0). Pure read + compute — no writes, no upstream API.

    Location-free planning: when home_lat/home_lon are omitted, we plan on the ticket budget
    alone — neutral US-center home + unlimited travel budget so distance never constrains the
    pick (the fan just wants the most stops their money buys, anywhere on the tour).
    max_events caps how many stops to follow; the optimizer keeps the best set that fits.
    start_date/end_date (ISO) set an explicit window; otherwise it's [today, today+days]."""
    from datetime import date as _date

    from trip_planner import plan_performer_tour

    db = require_sb()
    start, end = _tour_dates(days)
    today = _date.today()
    if start_date:
        try:
            start = max(today, _date.fromisoformat(start_date[:10]))
        except ValueError:
            pass
    if end_date:
        try:
            end = min(today + timedelta(days=730), _date.fromisoformat(end_date[:10]))
        except ValueError:
            pass
    if end <= start:                       # guard against an inverted/empty window
        end = start + timedelta(days=1)
    spend = None if budget_usd is None else max(0.0, min(float(budget_usd), 10_000_000.0))
    loc_free = home_lat is None or home_lon is None
    hlat = _US_CENTER_LAT if loc_free else float(home_lat)
    hlon = _US_CENTER_LON if loc_free else float(home_lon)
    bkm = 50000.0 if loc_free else max(100.0, min(float(budget_km), 50000.0))
    me = None if max_events is None else max(1, min(int(max_events), 12))
    return plan_performer_tour(
        db, int(performer_id), hlat, hlon,
        max(1, min(int(qty), 50)), bkm,
        start, end, home_name=(home_name or "Home").strip()[:60], budget_usd=spend,
        side=(side if side in ("auto", "away", "home", "concert") else "auto"),
        clear_at=min(max(float(clear_at), 0.01), 1.0),
        away_margin=min(max(float(away_margin), 0.0), 2.0),
        section_like=_clean_section(section_like), prefer_owned=bool(prefer_owned),
        max_events=me,
    )


def multi_tour_payload(performer_ids: str, home_lat: float, home_lon: float, qty: int,
                       budget_km: float, home_name: str, days: int, budget_usd: float | None,
                       side: str, clear_at: float, away_margin: float,
                       section_like: str | None, prefer_owned: bool,
                       *, require_sb) -> dict:
    """'Plan my summer': one routed+priced package across several performers' events."""
    from trip_planner import plan_multi_performer_tour

    # Guard the coercion: performer_ids is a free-text query param, so a
    # non-numeric token (e.g. "abc" or "1,foo,3") must 400, not bubble an
    # uncaught ValueError into a 500. Mirrors the catalog guard at the
    # /api/store/events perf-id gather.
    try:
        ids = [int(x) for x in str(performer_ids).replace(" ", "").split(",") if x][:8]
    except (TypeError, ValueError):
        raise HTTPException(400, "performer_ids must be comma-separated integers")
    if not ids:
        raise HTTPException(400, "performer_ids required (comma-separated, up to 8)")
    db = require_sb()
    start, end = _tour_dates(days)
    spend = None if budget_usd is None else max(0.0, min(float(budget_usd), 10_000_000.0))
    return plan_multi_performer_tour(
        db, ids, float(home_lat), float(home_lon),
        max(1, min(int(qty), 50)), max(100.0, min(float(budget_km), 50000.0)),
        start, end, home_name=(home_name or "Home").strip()[:60], budget_usd=spend,
        side=(side if side in ("auto", "away", "home", "concert") else "auto"),
        clear_at=min(max(float(clear_at), 0.01), 1.0),
        away_margin=min(max(float(away_margin), 0.0), 2.0),
        section_like=_clean_section(section_like), prefer_owned=bool(prefer_owned),
    )


def discover_payload(home_lat: float, home_lon: float, within_mi: float, days: int,
                     min_shows: int, concerts_only: bool, team_side: str = "home",
                     *, require_sb) -> dict:
    """Shared body for reverse-discovery ('tours near me'). Read-only.

    team_side: 'home' (default — D0 broker discover, legacy home-stand grouping) or
    'away' (D1 storefront — surfaces a team by its road games that come to your area)."""
    from trip_planner import discover_tours_near

    db = require_sb()
    start, end = _tour_dates(days)
    return discover_tours_near(
        db, float(home_lat), float(home_lon),
        max(5.0, min(float(within_mi), 1000.0)), start, end,
        min_shows=max(1, min(int(min_shows), 6)),
        event_types=["concert"] if concerts_only else None,
        team_side=(team_side if team_side in ("home", "away") else "home"),
    )
