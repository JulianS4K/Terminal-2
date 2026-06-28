"""Storefront test-harness HTML pages (non-prod gated).

server.py decomposition (BR-CODE-1). The `/store/test/*` multi-page wiring
harness — thin FileResponse servers, each gated behind a non-prod check so the
debug-exposing pages (source-mode dropdown, candidate counts, inventory_source
pill) never render to anonymous prod users. The factory takes the static dir +
a getter for the test-patched `_is_production` server symbol so the gate
resolves at request time (route tests monkeypatch app._is_production).
"""
from __future__ import annotations

import os
from typing import Callable

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse


def build_store_test_router(
    static_dir: str,
    *,
    get_is_production: Callable[[], bool],
) -> APIRouter:
    router = APIRouter()
    test_dir = os.path.join(static_dir, "store", "test")

    def _require_non_prod():
        """Test-harness gate: 404 in production. Test pages expose debug info
        (source-mode dropdown, hybrid candidate counts, inventory_source pill)
        that we don't want anonymous prod users to see. Per #57 A1 review:
        'Either @require_auth or gate behind a non-prod env check' — taking
        the non-prod gate so the test pages remain useful in staging without
        a Bearer-token auth handshake on HTML page loads."""
        if get_is_production():
            raise HTTPException(404, "not found")

    @router.get("/store/test")
    def store_test_index_page(_=Depends(_require_non_prod)):
        """Multi-page wiring test harness — index. Sidebar navigates to one
        page per evo-doc workflow (search, performer, venue, event landing)
        plus storefront-specific share links. Useful for verifying the store
        works against real data before merging."""
        return FileResponse(os.path.join(test_dir, "index.html"))

    @router.get("/store/test/search")
    def store_test_search_page(_=Depends(_require_non_prod)):
        return FileResponse(os.path.join(test_dir, "search.html"))

    @router.get("/store/test/performer")
    def store_test_performer_page(_=Depends(_require_non_prod)):
        return FileResponse(os.path.join(test_dir, "performer.html"))

    @router.get("/store/test/venue")
    def store_test_venue_page(_=Depends(_require_non_prod)):
        return FileResponse(os.path.join(test_dir, "venue.html"))

    @router.get("/store/test/event")
    def store_test_event_page(_=Depends(_require_non_prod)):
        return FileResponse(os.path.join(test_dir, "event.html"))

    @router.get("/store/test/share")
    def store_test_share_page(_=Depends(_require_non_prod)):
        return FileResponse(os.path.join(test_dir, "share.html"))

    @router.get("/store/test/media_test")
    def store_test_media_test_page(_=Depends(_require_non_prod)):
        # C1-authored sandbox under 2026-05-13 operator routing. Validates that
        # primary_performer_logo / primary_performer_color (already in the
        # /api/store/events payload) actually render through the test harness.
        return FileResponse(os.path.join(test_dir, "media_test.html"))

    @router.get("/store/test/trip")
    def store_test_trip_page(_=Depends(_require_non_prod)):
        """Sandbox for the per-performer trip planner (/api/store/performers/{id}/trip-plan).
        Pick a performer + home + travel budget → optimal multi-city itinerary vs sort-by-date."""
        return FileResponse(os.path.join(test_dir, "trip.html"))

    @router.get("/store/test/tour")
    def store_test_tour_page(_=Depends(_require_non_prod)):
        """Sandbox for the retail 'tour with the artist' agent
        (/api/store/performers/{id}/tour-package). Dual-mode priced multi-city package."""
        return FileResponse(os.path.join(test_dir, "tour.html"))

    return router
