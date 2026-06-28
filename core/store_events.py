"""SQL-only store event helpers — extracted from server.py (BR-CODE-1 core/ pass).

Leaf helpers for the storefront event/listing path, lifted out of server.py.
Their only external dependencies — the Supabase client (`require_sb`/`sb`) and
the TEvo `client` — are INJECTED by the caller (server.py keeps thin wrappers
that pass the live globals), so the monkeypatch tests bind the live accessors at
call time. One-directional: core never imports server.

Now also home to the keystone `resolve_event_with_filters` (the store
event-detail composer). It takes its patchable collaborators (the fetch_* /
build_zone_resolver / bulk_* helpers) as INJECTED params so the server-side
monkeypatch tests still intercept them; the pure helpers it uses (clean_opt_url,
normalize_filters, …) are imported directly. With this moved, the `/api/store/*`
event-detail routes can now be lifted into a router.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Callable

from fastapi import HTTPException

# Pure helpers used by resolve_event_with_filters — never monkeypatched by
# tests, so imported directly (the patchable helpers it composes — fetch_*,
# build_zone_resolver, bulk_* — are INJECTED as params so the server-side
# monkeypatches still bind).
from core.helpers import (
    clean_opt_url,
    normalize_filters,
    section_sort_key,
    tevo_runtime_to_http,
    ticket_group_to_listing,
)

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


def resolve_event_with_filters(
    sb, client, storefront_sql_only, fire_canonical_refresh,
    fetch_event_from_db, fetch_owned_ticket_groups_from_db,
    fetch_owned_ticket_groups, build_zone_resolver,
    bulk_performer_assets, bulk_event_context,
    event_id: int, filters: dict, include_inactive: bool = False,
) -> dict:
    """Fetch event + owned listings, apply filters, return the same shape
    /api/store/events/{id} returns. Shared by the public detail endpoint
    and the share-link resolver.

    SQL-only mode (storefront_sql_only=true): reads from `events` +
    `listings_snapshots` instead of TEvo. Same response shape so the UI
    is unchanged. inventory_source reflects 'snapshot' + adds
    snapshot_age_seconds so the demo banner can show staleness honestly.

    MVP prod checkpoint (2026-05-13): the SQL `event_lifecycle` gate was
    removed. Rationale: the catalog now filters by office_id at TEvo, so
    only events our office has inventory for ever surface. The gate was
    a defensive measure against ghost playoff rows + cancelled-but-still-
    listed games; with office_id, those edge cases are rare AND the
    broker terminal is the right place to manage stale listings, not the
    public detail page. Lifting the gate also fixes a real inconsistency
    where catalog showed a TBD playoff game (TEvo had inventory) but
    detail 404'd (audit SQL had marked it 'completed' when the series
    ended without that game). Set include_inactive=true is now a no-op
    kept for callsite compatibility.
    """
    snapshot_captured_at: str | None = None
    if storefront_sql_only:
        ev = fetch_event_from_db(event_id)
        groups, tg_source, snapshot_captured_at = fetch_owned_ticket_groups_from_db(event_id)
    else:
        try:
            ev = client.get_event(event_id)
        except RuntimeError as e:
            # Log full upstream error server-side; return a stable generic
            # string so TEvo's response text + upstream status codes never
            # reach the public detail page. Mirrors the /api/store/events
            # 502 scrub at line ~4194. Status is normalized: a 400/404 from
            # TEvo means the event doesn't exist → 404 (not a 502 gateway
            # error, which previously made cycling-id scans + dead share
            # links look like outages); 5xx/timeout → 502, 429/503 → 503.
            _log.warning(f"[store_event_detail] TEvo event lookup failed for {event_id}: {e!r}")
            raise tevo_runtime_to_http(
                e,
                not_found_detail="event not found",
                failure_detail="event lookup failed",
            ) from e

        # Storefront freshness contract: 10s. Tighter than broker's 90s because
        # this is the buy-decision page — stale availability => bad UX.
        groups, tg_source = fetch_owned_ticket_groups(event_id, max_age_seconds=10)

    eligible = [
        tg
        for tg in groups
        if (tg.get("type") or "event").lower() == "event"
        and (tg.get("available_quantity") or tg.get("quantity") or 0) > 0
    ]
    total_before_filters = len(eligible)

    # Parking inventory — TEvo splits seats vs parking via the type field.
    # We surface parking on a separate tab so its prices don't pollute
    # from_price / min-price filters / seat zone+section filters. Cap
    # display at $5K so a known-bad parking outlier (max retail $994K
    # observed in raw data, clearly a mis-priced parking pass) doesn't
    # blow up the tab.
    parking_groups = [
        tg
        for tg in groups
        if (tg.get("type") or "").lower() == "parking"
        and (tg.get("available_quantity") or tg.get("quantity") or 0) > 0
        and float(tg.get("retail_price") or 0) <= 5000
    ]
    parking_groups.sort(key=lambda tg: float(tg.get("retail_price") or 1e12))

    venue = ev.get("venue") or {}
    performances = ev.get("performances") or []
    primary_perf = next(
        ((p.get("performer") or {}) for p in performances if p.get("primary")),
        ((performances[0].get("performer") or {}) if performances else {}),
    )
    perf_id = primary_perf.get("id")
    venue_id = venue.get("id")

    f = normalize_filters(filters)

    # Capture the full section universe BEFORE applying any section filter
    # so the UI can render section chips that don't disappear when the user
    # narrows the listings. Letter-prefixed sections (Floor, Courtside, GA,
    # etc.) sort BEFORE numeric sections per the StubHub/SeatGeek convention;
    # numeric sections sort naturally (1, 2, 10, 100 — not lex-order).
    sections_available = sorted(
        {str(tg.get("section") or "").strip()
         for tg in eligible if tg.get("section")},
        key=section_sort_key,
    )

    # Distinct quantities the seller offers across the unfiltered listing
    # set. UI uses this to build the min-qty dropdown so we don't offer
    # "any" when nothing sells in singles, or "4+" when no listing has a
    # split ≥ 4. Pre-min_qty-filter so the dropdown stays useful as the
    # user narrows.
    splits_available = sorted({
        int(s) for tg in eligible for s in (tg.get("splits") or [])
        if (isinstance(s, int) or str(s).isdigit())
    })

    section_set = {s.lower() for s in f["section"]}
    if section_set:
        eligible = [tg for tg in eligible if str(tg.get("section") or "").lower() in section_set]

    if f["min_price"] is not None:
        eligible = [tg for tg in eligible if float(tg.get("retail_price") or 0) >= f["min_price"]]
    if f["max_price"] is not None:
        eligible = [tg for tg in eligible if float(tg.get("retail_price") or 0) <= f["max_price"]]

    if f["min_qty"] is not None and f["min_qty"] > 0:
        target = f["min_qty"]
        def _meets(tg):
            splits = tg.get("splits") or []
            avail = int(tg.get("available_quantity") or tg.get("quantity") or 0)
            if splits:
                return any(s >= target for s in splits)
            return avail >= target
        eligible = [tg for tg in eligible if _meets(tg)]

    zone_set = {z.lower() for z in f["zones"]}
    listings_with_zone: list[tuple[dict, str | None]]
    if zone_set:
        resolver = build_zone_resolver(perf_id, venue_id)
        kept: list[tuple[dict, str | None]] = []
        for tg in eligible:
            z = resolver(tg.get("section"), tg.get("row"))
            if z and z.lower() in zone_set:
                kept.append((tg, z))
        listings_with_zone = kept
    else:
        listings_with_zone = [(tg, None) for tg in eligible]

    listings_with_zone.sort(key=lambda x: float(x[0].get("retail_price") or 1e12))

    listings = []
    for tg, zone in listings_with_zone:
        item = ticket_group_to_listing(tg)
        if zone:
            item["zone"] = zone
        listings.append(item)

    config = ev.get("configuration") or {}
    seating = (config.get("seating_chart") or {})

    # Bulk-attach branded assets (logo / colors) for the performers on
    # this event. performer_metadata is populated by the audit lane's ESPN
    # ingest — we read only. Falls through gracefully when a performer has
    # no asset row yet (most non-MLB/NBA/NFL/NHL teams don't).
    perf_assets: dict[int, dict] = {}
    if sb is not None:
        try:
            perf_ids = [int((p.get("performer") or {}).get("id"))
                        for p in performances
                        if (p.get("performer") or {}).get("id")]
            if perf_ids:
                perf_assets = bulk_performer_assets(sb, perf_ids)
        except Exception:
            perf_assets = {}

    def _attach_assets(p):
        perf = p.get("performer") or {}
        pid = perf.get("id")
        a = perf_assets.get(int(pid)) if pid else None
        return {
            "id": pid,
            "name": perf.get("name"),
            "primary": p.get("primary"),
            "logo_url": (a or {}).get("logo_default_url"),
            "color_primary": (a or {}).get("color_primary"),
        }

    # Snapshot age (SQL-only mode only) — UI uses this to show honest staleness.
    snapshot_age_seconds: int | None = None
    if snapshot_captured_at:
        try:
            ts = datetime.fromisoformat(str(snapshot_captured_at).replace("Z", "+00:00"))
            snapshot_age_seconds = int((datetime.now(timezone.utc) - ts).total_seconds())
        except (ValueError, TypeError):
            snapshot_age_seconds = None

    # Pull asset bundle from v_event_seating_chart — audit-lane-maintained
    # view that joins events × configurations × venue_assets × performer
    # metadata into one row per event. Single round-trip, single source of
    # truth. Includes TEvo seating chart URLs (configurations.static_maps)
    # AND fanvenues_key for dynamic interactive seatmaps. Silently degrades
    # to the minimal payload when the row is missing.
    asset_bundle: dict = {}
    if sb is not None and ev.get("id"):
        try:
            ab_rows = (
                sb.table("v_event_seating_chart")
                .select(
                    "configuration_id,configuration_name,seating_chart_medium,"
                    "seating_chart_large,fanvenues_key,venue_hero_url,venue_map_url,"
                    "venue_capacity,venue_is_indoor,team_color_primary,team_color_alternate,"
                    "team_logo_url,team_logo_dark_url,team_espn_url"
                )
                .eq("event_id", int(ev["id"]))
                .limit(1)
                .execute().data
            ) or []
            if ab_rows:
                asset_bundle = ab_rows[0]
        except Exception:
            asset_bundle = {}

    # Also pull venue coords from venue_assets (not exposed by the view —
    # used by the near-me feature, separate from the event page UX).
    venue_assets: dict = {}
    if sb is not None and venue.get("id"):
        try:
            va_rows = (
                sb.table("venue_assets")
                .select("latitude,longitude,city,state,country,"
                        "espn_venue_id,espn_venue_name")
                .eq("tevo_venue_id", int(venue["id"]))
                .limit(1)
                .execute().data
            ) or []
            if va_rows:
                venue_assets = va_rows[0]
        except Exception:
            venue_assets = {}

    response = {
        "event": {
            "id": ev.get("id"),
            "name": ev.get("name"),
            "occurs_at": ev.get("occurs_at"),
            "occurs_at_local": ev.get("occurs_at_local"),
            "venue": {
                "id": venue.get("id"),
                "name": venue.get("name"),
                "location": venue.get("location"),
                "time_zone": venue.get("time_zone"),
                # Audit-lane assets (v_event_seating_chart + venue_assets).
                # All optional — UI hides any field that's null.
                "hero_image_url": asset_bundle.get("venue_hero_url"),
                "venue_map_url": asset_bundle.get("venue_map_url"),
                "is_indoor": asset_bundle.get("venue_is_indoor"),
                "capacity": asset_bundle.get("venue_capacity"),
                "latitude": venue_assets.get("latitude"),
                "longitude": venue_assets.get("longitude"),
                "city": venue_assets.get("city"),
                "state": venue_assets.get("state"),
                "country": venue_assets.get("country"),
                "espn_venue_id": venue_assets.get("espn_venue_id"),
                "espn_venue_name": venue_assets.get("espn_venue_name"),
            },
            "configuration": {
                # Static seating chart from TEvo's /v9/configurations.
                # Both medium (~500px) and large (~1000px) URLs available;
                # UI defaults to medium and lazy-loads large on click.
                # SQL-only mode reads these from v_event_seating_chart; live
                # mode falls back to the inline config dict from TEvo's
                # /v9/events/:id response.
                "id": asset_bundle.get("configuration_id") or config.get("id"),
                "name": asset_bundle.get("configuration_name") or config.get("name"),
                # clean_opt_url BEFORE the `or` so a sentinel "null" in
                # asset_bundle doesn't shadow a real URL from the live config.
                "seating_chart_medium": (
                    clean_opt_url(asset_bundle.get("seating_chart_medium"))
                    or clean_opt_url(seating.get("medium"))
                ),
                "seating_chart_large": (
                    clean_opt_url(asset_bundle.get("seating_chart_large"))
                    or clean_opt_url(seating.get("large"))
                ),
                # fanvenues_key — opaque ID for TEvo's seatmaps-client.js
                # interactive seat picker. Surfaced so a future enhancement
                # can mount the dynamic seatmap (today the UI uses the static
                # jpg). Per docs/api-08 §Seating Charts.
                "fanvenues_key": asset_bundle.get("fanvenues_key"),
            },
            # TEvo carries "series" performers alongside competing teams on
            # playoff games (e.g. "NBA Playoffs", "NBA Western Conference
            # Semifinals"). They show up in events.performer_ids and have rows
            # in performer_metadata, but with no logo / color / ESPN xref.
            # Drop them (non-primary only) so the header doesn't read
            # "Lakers (home) vs NBA Playoffs vs NBA Western Conference
            # Semifinals vs Thunder". Always keep the primary even when it
            # has minimal metadata (Peso Pluma etc. — would otherwise leave
            # a headliner-less event card).
            "performers": [
                p_meta for p_meta in (_attach_assets(p) for p in performances)
                if p_meta.get("primary")
                or p_meta.get("logo_url") or p_meta.get("color_primary")
            ],
        },
        "listings": listings,
        "listings_count": len(listings),
        # Parking is a separate tab on the event page (when present).
        # Stays out of sections_available / splits_available / from_price
        # so the seat-tab UX is unaffected by parking inventory.
        "parking_listings": [ticket_group_to_listing(tg) for tg in parking_groups],
        "parking_count": len(parking_groups),
        "total_before_filters": total_before_filters,
        # All section names present in the unfiltered set so the UI can
        # render the section chip group without it collapsing as the user
        # narrows. Without this the chips disappear after one click and
        # multi-select feels broken.
        "sections_available": sections_available,
        # Distinct seller-offered quantities (union of splits arrays in the
        # unfiltered set). UI builds the min-qty dropdown from this so we
        # don't offer values no listing actually sells in.
        "splits_available": splits_available,
        "filters": f,
        # 'cache' (≤10s old, live mode) | 'live' (live mode) | 'snapshot' (SQL-only mode)
        "inventory_source": tg_source,
        "snapshot_age_seconds": snapshot_age_seconds,
        "demo_mode": storefront_sql_only,
    }

    # Context badges — rivalry / MLB series / tournament / weather / holiday
    # / playoff. All nullable; UI hides the badge when None. Single bulk
    # call to keep the per-detail roundtrip count low.
    _empty_ctx = {
        "rivalry": None, "mlb_series": None, "tournament": None,
        "weather": None, "holiday": None, "playoff": None,
    }
    if sb is not None:
        ctx_by_id = bulk_event_context(sb, [event_id])
        response["context"] = ctx_by_id.get(event_id) or dict(_empty_ctx)
    else:
        response["context"] = dict(_empty_ctx)

    # Fire-and-forget: refresh canonical SQL via the audit-lane Edge Function.
    # Auto-tracks the event (adds performer to watchlist) if we've never seen
    # it before. Never blocks the response. SKIPPED in SQL-only mode — no
    # point firing a TEvo collector while we're trying to keep TEvo out.
    if not storefront_sql_only:
        fire_canonical_refresh(event_id, ev)

    return response

