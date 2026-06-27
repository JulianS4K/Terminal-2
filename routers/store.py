"""D1 storefront event-detail routes — /api/store/events/{id} (+ /zones).

server.py decomposition slice (BR-CODE-1): the two event-detail routes, lifted
behind unchanged paths now that their keystone composer
(`resolve_event_with_filters`) lives in `core/store_events.py`.

Getters resolve the live server symbols at request time so the monkeypatch tests
bind: `get_resolve_event` → `app._resolve_event_with_filters` (the wrapper that
itself injects sb/client/etc.), `get_require_sb` → `app.require_sb`,
`get_prefer_internal_zones` → `app.STOREFRONT_PREFER_INTERNAL_ZONES`.
`is_bowl_pattern_name` is a pure core helper (never patched).
"""
from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from fastapi import APIRouter, BackgroundTasks, Body, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from core.auth import HUMAN_COOKIE_NAME, HUMAN_TTL_SECONDS, issue_human_token
from core.helpers import (
    is_bowl_pattern_name,
    is_speculative_event_name,
    is_tbd,
    movers_cache_key,
    normalize_search_key,
    or_ilike_clause,
)

_log = logging.getLogger("app")

# A performer+venue pair with more zones than this almost certainly has a
# hand-curated granular layer on top of the consumer bowl seed (NYK@MSG = 26;
# the seeded consumer baseline tops out at ~5–7).
_GRANULAR_LAYER_ZONE_COUNT_THRESHOLD = 8


