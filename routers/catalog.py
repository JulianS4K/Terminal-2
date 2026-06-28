"""Catalog passthrough routes — TEvo performer / venue / configuration detail.

Second slice of the app.py decomposition (BR-CODE-1). These are thin
read-only passthroughs to the TEvo client, gated by require_auth.

Built via a factory that takes:
  - `get_client`: a zero-arg callable returning the live TEvo client. Passed as
    a getter (not the client itself) so the handlers resolve the CURRENT
    module-level client at request time — which keeps the monkeypatch-based
    tests (tests/test_catalog_routes.py patches app.client) working, and means
    require_auth/client stay owned by app.py (not relocated here).
  - `require_auth`: the auth dependency (unchanged, still defined in app.py).

Behavior is identical to the prior inline app.py routes.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from fastapi import APIRouter, Depends, HTTPException, Query

from core.helpers import is_event_seat


def build_catalog_router(
    get_client: Callable[[], Any],
    require_auth: Callable,
    # DB reads for the event time-series routes (event_metrics / section_metrics).
    # Getter so the monkeypatch tests bind; default no-op keeps existing callers
    # (which only pass get_client + require_auth) working.
    get_require_sb: Callable[[], Callable] = lambda: (lambda: None),
) -> APIRouter:
    router = APIRouter()

    @router.get("/api/performers/{performer_id}")
    def performer_detail(performer_id: int, include_opponents: bool = True, _=Depends(require_auth)):
        return get_client().get_performer(performer_id, include_opponents=include_opponents)

    @router.get("/api/venues/{venue_id}")
    def venue_detail(venue_id: int, _=Depends(require_auth)):
        return get_client().get_venue(venue_id)

    @router.get("/api/configurations")
    def configurations_list(venue_id: int | None = None, name: str | None = None, _=Depends(require_auth)):
        return get_client().list_configurations(venue_id=venue_id, name=name or None)

    @router.get("/api/configurations/{config_id}")
    def configuration_detail(config_id: int, _=Depends(require_auth)):
        return get_client().get_configuration(config_id)

    @router.get("/api/events")
    def events_search(
        q: str | None = None,
        performer_id: int | None = None,
        venue_id: int | None = None,
        occurs_at_gte: str | None = Query(None, alias="occurs_at.gte"),
        occurs_at_lte: str | None = Query(None, alias="occurs_at.lte"),
        only_with_available_tickets: bool = True,
        _=Depends(require_auth),
    ):
        events = get_client().search_events_all(
            q=q or None,
            performer_id=performer_id,
            venue_id=venue_id,
            occurs_at_gte=occurs_at_gte,
            occurs_at_lte=occurs_at_lte,
            only_with_available_tickets=only_with_available_tickets,
            order_by="events.popularity_score DESC",
        )
        return {"count": len(events), "events": events}

    @router.get("/api/performers")
    def performers_search(
        q: str | None = None,
        fuzzy: bool = False,
        category_id: int | None = None,
        category_tree: bool = True,
        only_with_upcoming_events: bool | None = None,
        _=Depends(require_auth),
    ):
        if category_id is not None:
            performers = []
            for page in range(1, 21):
                resp = get_client().list_performers(
                    category_id=category_id,
                    category_tree=category_tree,
                    only_with_upcoming_events=only_with_upcoming_events,
                    order_by="performers.popularity_score DESC",
                    per_page=100,
                    page=page,
                )
                batch = resp.get("performers", [])
                performers.extend(batch)
                if len(performers) >= resp.get("total_entries", 0) or not batch:
                    break
            return {"performers": performers, "total_entries": len(performers)}
        if q:
            return get_client().search_performers(q=q, fuzzy=fuzzy)
        raise HTTPException(400, "Provide q or category_id")

    @router.get("/api/venues")
    def venues_search(
        q: str | None = None,
        fuzzy: bool = False,
        lat: float | None = None,
        lon: float | None = None,
        within: int | None = None,
        postal_code: str | None = None,
        _=Depends(require_auth),
    ):
        if q:
            return get_client().search_venues(q=q, fuzzy=fuzzy)
        if lat is not None and lon is not None:
            return get_client().list_venues(lat=lat, lon=lon, within=within or 15)
        if postal_code:
            return get_client().list_venues(postal_code=postal_code, within=within or 15)
        raise HTTPException(400, "Provide q, or (lat+lon), or postal_code.")

    @router.get("/api/events/{event_id}")
    def event_detail(event_id: int, include_ancillary: bool = False, _=Depends(require_auth)):
        """Event detail. By default filters out parking/suite/hospitality
        ticket_groups so the per-event view shows only real seats.
        Pass include_ancillary=true to see everything."""
        event = get_client().get_event(event_id)
        try:
            stats = get_client().get_event_stats(event_id)
        except RuntimeError:
            stats = None
        try:
            stats_event_only = get_client().get_event_stats(event_id, inventory_type="event")
        except RuntimeError:
            stats_event_only = None
        listings = get_client().get_listings(event_id, order_by="retail_price ASC")
        raw_groups = listings.get("ticket_groups", []) or []
        if include_ancillary:
            groups = raw_groups
        else:
            groups = [tg for tg in raw_groups if is_event_seat(tg)]
        return {
            "event": event,
            "stats": stats,
            "stats_event_only": stats_event_only,
            "ticket_groups": groups,
            "ticket_groups_total": len(raw_groups),
            "ticket_groups_filtered_parking": len(raw_groups) - len(groups),
        }


    @router.get("/api/events/{event_id}/series")
    def event_series(
        event_id: int,
        days: int = 30,
        _=Depends(require_auth),
    ):
        """Return time-series metrics for one event from event_metrics.

        Query params:
            days: lookback window in days (default 30, clamped to [1, 365])

        Response shape:
            {
              "event_id": 12345,
              "days": 30,
              "series": [
                {
                  "t": "2026-04-23T14:00:00+00:00",
                  "tickets_count": 1990, "groups_count": 626, "sections_count": 48,
                  "retail_min": 39.0, "retail_p25": 180.0, "retail_median": 420.0,
                  "retail_mean": 945.12, "retail_p75": 1200.0, "retail_p90": 2500.0,
                  "retail_max": 9245.0,
                  "wholesale_median": 315.0, "wholesale_mean": 720.0,
                  "getin_price": 78.0, "top5_concentration": 0.62, "bid_ask_proxy": 0.22
                },
                ...
              ]
            }
        """
        days = max(1, min(int(days), 365))
        db = get_require_sb()()
        since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        resp = (
            db.table("event_metrics")
            .select(
                "captured_at,"
                "tickets_count,groups_count,sections_count,"
                "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,"
                "wholesale_median,wholesale_mean,"
                "getin_price,top5_concentration"
            )
            .eq("event_id", event_id)
            .gte("captured_at", since)
            .order("captured_at")
            .execute()
        )
        series = [
            {"t": r["captured_at"], **{k: v for k, v in r.items() if k != "captured_at"}}
            for r in (resp.data or [])
        ]
        return {"event_id": event_id, "days": days, "series": series}


    @router.get("/api/events/{event_id}/sections/series")
    def event_section_series(
        event_id: int,
        days: int = 30,
        _=Depends(require_auth),
    ):
        """Section-level time series for one event. One series per section.

        Response shape:
            {
              "event_id": 12345,
              "days": 30,
              "sections": [
                {
                  "section": "100",
                  "is_ancillary": false,
                  "points": [
                    {
                      "t": "2026-04-23T14:00:00+00:00",
                      "tickets_count": 42, "groups_count": 11,
                      "retail_min": 420.0, "retail_median": 520.0,
                      "retail_mean": 535.0, "retail_max": 820.0
                    },
                    ...
                  ]
                },
                ...
              ]
            }
        """
        days = max(1, min(int(days), 365))
        db = get_require_sb()()
        since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        resp = (
            db.table("section_metrics")
            .select(
                "captured_at,section,is_ancillary,"
                "tickets_count,groups_count,"
                "retail_min,retail_median,retail_mean,retail_max"
            )
            .eq("event_id", event_id)
            .gte("captured_at", since)
            .order("captured_at")
            .execute()
        )

        by_section: dict = {}
        for r in (resp.data or []):
            key = r["section"]
            if key not in by_section:
                by_section[key] = {
                    "section": key,
                    "is_ancillary": bool(r.get("is_ancillary", False)),
                    "points": [],
                }
            by_section[key]["points"].append({
                "t": r["captured_at"],
                "tickets_count": r.get("tickets_count"),
                "groups_count": r.get("groups_count"),
                "retail_min": r.get("retail_min"),
                "retail_median": r.get("retail_median"),
                "retail_mean": r.get("retail_mean"),
                "retail_max": r.get("retail_max"),
            })

        # Non-ancillary sections first, then alphabetical
        sections = sorted(
            by_section.values(),
            key=lambda s: (s["is_ancillary"], s["section"]),
        )
        return {"event_id": event_id, "days": days, "sections": sections}

    return router
