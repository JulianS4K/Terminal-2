"""Broker terminal routes (D0 surface) — the SIMPLE, helper-free subset.

Slice 11 of the app.py decomposition (BR-CODE-1). Only the trivially-decoupled
broker routes move here for now: /leagues (static), /performer/{id}/assets (one
table read), /event/{id}/espn (server-side edge-fn proxy). The helper-heavy
broker routes (overview / movers / chart-data / zones / …) stay in app.py until
their shared helpers (_bulk_event_context / _compute_movers / _delta / …) are
extracted to core/.

Factory takes getters for the live require_sb + the SUPABASE url/key (so the
espn route's monkeypatch tests keep working) + require_auth + the static
ESPN-league list. requests is the shared module (patched globally by tests).
"""
from __future__ import annotations

from typing import Callable

import requests
from fastapi import APIRouter, Depends, HTTPException


def build_broker_router(
    get_require_sb: Callable[[], Callable],
    require_auth: Callable,
    espn_leagues: list,
    get_supabase_url: Callable[[], str | None],
    get_supabase_anon_key: Callable[[], str | None],
) -> APIRouter:
    router = APIRouter()

    @router.get("/api/broker/leagues")
    def broker_leagues(_=Depends(require_auth)):
        """Static list of ESPN-tracked leagues for the league-browse strip."""
        return {"leagues": espn_leagues}

    @router.get("/api/broker/performer/{performer_id}/assets")
    def broker_performer_assets(performer_id: int, _=Depends(require_auth)):
        """ESPN team logo + colors + URLs for a TEvo performer (performer_metadata).
        Null fields for performers without ESPN mapping."""
        db = get_require_sb()()
        row = (db.table("performer_metadata")
                 .select("performer_id, name, espn_team_id, espn_league, "
                         "color_primary, color_alternate, "
                         "logo_default_url, logo_dark_url, logo_scoreboard_url, logo_4k_primary_url, logo_secondary_url, "
                         "espn_team_url, espn_roster_url, espn_schedule_url, espn_fetched_at")
                 .eq("performer_id", performer_id).limit(1).execute().data or [])
        return row[0] if row else {"performer_id": performer_id, "logo_default_url": None}

    @router.get("/api/broker/event/{event_id}/espn")
    def broker_event_espn(event_id: int, _=Depends(require_auth)):
        """Tab 2: ESPN aggregated data via the espn edge fn (JWT stays server-side)."""
        supabase_url = get_supabase_url()
        supabase_anon_key = get_supabase_anon_key()
        if not (supabase_url and supabase_anon_key):
            raise HTTPException(500, "espn fn not reachable: missing SUPABASE_URL/SUPABASE_ANON_KEY")
        url = f"{supabase_url}/functions/v1/espn/event/{int(event_id)}"
        try:
            r = requests.get(url, headers={"Authorization": f"Bearer {supabase_anon_key}"}, timeout=15)
            return r.json() if r.ok else {"applicable": False, "error": f"espn fn {r.status_code}"}
        except Exception as e:
            return {"applicable": False, "error": str(e)}

    return router
