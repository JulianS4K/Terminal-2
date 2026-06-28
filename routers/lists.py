"""Simple list/read DB routes — watchlist (GET) / runs / snapshots.

Third slice of the app.py decomposition (BR-CODE-1). Read-only Supabase
list endpoints, gated by require_auth.

Factory takes `get_require_sb` (a getter returning the live require_sb
callable) + `require_auth`, both still owned by app.py — so handlers resolve
the current require_sb at request time and the monkeypatch tests
(tests/test_watchlist_runs_snapshots.py patches app.require_sb) keep working.
Behavior identical to the prior inline app.py routes. The /api/watchlist POST +
DELETE (mutating) routes joined here in slice 35 — require_sb + require_auth only.
"""
from __future__ import annotations

from typing import Callable

from fastapi import APIRouter, Body, Depends, HTTPException


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

    # --- watchlist mutations (POST add / DELETE remove). require_sb + require_auth. ---

    @router.post("/api/watchlist")
    def watchlist_add(item: dict = Body(...), _=Depends(require_auth)):
        db = get_require_sb()()
        kind = item.get("kind")
        ext_id = item.get("ext_id")
        label = item.get("label")
        if kind not in ("performer", "venue"):
            raise HTTPException(400, "kind must be performer or venue")
        if not ext_id:
            raise HTTPException(400, "ext_id required")
        try:
            res = db.table("watchlist").insert(
                {"kind": kind, "ext_id": int(ext_id), "label": label or None}
            ).execute()
            return {"ok": True, "item": (res.data or [None])[0]}
        except Exception as e:
            msg = str(e)
            if "duplicate" in msg.lower() or "unique" in msg.lower() or "23505" in msg:
                return {"ok": False, "error": "already in watchlist"}
            raise HTTPException(400, msg)

    @router.delete("/api/watchlist/{item_id}")
    def watchlist_remove(item_id: int, _=Depends(require_auth)):
        db = get_require_sb()()
        db.table("watchlist").delete().eq("id", item_id).execute()
        return {"ok": True}

    return router
