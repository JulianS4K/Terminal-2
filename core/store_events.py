"""SQL-only store event helpers — extracted from server.py (BR-CODE-1 core/ pass).

Leaf helpers for the storefront event/listing path, lifted out of server.py.
Their only external dependencies — the Supabase client (`require_sb`/`sb`) and
the TEvo `client` — are INJECTED by the caller (server.py keeps thin wrappers
that pass the live globals), so the monkeypatch tests bind the live accessors at
call time. One-directional: core never imports server.

This is the in-progress core/ pass that must precede lifting the `/api/store/*`
routes into a router; `_resolve_event_with_filters` (which composes these) is
the remaining keystone, still in server.py.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Callable

from fastapi import HTTPException

_log = logging.getLogger("app")


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


def build_zone_resolver(sb, performer_id: int | None, venue_id: int | None):
    """Return a fn (section, row) -> zone_name | None for this performer+venue.

    Calls match_performer_zone() once per unique (section, row) pair encountered,
    cached within a single request. Returns a no-op resolver if
    (performer_id, venue_id) are missing or Supabase is offline. `sb` is the
    service-role client, injected by the caller."""
    if sb is None or not performer_id or not venue_id:
        return lambda section, row: None
    cache: dict[tuple[str, str], str | None] = {}

    def resolve(section, row):
        key = (str(section or ""), str(row or ""))
        if key in cache:
            return cache[key]
        try:
            res = sb.rpc(
                "match_performer_zone",
                {
                    "p_performer_id": performer_id,
                    "p_venue_id": venue_id,
                    "p_section": section or "",
                    "p_row": row or "",
                },
            ).execute()
            cache[key] = res.data if isinstance(res.data, str) else None
        except Exception:
            cache[key] = None
        return cache[key]

    return resolve


def fetch_owned_ticket_groups(sb, client, event_id: int,
                              max_age_seconds: int | None = None) -> tuple[list[dict], str]:
    """Pull owned-only ticket_groups for an event. Returns (groups, source)
    where source is 'cache' (≤max_age) or 'live'. `sb` + `client` injected.

    Read is gated on max_age_seconds (storefront ~10s; broker None → row's own
    90s expires_at); write is always a 90s TTL. Cache key is event_id only
    (owned=true implied for both call sites)."""
    if sb is not None:
        try:
            cached = sb.rpc("get_cached_ticket_groups", {"p_event_id": event_id}).execute().data
            if cached:
                payload_age_ok = True
                if max_age_seconds is not None:
                    captured_at_str = (cached or {}).get("captured_at")
                    if captured_at_str:
                        try:
                            captured_at = datetime.fromisoformat(
                                str(captured_at_str).replace("Z", "+00:00")
                            )
                            age = (datetime.now(timezone.utc) - captured_at).total_seconds()
                            payload_age_ok = age <= max_age_seconds
                        except (ValueError, TypeError):
                            payload_age_ok = False
                    else:
                        payload_age_ok = False
                if payload_age_ok:
                    return (cached or {}).get("ticket_groups", []) or [], "cache"
        except Exception:
            # Cache failure must never block the page; fall through to live.
            pass
    try:
        live = client.get_ticket_groups(event_id, owned=True)
    except RuntimeError as e:
        _log.warning(f"[ticket_groups] TEvo ticket_groups failed for {event_id}: {e!r}")
        raise HTTPException(502, "ticket listings fetch failed")
    groups = live.get("ticket_groups", []) or []
    if sb is not None:
        try:
            sb.rpc("put_cached_ticket_groups", {
                "p_event_id": event_id,
                "p_payload": {
                    "ticket_groups": groups,
                    "captured_at": datetime.now(timezone.utc).isoformat(),
                },
                "p_ttl_seconds": 90,
            }).execute()
        except Exception:
            pass
    return groups, "live"
