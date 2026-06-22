"""Misc singleton routes — /api/config + /api/cross-source/event/{id}.

Slice 10 of the app.py decomposition (BR-CODE-1). Two small read-only routes
that didn't belong to a source group. Factory takes live getters (sb /
require_sb) + require_auth + the stable config values, all owned by app.py.
Behavior identical to the prior inline app.py routes.
"""
from __future__ import annotations

from typing import Callable

from fastapi import APIRouter, Depends, HTTPException


def build_misc_router(
    get_sb: Callable[[], object],
    get_require_sb: Callable[[], Callable],
    require_auth: Callable,
    cron_secret: str | None,
    supabase_url: str | None,
    sandbox: bool,
) -> APIRouter:
    router = APIRouter()

    @router.get("/api/config")
    def config_info(user=Depends(require_auth)):
        sb = get_sb()
        return {
            "supabase_configured": sb is not None,
            "collect_available": bool(sb is not None and cron_secret and supabase_url),
            "env": "sandbox" if sandbox else "prod",
            "user_email": (user or {}).get("email"),
        }

    @router.get("/api/cross-source/event/{event_id}")
    def cross_source_event(event_id: int, _=Depends(require_auth)):
        """One-stop view of all 3 external xrefs (ESPN + SeatGeek + SeatData)
        for a TEvo event so the frontend doesn't need 3 separate calls."""
        db = get_require_sb()()
        ev = (db.table("events")
              .select("id,name,occurs_at_local,venue_id,venue_name,primary_performer_id,primary_performer_name,event_type")
              .eq("id", event_id).limit(1).execute()).data or []
        if not ev:
            raise HTTPException(404, f"event {event_id} not found")
        espn = (db.table("event_xref").select("espn_event_id,espn_league,espn_slug,match_method,matched_at")
                .eq("tevo_event_id", event_id).limit(1).execute()).data or []
        sg = (db.table("seatgeek_event_xref").select("sg_event_id,sg_event_name,sg_event_type,sg_event_location,match_method,matched_at,last_listings_at,last_sales_at")
              .eq("tevo_event_id", event_id).limit(1).execute()).data or []
        sd = (db.table("seatdata_event_xref").select("sd_event_id,match_method,matched_at,last_paid_pull_at")
              .eq("tevo_event_id", event_id).limit(1).execute()).data or []
        return {
            "tevo_event": ev[0],
            "espn":     espn[0] if espn else None,
            "seatgeek": sg[0]   if sg   else None,
            "seatdata": sd[0]   if sd   else None,
            "matched_count": sum(1 for x in (espn, sg, sd) if x),
        }

    return router
