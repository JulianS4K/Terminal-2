"""SQL-only store event helpers — extracted from server.py (BR-CODE-1 core/ pass).

These synthesize the TEvo /v9 response shapes from our local tables so the
storefront renders in STOREFRONT_SQL_ONLY mode without a live TEvo call. They
are leaf helpers — their only external dependency is the Supabase client,
passed in as the `require_sb` callable so callers (and their monkeypatch tests)
bind the live accessor at call time. One-directional: core never imports server.

This is the first step of moving the store block's shared helpers into core/ so
the `/api/store/*` routes can eventually follow.
"""
from __future__ import annotations

from typing import Callable

from fastapi import HTTPException


def fetch_event_from_db(require_sb: Callable, event_id: int) -> dict:
    """SQL-only mode: synthesize the TEvo /v9/events/{id} response shape from our
    local `events` table so the storefront can render without a live TEvo call.
    Configuration (seating chart) is TEvo-only data we don't mirror, so it comes
    back empty — UI hides the image."""
    db = require_sb()
    row = (
        db.table("events")
        .select("id,name,occurs_at_local,state,venue_id,venue_name,venue_location,"
                "primary_performer_id,primary_performer_name,performer_ids")
        .eq("id", event_id)
        .limit(1)
        .execute().data
    )
    if not row:
        raise HTTPException(404, f"event {event_id} not found in local snapshot")
    e = row[0]
    # Build the performances list: primary first, then secondaries (names
    # resolved via a second lookup so we don't return bare ids).
    perfs: list[dict] = []
    if e.get("primary_performer_id"):
        perfs.append({
            "performer": {
                "id": e["primary_performer_id"],
                "name": e.get("primary_performer_name"),
            },
            "primary": True,
        })
    other_ids = [int(p) for p in (e.get("performer_ids") or [])
                 if int(p) != int(e.get("primary_performer_id") or 0)]
    if other_ids:
        # Look up names from performer_metadata (covers all ~56k performers),
        # not from events.primary_performer_name (only covers performers who
        # have been primary in some event). NBA playoff games carry "series"
        # performer IDs that never appear as primary — those would render as
        # "null" in the UI without this. We drop any performer we still can't
        # name as a defensive belt-and-suspenders.
        names = (
            db.table("performer_metadata")
            .select("performer_id,name")
            .in_("performer_id", other_ids)
            .execute().data
        ) or []
        name_map = {int(r["performer_id"]): r.get("name")
                    for r in names if r.get("performer_id") and r.get("name")}
        for pid in other_ids:
            nm = name_map.get(int(pid))
            if not nm:
                # Unnamed — likely a TEvo-internal "series" tag (e.g. the
                # conference label on a playoff game). Skip.
                continue
            perfs.append({
                "performer": {"id": pid, "name": nm},
                "primary": False,
            })
    return {
        "id": e["id"],
        "name": e.get("name"),
        "occurs_at_local": e.get("occurs_at_local"),
        # occurs_at not stored — UI uses occurs_at_local exclusively, so this
        # is fine. Synthesized to match the TEvo shape.
        "occurs_at": e.get("occurs_at_local"),
        "state": e.get("state"),
        "venue": {
            "id": e.get("venue_id"),
            "name": e.get("venue_name"),
            "location": e.get("venue_location"),
            "time_zone": None,
        },
        "configuration": {},   # TEvo-only; UI gracefully renders without
        "performances": perfs,
    }


def fetch_owned_ticket_groups_from_db(require_sb: Callable, event_id: int) -> tuple[list[dict], str, str | None]:
    """SQL-only mode: pull the latest snapshot of owned ticket_groups for an
    event from `listings_snapshots` and shape rows like TEvo's response. Returns
    (groups, source, captured_at_iso). source is always 'snapshot'."""
    db = require_sb()
    # Latest captured_at for this event — single round-trip.
    latest = (
        db.table("listings_snapshots")
        .select("captured_at")
        .eq("event_id", event_id)
        .order("captured_at", desc=True)
        .limit(1)
        .execute().data
    )
    if not latest:
        return [], "snapshot", None
    captured_at = latest[0]["captured_at"]
    rows = (
        db.table("listings_snapshots")
        .select("tevo_ticket_group_id,section,row,quantity,retail_price,format,splits,"
                "wheelchair,instant_delivery,eticket,is_ancillary,type,is_owned")
        .eq("event_id", event_id)
        .eq("captured_at", captured_at)
        .eq("is_owned", True)
        .execute().data
    ) or []
    groups = []
    for r in rows:
        # Shape like TEvo's /v9/ticket_groups response so the existing filter +
        # render pipeline works unchanged.
        groups.append({
            "id": r.get("tevo_ticket_group_id"),
            "type": r.get("type") or "event",
            "section": r.get("section"),
            "row": r.get("row"),
            "quantity": r.get("quantity"),
            "available_quantity": r.get("quantity"),
            "retail_price": r.get("retail_price"),
            "format": r.get("format"),
            "splits": r.get("splits") or [],
            "wheelchair": r.get("wheelchair"),
            "instant_delivery": r.get("instant_delivery"),
            "eticket": r.get("eticket"),
            "in_hand": True,        # snapshot doesn't track this; assume yes
            "in_hand_on": None,
            "public_notes": None,    # not mirrored to listings_snapshots
        })
    return groups, "snapshot", captured_at
