"""AXS box-office read routes — event / sections / listings / series.

Slice 8 of the app.py decomposition (BR-CODE-1). All read-only DB reads of the
axs_* snapshot tables + v_axs_listings + the price-series RPC (no AXS API
calls). Factory takes a live require_sb getter + require_auth (owned by app.py);
behavior identical to the prior inline app.py routes.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Callable

from fastapi import APIRouter, Depends


def build_axs_router(get_require_sb: Callable[[], Callable], require_auth: Callable) -> APIRouter:
    router = APIRouter()

    @router.get("/api/axs/events")
    def axs_events(active: bool = True, limit: int = 500, _=Depends(require_auth)):
        """All AXS events in the tracked registry (axs_events) enriched with each
        event's latest snapshot summary (event/venue name, get-in, price band,
        listing/section counts, primary/resale seats). `active=false` includes
        retired rows. Service-role read (axs_* tables are RLS service-role-only),
        so this is the only path the terminal's user-JWT client has to the set."""
        limit = max(1, min(int(limit), 2000))
        db = get_require_sb()()
        q = (
            db.table("axs_events")
            .select("axs_event_id,event_url,tevo_event_id,tevo_venue_id,active,"
                    "last_pulled_at,last_snapshot_id")
        )
        if active:
            q = q.eq("active", True)
        evs = (q.order("last_pulled_at", desc=True).limit(limit).execute()).data or []

        snap_ids = [e["last_snapshot_id"] for e in evs if e.get("last_snapshot_id")]
        snaps: dict = {}
        if snap_ids:
            rows = (
                db.table("axs_event_snapshots")
                .select("id,captured_at,event_name,venue_name,occurs_at_local,currency,"
                        "price_min,price_max,getin,listings_count,sections_count,"
                        "offers_count,seats_primary,seats_resale,onsale_now")
                .in_("id", snap_ids).execute()
            ).data or []
            snaps = {r["id"]: r for r in rows}

        # Owned-inventory peg: which mapped events do WE hold tickets for. Batch
        # the canonical latest_event_metrics view (keyed on tevo event_id, one
        # latest row per event) over the mapped ids — owned_tickets_count is the
        # broker-pool truth (is_owned/brokerage 1768 rolled up by the collector).
        tevo_ids = [e["tevo_event_id"] for e in evs if e.get("tevo_event_id")]
        owned: dict = {}
        if tevo_ids:
            mrows = (
                db.table("latest_event_metrics")
                .select("event_id,owned_tickets_count,owned_groups_count,owned_share")
                .in_("event_id", tevo_ids).execute()
            ).data or []
            owned = {r["event_id"]: r for r in mrows}

        out = []
        for e in evs:
            s = snaps.get(e.get("last_snapshot_id")) or {}
            m = owned.get(e.get("tevo_event_id")) or {}
            owned_tix = m.get("owned_tickets_count")
            out.append({
                "axs_event_id": e.get("axs_event_id"),
                "event_url": e.get("event_url"),
                "tevo_event_id": e.get("tevo_event_id"),
                "tevo_venue_id": e.get("tevo_venue_id"),
                "active": e.get("active"),
                "linked": e.get("tevo_event_id") is not None,
                "we_own": bool(owned_tix and owned_tix > 0),
                "owned_tickets": owned_tix,
                "owned_groups": m.get("owned_groups_count"),
                "owned_share": m.get("owned_share"),
                "last_pulled_at": e.get("last_pulled_at"),
                "captured_at": s.get("captured_at"),
                "event_name": s.get("event_name"),
                "venue_name": s.get("venue_name"),
                "occurs_at_local": s.get("occurs_at_local"),
                "currency": s.get("currency"),
                "getin": s.get("getin"),
                "price_min": s.get("price_min"),
                "price_max": s.get("price_max"),
                "listings_count": s.get("listings_count"),
                "sections_count": s.get("sections_count"),
                "offers_count": s.get("offers_count"),
                "seats_primary": s.get("seats_primary"),
                "seats_resale": s.get("seats_resale"),
                "onsale_now": s.get("onsale_now"),
            })
        return {
            "count": len(out),
            "linked": sum(1 for e in out if e["linked"]),
            "pulled": sum(1 for e in out if e["captured_at"]),
            "owned": sum(1 for e in out if e["we_own"]),
            "events": out,
        }

    @router.get("/api/axs/event/{event_id}")
    def axs_event(event_id: int, _=Depends(require_auth)):
        db = get_require_sb()()
        snap = (
            db.table("axs_event_snapshots")
            .select("id,captured_at,axs_event_id,event_url,event_name,venue_name,"
                    "occurs_at_local,currency,price_min,price_max,getin,listings_count,"
                    "sections_count,offers_count,seats_primary,seats_resale,onsale_now,"
                    "in_axs_list,response_s")
            .eq("tevo_event_id", event_id)
            .order("captured_at", desc=True).limit(1).execute()
        ).data or []
        if not snap:
            return {"tevo_event_id": event_id, "linked": False, "latest": None,
                    "captured_at": None}
        return {"tevo_event_id": event_id, "linked": True, "latest": snap[0],
                "captured_at": snap[0]["captured_at"]}

    @router.get("/api/axs/event/{event_id}/sections")
    def axs_event_sections(event_id: int, limit: int = 1000, _=Depends(require_auth)):
        limit = max(1, min(int(limit), 5000))
        db = get_require_sb()()
        snap = (
            db.table("axs_event_snapshots")
            .select("id,captured_at,event_name,venue_name,currency,price_min,price_max,getin")
            .eq("tevo_event_id", event_id)
            .order("captured_at", desc=True).limit(1).execute()
        ).data or []
        if not snap:
            return {"event_id": event_id, "count": 0, "sections": [], "summary": None,
                    "captured_at": None}
        s0 = snap[0]
        rows = (
            db.table("axs_section_snapshots")
            .select("section_label,neighborhood,is_ga,sold_out,avail_qty,price_min,"
                    "price_max,seat_types,has_resale,connection_fee")
            .eq("snapshot_id", s0["id"])
            .order("price_min", desc=False).limit(limit).execute()
        ).data or []
        prices = sorted(r["price_min"] for r in rows if r.get("price_min") is not None)
        return {
            "event_id": event_id,
            "count": len(rows),
            "captured_at": s0["captured_at"],
            "event_name": s0.get("event_name"),
            "venue_name": s0.get("venue_name"),
            "currency": s0.get("currency"),
            "sections": rows,
            "summary": {
                "total_sections": len(rows),
                "available_qty": sum(int(r.get("avail_qty") or 0) for r in rows),
                "resale_sections": sum(1 for r in rows if r.get("has_resale")),
                "sold_out_sections": sum(1 for r in rows if r.get("sold_out")),
                "min_price": prices[0] if prices else s0.get("getin"),
                "max_price": prices[-1] if prices else s0.get("price_max"),
            },
        }

    @router.get("/api/axs/event/{event_id}/listings")
    def axs_event_listings(event_id: int, limit: int = 3000, _=Depends(require_auth)):
        limit = max(1, min(int(limit), 10000))
        db = get_require_sb()()
        snap = (
            db.table("axs_event_snapshots").select("id,captured_at,event_name,venue_name")
            .eq("tevo_event_id", event_id).order("captured_at", desc=True).limit(1).execute()
        ).data or []
        if not snap:
            return {"event_id": event_id, "count": 0, "listings": [], "summary": None,
                    "captured_at": None}
        s0 = snap[0]
        rows = (
            db.table("v_axs_listings")
            .select("section,row,quantity,retail_price,type,format,wheelchair,seat_numbers,"
                    "src,neighborhood,is_ga,seat_from,seat_to")
            .eq("snapshot_id", s0["id"])
            .order("section").order("row").order("seat_from")
            .limit(limit).execute()
        ).data or []
        prices = [r["retail_price"] for r in rows if r.get("retail_price") is not None]
        return {
            "event_id": event_id,
            "captured_at": s0["captured_at"],
            "event_name": s0.get("event_name"),
            "venue_name": s0.get("venue_name"),
            "count": len(rows),
            "listings": rows,
            "summary": {
                "blocks": len(rows),
                "total_seats": sum(int(r.get("quantity") or 0) for r in rows),
                "min_price": min(prices) if prices else None,
                "max_price": max(prices) if prices else None,
                "biggest_block": max((int(r.get("quantity") or 0) for r in rows), default=0),
                "resale_blocks": sum(1 for r in rows if r.get("src") == "resale"),
            },
        }

    @router.get("/api/axs/event/{event_id}/series")
    def axs_event_series(event_id: int, range: str | None = None, hours: int | None = None,
                         days: int = 30, _=Depends(require_auth)):
        rmap = {"6h": 6, "24h": 24, "1d": 24, "3d": 72, "7d": 168, "30d": 720, "all": None}
        if range is not None:
            range_hours = rmap.get(range.lower(), 720)
        elif hours is not None:
            range_hours = max(6, min(int(hours), 8760))
        else:
            range_hours = max(1, min(int(days), 365)) * 24
        since_iso = ("1970-01-01T00:00:00+00:00" if range_hours is None
                     else (datetime.now(timezone.utc) - timedelta(hours=range_hours)).isoformat())
        db = get_require_sb()()
        try:
            rows = (db.rpc("get_axs_event_price_series",
                           {"p_event_id": event_id, "p_since": since_iso}).execute()).data or []
        except Exception:
            rows = []
        return {
            "event_id": event_id,
            "prices_axs": [{"t": r["captured_at"], "v": r.get("median_price")} for r in rows],
            "counts_axs": [{"t": r["captured_at"], "v": r.get("listings_count")} for r in rows],
        }

    return router
