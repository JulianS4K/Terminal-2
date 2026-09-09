"""Paciolan / eVenue routes — browser-extension ingest + read endpoints.

Collection is browser-extension-sourced (paciolan_extension/): the operator's
real Chrome renders `<tenant>.evenue.net/event/...`, the content script reads
the rendered seat-map DOM and POSTs a normalized capture here. This env cannot
reach evenue.net itself (egress policy + eVenue bot-block), and RULE 2 forbids
any write to a Paciolan host anyway — so there is no server-side pull.

Ingest is gated by a shared **X-Ingest-Secret** header (PACIOLAN_INGEST_SECRET
env), never the Supabase service_role key (CLAUDE.md §1 hard rule 7 — don't rely
on platform verify_jwt alone). The route validates the secret, then calls the
SECDEF `paciolan_ingest(jsonb)` RPC via the service-role db to insert the
capture. Read endpoints serve the marketplace-standard listing view
(v_paciolan_listings) + the section availability summary, gated by require_auth
like the AXS routes (the paciolan_* tables are service-role-only).
"""
from __future__ import annotations

import hmac
import os
from typing import Any, Callable

from fastapi import APIRouter, Depends, Header, HTTPException


def build_paciolan_router(get_require_sb: Callable[[], Callable],
                          require_auth: Callable) -> APIRouter:
    router = APIRouter()

    @router.post("/api/paciolan/ingest")
    def paciolan_ingest(
        payload: dict[str, Any],
        x_ingest_secret: str | None = Header(None, alias="X-Ingest-Secret"),
    ):
        """Ingest one eVenue seat-map capture from the browser extension.

        Body: {platform, tenant, event_code, source_url, event_name,
        venue_name, sections:[{level,section_label,pct_available,disabled}],
        seats:[{data_seat_key,level,section_label,row_label,seat_number,
        seat_no,price,seat_type,is_ga,available}]}. Returns the snapshot_id +
        row counts. Shared-secret gated (never service_role)."""
        expected = os.environ.get("PACIOLAN_INGEST_SECRET")
        if not expected:
            # Fail closed: no configured secret means ingest is disabled, not open.
            raise HTTPException(503, "Paciolan ingest not configured")
        if not x_ingest_secret or not hmac.compare_digest(x_ingest_secret, expected):
            raise HTTPException(401, "bad or missing X-Ingest-Secret")
        if not payload.get("seats") and not payload.get("sections"):
            raise HTTPException(422, "payload must include 'seats' and/or 'sections'")

        db = get_require_sb()()
        res = db.rpc("paciolan_ingest", {"p_payload": payload}).execute()
        snap_id = getattr(res, "data", None)
        return {
            "ok": True,
            "snapshot_id": snap_id,
            "sections": len(payload.get("sections") or []),
            "seats": len(payload.get("seats") or []),
            "available_seats": sum(1 for s in (payload.get("seats") or [])
                                   if s.get("available")),
        }

    @router.get("/api/paciolan/events")
    def paciolan_events(active: bool = False, limit: int = 1000,
                        _=Depends(require_auth)):
        """URL layer for the PACIOLAN tab: every captured (tenant,event_code)
        with its latest snapshot, face get-in/band + live availability, AQ
        mapping, and pull-loop health (v_paciolan_events). `active=true` narrows
        to events the autonomous driver is still pulling. Service-role read
        (paciolan_* tables are RLS-locked, like the AXS events route)."""
        limit = max(1, min(int(limit), 5000))
        db = get_require_sb()()
        q = db.table("v_paciolan_events").select("*")
        if active:
            q = q.eq("target_active", True)
        rows = (q.order("occurs_at").limit(limit).execute()).data or []
        return {
            "count": len(rows),
            "mapped": sum(1 for r in rows if r.get("map_tevo_event_id")),
            "pulling": sum(1 for r in rows if r.get("target_active")),
            "stale": sum(1 for r in rows
                         if r.get("last_status") in ("error", "expired")),
            "events": rows,
        }

    @router.get("/api/paciolan/health")
    def paciolan_health(_=Depends(require_auth)):
        """Health screen for the PACIOLAN tab: single-row rollup of the
        autonomous pull loop — active targets, live queue depth, 24h outcome mix
        (ok/empty/error/expired), and freshness (v_paciolan_pull_health)."""
        db = get_require_sb()()
        rows = (db.table("v_paciolan_pull_health").select("*")
                .limit(1).execute()).data or []
        return rows[0] if rows else {}

    @router.get("/api/paciolan/drivers")
    def paciolan_drivers(_=Depends(require_auth)):
        """Per-Chrome-instance extraction + issues (v_paciolan_drivers): each
        driver's label, online state, 24h pull counts (ok/empty/error/expired),
        and last status/error — so you can see which instance is extracting and
        which is erroring. Service-role read (paciolan_* tables are RLS-locked)."""
        db = get_require_sb()()
        rows = (db.table("v_paciolan_drivers").select("*")
                .order("last_seen", desc=True).limit(500).execute()).data or []
        return {
            "count": len(rows),
            "online": sum(1 for r in rows if r.get("online")),
            "erroring": sum(1 for r in rows if (r.get("error_24h") or 0) > 0),
            "drivers": rows,
        }

    @router.get("/api/paciolan/snapshot/{snapshot_id}/listings")
    def paciolan_listings(snapshot_id: int, limit: int = 5000,
                          _=Depends(require_auth)):
        """Consecutive-seat "N together" blocks for a capture, in the
        marketplace listing standard (level/section/row/qty/price/seat range).
        Ordered section→row→seat_from. Missing seats already collapsed into the
        qty breaks by v_paciolan_listings."""
        limit = max(1, min(int(limit), 20000))
        db = get_require_sb()()
        rows = (
            db.table("v_paciolan_listings")
            .select("tenant,level,section,row,quantity,retail_price,type,"
                    "wheelchair,is_ga,seat_from,seat_to,seat_numbers")
            .eq("snapshot_id", snapshot_id)
            .order("level").order("section").order("row").order("seat_from")
            .limit(limit).execute()
        ).data or []
        prices = [r["retail_price"] for r in rows if r.get("retail_price") is not None]
        return {
            "snapshot_id": snapshot_id,
            "count": len(rows),
            "listings": rows,
            "summary": {
                "blocks": len(rows),
                "total_seats": sum(int(r.get("quantity") or 0) for r in rows),
                "biggest_block": max((int(r.get("quantity") or 0) for r in rows),
                                     default=0),
                "min_price": min(prices) if prices else None,
                "max_price": max(prices) if prices else None,
                "premium_blocks": sum(1 for r in rows if r.get("type") == "premium"),
            },
        }

    @router.get("/api/paciolan/snapshot/{snapshot_id}/sections")
    def paciolan_sections(snapshot_id: int, _=Depends(require_auth)):
        """Per-section availability % (top-level map, no seat expand needed)."""
        db = get_require_sb()()
        rows = (
            db.table("paciolan_section_snapshots")
            .select("level,section_label,pct_available,disabled")
            .eq("snapshot_id", snapshot_id)
            .order("level").order("section_label")
            .limit(2000).execute()
        ).data or []
        return {"snapshot_id": snapshot_id, "count": len(rows), "sections": rows}

    return router
