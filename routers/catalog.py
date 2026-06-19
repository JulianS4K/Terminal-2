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

from fastapi import APIRouter, Depends


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

    return router
