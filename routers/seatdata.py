"""SeatData read routes — account / usage / budget / event / event-sales.

Slice 7 of the app.py decomposition (BR-CODE-1); the link/auto-search/sync POSTs
joined in slice 32-sibling (slice 33). Read-only against SeatData (GET search /
salesdata), write only our seatdata_* tables.

Factory takes getters for the live SeatData-client factory + require_sb, plus
require_auth + the cron-or-auth gate — all still owned by server.py — so handlers
resolve current values at request time (monkeypatch tests keep working).
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Callable

from fastapi import APIRouter, Depends, Header, HTTPException, Query


def build_seatdata_router(
    get_seatdata_client: Callable[[], Any],
    get_require_sb: Callable[[], Callable],
    require_auth: Callable,
    # Cron-or-Bearer gate for the pg_cron-driven sync routes (server's
    # `_require_cron_or_auth`). Plain callable — reads AUTH_DISABLED/CRON_SECRET
    # from server state at call time; not monkeypatched by the route tests.
    require_cron_or_auth: Callable = lambda *a, **k: None,
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

    # --- Link + auto-search + sync POSTs (SeatData ingest). Read-only against
    # SeatData (GET search/salesdata), write only our seatdata_* tables. ---

    @router.post("/api/seatdata/event/{event_id}/link")
    def seatdata_link_event(event_id: int, sd_event_id: int = Query(..., description="SeatData event_id"),
                            _=Depends(require_auth)):
        """Manually link a TEvo event to a SeatData event. Free."""
        db = get_require_sb()()
        db.table("seatdata_event_xref").upsert({
            "tevo_event_id": event_id,
            "sd_event_id": sd_event_id,
            "match_method": "manual",
            "match_confidence": 1.0,
        }, on_conflict="tevo_event_id").execute()
        return {"linked": True, "tevo_event_id": event_id, "sd_event_id": sd_event_id}

    @router.post("/api/seatdata/event/{event_id}/auto-search")
    def seatdata_auto_search(
        event_id: int,
        authorization: str | None = Header(None),
        x_cron_secret: str | None = Header(None, alias="X-Cron-Secret"),
    ):
        """Search SeatData by date+venue and link if a high-confidence match is found.
        Free (uses /v1/events/search). Returns the chosen sd_event_id or null.
        Cron-or-auth: pg_cron drives this via pg_net with X-Cron-Secret.
        """
        require_cron_or_auth(authorization, x_cron_secret)
        client = get_seatdata_client()
        if not client:
            raise HTTPException(503, "SEATDATA_API_KEY not set on this Railway env")
        db = get_require_sb()()
        ev = (db.table("events")
              .select("id,name,occurs_at_local,venue_name,venue_location,primary_performer_name")
              .eq("id", event_id).limit(1).execute()).data or []
        if not ev:
            raise HTTPException(404, f"event {event_id} not found")
        e = ev[0]
        perf = (e.get("primary_performer_name") or "").split(",")[0].split()[-1] if e.get("primary_performer_name") else None
        date_prefix = (e.get("occurs_at_local") or "")[:10]  # YYYY-MM-DD
        venue = e.get("venue_name") or ""
        page = client.search_events(event_name=perf or None, event_date=date_prefix or None,
                                    venue_name=venue or None, limit=20)
        candidates = page.get("data") or []
        # Match on exact date + venue
        match = None
        for c in candidates:
            if c.get("event_date") == date_prefix and (c.get("venue_name") or "").lower() == venue.lower():
                match = c; break
        if not match:
            return {"matched": False, "candidates": candidates[:5]}
        sd_event_id = match["event_id"]
        client.link_event(event_id, sd_event_id, match_method="auto_name_date_venue",
                          confidence=0.95, meta={"sd_event_name": match.get("event_name")})
        return {"matched": True, "sd_event_id": sd_event_id, "match": match}

    @router.post("/api/seatdata/event/{event_id}/sync-sales")
    def seatdata_sync_sales(
        event_id: int,
        authorization: str | None = Header(None),
        x_cron_secret: str | None = Header(None, alias="X-Cron-Secret"),
    ):
        """Pull /v0.3/salesdata/get for a linked event and persist new rows.
        PAID: 1 pull per call. Will return 503 if SEATDATA_API_KEY not set,
        402 if budget exhausted. Cron-or-auth: pg_cron drives this via pg_net
        with X-Cron-Secret.
        """
        require_cron_or_auth(authorization, x_cron_secret)
        client = get_seatdata_client()
        if not client:
            raise HTTPException(503, "SEATDATA_API_KEY not set on this Railway env")
        db = get_require_sb()()
        xref = (db.table("seatdata_event_xref").select("sd_event_id")
                .eq("tevo_event_id", event_id).limit(1).execute()).data or []
        if not xref:
            raise HTTPException(404, f"event {event_id} not linked to SeatData; call /auto-search or /link first")
        sd_event_id = int(xref[0]["sd_event_id"])
        try:
            sales = client.salesdata(sd_event_id, tevo_event_id=event_id)
        except Exception as e:
            msg = str(e)
            if "budget exhausted" in msg.lower() or "BudgetExceeded" in type(e).__name__:
                raise HTTPException(402, msg)
            raise HTTPException(502, f"SeatData call failed: {msg}")
        inserted = client.store_sales(event_id, sd_event_id, sales)
        db.table("seatdata_event_xref").update({"last_paid_pull_at": datetime.now(timezone.utc).isoformat()}) \
          .eq("tevo_event_id", event_id).execute()
        return {"event_id": event_id, "sd_event_id": sd_event_id,
                "rows_received": len(sales), "rows_inserted": inserted}

    return router
