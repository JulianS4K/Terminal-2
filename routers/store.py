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

from typing import Callable

from fastapi import APIRouter

from core.helpers import is_bowl_pattern_name

# A performer+venue pair with more zones than this almost certainly has a
# hand-curated granular layer on top of the consumer bowl seed (NYK@MSG = 26;
# the seeded consumer baseline tops out at ~5–7).
_GRANULAR_LAYER_ZONE_COUNT_THRESHOLD = 8


def build_store_router(
    get_require_sb: Callable[[], Callable],
    get_resolve_event: Callable[[], Callable],
    get_prefer_internal_zones: Callable[[], bool],
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

    return router
