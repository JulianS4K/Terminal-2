"""D1 storefront event-detail routes — /api/store/events/{id} (+ /zones).

server.py decomposition slice (BR-CODE-1): the two event-detail routes, lifted
behind unchanged paths now that their keystone composer
(`resolve_event_with_filters`) lives in `core/store_events.py`.

Getters resolve the live server symbols at request time so the monkeypatch tests
bind: `get_resolve_event` → `app._resolve_event_with_filters` (the wrapper that
itself injects sb/client/etc.), `get_require_sb` → `app.require_sb`,
`get_prefer_internal_zones` → `app.STOREFRONT_PREFER_INTERNAL_ZONES`.
`is_bowl_pattern_name` is a pure core helper (never patched).
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Callable

from fastapi import APIRouter

from core.helpers import is_bowl_pattern_name, or_ilike_clause

_log = logging.getLogger("app")

# A performer+venue pair with more zones than this almost certainly has a
# hand-curated granular layer on top of the consumer bowl seed (NYK@MSG = 26;
# the seeded consumer baseline tops out at ~5–7).
_GRANULAR_LAYER_ZONE_COUNT_THRESHOLD = 8


def build_store_router(
    get_require_sb: Callable[[], Callable],
    get_resolve_event: Callable[[], Callable],
    get_prefer_internal_zones: Callable[[], bool],
    get_trip_plan_payload: Callable[[], Callable],
    get_tour_package_payload: Callable[[], Callable],
    get_multi_tour_payload: Callable[[], Callable],
    get_discover_payload: Callable[[], Callable],
) -> APIRouter:
    router = APIRouter()

    @router.get("/api/store/events/{event_id}")
    def store_event_detail(
        event_id: int,
        section: str | None = None,         # CSV of exact section names
        min_price: float | None = None,
        max_price: float | None = None,
        min_qty: int | None = None,
        zones: str | None = None,           # CSV of curated zone names (case-insensitive)
    ):
        """Event detail + live owned-only ticket groups from TEvo, with optional
        share-link filters applied server-side. Filters are AND-ed; an empty set
        of matches is a valid response (UI shows "no listings match")."""
        return get_resolve_event()(
            event_id,
            {
                "section": section,
                "min_price": min_price,
                "max_price": max_price,
                "min_qty": min_qty,
                "zones": zones,
            },
        )

    @router.get("/api/store/events/{event_id}/zones")
    def store_event_zones(event_id: int):
        """List curated zones with owned-ticket counts so the Share dialog can
        offer zone choices.

        Layer preference (per Julian's 2026-05-11 direction):
          1. If the event's performer+venue has any INTERNAL (granular) zones
             with matching owned tickets, return ONLY those.
          2. Else fall back to CONSUMER (coarse bowl-level) zones.
          3. Else empty (most events outside the seeded set).
        Response includes `layer` so the UI can label the chip group.
        """
        db = get_require_sb()()
        prefer_internal = get_prefer_internal_zones()
        try:
            rows = db.rpc(
                "get_event_zones_rollup",
                {"p_event_id": event_id, "p_owned_only": True},
            ).execute().data or []
        except Exception:
            rows = []
        # Only consider curated zones — fallback/unmapped names from
        # derive_zone_fallback() are noisy and not safe to share by name.
        curated = [r for r in rows if r.get("source") == "curated"]

        # Step 1: count the FULL zone universe for this event's performer+venue.
        # If larger than the consumer-only ceiling, the pair has been
        # hand-curated with granular zones layered on top of the bowl seed.
        pair_zone_count = 0
        try:
            ev_meta = (
                db.table("events").select("primary_performer_id,venue_id")
                .eq("id", event_id).limit(1).execute().data
            ) or []
            if ev_meta:
                perf_id = ev_meta[0].get("primary_performer_id")
                venue_id_x = ev_meta[0].get("venue_id")
                if perf_id and venue_id_x:
                    pair_rows = (
                        db.table("performer_zones").select("id", count="exact")
                        .eq("performer_id", perf_id).eq("venue_id", venue_id_x)
                        .execute()
                    )
                    pair_zone_count = pair_rows.count or len(pair_rows.data or [])
        except Exception:
            pair_zone_count = 0

        has_granular_layer = pair_zone_count > _GRANULAR_LAYER_ZONE_COUNT_THRESHOLD

        # Step 2: pick the layer to surface. Off by default — granular taxonomy
        # has coverage gaps; once A1 closes them, flip
        # STOREFRONT_PREFER_INTERNAL_ZONES=true.
        if has_granular_layer and prefer_internal:
            chosen = [r for r in curated if not is_bowl_pattern_name(r.get("zone"))]
            layer = "internal" if chosen else "none"
        else:
            chosen = curated
            layer = "consumer" if chosen else "none"

        zones = [
            {
                "name": r.get("zone"),
                "tickets": r.get("tickets") or 0,
                "min_retail": r.get("min_retail"),
                "max_retail": r.get("max_retail"),
            }
            for r in chosen
        ]
        return {
            "event_id": event_id,
            "zones": zones,
            "layer": layer,
            "pair_zone_count": pair_zone_count,  # debug: # of zones for performer+venue
            "has_granular_available": has_granular_layer,  # UI 'switch to expert view' toggle
            "prefer_internal_enabled": prefer_internal,
        }

    @router.get("/api/store/concierge")
    def store_concierge(city: str = "NYC", days: int = 60, limit: int = 18):
        """Concierge rail — upcoming owned events where we hold PREMIUM top-band
        seats (>= $500), EVO/TEvo inventory only (D3, 2026-06-16). Backed by the
        `concierge_events` rollup; ordered most-premium first. `from_price` is the
        entry into each event's premium tier. NYC-scoped like the movers rail.
        """
        db = get_require_sb()()
        today_iso = datetime.now(timezone.utc).date().isoformat()
        horizon_iso = (datetime.now(timezone.utc) + timedelta(days=max(1, min(int(days), 120)))).date().isoformat()
        venue_patterns = ("%New York%", "%Brooklyn%", "%Bronx%", "%Queens%",
                          "%Flushing%", "%Elmont%", "%, NY%", "%Newark%", "%East Rutherford%")
        try:
            q = (db.table("concierge_events")
                   .select("event_id,name,venue_name,venue_location,occurs_at_local,"
                           "from_price,prem_max_price,prem_tickets,primary_performer_name")
                   .gte("occurs_date", today_iso)
                   .lte("occurs_date", horizon_iso))
            q = q.or_(",".join(or_ilike_clause("venue_location", p) for p in venue_patterns))
            rows = q.order("prem_max_price", desc=True).limit(max(1, min(int(limit), 40))).execute().data or []
        except Exception as e:
            _log.warning(f"store_concierge query failed: {e}")
            return {"count": 0, "events": []}
        # Map event_id -> id so the card links to /store/event/{id}.
        events = [{**r, "id": r.pop("event_id")} for r in rows]
        return {"count": len(events), "events": events}

    # --- Trip-planner delegates (thin; the payload builders + the optimizer are
    # shared with the D0 broker routes and stay in server.py, resolved via
    # getters so the test stubs bind). ---

    @router.get("/api/store/performers/{performer_id}/trip-plan")
    def store_performer_trip_plan(
        performer_id: int,
        home_lat: float,
        home_lon: float,
        budget_km: float = 6000.0,
        home_name: str = "Home",
        days: int = 365,
        max_events: int | None = None,
        budget_usd: float | None = None,
        qty: int = 1,
    ):
        """D1 store: 'plan a trip around <performer>'. Consumer-facing; shares the
        optimizer with the D0 broker route via `trip_planner`."""
        return get_trip_plan_payload()(performer_id, home_lat, home_lon, budget_km,
                                       home_name, days, max_events, budget_usd, qty)

    @router.get("/api/store/performers/{performer_id}/tour-package")
    def store_performer_tour_package(
        performer_id: int,
        qty: int = 2,
        budget_usd: float | None = None,
        max_events: int | None = None,
        days: int = 365,
        start: str | None = None,
        end: str | None = None,
        side: str = "auto",
        # Location optional — the storefront flow is budget-first. Omit
        # home_lat/home_lon to plan on ticket spend alone.
        home_lat: float | None = None,
        home_lon: float | None = None,
        budget_km: float = 8000.0,
        home_name: str = "Home",
        clear_at: float = 0.15,
        away_margin: float = 0.18,
        section_like: str | None = None,
        prefer_owned: bool = False,
    ):
        """D1 store: retail 'follow the tour' agent. Budget-first; shares the
        optimizer with the D0 route via `trip_planner`."""
        return get_tour_package_payload()(performer_id, home_lat, home_lon, qty, budget_km,
                                          home_name, days, budget_usd, side, clear_at,
                                          away_margin, section_like, prefer_owned,
                                          max_events=max_events, start_date=start, end_date=end)

    @router.get("/api/store/tours/multi")
    def store_multi_tour(
        performer_ids: str,
        home_lat: float,
        home_lon: float,
        qty: int = 3,
        budget_km: float = 10000.0,
        home_name: str = "Home",
        days: int = 365,
        budget_usd: float | None = None,
        side: str = "auto",
        clear_at: float = 0.15,
        away_margin: float = 0.18,
        section_like: str | None = None,
        prefer_owned: bool = False,
    ):
        """D1 store 'plan my summer' — one routed+priced package across several
        performers (comma-separated `performer_ids`, up to 8)."""
        return get_multi_tour_payload()(performer_ids, home_lat, home_lon, qty, budget_km,
                                        home_name, days, budget_usd, side, clear_at,
                                        away_margin, section_like, prefer_owned)

    @router.get("/api/store/tours/near")
    def store_tours_near(
        home_lat: float,
        home_lon: float,
        within_mi: float = 250.0,
        days: int = 120,
        min_shows: int = 2,
        concerts_only: bool = False,
    ):
        """D1 store reverse discovery — performers/teams playing >= min_shows
        within `within_mi` of home in the window (teams surface by AWAY games)."""
        return get_discover_payload()(home_lat, home_lon, within_mi, days, min_shows,
                                      concerts_only, team_side="away")

    return router