def build_store_router(
    get_require_sb: Callable[[], Callable],
    get_resolve_event: Callable[[], Callable],
    get_prefer_internal_zones: Callable[[], bool],
    get_trip_plan_payload: Callable[[], Callable],
    get_tour_package_payload: Callable[[], Callable],
    get_multi_tour_payload: Callable[[], Callable],
    get_discover_payload: Callable[[], Callable],
    # Discovery-route deps (search / movers / home / near). Getters resolve the
    # live server symbols at request time so the monkeypatch tests bind; the
    # mutable caches (`_search_cache`, `_movers_cache`, `_MOVERS_CACHE_REFRESHING`)
    # stay in server.py — getters hand back the live container so in-place
    # mutation + conftest's per-test reset both keep working.
    get_storefront_sql_only: Callable[[], bool] = lambda: False,
    get_storefront_search_sql_only: Callable[[], bool] = lambda: False,
    get_search_cache_get: Callable[[], Callable] = lambda: (lambda k: None),
    get_search_cache_put: Callable[[], Callable] = lambda: (lambda k, p: None),
    get_search_sql_only: Callable[[], Callable] = lambda: (lambda *a: {}),
    get_search_live: Callable[[], Callable] = lambda: (lambda *a: {}),
    get_search_players: Callable[[], Callable] = lambda: (lambda *a: []),
    get_movers_cache: Callable[[], dict] = dict,
    get_movers_cache_ttl: Callable[[], float] = lambda: 300.0,
    get_movers_refreshing: Callable[[], set] = set,
    get_refresh_movers: Callable[[], Callable] = lambda: (lambda *a: None),
    get_compute_movers: Callable[[], Callable] = lambda: (lambda *a: {}),
    get_bulk_performer_assets: Callable[[], Callable] = lambda: (lambda *a: {}),
    get_client: Callable[[], Any] = lambda: None,
    get_attach_owned_metadata: Callable[[], Callable] = lambda: (lambda *a: []),
    # Storefront stale-snapshot read (production-readiness P1 #4): runs a DB read
    # through the shared circuit breaker so a Supabase blip fast-fails to a
    # fallback instead of hanging the homepage. Default = plain passthrough.
    get_safe_read: Callable[[], Callable] = lambda: (lambda fn, fb, on_error=None: fn()),
    # TEvo office id — server-side filter for "events MY office has listings on"
    # (the catalog /api/store/events route). Server-module constant, via getter.
    get_tevo_office_id: Callable[[], int] = lambda: 0,
    # Bot-gated store POSTs (verify-human / reserve). Getters resolve the live
    # server symbols the tests patch (RECAPTCHA_ENABLED, _verify_recaptcha,
    # _require_human, STOREFRONT_RESERVE_REQUIRES_AUTH, _fetch_owned_ticket_groups
    # _from_db); require_auth is the live gate (reserve calls it directly). The
    # cookie helpers (issue_human_token / HUMAN_*) are pure core.auth imports.
    get_require_auth: Callable[[], Callable] = lambda: (lambda *a, **k: None),
    get_recaptcha_enabled: Callable[[], bool] = lambda: False,
    get_verify_recaptcha: Callable[[], Callable] = lambda: (lambda *a: True),
    get_require_human: Callable[[], Callable] = lambda: (lambda *a, **k: None),
    get_reserve_requires_auth: Callable[[], bool] = lambda: False,
    get_fetch_owned_tg_from_db: Callable[[], Callable] = lambda: (lambda *a: ([], "", None)),
) -> APIRouter:
    router = APIRouter()

    # NOTE: /api/store/events/near MUST be declared before the
    # /api/store/events/{event_id} catch-all below — Starlette matches in
    # definition order, so the literal "near" path has to win before the int
    # path-param tries (and fails with 422) to coerce "near" to an event_id.
    @router.get("/api/store/events/near")
    def store_events_near(
        lat: float,
        lon: float,
        within: float = 50.0,       # miles
        limit: int = 10,
        source: str = "hybrid",     # 'hybrid' | 'supabase' | 'tevo'
    ):
        """Owned-inventory events sorted by distance from (lat, lon).

        Three modes via `?source=`:
        1. **hybrid** (default) — TEvo geo query for authoritative venue
           coverage, intersected with our owned+active set.
        2. **supabase** — pure local: owned+active set joined to venue_assets
           coords, Python haversine. Zero TEvo quota; caps at geocoded venues.
        3. **tevo** — raw TEvo geo, no owned filter. Debug-only.

        Distance display uses our venue_assets coords (TEvo's events response
        omits venue lat/lon). Events with no coord sort to the end.
        """
        within = max(1.0, min(within, 500.0))
        cap = max(1, min(limit, 50))
        client = get_client()

        # SQL-only mode: force supabase mode regardless of ?source=. No TEvo
        # calls on the home page during demo testing.
        if get_storefront_sql_only():
            source = "supabase"

        if source == "tevo":
            # Debug mode: raw TEvo geo, NO owned filter. Not used by the UI.
            try:
                tevo_resp = client.list_events(
                    lat=lat, lon=lon, within=within,
                    only_with_available_tickets=True,
                    order_by="events.occurs_at ASC",
                    per_page=min(cap, 100),
                )
            except RuntimeError as e:
                _log.warning(f"[store_events_near] TEvo geo lookup failed: {e!r}")
                raise HTTPException(502, "geo lookup failed")
            evs = tevo_resp.get("events") or []
            return {
                "count": len(evs),
                "events": [
                    {
                        "id": ev.get("id"),
                        "name": ev.get("name"),
                        "occurs_at_local": ev.get("occurs_at_local"),
                        "venue_name": (ev.get("venue") or {}).get("name"),
                        "venue_location": (ev.get("venue") or {}).get("location"),
                        "distance_miles": None,
                    }
                    for ev in evs
                ],
                "user_lat": lat, "user_lon": lon, "within_miles": within,
                "source": "tevo",
            }

        db = get_require_sb()()
        attach_owned_metadata = get_attach_owned_metadata()

        if source == "hybrid":
            # Step 1: TEvo geo query for events near (lat, lon) with available
            # marketplace tickets. per_page is capped at 100 by TEvo.
            try:
                tevo_resp = client.list_events(
                    lat=lat, lon=lon, within=within,
                    only_with_available_tickets=True,
                    order_by="events.occurs_at ASC",
                    per_page=100,
                )
            except RuntimeError as e:
                # On TEvo failure, fall through to supabase mode rather than
                # 502'ing the home page.
                _log.warning(f"near (hybrid): TEvo failed, falling back to supabase: {e}")
                source = "supabase"
            else:
                candidate_ids = [int(e["id"]) for e in (tevo_resp.get("events") or []) if e.get("id")]
                decorated = attach_owned_metadata(db, candidate_ids, lat, lon)
                decorated.sort(key=lambda x: (x["distance_miles"] is None, x["distance_miles"] or 1e9))
                return {
                    "count": len(decorated[:cap]),
                    "events": decorated[:cap],
                    "user_lat": lat, "user_lon": lon, "within_miles": within,
                    "total_within_radius": len(decorated),
                    "tevo_candidates": len(candidate_ids),
                    "source": "hybrid",
                }

        # source == "supabase" (or hybrid fallback). Pull all owned event ids;
        # _attach_owned_metadata does its own two-query merge join.
        rows = (
            db.table("latest_event_metrics")
            .select("event_id")
            .gt("owned_tickets_count", 0)
            .limit(500)
            .execute().data
        ) or []
        candidate_ids = [int(r["event_id"]) for r in rows if r.get("event_id")]
        decorated = attach_owned_metadata(db, candidate_ids, lat, lon)
        # Drop events outside the radius (or missing coords entirely).
        in_radius = [d for d in decorated
                     if d["distance_miles"] is not None and d["distance_miles"] <= within]
        in_radius.sort(key=lambda x: x["distance_miles"])
        return {
            "count": len(in_radius[:cap]),
            "events": in_radius[:cap],
            "user_lat": lat, "user_lon": lon, "within_miles": within,
            "total_within_radius": len(in_radius),
            "supabase_candidates": len(rows),
            "missing_coords": sum(1 for d in decorated if d["distance_miles"] is None),
            "source": "supabase",
        }

    @router.get("/api/store/events/{event_id}")
    def store_event_detail(
        event_id: int,
        section: str | None = None,         # CSV of exact section names
        min_price: float | None = None,
        max_price: float | None = None,
        min_qty: int | None = None,
        zones: str | None = None,           # CSV of curated zone names (case-insensitive)
    ):
        """Event detail + live owned-only ticket groups from TEvo, with optional
        share-link filters applied server-side. Filters are AND-ed; an empty set
        of matches is a valid response (UI shows "no listings match")."""
        return get_resolve_event()(
            event_id,
            {
                "section": section,
                "min_price": min_price,
                "max_price": max_price,
                "min_qty": min_qty,
                "zones": zones,
            },
        )

    @router.get("/api/store/events/{event_id}/zones")
    def store_event_zones(event_id: int):
        """List curated zones with owned-ticket counts so the Share dialog can
        offer zone choices.

        Layer preference (per Julian's 2026-05-11 direction):
          1. If the event's performer+venue has any INTERNAL (granular) zones
             with matching owned tickets, return ONLY those.
          2. Else fall back to CONSUMER (coarse bowl-level) zones.
          3. Else empty (most events outside the seeded set).
        Response includes `layer` so the UI can label the chip group.
        """
        db = get_require_sb()()
        prefer_internal = get_prefer_internal_zones()
        try:
            rows = db.rpc(
                "get_event_zones_rollup",
                {"p_event_id": event_id, "p_owned_only": True},
            ).execute().data or []
        except Exception:
            rows = []
        # Only consider curated zones — fallback/unmapped names from
        # derive_zone_fallback() are noisy and not safe to share by name.
        curated = [r for r in rows if r.get("source") == "curated"]

        # Step 1: count the FULL zone universe for this event's performer+venue.
        # If larger than the consumer-only ceiling, the pair has been
        # hand-curated with granular zones layered on top of the bowl seed.
        pair_zone_count = 0
        try:
            ev_meta = (
                db.table("events").select("primary_performer_id,venue_id")
                .eq("id", event_id).limit(1).execute().data
            ) or []
            if ev_meta:
                perf_id = ev_meta[0].get("primary_performer_id")
                venue_id_x = ev_meta[0].get("venue_id")
                if perf_id and venue_id_x:
                    pair_rows = (
                        db.table("performer_zones").select("id", count="exact")
                        .eq("performer_id", perf_id).eq("venue_id", venue_id_x)
                        .execute()
                    )
                    pair_zone_count = pair_rows.count or len(pair_rows.data or [])
        except Exception:
            pair_zone_count = 0

        has_granular_layer = pair_zone_count > _GRANULAR_LAYER_ZONE_COUNT_THRESHOLD

        # Step 2: pick the layer to surface. Off by default — granular taxonomy
        # has coverage gaps; once A1 closes them, flip
        # STOREFRONT_PREFER_INTERNAL_ZONES=true.
        if has_granular_layer and prefer_internal:
            chosen = [r for r in curated if not is_bowl_pattern_name(r.get("zone"))]
            layer = "internal" if chosen else "none"
        else:
            chosen = curated
            layer = "consumer" if chosen else "none"

        zones = [
            {
                "name": r.get("zone"),
                "tickets": r.get("tickets") or 0,
                "min_retail": r.get("min_retail"),
                "max_retail": r.get("max_retail"),
            }
            for r in chosen
        ]
        return {
            "event_id": event_id,
            "zones": zones,
            "layer": layer,
            "pair_zone_count": pair_zone_count,  # debug: # of zones for performer+venue
            "has_granular_available": has_granular_layer,  # UI 'switch to expert view' toggle
            "prefer_internal_enabled": prefer_internal,
        }

    @router.get("/api/store/concierge")
    def store_concierge(city: str = "NYC", days: int = 60, limit: int = 18):
        """Concierge rail — upcoming owned events where we hold PREMIUM top-band
        seats (>= $500), EVO/TEvo inventory only (D3, 2026-06-16). Backed by the
        `concierge_events` rollup; ordered most-premium first. `from_price` is the
        entry into each event's premium tier. NYC-scoped like the movers rail.
        """
        db = get_require_sb()()
        today_iso = datetime.now(timezone.utc).date().isoformat()
        horizon_iso = (datetime.now(timezone.utc) + timedelta(days=max(1, min(int(days), 120)))).date().isoformat()
        venue_patterns = ("%New York%", "%Brooklyn%", "%Bronx%", "%Queens%",
                          "%Flushing%", "%Elmont%", "%, NY%", "%Newark%", "%East Rutherford%")
        try:
            q = (db.table("concierge_events")
                   .select("event_id,name,venue_name,venue_location,occurs_at_local,"
                           "from_price,prem_max_price,prem_tickets,primary_performer_name")
                   .gte("occurs_date", today_iso)
                   .lte("occurs_date", horizon_iso))
            q = q.or_(",".join(or_ilike_clause("venue_location", p) for p in venue_patterns))
            rows = q.order("prem_max_price", desc=True).limit(max(1, min(int(limit), 40))).execute().data or []
        except Exception as e:
            _log.warning(f"store_concierge query failed: {e}")
            return {"count": 0, "events": []}
        # Map event_id -> id so the card links to /store/event/{id}.
        events = [{**r, "id": r.pop("event_id")} for r in rows]
        return {"count": len(events), "events": events}

    # --- Trip-planner delegates (thin; the payload builders + the optimizer are
    # shared with the D0 broker routes and stay in server.py, resolved via
    # getters so the test stubs bind). ---

    @router.get("/api/store/performers/{performer_id}/trip-plan")
    def store_performer_trip_plan(
        performer_id: int,
        home_lat: float,
        home_lon: float,
        budget_km: float = 6000.0,
        home_name: str = "Home",
        days: int = 365,
        max_events: int | None = None,
        budget_usd: float | None = None,
        qty: int = 1,
    ):
        """D1 store: 'plan a trip around <performer>'. Consumer-facing; shares the
        optimizer with the D0 broker route via `trip_planner`."""
        return get_trip_plan_payload()(performer_id, home_lat, home_lon, budget_km,
                                       home_name, days, max_events, budget_usd, qty)

    @router.get("/api/store/performers/{performer_id}/tour-package")
    def store_performer_tour_package(
        performer_id: int,
        qty: int = 2,
        budget_usd: float | None = None,
        max_events: int | None = None,
        days: int = 365,
        start: str | None = None,
        end: str | None = None,
        side: str = "auto",
        # Location optional — the storefront flow is budget-first. Omit
        # home_lat/home_lon to plan on ticket spend alone.
        home_lat: float | None = None,
        home_lon: float | None = None,
        budget_km: float = 8000.0,
        home_name: str = "Home",
        clear_at: float = 0.15,
        away_margin: float = 0.18,
        section_like: str | None = None,
        prefer_owned: bool = False,
    ):
        """D1 store: retail 'follow the tour' agent. Budget-first; shares the
        optimizer with the D0 route via `trip_planner`."""
        return get_tour_package_payload()(performer_id, home_lat, home_lon, qty, budget_km,
                                          home_name, days, budget_usd, side, clear_at,
                                          away_margin, section_like, prefer_owned,
                                          max_events=max_events, start_date=start, end_date=end)

    @router.get("/api/store/tours/multi")
    def store_multi_tour(
        performer_ids: str,
        home_lat: float,
        home_lon: float,
        qty: int = 3,
        budget_km: float = 10000.0,
        home_name: str = "Home",
        days: int = 365,
        budget_usd: float | None = None,
        side: str = "auto",
        clear_at: float = 0.15,
        away_margin: float = 0.18,
        section_like: str | None = None,
        prefer_owned: bool = False,
    ):
        """D1 store 'plan my summer' — one routed+priced package across several
        performers (comma-separated `performer_ids`, up to 8)."""
        return get_multi_tour_payload()(performer_ids, home_lat, home_lon, qty, budget_km,
                                        home_name, days, budget_usd, side, clear_at,
                                        away_margin, section_like, prefer_owned)

    @router.get("/api/store/tours/near")
    def store_tours_near(
        home_lat: float,
        home_lon: float,
        within_mi: float = 250.0,
        days: int = 120,
        min_shows: int = 2,
        concerts_only: bool = False,
    ):
        """D1 store reverse discovery — performers/teams playing >= min_shows
        within `within_mi` of home in the window (teams surface by AWAY games)."""
        return get_discover_payload()(home_lat, home_lon, within_mi, days, min_shows,
                                      concerts_only, team_side="away")

    # --- Bot-gated store POSTs (verify-human / reserve). reserve is a MOCK —
    # it validates owned inventory + returns a confirmation shape but NEVER
    # calls /v9/orders (no real charge). ---

    @router.post("/api/store/verify-human")
    def store_verify_human(request: Request, payload: dict = Body(...)):
        """First-interaction bot gate (reCAPTCHA v3). store.js calls this once per
        session with a v3 token (action 'gate'); on a passing score we set a
        short-lived signed cookie that the write endpoints accept, so the gate runs
        once rather than on every action. No-op success when the gate is dormant."""
        if not get_recaptcha_enabled():
            return JSONResponse({"ok": True, "enabled": False})
        token = payload.get("recaptcha_token") or payload.get("token")
        xff = request.headers.get("x-forwarded-for") or ""
        ip = (xff.split(",")[-1].strip() if xff else (request.client.host if request.client else None))
        if not get_verify_recaptcha()(token, "gate", ip):
            raise HTTPException(403, "verification failed")
        resp = JSONResponse({"ok": True, "enabled": True})
        resp.set_cookie(
            HUMAN_COOKIE_NAME,
            issue_human_token(),
            max_age=HUMAN_TTL_SECONDS,
            httponly=True,
            samesite="lax",
            secure=True,
            path="/",
        )
        return resp

    @router.post("/api/store/reserve")
    def store_reserve(request: Request, payload: dict = Body(...), authorization: str | None = Header(None)):
        """MVP placeholder: a real checkout is not wired up yet. Validates that
        the requested ticket_group + quantity matches the live owned inventory in
        TEvo, then returns a mock confirmation. NEVER calls /v9/orders.

        Auth: gated by STOREFRONT_RESERVE_REQUIRES_AUTH env flag. MVP demo
        leaves it off so the front-end's "Reserve (mock)" button works without
        a Supabase session. Sprint 2 (real-purchase path) flips the flag on
        once the front-end attaches Authorization headers."""
        if get_reserve_requires_auth():
            get_require_auth()(authorization)
        # Bot gate: honeypot (always) + reCAPTCHA human-cookie/token (when enabled).
        get_require_human()(request, payload)
        try:
            event_id = int(payload.get("event_id") or 0)
            ticket_group_id = int(payload.get("ticket_group_id") or 0)
            quantity = int(payload.get("quantity") or 0)
        except (TypeError, ValueError):
            raise HTTPException(400, "event_id, ticket_group_id and quantity must be integers")
        if not (event_id and ticket_group_id and quantity > 0):
            raise HTTPException(400, "event_id, ticket_group_id and quantity > 0 required")
        # Upper-bound the requested quantity before we touch inventory. TEvo
        # ticket groups in practice cap around 8-12 per seat block; 50 is a
        # generous ceiling that still bounds the request shape so a malformed
        # client (quantity=999999) gets rejected fast without consulting the
        # upstream API or the snapshot table.
        if quantity > 50:
            raise HTTPException(400, "quantity exceeds maximum allowed per reservation")

        if get_storefront_sql_only():
            # SQL-only mode: validate against listings_snapshots' latest capture
            # for this event. Same validation surface (available + splits) so
            # the UX is identical, just slightly stale-tolerant.
            groups, _src, _captured = get_fetch_owned_tg_from_db()(event_id)
            match = next(
                (tg for tg in groups if int(tg.get("id") or 0) == ticket_group_id),
                None,
            )
            if not match:
                raise HTTPException(
                    404,
                    "ticket group is no longer available from this seller (snapshot-based)",
                )
        else:
            try:
                tg_resp = get_client().get_ticket_groups(event_id, owned=True)
            except RuntimeError as e:
                _log.warning(f"[store_reserve] TEvo ticket_groups failed for {event_id}: {e!r}")
                raise HTTPException(502, "ticket listings fetch failed")
            match = next(
                (tg for tg in (tg_resp.get("ticket_groups") or []) if int(tg.get("id") or 0) == ticket_group_id),
                None,
            )
            if not match:
                raise HTTPException(404, "ticket group is no longer available from this seller")

        # available_quantity is authoritative when present. A sold-out group reports
        # available_quantity=0 while `quantity` (the original block size) stays
        # non-zero, so the old `available_quantity or quantity` fallback (0 is falsy)
        # silently admitted reservations against zero sellable inventory. Only fall
        # back to `quantity` when available_quantity is genuinely absent (None).
        _aq = match.get("available_quantity")
        avail = int(_aq if _aq is not None else (match.get("quantity") or 0))
        splits = match.get("splits") or []
        if quantity > avail:
            raise HTTPException(409, f"requested {quantity} but only {avail} available")
        if splits and quantity not in splits:
            raise HTTPException(409, f"this listing only sells in quantities of {splits}")

        unit = float(match.get("retail_price") or 0)
        return {
            "ok": True,
            "purchase_enabled": False,
            "message": "MVP demo — no charge processed. This is what a real purchase confirmation would look like.",
            "reservation": {
                "event_id": event_id,
                "ticket_group_id": ticket_group_id,
                "section": match.get("section"),
                "row": match.get("row"),
                "quantity": quantity,
                "unit_price": unit,
                "subtotal": round(unit * quantity, 2),
                "format": match.get("format"),
                "in_hand": match.get("in_hand"),
            },
        }

    # --- Storefront discovery surface — search / movers / home / near. Lifted
    # from server.py (BR-CODE-1); the in-process caches + the heavy helpers
    # (`_search_*`, `_attach_owned_metadata`, `_refresh_movers`, `_compute_movers`)
    # stay in server.py, resolved via getters so the route tests' monkeypatch
    # (app._search_cache / app._movers_cache / app.client / …) keeps binding. ---

    @router.get("/api/store/search")
    def store_search(
        q: str = Query(..., max_length=200, description="Search term; max 200 chars to prevent multi-MB DoS payloads"),
        limit: int = 8,
    ):
        """Live storefront search. Hits TEvo /v9/searches/suggestions in live
        mode (and cross-joins our SQL for we_own/from_price tagging), or
        ILIKE-searches our tables when STOREFRONT_SQL_ONLY=true.

        Returns three buckets the dropdown UI renders separately:
          events:     [ { id, name, venue_name, location, occurs_at, we_own,
                          from_price, owned_tix } ]
          performers: [ { id, name, location, venue_name?, league? } ]
          venues:     [ { id, name, location } ]

        Cached per-q for 60s in process memory so a typist's stream of
        keystrokes doesn't burn TEvo quota.
        """
        q_norm = (q or "").strip()
        if not q_norm:
            return {"q": "", "players": [], "events": [], "performers": [], "venues": [],
                    "source": "empty", "latency_ms": 0}

        # Cap at 50; the upstream cap is 20, so anything past that just trims.
        lim = max(1, min(int(limit), 50))
        # Cache key segregates by which path actually ran. Matches the routing
        # decision below so a STOREFRONT_SEARCH_SQL_ONLY flip doesn't serve stale
        # cross-mode entries.
        sql_only = get_storefront_sql_only()
        search_sql_only = get_storefront_search_sql_only()
        _search_path = "sql" if (sql_only or search_sql_only) else "live"
        cache_key = f"{normalize_search_key(q_norm)}|{lim}|{_search_path}"
        cached = get_search_cache_get()(cache_key)
        if cached is not None:
            return {**cached, "q": q_norm, "source": "cache", "latency_ms": 0}

        t0 = time.time()
        db = get_require_sb()()
        # Routing: STOREFRONT_SEARCH_SQL_ONLY (default true) takes search to the
        # SQL path. STOREFRONT_SQL_ONLY=true wins regardless (legacy unified flag).
        if sql_only or search_sql_only:
            payload = get_search_sql_only()(db, q_norm, lim)
        else:
            payload = get_search_live()(db, q_norm, lim)

        # Sports player layer (mode-agnostic): "messi"/"lebron" → their team's
        # upcoming events. Independent of the events/performers/venues path so it
        # works under both SQL and live modes; cached as part of payload below.
        payload["players"] = get_search_players()(db, q_norm, lim)

        elapsed_ms = int((time.time() - t0) * 1000)
        payload["q"] = q_norm
        payload["latency_ms"] = elapsed_ms
        get_search_cache_put()(cache_key, payload)
        return payload

    @router.get("/api/store/movers")
    def store_movers(
        background_tasks: BackgroundTasks,
        city: str = "NYC",
        days: int = 21,
        limit: int = 8,
    ):
        """Homepage "moving fast" strip — owned-inventory events in a target
        city sorted by 24h ticket-velocity (most negative tickets_delta first).

        Only one city supported today (`city=NYC`). Stale-while-revalidate
        cached: the bare compute hits ~1s warm but velocity data refreshes only
        hourly, so a 5-min cache collapses the homescreen response to a dict
        lookup on every request past the first per (city, days, limit) tuple.
        Fresh hits return instantly; stale hits return cached AND schedule a
        background recompute; cold hits compute synchronously.
        """
        cap = max(1, min(int(limit), 24))
        day_cap = max(1, min(int(days), 90))
        key = movers_cache_key(city, day_cap, cap)
        now = time.time()
        movers_cache = get_movers_cache()
        cached = movers_cache.get(key)

        if cached:
            age = now - cached[0]
            if age < get_movers_cache_ttl():
                # FRESH: serve immediately, no compute.
                return cached[1]
            # STALE: serve old payload + schedule a background recompute so the
            # NEXT request gets fresh data. Guard against duplicate fans for the
            # same key under concurrent requests.
            refreshing = get_movers_refreshing()
            if key not in refreshing:
                refreshing.add(key)
                background_tasks.add_task(get_refresh_movers(), city, day_cap, cap, key)
            return cached[1]

        # COLD: never-seen key. Compute synchronously, cache, return.
        fresh = get_compute_movers()(get_require_sb()(), city, day_cap, cap)
        movers_cache[key] = (now, fresh)
        return fresh

    @router.get("/api/store/home")
    def store_home(
        limit: int = 60,
        city: str = "",
    ):
        """Homepage "first paint" endpoint — owned + active future events
        served entirely from SQL (no TEvo round-trip).

        Joins `latest_event_metrics` (retail_min, owned counts, captured_at)
        with `events` (metadata), `event_lifecycle` (drop ghost/cancelled), and
        `performer_metadata` (logos/colors). Response shape mirrors
        /api/store/events so the client renderer is interchangeable. Velocity
        signals (selling_fast/demand_rising) live on /api/store/movers; this
        grid serves premium-first in <50ms.

        `city=NYC` (optional) restricts to NYC-area venues. Empty means national.
        """
        db = get_require_sb()()
        cap = max(1, min(int(limit), 100))
        city_norm = (city or "").upper().strip()

        # Pull owned-future LEM rows through the shared DB circuit breaker
        # (production-readiness P1 #4): a Supabase blip fast-fails to an empty
        # grid (sentinel None) instead of hanging the homepage; after repeated
        # failures the breaker opens and skips the call entirely.
        def _read_lem():
            return (db.table("latest_event_metrics")
                      .select("event_id,owned_tickets_count,owned_groups_count,"
                              "retail_min,retail_median,retail_p25,retail_p75,"
                              "getin_price,captured_at,tickets_count")
                      .gt("owned_tickets_count", 0)
                      .limit(1000)
                      .execute().data) or []

        lem_rows = get_safe_read()(
            _read_lem, None,
            on_error=lambda e: _log.warning(f"[store_home] LEM query failed: {e!r}"),
        )
        if lem_rows is None:
            # Conservative fallback so the homepage never breaks on a transient
            # matview read error (or an open breaker).
            return {"count": 0, "events": [], "source": "sql"}

        if not lem_rows:
            return {"count": 0, "events": [], "limit": cap, "source": "sql"}

        ev_ids = [int(r["event_id"]) for r in lem_rows if r.get("event_id")]
        lem_by_id = {int(r["event_id"]): r for r in lem_rows if r.get("event_id")}

        # Events (future only). Two-query merge — PostgREST view-to-table FK
        # inference has been flaky on rebuilds. tbd is derived from the event
        # name string via is_tbd() (no SQL column).
        today_iso = datetime.now(timezone.utc).date().isoformat()
        try:
            ev_rows = (db.table("events")
                         .select("id,name,occurs_at_local,venue_id,venue_name,"
                                 "venue_location,primary_performer_id,"
                                 "primary_performer_name,performer_ids")
                         .in_("id", ev_ids)
                         .gte("occurs_at_local", today_iso)
                         .limit(1000)
                         .execute().data) or []
        except Exception as e:
            _log.warning(f"[store_home] events query failed: {e!r}")
            return {"count": 0, "events": [], "source": "sql"}

        events_by_id = {int(e["id"]): e for e in ev_rows if e.get("id")}

        # Drop CANCELLED-name rows (TEvo bakes the marker into the event name).
        events_by_id = {
            k: v for k, v in events_by_id.items()
            if not is_speculative_event_name(v.get("name"))
        }

        # Active-only via event_lifecycle.
        if events_by_id:
            try:
                lc = (db.table("event_lifecycle")
                        .select("event_id,is_active")
                        .in_("event_id", list(events_by_id.keys()))
                        .execute().data) or []
                inactive = {int(r["event_id"]) for r in lc if not r.get("is_active")}
            except Exception:
                inactive = set()
            events_by_id = {k: v for k, v in events_by_id.items() if k not in inactive}

        # Optional city filter. NYC-area substring match.
        if city_norm in ("NYC", "NEW YORK", "NEW YORK CITY"):
            nyc_substrings = ("new york", "brooklyn", "bronx", "queens",
                              "manhattan", "flushing")
            events_by_id = {
                k: v for k, v in events_by_id.items()
                if any(s in (v.get("venue_location") or "").lower() for s in nyc_substrings)
                or ", NY" in (v.get("venue_location") or "")
            }

        if not events_by_id:
            return {"count": 0, "events": [], "limit": cap, "source": "sql"}

        # Bulk performer assets for card branding (logo + brand color), home +
        # away so cards can render matchup branding.
        perf_ids_set: set[int] = set()
        for evt in events_by_id.values():
            pp = evt.get("primary_performer_id")
            if pp:
                try: perf_ids_set.add(int(pp))
                except (TypeError, ValueError): pass
            for raw_pid in (evt.get("performer_ids") or []):
                try: perf_ids_set.add(int(raw_pid))
                except (TypeError, ValueError): pass
        perf_assets = get_bulk_performer_assets()(db, list(perf_ids_set)) if perf_ids_set else {}

        # Build cards. Schema mirrors /api/store/events for renderer reuse, plus
        # `from_price` + `owned_tickets_count` + `signal` actually populated.
        cards: list[dict] = []
        for eid, ev in events_by_id.items():
            lem = lem_by_id.get(eid, {})
            perf_id = ev.get("primary_performer_id")
            try:
                primary_pid = int(perf_id) if perf_id else None
            except (TypeError, ValueError):
                primary_pid = None
            assets = perf_assets.get(primary_pid) if primary_pid else None
            # Away-team assets — first performer in array that's NOT the home
            # team. Null when array has only the primary (playoff placeholders).
            away_pid: int | None = None
            for raw_pid in (ev.get("performer_ids") or []):
                try:
                    pid_int = int(raw_pid)
                except (TypeError, ValueError):
                    continue
                if primary_pid is not None and pid_int == primary_pid:
                    continue
                away_pid = pid_int
                break
            away_assets = perf_assets.get(away_pid) if away_pid else None

            try:
                rm = float(lem.get("retail_min")) if lem.get("retail_min") is not None else None
            except (TypeError, ValueError):
                rm = None

            # Signal classification — premium only (price >= $500). The
            # selling_fast / demand_rising signals require velocity data and
            # live on /api/store/movers instead.
            signal: str | None = "premium" if (rm is not None and rm >= 500.0) else None

            cards.append({
                "id": eid,
                "name": ev.get("name"),
                "occurs_at_local": ev.get("occurs_at_local"),
                "venue_name": ev.get("venue_name"),
                "venue_location": ev.get("venue_location"),
                "primary_performer_name": ev.get("primary_performer_name"),
                "primary_performer_id": perf_id,
                "primary_performer_logo": (assets or {}).get("logo_default_url"),
                "primary_performer_color": (assets or {}).get("color_primary"),
                "primary_performer_league": (assets or {}).get("espn_league"),
                "away_performer_id":    away_pid,
                "away_performer_name":  (away_assets or {}).get("name"),
                "away_performer_logo":  (away_assets or {}).get("logo_default_url"),
                "away_performer_color": (away_assets or {}).get("color_primary"),
                "available_count": lem.get("tickets_count"),
                "we_own": True,
                "tbd": is_tbd(ev.get("name")),
                "from_price": rm,
                "retail_median": lem.get("retail_median"),
                "owned_tickets_count": lem.get("owned_tickets_count"),
                "owned_groups_count": lem.get("owned_groups_count"),
                "captured_at": lem.get("captured_at"),
                "tix_d24h": None,
                "getin_d24h_pct": None,
                "signal": signal,
                "rivalry": None,
                "mlb_series": None,
                "tournament": None,
                "weather": None,
                "holiday": None,
                "playoff": None,
            })

        # Curation sort: premium first, then by date asc.
        def _home_sort_key(c):
            rank = 0 if c.get("signal") == "premium" else 1
            return (rank, c.get("occurs_at_local") or "9999")

        cards.sort(key=_home_sort_key)
        cards = cards[:cap]

        return {
            "count": len(cards),
            "events": cards,
            "limit": cap,
            "city": city_norm or None,
            "source": "sql",
        }

    @router.get("/api/store/events")
    def store_events(
        q: str | None = None,
        performer_id: int | None = None,
        venue_id: int | None = None,
        limit: int = 60,
        offset: int = 0,
        include_inactive: bool = False,
    ):
        """Catalog: upcoming events our brokerage office has inventory for.

        Pulled directly from TEvo /v9/events with office_id=TEVO_OFFICE_ID,
        which is TEvo's native server-side filter for "events MY office has
        listings on". 100% we_own — there is no "browse market" fallthrough.

        Performer media (logos + brand colors) is bulk-enriched from Supabase
        performer_metadata. That's the only Supabase touch on this route —
        the events themselves come from TEvo. Rest of the prior badge
        enrichments (rivalry / MLB-series / tournament / weather / holiday /
        playoff) stay nullable for now; they get re-layered after the prod
        checkpoint.

        Pagination: TEvo caps per_page at 100; this handler pages through
        enough TEvo pages to fill the requested `limit` (max 500 → up to
        5 TEvo calls).

        Args mirror the prior shape so the front-end + share-link routes
        don't need to change. `include_inactive` is kept as a no-op for
        callsite compatibility (CANCELLED markers are still filtered by
        name string in case TEvo leaks them through the office filter).
        """
        client = get_client()
        if client is None:
            # SQL-only demo mode boots without TEvo. MVP catalog requires it.
            raise HTTPException(503, "TEvo client not configured")

        cap = min(max(limit, 1), 500)
        # offset → TEvo page index. TEvo paginates 1-based.
        per_page = min(cap, 100)
        # Cap offset to prevent absurd values from triggering a 502 on impossible
        # page lookups (TEvo doesn't paginate beyond what its catalog holds —
        # office-filtered catalog is ~3-4k events at peak, so 5000 is a safe
        # upper bound that catches malicious/bug values like ?offset=999999).
        offset = min(max(offset, 0), 5000)
        start_page = (offset // per_page) + 1
        # When offset is NOT a multiple of per_page, we land mid-page and have to
        # slice the leading rows off the first fetched page. Account for that in
        # pages_needed so the post-slice list still contains `cap` rows.
        offset_in_first_page = offset % per_page
        pages_needed = ((offset_in_first_page + cap) + per_page - 1) // per_page

        today_iso = datetime.now(timezone.utc).date().isoformat()

        raw_events: list[dict] = []
        try:
            for p in range(start_page, start_page + pages_needed):
                # office_id=TEVO_OFFICE_ID filters TEvo to ONLY events our office
                # has inventory for. Verified 100% we_own match in probe v2.
                # `office_id` goes through evo_client.list_events's **extra
                # kwarg so it reaches the request as-is.
                resp = client.list_events(
                    q=q or None,
                    performer_id=performer_id,
                    venue_id=venue_id,
                    occurs_at_gte=today_iso,
                    only_with_available_tickets=True,
                    order_by="events.occurs_at ASC",
                    per_page=per_page,
                    page=p,
                    **{"office_id": get_tevo_office_id()},
                )
                batch = resp.get("events", []) or []
                if not batch:
                    break
                raw_events.extend(batch)
                # Stop when we have enough rows to fill the requested window AFTER
                # slicing off the leading offset_in_first_page rows. Using `>= cap`
                # alone short-circuits the loop before the second page when offset
                # is non-aligned (e.g. offset=25, cap=60: page-1 fills 60 rows,
                # break fires, slice yields only 35). Caught by test_pagination_
                # offset_non_aligned.
                if len(raw_events) >= offset_in_first_page + cap:
                    break
                # Stop early if we've hit the total.
                total = int(resp.get("total_entries") or 0)
                if total and len(raw_events) >= total:
                    break
        except RuntimeError as e:
            # Log full upstream error server-side; return a stable string so TEvo's
            # response text (URLs, partial tokens, internal IDs from the requests
            # exception) never reaches the public storefront.
            _log.warning(f"[store_events] TEvo events fetch failed: {e!r}")
            raise HTTPException(502, "events fetch failed")

        # TEvo bakes CANCELLED markers into the event name string.
        raw_events = [
            e for e in raw_events
            if "CANCELLED" not in (e.get("name") or "").upper()
        ]
        # Slice from the offset-in-first-page so callers requesting a non-multiple
        # offset get the records they asked for (vs records starting at the page
        # boundary).
        raw_events = raw_events[offset_in_first_page : offset_in_first_page + cap]

        # ---- Bulk-fetch performer media from Supabase performer_metadata ----
        # Single SQL roundtrip pulls logo + color for every performer that
        # appears on the catalog page. The TEvo /v9/events response only
        # carries performer id + name — logos and ESPN team data live in our
        # SQL enrichment table (populated by the crawl-venues-and-performers
        # collector). This is the only Supabase touch on the catalog.
        perf_ids: set[int] = set()
        for ev in raw_events:
            for perf in (ev.get("performances") or []):
                pid = (perf.get("performer") or {}).get("id")
                if pid:
                    # Guard the coercion: a non-numeric performer id must not 500 the
                    # whole catalog. The per-card loop below already tolerates bad
                    # ids (try/except → None); mirror that here so the gather step
                    # can't crash first on the same data.
                    try:
                        perf_ids.add(int(pid))
                    except (TypeError, ValueError):
                        pass
        perf_assets: dict[int, dict] = {}
        if perf_ids:
            try:
                db = get_require_sb()()
                perf_assets = get_bulk_performer_assets()(db, list(perf_ids))
            except Exception as e:
                # Don't break the catalog if performer_metadata is unavailable;
                # cards just render without logos/colors.
                _log.warning(f"performer_metadata bulk-fetch failed: {e}")
                perf_assets = {}

        out: list[dict] = []
        for ev in raw_events:
            venue = ev.get("venue") or {}
            # TEvo venue shape: {id, name, slug, location, time_zone,
            #   city, state, country, ...}. `location` is "City, ST" string
            #   on most events; fall back to city/state if absent.
            venue_loc = venue.get("location")
            if not venue_loc:
                city = venue.get("city") or ""
                state = venue.get("state") or ""
                venue_loc = f"{city}, {state}".strip(", ") or None

            # /v9/events list response uses `performances`, NOT `performers`
            # (that's the /v9/events/:id show shape). Each performance nests
            # a `performer: {id, name}` object plus a `primary` boolean.
            performances = ev.get("performances") or []
            primary_perf = (
                next((p for p in performances if p.get("primary")), None)
                or (performances[0] if performances else {})
            )
            performer = (primary_perf or {}).get("performer") or {}

            # owned_by_office is TEvo's native we-own signal — true when our
            # token's brokerage office has inventory listed for this event.
            # With office_id filter applied to /v9/events, this is always
            # true; kept on the response shape for forward-compat.
            we_own = bool(ev.get("owned_by_office"))

            # Performer media: logo + brand color from Supabase performer_metadata.
            # Falls back to None on either side if the performer isn't seeded.
            perf_id = performer.get("id")
            try:
                primary_pid = int(perf_id) if perf_id else None
            except (TypeError, ValueError):
                primary_pid = None
            assets = perf_assets.get(primary_pid) if primary_pid else None
            # Away-team assets — first non-primary performance in the array.
            # 2026-05-19: "populate all store events with team assets where
            # available". Sports matchups: TEvo emits both teams as separate
            # performances. Playoff placeholders may carry only home.
            away_pid: int | None = None
            away_name: str | None = None
            for p in performances:
                pf = (p or {}).get("performer") or {}
                pid_raw = pf.get("id")
                try:
                    pid_int = int(pid_raw) if pid_raw else None
                except (TypeError, ValueError):
                    pid_int = None
                if pid_int is None or pid_int == primary_pid:
                    continue
                away_pid = pid_int
                away_name = pf.get("name")
                break
            away_assets = perf_assets.get(away_pid) if away_pid else None

            out.append({
                "id": ev.get("id"),
                "name": ev.get("name"),
                # occurs_at_local has the real local offset; occurs_at is the
                # misleading "Z"-suffixed local time. Prefer _local.
                "occurs_at_local": ev.get("occurs_at_local") or ev.get("occurs_at"),
                "venue_name": venue.get("name"),
                "venue_location": venue_loc,
                "primary_performer_name": performer.get("name"),
                "primary_performer_id": perf_id,
                "primary_performer_logo": (assets or {}).get("logo_default_url"),
                "primary_performer_color": (assets or {}).get("color_primary"),
                "primary_performer_league": (assets or {}).get("espn_league"),
                # Away-team assets — populated when matchup data + metadata
                # both available. FE renders both logos for sports cards.
                "away_performer_id":    away_pid,
                "away_performer_name":  away_name,
                "away_performer_logo":  (away_assets or {}).get("logo_default_url"),
                "away_performer_color": (away_assets or {}).get("color_primary"),
                # available_count is deprecated for authoritative pricing but
                # is fine as a "tickets available" indicator on cards (the
                # detail page uses /v9/events/:id/stats for exact numbers).
                "available_count": ev.get("available_count"),
                "we_own": we_own,
                "tbd": bool(ev.get("tbd")),
                "popularity_score": ev.get("popularity_score"),
                # from_price + owned_tickets_count still need a per-event call
                # so stay null on the catalog payload; revealed on click-through.
                "from_price": None,
                "owned_tickets_count": None,
                "owned_groups_count": None,
                "captured_at": None,
                # Other badge enrichments (rivalry / series / weather / holiday
                # / playoff) — re-layer in a follow-up after the prod checkpoint.
                "rivalry": None,
                "mlb_series": None,
                "tournament": None,
                "weather": None,
                "holiday": None,
                "playoff": None,
            })

        return {"count": len(out), "events": out, "limit": cap, "offset": offset}

    return router
