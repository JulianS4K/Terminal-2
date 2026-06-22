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

from typing import Callable

from fastapi import APIRouter, Depends, Query


def build_catalog_router(get_client: Callable[[], object], require_auth: Callable) -> APIRouter:
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

    return router
