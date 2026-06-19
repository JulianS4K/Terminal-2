"""SeatData read routes — account / usage / budget / event / event-sales.

Slice 7 of the app.py decomposition (BR-CODE-1). Read-only diagnostics + DB
reads (no SeatData mutations — the link/auto-search/sync POSTs stay in app.py).

Factory takes getters for the live SeatData-client factory + require_sb, plus
require_auth — all still owned by app.py — so handlers resolve current values at
request time (monkeypatch tests keep working). Behavior identical to the prior
inline app.py routes.
"""
from __future__ import annotations

from typing import Callable

from fastapi import APIRouter, Depends, HTTPException


def build_seatdata_router(
    get_seatdata_client: Callable[[], object],
    get_require_sb: Callable[[], Callable],
    require_auth: Callable,
) -> APIRouter:
    router = APIRouter()

    @router.get("/api/seatdata/account")
    def seatdata_account(_=Depends(require_auth)):
        client = get_seatdata_client()
        if not client:
            raise HTTPException(503, "SEATDATA_API_KEY not set on this Railway env")
        return client.account()

    @router.get("/api/seatdata/usage")
    def seatdata_usage(_=Depends(require_auth)):
        client = get_seatdata_client()
        if not client:
            raise HTTPException(503, "SEATDATA_API_KEY not set on this Railway env")
        return client.usage()

    @router.get("/api/seatdata/budget")
    def seatdata_budget(_=Depends(require_auth)):
        db = get_require_sb()()
        res = db.rpc("seatdata_check_budget", {"p_endpoint": "paid"}).execute()
        return res.data or {}

    @router.get("/api/seatdata/event/{event_id}")
    def seatdata_event(event_id: int, _=Depends(require_auth)):
        db = get_require_sb()()
        xref = (
            db.table("seatdata_event_xref").select("*")
            .eq("tevo_event_id", event_id).limit(1).execute()
        ).data or []
        if not xref:
            return {"tevo_event_id": event_id, "linked": False, "xref": None,
                    "sales_count": 0, "stats_count": 0, "latest_stats": None}
        sales_n = (
            db.table("seatdata_sales_snapshots").select("id", count="exact")
            .eq("tevo_event_id", event_id).limit(1).execute()
        )
        stats_n = (
            db.table("seatdata_event_stats").select("id", count="exact")
            .eq("tevo_event_id", event_id).limit(1).execute()
        )
        latest = (
            db.table("seatdata_event_latest").select("*")
            .eq("tevo_event_id", event_id).limit(1).execute()
        ).data or []
        return {
            "tevo_event_id": event_id,
            "linked": True,
            "xref": xref[0],
            "sales_count": getattr(sales_n, "count", None) or 0,
            "stats_count": getattr(stats_n, "count", None) or 0,
            "latest_stats": latest[0] if latest else None,
        }

    @router.get("/api/seatdata/event/{event_id}/sales")
    def seatdata_event_sales(event_id: int, limit: int = 500, _=Depends(require_auth)):
        limit = max(1, min(int(limit), 5000))
        db = get_require_sb()()
        rows = (
            db.table("seatdata_sales_snapshots")
            .select("sale_timestamp,quantity,price,zone,section,row")
            .eq("tevo_event_id", event_id)
            .order("sale_timestamp", desc=True)
            .limit(limit).execute()
        ).data or []
        if not rows:
            return {"event_id": event_id, "count": 0, "sales": [],
                    "summary": {"avg": None, "median": None, "min": None, "max": None,
                                "tickets_total": 0, "zones": [], "first_sale": None, "last_sale": None}}
        prices = sorted(r["price"] for r in rows if r.get("price") is not None)
        n = len(prices)
        median = prices[n // 2] if n % 2 == 1 else (prices[n // 2 - 1] + prices[n // 2]) / 2 if n else None
        return {
            "event_id": event_id,
            "count": len(rows),
            "sales": rows,
            "summary": {
                "avg":    round(sum(prices) / n, 2) if n else None,
                "median": round(median, 2) if median is not None else None,
                "min":    min(prices) if prices else None,
                "max":    max(prices) if prices else None,
                "tickets_total": sum(max(int(r.get("quantity") or 1), 1) for r in rows),
                "zones":  sorted({r.get("zone") for r in rows if r.get("zone")}),
                "first_sale": rows[-1]["sale_timestamp"],
                "last_sale":  rows[0]["sale_timestamp"],
            },
        }

    return router
