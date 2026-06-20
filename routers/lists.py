"""Simple list/read DB routes — watchlist (GET) / runs / snapshots.

Third slice of the app.py decomposition (BR-CODE-1). Read-only Supabase
list endpoints, gated by require_auth.

Factory takes `get_require_sb` (a getter returning the live require_sb
callable) + `require_auth`, both still owned by app.py — so handlers resolve
the current require_sb at request time and the monkeypatch tests
(tests/test_watchlist_runs_snapshots.py patches app.require_sb) keep working.
Behavior identical to the prior inline app.py routes.

Note: the /api/watchlist POST + DELETE (mutating) routes stay in app.py for
now; only the GET reads move here.
"""
from __future__ import annotations

from typing import Callable

from fastapi import APIRouter, Depends


def build_lists_router(get_require_sb: Callable[[], Callable], require_auth: Callable) -> APIRouter:
    router = APIRouter()

    @router.get("/api/watchlist")
    def watchlist_list(_=Depends(require_auth)):
        db = get_require_sb()()
        data = db.table("watchlist").select("*").order("added_at", desc=True).execute().data
        return {"items": data or []}

    @router.get("/api/runs")
    def runs_list(limit: int = 20, _=Depends(require_auth)):
        db = get_require_sb()()
        data = db.table("runs").select("*").order("id", desc=True).limit(limit).execute().data
        return {"items": data or []}

    @router.get("/api/snapshots/latest")
    def snapshots_latest(_=Depends(require_auth)):
        db = get_require_sb()()
        snaps = db.table("latest_snapshots").select("*").execute().data or []
        if not snaps:
            return {"items": []}
        ids = [s["event_id"] for s in snaps]
        events = db.table("events").select("*").in_("id", ids).execute().data or []
        by_id = {e["id"]: e for e in events}
        items = []
        for s in snaps:
            e = by_id.get(s["event_id"], {})
            items.append({
                **s,
                "event_name": e.get("name"),
                "occurs_at_local": e.get("occurs_at_local"),
                "venue_name": e.get("venue_name"),
                "venue_location": e.get("venue_location"),
                "primary_performer_name": e.get("primary_performer_name"),
            })
        items.sort(key=lambda x: x.get("occurs_at_local") or "")
        return {"items": items}

    @router.get("/api/snapshots/velocity")
    def snapshots_velocity(_=Depends(require_auth)):
        db = get_require_sb()()
        data = db.table("event_velocity").select("*").order("occurs_at_local").execute().data or []
        return {"items": data}

    return router
