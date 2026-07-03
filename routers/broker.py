"""Broker terminal routes (D0 surface) — the SIMPLE, helper-free subset.

Slice 11 of the app.py decomposition (BR-CODE-1). Only the trivially-decoupled
broker routes move here for now: /leagues (static), /performer/{id}/assets (one
table read), /event/{id}/espn (server-side edge-fn proxy). The helper-heavy
broker routes (overview / movers / chart-data / zones / …) stay in app.py until
their shared helpers (_bulk_event_context / _compute_movers / _delta / …) are
extracted to core/.

Factory takes getters for the live require_sb + the SUPABASE url/key (so the
espn route's monkeypatch tests keep working) + require_auth + the static
ESPN-league list. requests is the shared module (patched globally by tests).
"""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

import requests
from fastapi import APIRouter, Depends, HTTPException

from core.concurrency import run_parallel
from core.helpers import clean_section, delta, listings_cadence_seconds
from core.substitutions import find_row_substitutions, find_section_substitutions

# Auto-hide parking/garage/hospitality zones unless the caller opts in. Names
# like "Parking East", "Garage A", "Premium Parking", "Hospitality Tent".
_PARKING_ZONE_RE = re.compile(r"\b(parking|garage|valet|lot|hospitality|premium\s*park)\b", re.IGNORECASE)
_PARKING_SECTION_RE = re.compile(r"\b(parking|garage|valet|lot|hospitality|premium\s*park|prepaid|preferred\s*parking|guest\s*parking|vip\s*lot|vip\s*parking)\b", re.IGNORECASE)


def _batch_fallback_zones(db, pairs: list[tuple]) -> dict[tuple, str | None]:
    """Resolve derive_zone_fallback for many (section, row) pairs in one RPC.

    Returns a {(section, row): zone-or-None} map. Tries the batch RPC
    (derive_zone_fallback_batch, one round-trip); if it is unavailable (not yet
    applied) or errors, degrades to the legacy per-pair scalar RPC so the result
    is identical either way. A per-pair RPC error maps that pair to None
    (unmapped), matching the old in-loop `except`.
    """
    if not pairs:
        return {}
    payload = [{"section": section, "row": row} for section, row in pairs]
    try:
        rows = db.rpc("derive_zone_fallback_batch", {"p_pairs": payload}).execute().data
        # On success the RPC returns exactly one row per input pair; an empty
        # list means the function is absent (Fake/PostgREST shape) → degrade.
        if isinstance(rows, list) and rows:
            return {(r.get("section"), r.get("row")): r.get("zone") for r in rows}
    except Exception:
        pass
    out: dict[tuple, str | None] = {}
    for section, row in pairs:
        try:
            res = db.rpc("derive_zone_fallback", {"p_section": section, "p_row": row}).execute().data
            out[(section, row)] = res if isinstance(res, str) else None
        except Exception:
            out[(section, row)] = None
    return out


def _broadway_participants(db, slug: str) -> list:
    """Full lead roster for a Broadway show (broadway_cast_run) merged with priced
    aggregates (v_broadway_performer_getin): uncovered leads come back
    measured=false ('awaiting coverage'). Shared by the event- and
    performer-scoped Broadway cast routes so both feed the same panel/renderer."""
    runs = (db.table("broadway_cast_run")
              .select("performer_name,role,engagement_seq,run_start,run_end,"
                      "is_final_confirmed,confidence,source_name")
              .eq("show_slug", slug).order("run_end").execute().data or [])
    priced = (db.table("v_broadway_performer_getin")
                .select("*").eq("show_slug", slug).execute().data or [])
    pmap = {(p.get("performer_name"), p.get("engagement_seq")): p for p in priced}
    out = []
    for r in runs:
        p = pmap.get((r.get("performer_name"), r.get("engagement_seq"))) or {}
        out.append({
            "name": r.get("performer_name"), "role": r.get("role"),
            "window_start": r.get("run_start"), "window_end": r.get("run_end"),
            "is_final_confirmed": r.get("is_final_confirmed"),
            "confidence": r.get("confidence"), "source": r.get("source_name"),
            "measured": bool(p),
            "avg_getin": p.get("avg_getin"), "median_getin": p.get("median_getin"),
            "min_getin": p.get("min_getin"), "max_getin": p.get("max_getin"),
            "closing_getin": p.get("closing_night_getin"),
            "perfs_priced": p.get("perfs_priced"), "snapshot_rows": p.get("snapshot_rows"),
        })
    return out


def build_broker_router(
    get_require_sb: Callable[[], Callable],
    require_auth: Callable,
    espn_leagues: list,
    get_supabase_url: Callable[[], str | None],
    get_supabase_anon_key: Callable[[], str | None],
    # Trip-planner delegates (D0 broker twins of the D1 store routes). The
    # payload builders + optimizer stay in server.py (shared with the store
    # routes); getters resolve the live server symbols at request time so the
    # `app._trip_plan_payload` monkeypatch tests bind.
    get_trip_plan_payload: Callable[[], Callable] = lambda: (lambda *a, **k: {}),
    get_tour_package_payload: Callable[[], Callable] = lambda: (lambda *a, **k: {}),
    get_multi_tour_payload: Callable[[], Callable] = lambda: (lambda *a, **k: {}),
    get_discover_payload: Callable[[], Callable] = lambda: (lambda *a, **k: {}),
    # Live TEvo client (read-only GET surface) — resolved at request time so the
    # `app.client` monkeypatch tests bind. Used by the raw-tevo passthrough.
    get_client: Callable[[], Any] = lambda: None,
    # Bulk performer assets (logos/colors) — core/broker_helpers, but tests patch
    # the server alias `app._bulk_performer_assets`, so resolve via getter.
    get_bulk_performer_assets: Callable[[], Callable] = lambda: (lambda *a: {}),
) -> APIRouter:
    router = APIRouter()

    @router.get("/api/broker/leagues")
    def broker_leagues(_=Depends(require_auth)):
        """Static list of ESPN-tracked leagues for the league-browse strip."""
        return {"leagues": espn_leagues}

    @router.get("/api/broker/performer/{performer_id}/assets")
    def broker_performer_assets(performer_id: int, _=Depends(require_auth)):
        """ESPN team logo + colors + URLs for a TEvo performer (performer_metadata).
        Null fields for performers without ESPN mapping."""
        db = get_require_sb()()
        row = (db.table("performer_metadata")
                 .select("performer_id, name, espn_team_id, espn_league, "
                         "color_primary, color_alternate, "
                         "logo_default_url, logo_dark_url, logo_scoreboard_url, logo_4k_primary_url, logo_secondary_url, "
                         "espn_team_url, espn_roster_url, espn_schedule_url, espn_fetched_at")
                 .eq("performer_id", performer_id).limit(1).execute().data or [])
        if row:
            return row[0]
        # Non-ESPN performer (e.g. a Broadway show): no metadata row. Fall back to
        # the performer's name from its events so the hero still renders a title.
        ev = (db.table("events").select("primary_performer_name")
                .eq("primary_performer_id", performer_id).limit(1).execute().data or [])
        nm = ev[0].get("primary_performer_name") if ev else None
        return {"performer_id": performer_id, "name": nm, "logo_default_url": None}

    @router.get("/api/broker/event/{event_id}/espn")
    def broker_event_espn(event_id: int, _=Depends(require_auth)):
        """Tab 2: ESPN aggregated data via the espn edge fn (JWT stays server-side)."""
        supabase_url = get_supabase_url()
        supabase_anon_key = get_supabase_anon_key()
        if not (supabase_url and supabase_anon_key):
            raise HTTPException(500, "espn fn not reachable: missing SUPABASE_URL/SUPABASE_ANON_KEY")
        url = f"{supabase_url}/functions/v1/espn/event/{int(event_id)}"
        try:
            r = requests.get(url, headers={"Authorization": f"Bearer {supabase_anon_key}"}, timeout=15)
            return r.json() if r.ok else {"applicable": False, "error": f"espn fn {r.status_code}"}
        except Exception as e:
            return {"applicable": False, "error": str(e)}

    @router.get("/api/broker/event/{event_id}/cadences")
    def broker_event_cadences(event_id: int, _=Depends(require_auth)):
        """Per-section poll cadence for the page. Each section reads its own
        last_pull_at + cadence_seconds; next poll = last + cadence + jitter."""
        db = get_require_sb()()
        ev = (db.table("events").select("id,occurs_at_local").eq("id", event_id).limit(1).execute().data or [{}])[0]
        listings_cad = listings_cadence_seconds(ev.get("occurs_at_local"))
        last_listings = (
            db.table("event_metrics").select("captured_at")
            .eq("event_id", event_id).order("captured_at", desc=True).limit(1)
            .execute()
        ).data or []
        last_listings_at = last_listings[0]["captured_at"] if last_listings else None
        last_inj = (
            db.table("espn_injuries_snapshots").select("last_seen_at")
            .order("last_seen_at", desc=True).limit(1).execute()
        ).data or []
        last_inj_at = last_inj[0]["last_seen_at"] if last_inj else None
        last_team_snap = (
            db.table("espn_team_snapshots").select("last_seen_at")
            .order("last_seen_at", desc=True).limit(1).execute()
        ).data or []
        last_team_at = last_team_snap[0]["last_seen_at"] if last_team_snap else None
        return {
            "event_id": event_id,
            "sections": {
                "overview":        {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
                "section_metrics": {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
                "raw_tevo":        {"last_pull_at": last_listings_at, "cadence_seconds": listings_cad},
                "espn_injuries":   {"last_pull_at": last_inj_at,      "cadence_seconds": 60 * 10},
                "espn_team":       {"last_pull_at": last_team_at,     "cadence_seconds": 60 * 60 * 24},
            },
        }

    @router.get("/api/broker/event/{event_id}/prediction-markets")
    def broker_event_prediction_markets(event_id: int, _=Depends(require_auth)):
        """Kalshi + Polymarket implied-probability markets matched to this event:
        game moneyline (matched by team + date) plus futures on the event's teams
        (e.g. World Series / champion odds). Public data; served via the SECDEF
        get_event_prediction_markets RPC. Degrades to empty arrays if the pipeline
        migration is not yet applied."""
        db = get_require_sb()()
        empty = {"event_id": event_id, "game_markets": [], "futures": []}
        try:
            res = db.rpc("get_event_prediction_markets", {"p_event_id": event_id}).execute().data
        except Exception as e:
            return {**empty, "error": str(e)}
        return res if isinstance(res, dict) else empty

    @router.get("/api/broker/event/{event_id}/broadway-cast")
    def broker_event_broadway_cast(event_id: int, _=Depends(require_auth)):
        """Broadway 'who's playing the lead' + get-in price per performer for the
        show at this event's venue. Venue-anchored resolution (like broadway_show_ref):
        each Broadway house runs one show at a time. Returns a GENERIC
        participant-getin contract — {kind, subject, metric, participants[]} — so
        ESPN athletes can later feed the SAME panel/renderer under kind='espn'.

        Full lead roster (broadway_cast_run) merged with priced aggregates
        (v_broadway_performer_getin): a lead with no price coverage comes back
        measured=false ('awaiting coverage') rather than dropped. applicable=false
        when the event isn't a tracked Broadway show or the cast pipeline isn't
        applied yet (degrades like the prediction-markets route)."""
        db = get_require_sb()()
        empty = {"event_id": event_id, "applicable": False, "kind": "broadway",
                 "metric": "get_in_usd", "subject": None, "participants": []}
        try:
            ev = (db.table("events").select("id,name,venue_name")
                    .eq("id", event_id).limit(1).execute().data or [])
            if not ev:
                return empty
            venue = (ev[0].get("venue_name") or "").lower()
            name = (ev[0].get("name") or "").lower()
            refs = (db.table("broadway_show_ref")
                      .select("show_slug,title,venue_name_pattern,event_name_pattern")
                      .execute().data or [])
            slug = title = None
            for r in refs:
                vp = (r.get("venue_name_pattern") or "").strip("%").lower()
                if not vp or vp not in venue:
                    continue
                ep = (r.get("event_name_pattern") or "").strip("%").lower()
                if ep and ep not in name:  # optional name guard for shared venues
                    continue
                slug, title = r["show_slug"], r.get("title")
                break
            if not slug:
                return empty
            participants = _broadway_participants(db, slug)
            return {"event_id": event_id, "applicable": bool(participants),
                    "kind": "broadway", "metric": "get_in_usd",
                    "subject": {"slug": slug, "title": title},
                    "participants": participants}
        except Exception as e:
            return {**empty, "error": str(e)}

    @router.get("/api/broker/performer/{performer_id}/broadway-cast")
    def broker_performer_broadway_cast(performer_id: int, _=Depends(require_auth)):
        """Broadway cast get-in for a SHOW-as-performer (resolved via
        broadway_show_ref.tevo_performer_id). Same generic participant contract as
        the event route, so the performer page reuses the same Cast panel.
        applicable=false for a non-Broadway performer / unapplied pipeline."""
        db = get_require_sb()()
        empty = {"performer_id": performer_id, "applicable": False, "kind": "broadway",
                 "metric": "get_in_usd", "subject": None, "participants": []}
        try:
            ref = (db.table("broadway_show_ref").select("show_slug,title")
                     .eq("tevo_performer_id", performer_id).limit(1).execute().data or [])
            if not ref:
                return empty
            slug, title = ref[0]["show_slug"], ref[0].get("title")
            participants = _broadway_participants(db, slug)
            return {"performer_id": performer_id, "applicable": bool(participants),
                    "kind": "broadway", "metric": "get_in_usd",
                    "subject": {"slug": slug, "title": title},
                    "participants": participants}
        except Exception as e:
            return {**empty, "error": str(e)}

    @router.get("/api/broker/performer/{performer_id}/prediction-markets")
    def broker_performer_prediction_markets(performer_id: int, _=Depends(require_auth)):
        """Kalshi + Polymarket markets attributed to a performer (team): its game
        moneylines + season/champion futures. Public data via the SECDEF
        get_performer_prediction_markets RPC; empty when unmatched / not applied."""
        db = get_require_sb()()
        empty = {"performer_id": performer_id, "markets": []}
        try:
            res = db.rpc("get_performer_prediction_markets", {"p_performer_id": performer_id}).execute().data
        except Exception as e:
            return {**empty, "error": str(e)}
        return res if isinstance(res, dict) else empty

    @router.get("/api/broker/macro/{series_id}")
    def broker_macro_series(series_id: str, limit: int = 90, _=Depends(require_auth)):
        """Recent observations for one macro series (TSA_THROUGHPUT, UMCSENT, …)
        from the anon-granted v_macro_indicators_latest view, oldest→newest for
        direct charting. Reads the view (not the email-gated get_macro_series RPC)
        so the service-role terminal client can serve it."""
        db = get_require_sb()()
        lim = max(1, min(int(limit), 600))
        rows = (db.table("v_macro_indicators_latest")
                  .select("observation_date, value")
                  .eq("series_id", series_id)
                  .order("observation_date", desc=True)
                  .limit(lim).execute().data) or []
        rows = list(reversed(rows))
        return {"series_id": series_id, "points": rows, "count": len(rows)}

    @router.get("/api/broker/event/{event_id}/substitutions")
    def broker_event_substitutions(
        event_id: int,
        section: str,
        row: str | None = None,
        quantity: int = 1,
        revenue: float | None = None,
        source: str = "owned",
        fee_pct: float = 0.0,
        _=Depends(require_auth),
    ):
        """Substitution checker — ROW phase.

        Given a ticket we need to cover (its section + row + quantity), find
        same-section substitutes with the same or a better (closer-in) row,
        ranked CHEAPEST-FIRST — over-delivering a better seat than was sold is
        wasted money, so the least-cost acceptable seat wins.

        `source` selects the candidate pool:
          owned  (default) our held inventory — the latest `listings_snapshots`
                 `is_owned=true` rows (TEvo, cost≈list `retail_price`) MERGED
                 with our SeatGeek SellerDirect book (`seatgeek_seller_listings`,
                 real `cost` basis) — a free swap from stock we already hold
          market the rest of the `listings_snapshots` book — a buy-in when we
                 hold no sub
        `revenue` (total $ received for the sale) turns on per-sub P&L so the
        loss/margin of each cover is explicit. Ranking/matching is pure logic in
        core.substitutions; "better SECTION" matching is a deliberate future phase.

        Query params:
          section   (required) the section to cover
          row       the row to cover
          quantity  seats needed; a candidate must have quantity >= this (default 1)
          revenue   total $ received on the sale (optional; enables P&L)
          source    "owned" (default) | "market"
          fee_pct   buy-in buyer-fee % applied to a market ask so P&L reflects
                    landed cost (only used when source="market"; owned swaps
                    are stock we already hold, no purchase fee)
        """
        db = get_require_sb()()
        qty = max(1, int(quantity or 1))
        rev_per_ticket = (revenue / qty) if revenue is not None else None

        latest = (
            db.table("listings_snapshots").select("captured_at")
            .eq("event_id", event_id).order("captured_at", desc=True).limit(1)
            .execute().data or []
        )
        captured_at = latest[0]["captured_at"] if latest else None
        pool: list[dict] = []
        if captured_at is not None:
            ls = (
                db.table("listings_snapshots")
                .select("tevo_ticket_group_id,section,row,quantity,retail_price,is_owned")
                .eq("event_id", event_id).eq("captured_at", captured_at)
                .eq("is_owned", source == "owned")
                .execute().data or []
            )
            for r in ls:
                r["inv_source"] = "tevo_owned" if source == "owned" else "tevo_market"
            pool.extend(ls)

        # Owned pool also spans our SeatGeek SellerDirect book (its own `cost`
        # basis), so a sub we hold there isn't missed as a "buy-in".
        if source == "owned":
            seller_raw = (
                db.table("seatgeek_seller_listings")
                .select("seller_listing_id,section,row,quantity,cost,pulled_at")
                .eq("tevo_event_id", event_id)
                .execute().data or []
            )
            latest_seller: dict = {}
            for r in seller_raw:
                k = r.get("seller_listing_id")
                if k not in latest_seller or (r.get("pulled_at") or "") > (latest_seller[k].get("pulled_at") or ""):
                    latest_seller[k] = r
            for r in latest_seller.values():
                pool.append({
                    "id": r.get("seller_listing_id"),
                    "section": r.get("section"),
                    "row": r.get("row"),
                    "quantity": r.get("quantity"),
                    "cost": r.get("cost"),
                    "inv_source": "sg_seller",
                })

        # Buy-in fees only apply to a market purchase; an owned swap is stock we
        # already hold (no fee).
        eff_fee_pct = fee_pct if source == "market" else 0.0
        result = find_row_substitutions(section, row, qty, pool,
                                        revenue_per_ticket=rev_per_ticket,
                                        fee_pct=eff_fee_pct)

        # Better-SECTION fallback: rank sections by market quality (retail_median
        # per section) and offer cheapest acceptable upgrades from the same pool.
        sm = (
            db.table("section_metrics")
            .select("section,retail_median,is_ancillary,captured_at")
            .eq("event_id", event_id).order("captured_at", desc=True)
            .execute().data or []
        )
        section_quality: dict = {}
        for r in sm:
            if r.get("is_ancillary"):
                continue  # parking/ancillary aren't seating upgrades
            sec = clean_section(r.get("section"))
            if sec and sec not in section_quality and r.get("retail_median") is not None:
                section_quality[sec] = r.get("retail_median")  # latest wins (desc order)
        result["section_subs"] = find_section_substitutions(
            section, qty, pool, section_quality, revenue_per_ticket=rev_per_ticket,
            fee_pct=eff_fee_pct)

        result.update({"captured_at": captured_at, "event_id": event_id,
                       "source": source, "fee_pct": eff_fee_pct})
        return result

    @router.get("/api/broker/order-lookup")
    def broker_order_lookup(order_id: str, source: str | None = None,
                            _=Depends(require_auth)):
        """Resolve one of OUR order numbers to the fields the substitution
        checker needs (event/section/row/quantity/revenue), so a broker can
        paste an order # instead of typing the sold ticket by hand.

        Searches the 4 ingested order sources (seatgeek / tickpick / vivid /
        evo). `source` narrows the search; omit it to try all. StubHub is NOT
        ingested as an order source — those orders won't resolve here, use the
        manual fields. `revenue` is the order's own total/payment (editable in
        the UI). EVO orders use the first line item for section/row and report
        `line_items` so a multi-section order can be flagged.
        """
        db = get_require_sb()()
        oid = (order_id or "").strip()
        if not oid:
            raise HTTPException(400, "order_id required")
        src = ((source or "").strip().lower()) or None

        def payload(source_name, tev, ev_name, section, row, qty, revenue, **extra):
            return {
                "found": True, "source": source_name, "order_id": oid,
                "tevo_event_id": tev, "event_name": ev_name,
                "section": section, "row": row, "quantity": qty,
                "revenue": revenue, **extra,
            }

        if src in (None, "seatgeek"):
            r = (db.table("seatgeek_orders")
                 .select("sg_order_id,tevo_event_id,sg_event_name,sale_section,sale_row,sale_quantity,payment_total,payment_price")
                 .eq("sg_order_id", oid).limit(1).execute().data or [])
            if r:
                o = r[0]
                return payload("seatgeek", o.get("tevo_event_id"), o.get("sg_event_name"),
                               o.get("sale_section"), o.get("sale_row"), o.get("sale_quantity"),
                               o.get("payment_total") if o.get("payment_total") is not None else o.get("payment_price"))

        if src in (None, "tickpick"):
            r = (db.table("tickpick_orders")
                 .select("tp_order_id,tevo_event_id,event_name,section,row,quantity,total")
                 .eq("tp_order_id", oid).limit(1).execute().data or [])
            if r:
                o = r[0]
                return payload("tickpick", o.get("tevo_event_id"), o.get("event_name"),
                               o.get("section"), o.get("row"), o.get("quantity"), o.get("total"))

        if src in (None, "vivid"):
            r = (db.table("vivid_orders")
                 .select("vivid_order_id,tevo_event_id,event_name,section,row,quantity,total")
                 .eq("vivid_order_id", oid).limit(1).execute().data or [])
            if r:
                o = r[0]
                return payload("vivid", o.get("tevo_event_id"), o.get("event_name"),
                               o.get("section"), o.get("row"), o.get("quantity"), o.get("total"))

        if src in (None, "evo"):
            try:
                eoid = int(oid)
            except (TypeError, ValueError):
                eoid = None
            if eoid is not None:
                hdr = (db.table("evo_orders")
                       .select("evo_order_id,tevo_event_id,total,subtotal")
                       .eq("evo_order_id", eoid).limit(1).execute().data or [])
                if hdr:
                    items = (db.table("evo_order_items")
                             .select("ticket_group_section,ticket_group_row,quantity,event_name,event_id")
                             .eq("evo_order_id", eoid).execute().data or [])
                    it = items[0] if items else {}
                    tev = hdr[0].get("tevo_event_id") or it.get("event_id")
                    rev = hdr[0].get("subtotal") if hdr[0].get("subtotal") is not None else hdr[0].get("total")
                    return payload("evo", tev, it.get("event_name"),
                                   it.get("ticket_group_section"), it.get("ticket_group_row"),
                                   it.get("quantity"), rev, line_items=len(items))

        return {"found": False, "order_id": oid, "source": src,
                "note": "no matching order in seatgeek/tickpick/vivid/evo (StubHub orders aren't ingested — enter details manually)"}

    # --- Trip-planner delegates (D0 terminal). Thin auth-gated wrappers over the
    # shared payload builders in server.py — the D0 twins of the D1 store routes
    # (routers/store.py). Optimizer (trip_planner) + payload builders are shared;
    # only the auth gate differs (broker = authed D0, store = public). ---

    @router.get("/api/broker/performers/{performer_id}/trip-plan")
    def broker_performer_trip_plan(
        performer_id: int,
        home_lat: float,
        home_lon: float,
        budget_km: float = 6000.0,
        home_name: str = "Home",
        days: int = 365,
        max_events: int | None = None,
        budget_usd: float | None = None,
        qty: int = 1,
        _=Depends(require_auth),
    ):
        """D0 terminal: optimal trip around a touring performer's upcoming concert dates.

        Given a home location + travel budget (and optional ticket-spend budget + tickets/show),
        returns the maximum-value itinerary plus the sort-by-date baseline for comparison.
        """
        return get_trip_plan_payload()(performer_id, home_lat, home_lon, budget_km,
                                       home_name, days, max_events, budget_usd, qty)

    @router.get("/api/broker/performers/{performer_id}/tour-package")
    def broker_performer_tour_package(
        performer_id: int,
        home_lat: float,
        home_lon: float,
        qty: int = 3,
        budget_km: float = 8000.0,
        home_name: str = "Home",
        days: int = 365,
        budget_usd: float | None = None,
        side: str = "auto",
        clear_at: float = 0.15,
        away_margin: float = 0.18,
        section_like: str | None = None,
        prefer_owned: bool = False,
        _=Depends(require_auth),
    ):
        """D0: retail 'tour with the artist' package — routed multi-city tour priced via the
        dual-mode model (owned-splits for concerts, market-sourced for a team's away games)."""
        return get_tour_package_payload()(performer_id, home_lat, home_lon, qty, budget_km, home_name,
                                          days, budget_usd, side, clear_at, away_margin,
                                          section_like, prefer_owned)

    @router.get("/api/broker/tours/multi")
    def broker_multi_tour(
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
        _=Depends(require_auth),
    ):
        """D0 'plan my summer' — one package across several performers (comma-separated ids)."""
        return get_multi_tour_payload()(performer_ids, home_lat, home_lon, qty, budget_km, home_name,
                                        days, budget_usd, side, clear_at, away_margin,
                                        section_like, prefer_owned)

    @router.get("/api/broker/tours/near")
    def broker_tours_near(
        home_lat: float,
        home_lon: float,
        within_mi: float = 250.0,
        days: int = 120,
        min_shows: int = 2,
        concerts_only: bool = False,
        _=Depends(require_auth),
    ):
        """D0 reverse discovery — performers with >= min_shows within `within_mi` of home."""
        return get_discover_payload()(home_lat, home_lon, within_mi, days, min_shows, concerts_only)

    # --- Standalone DB-read broker routes (news / by-league / raw-tevo). No
    # in-server helper coupling — just require_sb (+ the live TEvo client for the
    # raw-tevo read-through), resolved via getters so the route tests bind. ---

    @router.get("/api/broker/news")
    def broker_news(
        limit: int = 20,
        league: str | None = None,
        team_ids: str | None = None,
        event_id: int | None = None,
        _=Depends(require_auth),
    ):
        """Recent ESPN news. Modes:
          - no filter         → global feed (home view).
          - league=NBA        → single league.
          - team_ids=20,18    → comma-separated espn_team_ids (event level page).
          - event_id=N        → resolves event_xref → home/away ESPN team_ids and
                                scopes news to those two teams + their league.
        """
        limit = max(1, min(int(limit), 100))
        db = get_require_sb()()

        resolved_teams: list[str] = []
        resolved_league: str | None = league

        if event_id is not None and not team_ids:
            xref = (db.table("event_xref")
                      .select("espn_event_id, espn_league")
                      .eq("tevo_event_id", event_id).limit(1).execute().data or [])
            if xref:
                resolved_league = xref[0]["espn_league"]
                snap = (db.table("espn_event_snapshots")
                          .select("home_team_id, away_team_id")
                          .eq("espn_event_id", xref[0]["espn_event_id"])
                          .order("captured_at", desc=True).limit(1).execute().data or [])
                if snap:
                    for k in ("home_team_id", "away_team_id"):
                        v = snap[0].get(k)
                        if v: resolved_teams.append(str(v))
        elif team_ids:
            resolved_teams = [t.strip() for t in team_ids.split(",") if t.strip()]

        q = (db.table("espn_news")
               .select("headline, description, url, published_at, type, espn_team_id, espn_league")
               .order("published_at", desc=True).limit(limit))
        if resolved_league:
            q = q.eq("espn_league", resolved_league)
        if resolved_teams:
            q = q.in_("espn_team_id", resolved_teams)
        rows = q.execute().data or []

        return {
            "count": len(rows),
            "items": rows,
            "filter": {"league": resolved_league, "team_ids": resolved_teams, "event_id": event_id},
        }

    @router.get("/api/broker/performers/by-league/{league}")
    def broker_performers_by_league(league: str, include_inactive: bool = False, _=Depends(require_auth)):
        """Per-team HOME/ROAD price metrics for ESPN-tracked teams in a league.
        Backed by the get_performers_by_league SQL RPC (mig 20260508050000).

        Returns: { league, count, performers: [
            { performer_id, performer_name, home_venue_id, home_venue_name,
              home: { events, market_med, owned_med, market_tix, owned_tix, first_event, last_event },
              road: { events, market_med, owned_med, market_tix, owned_tix, first_event, last_event } },
            ...
        ] }

        `include_inactive`: passthrough flag. The underlying SQL RPC currently
        aggregates over ALL events (including ghost playoff brackets where the
        team was eliminated). NEXT (code) — update get_performers_by_league
        to JOIN against event_lifecycle and exclude is_active=false rows when
        include_inactive=false. Until that lands, the response field
        `_inactive_filter_applied` reports false so the frontend can flag it.
        """
        db = get_require_sb()()
        rows = db.rpc("get_performers_by_league", {"p_league": league}).execute().data or []

        def _delta_pct(cur, prev):
            if cur is None or prev is None: return None
            try:
                c = float(cur); p = float(prev)
            except (TypeError, ValueError):
                return None
            if p == 0: return None
            return round((c - p) / p * 100, 2)

        performers = [
            {
                "performer_id":    r.get("performer_id"),
                "performer_name":  r.get("performer_name"),
                "league":          r.get("league"),
                "home_venue_id":   r.get("home_venue_id"),
                "home_venue_name": r.get("home_venue_name"),
                "home": {
                    "events":          r.get("home_events") or 0,
                    "market_med":      r.get("home_market_med"),
                    "owned_med":       r.get("home_owned_med"),
                    "market_tix":      r.get("home_market_tix") or 0,
                    "owned_tix":       r.get("home_owned_tix")  or 0,
                    "first_event":     r.get("home_first_event"),
                    "last_event":      r.get("home_last_event"),
                    "prev_market_med": r.get("home_prev_market_med"),
                    "prev_owned_med":  r.get("home_prev_owned_med"),
                    "delta_market_pct": _delta_pct(r.get("home_market_med"), r.get("home_prev_market_med")),
                    "delta_owned_pct":  _delta_pct(r.get("home_owned_med"),  r.get("home_prev_owned_med")),
                },
                "road": {
                    "events":          r.get("road_events") or 0,
                    "market_med":      r.get("road_market_med"),
                    "owned_med":       r.get("road_owned_med"),
                    "market_tix":      r.get("road_market_tix") or 0,
                    "owned_tix":       r.get("road_owned_tix")  or 0,
                    "first_event":     r.get("road_first_event"),
                    "last_event":      r.get("road_last_event"),
                    "prev_market_med": r.get("road_prev_market_med"),
                    "prev_owned_med":  r.get("road_prev_owned_med"),
                    "delta_market_pct": _delta_pct(r.get("road_market_med"), r.get("road_prev_market_med")),
                    "delta_owned_pct":  _delta_pct(r.get("road_owned_med"),  r.get("road_prev_owned_med")),
                },
            }
            for r in rows
        ]
        return {
            "league": league,
            "count": len(performers),
            "performers": performers,
            "_inactive_filter_applied": False,  # see NEXT in docstring; tracked in KANBAN
            "_include_inactive_param": include_inactive,
        }

    @router.get("/api/broker/event/{event_id}/raw-tevo")
    def broker_event_raw_tevo(event_id: int, force: bool = False, _=Depends(require_auth)):
        """Tab 3: raw TEvo /v9/ticket_groups payload. Reads cowork's
        tevo_ticket_groups_cache (90s TTL); fetches fresh if expired or force=1."""
        db = get_require_sb()()
        if not force:
            cached = db.rpc("get_cached_ticket_groups", {"p_event_id": event_id}).execute().data
            if cached:
                return {"source": "cache", "groups": (cached or {}).get("ticket_groups", []),
                        "captured_at": (cached or {}).get("captured_at")}
        # Cache miss / forced refresh — fetch live
        try:
            live = get_client().get_ticket_groups(event_id)
        except RuntimeError as e:
            raise HTTPException(502, f"TEvo fetch failed: {e}")
        payload = {"ticket_groups": live.get("ticket_groups", []), "captured_at": datetime.now(timezone.utc).isoformat()}
        try:
            db.rpc("put_cached_ticket_groups", {"p_event_id": event_id, "p_payload": payload, "p_ttl_seconds": 90}).execute()
        except Exception:
            pass
        return {"source": "live", "groups": payload["ticket_groups"], "captured_at": payload["captured_at"]}

    # --- More standalone DB-read broker routes (section-metrics / watchlist-movers
    # / orders). require_sb only (+ the pure core delta/cadence helpers); local
    # nested pct/val helpers kept inline as in the original. ---

    @router.get("/api/broker/event/{event_id}/section-metrics")
    def broker_event_section_metrics(event_id: int, _=Depends(require_auth)):
        """Tab 1: section-level metrics with delta vs prior snapshot."""
        db = get_require_sb()()
        rows = (
            db.table("section_metrics")
            .select("captured_at,section,is_ancillary,tickets_count,groups_count,"
                    "retail_min,retail_median,retail_mean,retail_max")
            .eq("event_id", event_id)
            .order("captured_at", desc=True)
            .limit(2000)
            .execute()
        ).data or []
        # Group by section, take the latest two captured_at per section
        by_section: dict[str, list] = {}
        for r in rows:
            by_section.setdefault(r["section"], []).append(r)

        out = []
        last_pull = None
        for section, snaps in by_section.items():
            snaps.sort(key=lambda x: x["captured_at"], reverse=True)
            c = snaps[0]
            p = snaps[1] if len(snaps) >= 2 else {}
            if last_pull is None or c["captured_at"] > last_pull:
                last_pull = c["captured_at"]
            out.append({
                "section": section,
                "is_ancillary": bool(c.get("is_ancillary")),
                "metrics": {k: {"v": c.get(k), "delta": delta(c.get(k), p.get(k))}
                            for k in ["tickets_count", "groups_count",
                                      "retail_min", "retail_median", "retail_mean", "retail_max"]},
            })
        out.sort(key=lambda s: (s["is_ancillary"], s["section"]))

        # Cadence matches event listings cadence
        ev_meta = (db.table("events").select("occurs_at_local").eq("id", event_id).limit(1).execute().data or [{}])[0]
        cadence = listings_cadence_seconds(ev_meta.get("occurs_at_local"))
        return {"sections": out, "last_pull_at": last_pull, "cadence_seconds": cadence}

    @router.get("/api/broker/watchlist-movers")
    def broker_watchlist_movers(
        window_hours: int = 24,
        sort: str = "value",       # "value" → Δ market_val, "pct" → Δ market_pct
        limit: int = 25,
        _=Depends(require_auth),
    ):
        """Watchlisted events ordered by movement. Backs the WATCHLIST panel
        on the Events tab. Same row shape as /api/broker/movers events list,
        so the front-end can render it with shared code.

        Pulls get_event_movers for the window, filters to events present in
        watch_sources, then sorts by either notional Δ value or Δ %.
        """
        window_hours = max(1, min(int(window_hours), 168))
        db = get_require_sb()()

        # 1. Watchlisted event_ids
        watch = (db.table("watch_sources").select("event_id").execute().data or [])
        watch_ids = {int(r["event_id"]) for r in watch if r.get("event_id") is not None}
        if not watch_ids:
            return {"window_hours": window_hours, "sort": sort, "count": 0, "events": []}

        # 2. Latest+prior aggregation via the existing RPC
        rpc_rows = db.rpc("get_event_movers", {"p_window_hours": window_hours}).execute().data or []

        def pct_delta(cur, prev):
            if cur is None or prev is None: return None
            try: c = float(cur); p = float(prev)
            except (TypeError, ValueError): return None
            if p == 0: return None
            return round((c - p) / p * 100, 2)
        def val(price, tix):
            if price is None or tix is None: return None
            try: return float(price) * float(tix)
            except (TypeError, ValueError): return None

        rows = []
        for r in rpc_rows:
            if int(r.get("event_id") or 0) not in watch_ids:
                continue
            cur_market_val  = val(r.get("cur_market_med"),  r.get("cur_market_tix"))
            prev_market_val = val(r.get("prev_market_med"), r.get("prev_market_tix"))
            cur_owned_val   = val(r.get("cur_owned_med"),   r.get("cur_owned_tix"))
            prev_owned_val  = val(r.get("prev_owned_med"),  r.get("prev_owned_tix"))
            rows.append({
                "event_id": r.get("event_id"),
                "name": r.get("name"),
                "venue_id": r.get("venue_id"),
                "venue_name": r.get("venue_name"),
                "occurs_at_local": r.get("occurs_at_local"),
                "latest_at":      r.get("latest_at"),
                "cur_market_med": r.get("cur_market_med"),
                "cur_market_tix": r.get("cur_market_tix"),
                "cur_owned_med":  r.get("cur_owned_med"),
                "cur_owned_tix":  r.get("cur_owned_tix"),
                "cur_owned_share": r.get("cur_owned_share"),  # v3: for "we ARE the market" badge
                "delta_market_pct": pct_delta(r.get("cur_market_med"), r.get("prev_market_med")),
                "delta_owned_pct":  pct_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
                "cur_market_val":  round(cur_market_val,  2) if cur_market_val  is not None else None,
                "cur_owned_val":   round(cur_owned_val,   2) if cur_owned_val   is not None else None,
                "delta_market_val": (None if cur_market_val is None or prev_market_val is None
                                     else round(cur_market_val - prev_market_val, 2)),
                "delta_owned_val":  (None if cur_owned_val is None or prev_owned_val is None
                                     else round(cur_owned_val - prev_owned_val, 2)),
            })

        # Sort: events with no movement signal sink to the bottom
        sort_key = "delta_market_val" if sort == "value" else "delta_market_pct"
        rows_with = [r for r in rows if r.get(sort_key) is not None]
        rows_with.sort(key=lambda r: abs(r[sort_key]), reverse=True)
        rows_without = [r for r in rows if r.get(sort_key) is None]
        out = (rows_with + rows_without)[: max(1, min(int(limit), 100))]

        return {"window_hours": window_hours, "sort": sort, "count": len(out), "events": out}

    @router.get("/api/broker/event/{event_id}/orders")
    def broker_event_orders(event_id: int, _=Depends(require_auth)):
        """Read persisted evo_orders + items for an event. Free, no TEvo call.
        Used by the event-detail page to show pending/accepted/rejected/completed
        counts + the actual order rows.
        """
        db = get_require_sb()()
        items = (
            db.table("evo_order_items")
            .select("evo_order_id,evo_item_id,quantity,price,"
                    "ticket_group_id,ticket_group_section,ticket_group_row,ticket_group_seats,"
                    "eticket_available,eticket_downloaded_at,occurs_at")
            .eq("event_id", event_id).execute()
        ).data or []
        if not items:
            return {"event_id": event_id, "items": [], "orders": [], "summary": None}
        order_ids = list({i["evo_order_id"] for i in items if i.get("evo_order_id")})
        orders = (
            db.table("evo_orders")
            .select("evo_order_id,state,type,fraud_check_status,total,subtotal,refunded,balance,"
                    "buyer_name,seller_name,client_name,evo_created_at,evo_updated_at")
            .in_("evo_order_id", order_ids).execute()
        ).data or []
        state_map = {o["evo_order_id"]: o for o in orders}
        # Summary roll-up
        by_state: dict[str, int] = {}
        tickets_sold = 0
        gross_sold = 0.0
        for it in items:
            oid = it.get("evo_order_id")
            st = (state_map.get(oid) or {}).get("state") or "unknown"
            by_state[st] = by_state.get(st, 0) + 1
            if st in ("accepted", "completed") and it.get("quantity") and it.get("price"):
                tickets_sold += int(it["quantity"])
                gross_sold += float(it["price"]) * int(it["quantity"])
        return {
            "event_id": event_id,
            "items": items,
            "orders": orders,
            "summary": {
                "total_items":     len(items),
                "by_state":        by_state,
                "tickets_sold":    tickets_sold,
                "gross_sold":      round(gross_sold, 2),
                "last_update_at":  max((o.get("evo_updated_at") for o in orders if o.get("evo_updated_at")), default=None),
            },
        }

    @router.get("/api/broker/event/{event_id}/overview")
    def broker_event_overview(event_id: int, _=Depends(require_auth)):
        """Top-left pane: event header + event-level metrics + zone breakdown.
        Returns latest + prior values so the UI can render delta arrows."""
        db = get_require_sb()()

        # These four reads are mutually independent — fan them out concurrently
        # (was four sequential round-trips). Queries are unchanged; results are
        # identical to the sequential path.
        #   1) Event header (cowork's RPC for the rich payload)
        #   2) Latest two event_metrics for delta computation. Pull every column
        #      we collect — frontend slices it into Distribution / Volume /
        #      Wholesale / Market Structure / Owned panels.
        #   3/4) Zone breakdown — owned + market split via cowork's RPC
        detail, em_rows, zones_owned, zones_market = run_parallel([
            lambda: db.rpc("get_broker_event_detail", {"p_event_id": event_id}).execute().data or [],
            lambda: (
                db.table("event_metrics")
                .select(
                    "captured_at,"
                    # Inventory
                    "tickets_count,groups_count,sections_count,median_group_size,"
                    "ancillary_groups,ancillary_tickets,"
                    # Retail price distribution
                    "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,retail_sum,"
                    # Wholesale price distribution
                    "wholesale_min,wholesale_median,wholesale_mean,wholesale_max,"
                    # Market structure / quality
                    # NOTE: bid_ask_proxy was dropped in mig 20260428000001 (always 0 — TEvo
                    # API doesn't expose true wholesale to this token). Don't re-add to the
                    # select or the query 500s.
                    "getin_price,top5_concentration,"
                    "price_dispersion,tail_premium,"
                    # Owned (S4K)
                    "owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
                    # Splits inventory metrics (mig 20260508230000)
                    "splits_min_q,splits_listings_with_singles,splits_listings_with_pairs,"
                    "splits_listings_with_3,splits_listings_with_4plus,splits_listings_no_split,"
                    "splits_pct_pairs,splits_pct_singles"
                )
                .eq("event_id", event_id)
                .order("captured_at", desc=True)
                .limit(2)
                .execute()
            ).data or [],
            lambda: db.rpc("get_event_zones_rollup", {"p_event_id": event_id, "p_owned_only": True}).execute().data or [],
            lambda: db.rpc("get_event_zones_rollup", {"p_event_id": event_id, "p_owned_only": False}).execute().data or [],
        ])
        head = detail[0] if detail else None
        curr = em_rows[0] if len(em_rows) >= 1 else {}
        prev = em_rows[1] if len(em_rows) >= 2 else {}

        metric_keys = [
            # Inventory
            "tickets_count", "groups_count", "sections_count", "median_group_size",
            "ancillary_groups", "ancillary_tickets",
            # Retail distribution
            "retail_min", "retail_p25", "retail_median", "retail_mean", "retail_p75", "retail_p90", "retail_max", "retail_sum",
            # Wholesale distribution
            "wholesale_min", "wholesale_median", "wholesale_mean", "wholesale_max",
            # Market structure
            "getin_price", "top5_concentration",
            "price_dispersion", "tail_premium",
            # Owned
            "owned_groups_count", "owned_tickets_count", "owned_share", "owned_median_retail",
            # Splits inventory
            "splits_min_q", "splits_listings_with_singles", "splits_listings_with_pairs",
            "splits_listings_with_3", "splits_listings_with_4plus", "splits_listings_no_split",
            "splits_pct_pairs", "splits_pct_singles",
        ]
        metrics = {k: {"v": curr.get(k), "delta": delta(curr.get(k), prev.get(k))} for k in metric_keys}

        # (zones_owned / zones_market were fetched above in the parallel fan-out)

        cadence = listings_cadence_seconds(head.get("occurs_at_local") if head else None)
        last_pull = curr.get("captured_at")

        # Attach home + away assets (logos, colors). Resolve teams via:
        # 1) primary_performer_id is "home" (per AGENTS.md performer_home_venues semantics)
        # 2) other performer_ids[] entries are away/opponent
        # If event_xref maps to ESPN, additional team_ids come back from espn_event_snapshots.
        perf_ids: list[int] = []
        if head:
            if head.get("primary_performer_id"):
                perf_ids.append(int(head["primary_performer_id"]))
            for pid in (head.get("performer_ids") or []):
                if pid and pid not in perf_ids:
                    perf_ids.append(int(pid))
        assets_by_id = get_bulk_performer_assets()(db, perf_ids)
        home_perf_id = head.get("primary_performer_id") if head else None
        home_assets = assets_by_id.get(int(home_perf_id)) if home_perf_id else None
        away_assets_list = [assets_by_id.get(int(p)) for p in perf_ids if p != home_perf_id and assets_by_id.get(int(p))]

        # Lifecycle classification — flags ghost playoff games, completed events,
        # postponed/cancelled. Used by the UI to render a status banner and to
        # let movers/league/portfolio surfaces filter ghosts out by default.
        # See migration 20260509050000_event_lifecycle for rule definitions.
        try:
            lc_rows = db.rpc("derive_event_lifecycle", {"p_event_id": event_id}).execute().data or []
            lc = lc_rows[0] if lc_rows else None
        except Exception:
            lc = None

        return {
            "event": head,
            "metrics": metrics,
            "zones": {"owned": zones_owned, "market": zones_market},
            "last_pull_at": last_pull,
            "cadence_seconds": cadence,
            "assets": {
                "home": home_assets,
                "away": away_assets_list[0] if away_assets_list else None,
                "all": list(assets_by_id.values()),
            },
            "lifecycle": lc,
        }

    @router.get("/api/broker/event/{event_id}/section-zones")
    def broker_event_section_zones(event_id: int, _=Depends(require_auth)):
        """Section → zone lookup map for an event. Used by the Market vs Owned
        Depth panel to render a Zone column next to each ticket_group.

        Resolution: curated performer_zones (priority) → derive_zone_fallback()
        keyword/numeric heuristic → null.
        """
        db = get_require_sb()()
        ev = (db.table("events")
                .select("primary_performer_id, venue_id")
                .eq("id", event_id).limit(1).execute().data or [])
        if not ev:
            return {"map": {}, "source_mix": {}}
        primary_perf = ev[0].get("primary_performer_id")
        venue_id = ev[0].get("venue_id")

        # Distinct (section, row) pairs in the event's latest listings snapshot
        latest = (db.table("listings_snapshots")
                    .select("captured_at").eq("event_id", event_id)
                    .order("captured_at", desc=True).limit(1).execute().data or [])
        if not latest:
            return {"map": {}, "source_mix": {}}
        latest_at = latest[0]["captured_at"]
        sec_rows = (db.table("listings_snapshots")
                      .select("section, row")
                      .eq("event_id", event_id).eq("captured_at", latest_at)
                      .execute().data or [])
        secs = list({(r.get("section"), r.get("row")) for r in sec_rows})

        # Build map. For each (section, row), call derive_zone_fallback for the system
        # answer; also check performer_zones for curated. Curated wins.
        section_map: dict[str, dict] = {}
        source_mix: dict[str, int] = {}

        # Curated lookups (in batch) — query performer_zone_section_rules joined with performer_zones
        if primary_perf and venue_id:
            cur_rules = (db.table("performer_zones")
                           .select("id, zone, performer_zone_section_rules(section_pattern, match_type, row_pattern, priority)")
                           .eq("performer_id", primary_perf).eq("venue_id", venue_id)
                           .eq("source", "curated")
                           .execute().data or [])
            # Flatten rules: list of (zone, pattern, match_type, row_pattern, priority)
            rules: list[tuple] = []
            for cz in cur_rules:
                for rule in (cz.get("performer_zone_section_rules") or []):
                    rules.append((cz["zone"], rule.get("section_pattern") or "",
                                  rule.get("match_type") or "exact",
                                  rule.get("row_pattern"), rule.get("priority") or 0))
            rules.sort(key=lambda r: -r[4])  # priority desc

            def _curated_match(section: str | None, row: str | None) -> str | None:
                if not section: return None
                sec = section
                for zone, patt, mtype, rpatt, _pri in rules:
                    hit = False
                    if mtype == "exact":     hit = sec == patt
                    elif mtype == "prefix":  hit = sec.lower().startswith(patt.lower())
                    elif mtype == "suffix":  hit = sec.lower().endswith(patt.lower())
                    elif mtype == "substring": hit = patt.lower() in sec.lower()
                    elif mtype == "regex":
                        try: hit = bool(re.search(patt, sec, re.IGNORECASE))
                        except re.error: hit = False
                    if hit and rpatt and row:
                        try: hit = bool(re.search(rpatt, row, re.IGNORECASE))
                        except re.error: pass
                    if hit: return zone
                return None
        else:
            def _curated_match(section: str | None, row: str | None) -> str | None:
                return None

        # Pre-resolve the system fallback for every non-curated (section, row)
        # in ONE round-trip (was an N+1: one derive_zone_fallback RPC per
        # section). _batch_fallback_zones degrades to the legacy per-pair loop
        # if the batch RPC is unavailable, so behaviour is identical whether or
        # not the batch migration has been applied.
        pending = [(section, row) for section, row in secs if not _curated_match(section, row)]
        fb_map = _batch_fallback_zones(db, pending)

        # Resolve each section
        for section, row in secs:
            z_curated = _curated_match(section, row)
            if z_curated:
                section_map[section] = {"zone": z_curated, "source": "curated"}
                source_mix["curated"] = source_mix.get("curated", 0) + 1
                continue
            zfall = fb_map.get((section, row))
            if zfall:
                section_map[section] = {"zone": zfall, "source": "fallback"}
                source_mix["fallback"] = source_mix.get("fallback", 0) + 1
            else:
                section_map[section] = {"zone": None, "source": "unmapped"}
                source_mix["unmapped"] = source_mix.get("unmapped", 0) + 1

        return {"map": section_map, "source_mix": source_mix}

    @router.get("/api/broker/event/{event_id}/zones")
    def broker_event_zones(event_id: int, include_parking: bool = False, _=Depends(require_auth)):
        """Per-zone latest metrics with full distribution.

        Picks ONE zone_source per event by priority: curated > fallback > unmapped.
        User spec: never show two competing zone classifications side-by-side.
        If the event has any curated zones, only curated rows surface; the fallback
        layer is redundant noise in that case (mostly leftover sections that didn't
        match a curated rule, with tiny ticket counts).

        Returns latest snapshot per zone within the chosen source. zone_metrics has
        the same shape as event_metrics (full percentile distribution + owned
        breakdown).
        """
        db = get_require_sb()()
        rows = (
            db.table("zone_metrics")
            .select(
                "zone, zone_source, captured_at, "
                "tickets_count, groups_count, sections_count, "
                "retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum, "
                "wholesale_min, wholesale_median, wholesale_mean, wholesale_max, "
                "getin_price, "
                "owned_groups_count, owned_tickets_count, owned_share, owned_median_retail"
            )
            .eq("event_id", event_id)
            .order("captured_at", desc=True)
            .limit(1000)
            .execute()
        ).data or []

        # 1) Decide which source to use. Priority: curated > fallback > unmapped.
        sources_present = {r.get("zone_source") for r in rows}
        if "curated" in sources_present:
            chosen_source = "curated"
        elif "fallback" in sources_present:
            chosen_source = "fallback"
        elif "unmapped" in sources_present:
            chosen_source = "unmapped"
        else:
            chosen_source = None

        # 2) Filter to chosen source, then take latest per zone (rows are pre-sorted desc).
        if chosen_source is None:
            return {"zones": [], "count": 0, "source": None, "available_sources": []}

        seen = set()
        out = []
        parking_count = 0
        for r in rows:
            if r.get("zone_source") != chosen_source:
                continue
            z = r.get("zone")
            if z in seen:
                continue
            # Auto-hide parking/garage/hospitality unless caller explicitly opts in.
            if not include_parking and z and _PARKING_ZONE_RE.search(z):
                parking_count += 1
                continue
            seen.add(z)
            out.append(r)

        # 3) Sort by tickets_count desc within the chosen source
        out.sort(key=lambda r: -(r.get("tickets_count") or 0))

        return {
            "zones": out,
            "count": len(out),
            "source": chosen_source,
            "available_sources": sorted(sources_present),
            "parking_hidden": parking_count,
            "include_parking": include_parking,
        }

    @router.get("/api/broker/performer/{performer_id}/espn")
    def broker_performer_espn(performer_id: int, _=Depends(require_auth)):
        """ESPN context for a TEvo performer. Resolves performer_id → ESPN team_id
        via performer_external_ids (source='espn'), then pulls the latest team
        snapshot, current injuries, recent news, and the last 5 game snapshots
        involving that team.

        Returns: {
          applicable, performer_id, espn_team_id, league,
          team:    { record_summary, standing_summary, streak, win_pct, captured_at },
          injuries:[{ athlete_name, position, status, injury_type, return_date, ... }],
          news:    [{ headline, description, url, published_at, type }],
          recent:  [{ espn_event_id, captured_at, home_team_id, away_team_id, home_score, away_score, status_short }]
        }
        """
        db = get_require_sb()()
        pei = (db.table("performer_external_ids")
                 .select("performer_id, external_id, league, meta")
                 .eq("performer_id", performer_id).eq("source", "espn")
                 .limit(1).execute().data or [])
        if not pei:
            return {"applicable": False, "reason": "no ESPN mapping for this performer"}
        espn_team_id = str(pei[0]["external_id"])
        league       = pei[0]["league"]

        # Latest team snapshot (one row, most recent captured_at).
        team_rows = (db.table("espn_team_snapshots")
                       .select("captured_at, wins, losses, ties, win_pct, games_back, playoff_seed, conference_rank, division_rank, record_summary, standing_summary, streak")
                       .eq("espn_team_id", espn_team_id).eq("espn_league", league)
                       .order("captured_at", desc=True).limit(1).execute().data or [])

        # Current injuries — latest snapshot per athlete (last 24h).
        injuries = (db.table("espn_injuries_snapshots")
                      .select("athlete_id, athlete_name, position, status, injury_type, short_comment, return_date, captured_at")
                      .eq("espn_team_id", espn_team_id).eq("espn_league", league)
                      .gte("captured_at", (datetime.now(timezone.utc) - timedelta(hours=36)).isoformat())
                      .order("captured_at", desc=True).limit(50).execute().data or [])
        seen = set(); inj_dedup = []
        for x in injuries:
            k = x.get("athlete_id")
            if k in seen: continue
            seen.add(k); inj_dedup.append(x)

        # Recent news (last 30 days, top 8).
        news = (db.table("espn_news")
                  .select("headline, description, url, published_at, type")
                  .eq("espn_team_id", espn_team_id).eq("espn_league", league)
                  .order("published_at", desc=True).limit(8).execute().data or [])

        # Last 5 finished/upcoming game snapshots where this team is home or away.
        recent: list = []
        try:
            recent = (db.rpc("get_team_recent_games", {"p_espn_team_id": espn_team_id, "p_league": league, "p_limit": 5}).execute().data or [])
        except Exception:
            # Fallback: query espn_event_snapshots directly (latest snap per event).
            rows_h = (db.table("espn_event_snapshots")
                        .select("espn_event_id, captured_at, status_short, state, home_team_id, away_team_id, home_score, away_score")
                        .eq("home_team_id", espn_team_id).eq("espn_league", league)
                        .order("captured_at", desc=True).limit(15).execute().data or [])
            rows_a = (db.table("espn_event_snapshots")
                        .select("espn_event_id, captured_at, status_short, state, home_team_id, away_team_id, home_score, away_score")
                        .eq("away_team_id", espn_team_id).eq("espn_league", league)
                        .order("captured_at", desc=True).limit(15).execute().data or [])
            all_rows = rows_h + rows_a
            seen_ev = set(); merged = []
            for x in sorted(all_rows, key=lambda r: r.get("captured_at", ""), reverse=True):
                ek = x.get("espn_event_id")
                if ek in seen_ev: continue
                seen_ev.add(ek); merged.append(x)
                if len(merged) >= 5: break
            recent = merged

        return {
            "applicable": True,
            "performer_id": performer_id,
            "espn_team_id": espn_team_id,
            "league": league,
            "team":     team_rows[0] if team_rows else None,
            "injuries": inj_dedup[:20],
            "news":     news,
            "recent":   recent,
        }

    @router.get("/api/broker/event/{event_id}/chart-data")
    def broker_event_chart_data(
        event_id: int,
        days: int = 30,
        hours: int | None = None,
        range: str | None = None,   # "6h" "24h" "3d" "7d" "30d" "all"
        _=Depends(require_auth),
    ):
        """Stage 2 chart data: 4 default time-series + 4 overlay event streams.

        Series:
          prices_owned   — event_metrics.owned_median_retail
          prices_market  — event_metrics.retail_median
          counts_owned   — event_metrics.owned_tickets_count
          counts_market  — event_metrics.tickets_count
          home_standings — espn_team_snapshots filtered to home team (win_pct over time)
          away_standings — espn_team_snapshots filtered to away team (win_pct over time)

        Overlay events (vertical markers):
          injuries     — espn_injuries_snapshots, only is_baseline=false rows (real changes)
          roster_moves — espn_athlete_team_history with transaction_type in (traded, released)

        Last-5 record:
          espn_event_snapshots state='post' for either team, last 5 by captured_at,
          W/L computed from home_team_id + scores.
        """
        # Time range: prefer `range` (preset string) over `hours` over `days`.
        # Presets: 6h, 24h, 3d, 7d, 30d, all. Min 6h, max 30d (cap user-driven
        # views; 'all' bypasses the cap and pulls everything we have).
        range_hours: int | None = None
        if range:
            rmap = {"6h": 6, "24h": 24, "1d": 24, "3d": 72, "7d": 168, "30d": 720, "all": None}
            if range.lower() not in rmap:
                raise HTTPException(400, f"range must be one of {list(rmap)}")
            range_hours = rmap[range.lower()]
        elif hours is not None:
            range_hours = max(6, min(int(hours), 720))
        else:
            days = max(1, min(int(days), 180))
            range_hours = days * 24

        db = get_require_sb()()
        if range_hours is None:
            # 'all' — pick a far-past floor so SELECTs still index well
            since_iso = "1970-01-01T00:00:00+00:00"
        else:
            since_iso = (datetime.now(timezone.utc) - timedelta(hours=range_hours)).isoformat()
        days = (range_hours // 24) if range_hours else 9999  # back-compat for any consumer reading `days`

        # These three reads are mutually independent — fan them out concurrently
        # (was three sequential round-trips). Queries are unchanged.
        #   1) Full event_metrics distribution as time series — chart workbench
        #      toggles any subset on/off. SELECT every column we collect.
        #   - AXS box-office series (median section price + listing count). Empty
        #     until AXS snapshots are AQ-linked to this tevo_event_id; the RPC may
        #     be absent → swallow inside the thunk so it degrades to [].
        #   2) event_xref row for ESPN team resolution.
        def _fetch_axs() -> list:
            try:
                return (
                    db.rpc("get_axs_event_price_series",
                           {"p_event_id": event_id, "p_since": since_iso}).execute()
                ).data or []
            except Exception:
                return []

        em, axs_rows, xref = run_parallel([
            lambda: (
                db.table("event_metrics")
                .select(
                    "captured_at,"
                    "tickets_count,groups_count,sections_count,median_group_size,"
                    "ancillary_groups,ancillary_tickets,"
                    "retail_min,retail_p25,retail_median,retail_mean,retail_p75,retail_p90,retail_max,retail_sum,"
                    "wholesale_min,wholesale_median,wholesale_mean,wholesale_max,"
                    "getin_price,top5_concentration,price_dispersion,tail_premium,"
                    "owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
                    "nonowned_median_retail,"   # NEW: median of non-S4K listings ("MARKET NOT US")
                    "splits_min_q,splits_pct_pairs,splits_pct_singles,"
                    "splits_listings_with_singles,splits_listings_with_pairs,"
                    "splits_listings_with_3,splits_listings_with_4plus,splits_listings_no_split"
                )
                .eq("event_id", event_id)
                .gte("captured_at", since_iso)
                .order("captured_at")
                .execute()
            ).data or [],
            _fetch_axs,
            lambda: (
                db.table("event_xref").select("espn_event_id,espn_slug,espn_league")
                .eq("tevo_event_id", event_id).limit(1).execute()
            ).data or [],
        ])

        def _series(col: str) -> list:
            return [{"t": r["captured_at"], "v": r.get(col)} for r in em]

        # Legacy aliases (preserved for backwards-compat)
        prices_owned    = _series("owned_median_retail")
        prices_market   = _series("retail_median")
        prices_nonowned = _series("nonowned_median_retail")  # NEW — "MARKET NOT US"
        counts_owned    = _series("owned_tickets_count")
        counts_market   = _series("tickets_count")

        prices_axs = [{"t": r["captured_at"], "v": r.get("median_price")} for r in axs_rows]
        counts_axs = [{"t": r["captured_at"], "v": r.get("listings_count")} for r in axs_rows]

        # 2) Resolve home + away ESPN team ids from event_xref → espn_event_snapshots
        home_team_id = away_team_id = home_slug = away_slug = home_league = None
        if xref:
            x = xref[0]
            home_league = x["espn_league"]
            snap = (
                db.table("espn_event_snapshots")
                .select("home_team_id,away_team_id")
                .eq("espn_event_id", x["espn_event_id"])
                .order("captured_at", desc=True).limit(1)
                .execute()
            ).data or []
            if snap:
                home_team_id = snap[0].get("home_team_id")
                away_team_id = snap[0].get("away_team_id")
                home_slug = away_slug = x["espn_slug"]

        # ----- ESPN + zone reads: ONE concurrent wave -----
        # Once the team ids are known these are all independent, so fan them out
        # together (previously several sequential steps). Consolidations vs the
        # prior code:
        #   (a) espn_injuries_snapshots is read ONCE for both teams and reused for
        #       the overlay AND both per-team injury-load series (was 3 reads).
        #   (b) zone_metrics joins the wave instead of trailing it.
        # last5 stays per-team: its LIMIT 25 is a per-team cap, so folding both
        # teams into one capped query could drop games before the dedupe.
        team_ids = [t for t in (home_team_id, away_team_id) if t]
        _have_teams = bool(team_ids) and bool(home_league)

        def _fetch_standings(team_id: str | None) -> list:
            if not team_id or not home_league:
                return []
            return (
                db.table("espn_team_snapshots")
                .select("captured_at,win_pct,wins,losses,games_back,playoff_seed,conference_rank,division_rank,record_summary,streak")
                .eq("espn_team_id", team_id)
                .eq("espn_league", home_league)   # league-scope: same id exists across leagues
                .gte("captured_at", since_iso)
                .order("captured_at")
                .execute()
            ).data or []

        def _fetch_injuries() -> list:
            # ONE read for both teams. Superset select feeds the overlay
            # (athlete_name/injury_type/short_comment/is_baseline) AND the
            # per-team injury-load state machine (athlete_id/status).
            # CRITICAL: filter by espn_league — espn_team_id is league-scoped
            # ("18" = NBA Knicks AND MLB Pirates AND NFL Saints AND NHL #18 …);
            # without it we'd pull 229 rows when only 12 are real.
            if not _have_teams:
                return []
            return (
                db.table("espn_injuries_snapshots")
                .select("captured_at,athlete_name,athlete_id,status,injury_type,short_comment,espn_team_id,is_baseline")
                .in_("espn_team_id", team_ids)
                .eq("espn_league", home_league)
                .gte("captured_at", since_iso)
                .order("captured_at")
                .execute()
            ).data or []

        def _fetch_roster() -> list:
            if not _have_teams:
                return []
            return (
                db.table("espn_athlete_team_history")
                .select("detected_at,transaction_type,prior_team_id,espn_team_id,espn_athlete_id,notes")
                .in_("transaction_type", ["traded", "released"])
                .eq("espn_league", home_league)   # league-scope; team_id+league together is the unique team
                .gte("detected_at", since_iso)
                .or_(",".join(filter(None, [
                    f"espn_team_id.eq.{home_team_id}" if home_team_id else None,
                    f"espn_team_id.eq.{away_team_id}" if away_team_id else None,
                    f"prior_team_id.eq.{home_team_id}" if home_team_id else None,
                    f"prior_team_id.eq.{away_team_id}" if away_team_id else None,
                ])) or "espn_team_id.eq.NULL")
                .order("detected_at")
                .execute()
            ).data or []

        def _fetch_last5(team_id: str | None) -> list:
            if not team_id or not home_league:
                return []
            return (
                db.table("espn_event_snapshots")
                .select("captured_at,espn_event_id,home_team_id,away_team_id,home_score,away_score,state")
                .or_(f"home_team_id.eq.{team_id},away_team_id.eq.{team_id}")
                .eq("espn_league", home_league)   # league-scope: id "20" exists in NBA + MLB + NFL etc.
                .eq("state", "post")
                .order("captured_at", desc=True).limit(25)
                .execute()
            ).data or []

        def _fetch_news(team_id: str | None) -> list:
            if not team_id:
                return []
            return (
                db.table("espn_news")
                .select("published_at")
                .eq("espn_team_id", team_id).eq("espn_league", home_league or "")
                .gte("published_at", since_iso)
                .order("published_at")
                .execute()
            ).data or []

        def _fetch_zone_metrics() -> list:
            return (
                db.table("zone_metrics")
                .select("captured_at, zone, zone_source, retail_median, tickets_count, owned_tickets_count, owned_median_retail")
                .eq("event_id", event_id)
                .gte("captured_at", since_iso)
                .order("captured_at")
                .execute()
            ).data or []

        (home_standings_rows, away_standings_rows, inj_rows, rm_rows,
         last5_home_rows, last5_away_rows, home_news_rows, away_news_rows,
         zm_rows) = run_parallel([
            lambda: _fetch_standings(home_team_id),
            lambda: _fetch_standings(away_team_id),
            _fetch_injuries,
            _fetch_roster,
            lambda: _fetch_last5(home_team_id),
            lambda: _fetch_last5(away_team_id),
            lambda: _fetch_news(home_team_id),
            lambda: _fetch_news(away_team_id),
            _fetch_zone_metrics,
        ])

        def _stand_series(rows: list, field: str) -> list:
            """Pluck one ESPN standings field into a t,v time-series."""
            return [{"t": r["captured_at"], "v": r.get(field)} for r in rows]

        # Legacy field kept for backwards-compat: home_standings/away_standings are
        # the win_pct series with extra metadata. New per-field series are emitted
        # separately so the chart workbench can plot any combination.
        home_standings = [{"t": r["captured_at"], "v": r.get("win_pct"),
                           "wins": r.get("wins"), "losses": r.get("losses"),
                           "seed": r.get("playoff_seed"), "rec": r.get("record_summary")}
                          for r in home_standings_rows]
        away_standings = [{"t": r["captured_at"], "v": r.get("win_pct"),
                           "wins": r.get("wins"), "losses": r.get("losses"),
                           "seed": r.get("playoff_seed"), "rec": r.get("record_summary")}
                          for r in away_standings_rows]

        # 3) Injury overlay — all rows (both teams), tagged home/away. is_baseline
        # detection only works for MLB+NHL (NBA/NFL/MLS/WNBA/WC always report
        # is_baseline=true), so baseline rows are included and the UI tags each
        # marker with is_change (true = real status flip; false = baseline row).
        injuries = [{"t": r["captured_at"], "athlete": r.get("athlete_name"),
                     "status": r.get("status"), "team": "home" if r.get("espn_team_id") == home_team_id else "away",
                     "comment": r.get("short_comment"),
                     "is_change": (r.get("is_baseline") is False)}
                    for r in inj_rows]

        # 4) Roster moves (trades + releases)
        roster_moves = [{"t": r["detected_at"], "type": r["transaction_type"],
                         "athlete_id": r.get("espn_athlete_id"),
                         "from_team": r.get("prior_team_id"), "to_team": r.get("espn_team_id"),
                         "notes": r.get("notes")} for r in rm_rows]

        # 5) Last-5 record per team. Rows are already team-scoped by the fetch;
        # dedupe by espn_event_id (the collector re-snapshots each finished game
        # many times, so a raw take-5 would repeat one game), keeping the latest
        # snapshot per event, and cap at 5. Mirrors the /performer/{id}/espn
        # fallback dedupe.
        def _last5_from(rows: list, team_id: str | None) -> list:
            if not team_id:
                return []
            out = []
            seen_ev = set()
            for r in rows:
                ek = r.get("espn_event_id")
                if ek in seen_ev:
                    continue
                seen_ev.add(ek)
                h, a = r.get("home_score"), r.get("away_score")
                if h is None or a is None:
                    continue
                is_home = r.get("home_team_id") == team_id
                won = (is_home and h > a) or (not is_home and a > h)
                out.append({"t": r["captured_at"], "result": "W" if won else "L",
                            "score": f"{h}-{a}", "home": is_home})
                if len(out) >= 5:
                    break
            return out

        last5_home = _last5_from(last5_home_rows, home_team_id)
        last5_away = _last5_from(last5_away_rows, away_team_id)

        # ----- News velocity per team (rows per hour bucket) -----
        def _news_from(rows: list, team_id: str | None) -> list:
            if not team_id:
                return []
            from collections import Counter
            buckets: Counter = Counter()
            for r in rows:
                ts = r.get("published_at") or ""
                buckets[ts[:13]] += 1   # YYYY-MM-DDTHH
            return [{"t": k + ":00:00+00:00", "v": v} for k, v in sorted(buckets.items())]

        home_news = _news_from(home_news_rows, home_team_id)
        away_news = _news_from(away_news_rows, away_team_id)

        # ----- Active-injury count over time (per team) -----
        # Split the single injuries read by team, then forward-fill: athlete_id ->
        # latest status, emit the count of non-active athletes at each change. We
        # can't know "still injured at time T" without a reverse pass; this cheap
        # approximation is fine since the tables are small.
        def _injury_load_from(team_id: str | None) -> list:
            if not team_id:
                return []
            state: dict[str, str] = {}
            out = []
            for r in inj_rows:
                if r.get("espn_team_id") != team_id:
                    continue
                aid = r.get("athlete_id"); st = (r.get("status") or "").lower()
                if not aid:
                    continue
                state[aid] = st
                active_injured = sum(1 for s in state.values() if s and s != "active")
                out.append({"t": r["captured_at"], "v": active_injured})
            return out

        home_injury_load = _injury_load_from(home_team_id)
        away_injury_load = _injury_load_from(away_team_id)

        # ----- Composite team_index with window-content-derived weights -----
        # Weight each signal by how much CONTENT (snapshots) it generated during
        # the visible window. Heavy injury-news day → injuries dominate the index.
        # Quiet news week → standings drive it. Per user spec.
        def _team_index_series(stand_rows, news_rows, inj_load_rows, team_id: str | None) -> tuple[list, dict]:
            if not team_id:
                return [], {}
            n_stand = len(stand_rows)
            n_news  = len(news_rows)
            n_inj   = len(inj_load_rows)
            total = max(n_stand + n_news + n_inj, 1)
            w = {"standings": n_stand/total, "news": n_news/total, "injury": n_inj/total}

            # Build a unified hourly grid from all three sources
            keypoints = sorted({r["t"] for r in (stand_rows + news_rows + inj_load_rows)})
            if not keypoints: return [], w

            # Forward-fill helpers
            def ff_value(rows, t):
                v = None
                for r in rows:
                    if r["t"] <= t: v = r.get("v")
                    else: break
                return v

            # Normalize each series to 0-100 within the window
            def vals(rs): return [r.get("v") for r in rs if r.get("v") is not None]
            s_vals = vals(stand_rows); n_vals = vals(news_rows); i_vals = vals(inj_load_rows)
            def norm(v, vs):
                if v is None or not vs: return 50.0  # neutral if no data
                mn, mx = min(vs), max(vs)
                if mx == mn: return 50.0
                return (float(v) - mn) / (mx - mn) * 100.0

            out = []
            for t in keypoints:
                s = norm(ff_value(stand_rows, t), s_vals)            # higher win% = higher
                n = norm(ff_value(news_rows,  t), n_vals)            # more news = higher (popularity proxy)
                i = 100.0 - norm(ff_value(inj_load_rows, t), i_vals) # MORE injuries = LOWER index
                idx = w["standings"]*s + w["news"]*n + w["injury"]*i
                out.append({"t": t, "v": round(idx, 2)})
            return out, w

        # Pass the already-normalized t/v standings series (home_standings/
        # away_standings), NOT the raw rows — _team_index_series indexes every input
        # row by r["t"], which the raw espn_team_snapshots rows (keyed captured_at)
        # don't have. Raw rows would KeyError the instant standings exist.
        home_index, home_weights = _team_index_series(home_standings, home_news, home_injury_load, home_team_id)
        away_index, away_weights = _team_index_series(away_standings, away_news, away_injury_load, away_team_id)

        # ----- Per-zone time series (curated > fallback > unmapped, single source) -----
        # User spec: only render ONE zone classification, prefer curated. Returns one
        # series per zone with retail_median + tickets_count time points so the
        # chart workbench can plot any subset. (zm_rows fetched in the wave above.)
        zm_sources = {r.get("zone_source") for r in zm_rows}
        if "curated" in zm_sources:   zm_chosen = "curated"
        elif "fallback" in zm_sources: zm_chosen = "fallback"
        elif "unmapped" in zm_sources: zm_chosen = "unmapped"
        else:                           zm_chosen = None
        zone_series: dict[str, dict] = {}
        if zm_chosen:
            for r in zm_rows:
                if r.get("zone_source") != zm_chosen: continue
                zname = r.get("zone") or "unmapped"
                ent = zone_series.setdefault(zname, {
                    "zone": zname, "source": zm_chosen,
                    "prices_market": [], "counts_market": [],
                    "prices_owned":  [], "counts_owned":  [],
                })
                ent["prices_market"].append({"t": r["captured_at"], "v": r.get("retail_median")})
                ent["counts_market"].append({"t": r["captured_at"], "v": r.get("tickets_count")})
                ent["prices_owned"].append({"t": r["captured_at"], "v": r.get("owned_median_retail")})
                ent["counts_owned"].append({"t": r["captured_at"], "v": r.get("owned_tickets_count")})
        zone_series_list = sorted(zone_series.values(), key=lambda z: -sum(p.get("v") or 0 for p in z["counts_market"]))

        # Range metadata so the chart can pin its x-axis explicitly to the
        # requested window — prevents Chart.js from auto-fitting to whichever
        # series happens to have data, which collapsed 30d views to ~24h when
        # newer series (nonowned_median_retail, splits_min_q) hadn't backfilled
        # past their introduction date.
        until_iso = datetime.now(timezone.utc).isoformat()
        range_meta = {
            "range":    range or (f"{range_hours}h" if range_hours else "all"),
            "hours":    range_hours,
            "since":    since_iso if range_hours else None,  # None = open-left for 'all'
            "until":    until_iso,
        }

        return {
            "event_id": event_id,
            "days": days,
            "range_meta": range_meta,
            "series": {
                # ===== TEvo: prices and counts (legacy IDs preserved) =====
                "prices_owned":    prices_owned,
                "prices_market":   prices_market,
                "prices_nonowned": prices_nonowned,    # NEW: "MARKET NOT US" median
                "counts_owned":    counts_owned,
                "counts_market":   counts_market,
                # ===== AXS box office: median price + listing count =====
                "prices_axs":      prices_axs,
                "counts_axs":      counts_axs,
                # ===== TEvo: full retail percentile distribution =====
                "retail_min":     _series("retail_min"),
                "retail_p25":     _series("retail_p25"),
                "retail_p75":     _series("retail_p75"),
                "retail_p90":     _series("retail_p90"),
                "retail_max":     _series("retail_max"),
                "retail_mean":    _series("retail_mean"),
                "retail_sum":     _series("retail_sum"),
                # ===== TEvo: wholesale percentile distribution =====
                "wholesale_min":     _series("wholesale_min"),
                "wholesale_median":  _series("wholesale_median"),
                "wholesale_mean":    _series("wholesale_mean"),
                "wholesale_max":     _series("wholesale_max"),
                # ===== TEvo: structure and concentration =====
                "getin_price":          _series("getin_price"),
                "top5_concentration":   _series("top5_concentration"),
                "price_dispersion":     _series("price_dispersion"),
                "tail_premium":         _series("tail_premium"),
                "median_group_size":    _series("median_group_size"),
                "groups_count":         _series("groups_count"),
                "sections_count":       _series("sections_count"),
                "ancillary_tickets":    _series("ancillary_tickets"),
                "ancillary_groups":     _series("ancillary_groups"),
                # ===== TEvo: owned aggregates =====
                "owned_groups_count":   _series("owned_groups_count"),
                "owned_share":          _series("owned_share"),
                # ===== TEvo: splits inventory =====
                "splits_min_q":         _series("splits_min_q"),
                "splits_pct_pairs":     _series("splits_pct_pairs"),
                "splits_pct_singles":   _series("splits_pct_singles"),
                "splits_with_singles":  _series("splits_listings_with_singles"),
                "splits_with_pairs":    _series("splits_listings_with_pairs"),
                "splits_with_3":        _series("splits_listings_with_3"),
                "splits_with_4plus":    _series("splits_listings_with_4plus"),
                "splits_no_split":      _series("splits_listings_no_split"),
                # ===== ESPN standings: legacy combined + new per-field per-team =====
                "home_standings": home_standings,   # legacy alias for home_win_pct
                "away_standings": away_standings,
                "home_win_pct":     _stand_series(home_standings_rows, "win_pct"),
                "home_wins":        _stand_series(home_standings_rows, "wins"),
                "home_losses":      _stand_series(home_standings_rows, "losses"),
                "home_games_back":  _stand_series(home_standings_rows, "games_back"),
                "home_seed":        _stand_series(home_standings_rows, "playoff_seed"),
                "home_conf_rank":   _stand_series(home_standings_rows, "conference_rank"),
                "home_div_rank":    _stand_series(home_standings_rows, "division_rank"),
                "away_win_pct":     _stand_series(away_standings_rows, "win_pct"),
                "away_wins":        _stand_series(away_standings_rows, "wins"),
                "away_losses":      _stand_series(away_standings_rows, "losses"),
                "away_games_back":  _stand_series(away_standings_rows, "games_back"),
                "away_seed":        _stand_series(away_standings_rows, "playoff_seed"),
                "away_conf_rank":   _stand_series(away_standings_rows, "conference_rank"),
                "away_div_rank":    _stand_series(away_standings_rows, "division_rank"),
                # ===== ESPN news velocity =====
                "home_news_1h":     home_news,
                "away_news_1h":     away_news,
                # ===== ESPN injury load over time =====
                "home_injury_load": home_injury_load,
                "away_injury_load": away_injury_load,
                # ===== ESPN composite "team_index" (window-content-weighted) =====
                "home_team_index":  home_index,
                "away_team_index":  away_index,
            },
            "signal_weights": {
                "home": home_weights,
                "away": away_weights,
                "explainer": "Composite team_index = sum(weight_i * normalized_signal_i). Weights derived from how many content rows each signal source produced during the visible window — heavy news → news dominates; quiet news week → standings drive it.",
            },
            "overlays": {
                "injuries":     injuries,
                "roster_moves": roster_moves,
            },
            "last5": {
                "home": last5_home,
                "away": last5_away,
            },
            "teams": {
                "home_team_id": home_team_id,
                "away_team_id": away_team_id,
                "league":       home_league,
            },
            "zone_series": {
                "source":    zm_chosen,
                "available": sorted([s for s in zm_sources if s]),
                "zones":     zone_series_list,
            },
        }

    def _broker_movers_v2(source: str, window_days: int, category=None, include_inactive: bool = False):
        """v2 movers path: reads from event_movers_index (SMA-based signal scoring).
        Returns events grouped by category with cross-source spread data.
        Index is seeded 3×/day by compute_movers_index_post_snapshot cron.
        """
        db = get_require_sb()()
        rows = db.rpc("get_event_movers_v2", {
            "p_source":      source,
            "p_window_days": window_days,
            "p_category":    category,   # None → all categories (SQL NULL)
            "p_limit":       200,        # 6 cat × 25 events = 150 max; 200 gives headroom
        }).execute().data or []
        summary = db.rpc("get_event_movers_index_summary", {
            "p_source":      source,
            "p_window_days": window_days,
        }).execute().data or []
        by_cat: dict = {}
        for r in rows:
            cat = r.get("category") or "unknown"
            by_cat.setdefault(cat, []).append(r)
        return {
            "v":                  2,
            "source":             source,
            "window_days":        window_days,
            "category":           category,
            "event_count":        len(rows),
            "events_by_category": by_cat,
            "summary":            summary,
        }


    @router.get("/api/broker/movers")
    def broker_movers(window_hours: int = 24, source: str = "merged", window_days: int | None = None,
                      category: str | None = None, include_inactive: bool = False, _=Depends(require_auth)):
        """Top 10 winners + losers at event / performer / venue level, owned vs market.
        Window: compare latest event_metrics row vs latest row from `window_hours` ago.

        Owned segment    = events with owned_tickets_count > 0 in current window
        Market segment   = events with market listings (regardless of owned)
        Returns 12 lists total: {events,performers,venues} × {owned,market} × {winners,losers}

        `include_inactive`: by default we exclude ghost / completed / cancelled events
        (lifecycle.is_active=false) so a Raptors playoff bracket that won't happen
        doesn't pollute the movers list. Pass true to see everything raw.

        v2 path (window_days set): uses event_movers_index (SMA-based, source×window×category).
        source defaults to "merged"; category=None returns all categories grouped by key.
        """
        # v2 path: index-backed SMA signals, source×window×category
        if window_days is not None:
            return _broker_movers_v2(source, window_days, category, include_inactive)

        window_hours = max(1, min(int(window_hours), 168))
        db = get_require_sb()()

        # Pre-aggregated in SQL via get_event_movers_with_sg RPC
        # (mig 20260518000000 wraps the original get_event_movers from mig
        # 20260508040000). Adds per-event SG sales count over the same window
        # — powers the new "SG sales" column on movers + the "BLIND SPOTS —
        # SG SELLING, WE'RE NOT" panel. DISTINCT ON (sg_sale_id) inside the
        # RPC handles the 11x SG firehose dedup (PROJECT_BIBLE §3).
        #
        # Old approach (Python aggregation over a 50k-row window) was silently
        # capped at 1000 rows by PostgREST's per-request row limit, producing
        # an empty Movers report even when the underlying data was rich.
        rpc_rows = db.rpc("get_event_movers_with_sg", {"p_window_hours": window_hours}).execute().data or []

        # Filter ghost/completed/cancelled events unless caller explicitly opts in.
        # event_lifecycle is a view over derive_event_lifecycle(); cheap to query
        # for the small id-set we get from the movers RPC.
        if rpc_rows and not include_inactive:
            ids = [r.get("event_id") for r in rpc_rows if r.get("event_id")]
            if ids:
                lc_rows = (
                    db.table("event_lifecycle").select("event_id,status,is_active")
                    .in_("event_id", ids).execute()
                ).data or []
                inactive = {r["event_id"] for r in lc_rows if not r.get("is_active")}
                if inactive:
                    rpc_rows = [r for r in rpc_rows if r.get("event_id") not in inactive]

        def pct_delta(cur, prev):
            if cur is None or prev is None: return None
            try: c = float(cur); p = float(prev)
            except (TypeError, ValueError): return None
            if p == 0: return None
            return round((c - p) / p * 100, 2)

        def abs_delta(cur, prev):
            if cur is None or prev is None: return None
            try: return round(float(cur) - float(prev), 2)
            except (TypeError, ValueError): return None

        def _val(price, tix):
            if price is None or tix is None: return None
            try: return float(price) * float(tix)
            except (TypeError, ValueError): return None

        rows_built = []
        for r in rpc_rows:
            cur_market_val  = _val(r.get("cur_market_med"),  r.get("cur_market_tix"))
            prev_market_val = _val(r.get("prev_market_med"), r.get("prev_market_tix"))
            cur_owned_val   = _val(r.get("cur_owned_med"),   r.get("cur_owned_tix"))
            prev_owned_val  = _val(r.get("prev_owned_med"),  r.get("prev_owned_tix"))
            rows_built.append({
                "event_id":       r.get("event_id"),
                "name":           r.get("name"),
                "performer_id":   r.get("primary_performer_id"),
                "performer_name": r.get("primary_performer_name"),
                "venue_id":       r.get("venue_id"),
                "venue_name":     r.get("venue_name"),
                "occurs_at_local": r.get("occurs_at_local"),
                "latest_at":      r.get("latest_at"),
                "cur_market_med": r.get("cur_market_med"),
                "cur_market_tix": r.get("cur_market_tix"),
                "cur_owned_med":  r.get("cur_owned_med"),
                "cur_owned_tix":  r.get("cur_owned_tix"),
                "cur_owned_share": r.get("cur_owned_share"),  # v3: for "we ARE the market" badge
                "delta_market_pct": pct_delta(r.get("cur_market_med"), r.get("prev_market_med")),
                "delta_market_abs": abs_delta(r.get("cur_market_med"), r.get("prev_market_med")),
                "delta_owned_pct":  pct_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
                "delta_owned_abs":  abs_delta(r.get("cur_owned_med"),  r.get("prev_owned_med")),
                # Notional ticket inventory marked-to-market — captures both price moves
                # AND inventory moves in a single number. Treat each event like a position:
                # value = price × quantity; Δvalue = (cur_price × cur_qty) − (prev_price × prev_qty).
                "cur_market_val":   round(cur_market_val,  2) if cur_market_val  is not None else None,
                "prev_market_val":  round(prev_market_val, 2) if prev_market_val is not None else None,
                "delta_market_val": (None if cur_market_val is None or prev_market_val is None
                                     else round(cur_market_val - prev_market_val, 2)),
                "cur_owned_val":    round(cur_owned_val,  2) if cur_owned_val  is not None else None,
                "prev_owned_val":   round(prev_owned_val, 2) if prev_owned_val is not None else None,
                "delta_owned_val":  (None if cur_owned_val is None or prev_owned_val is None
                                     else round(cur_owned_val - prev_owned_val, 2)),
                # SG broker-sales count over the same window (DISTINCT ON sg_sale_id
                # inside the RPC handles 11x firehose dedup). Drives the new SG
                # column on the movers table + BLIND SPOTS panel (sg_sales > N
                # AND cur_owned_tix = 0).
                "sg_sales_window":  r.get("sg_sales_window") or 0,
            })

        if not rows_built:
            return {"window_hours": window_hours, "events": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []},
                    "performers": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []},
                    "venues": {"owned_winners": [], "owned_losers": [], "market_winners": [], "market_losers": []}}

        def top10(items, key, desc=True):
            filtered = [r for r in items if r.get(key) is not None]
            filtered.sort(key=lambda r: r[key], reverse=desc)
            return filtered[:10]

        # Owned segment = events where current owned tix > 0
        owned = [r for r in rows_built if (r.get("cur_owned_tix") or 0) > 0]
        market = rows_built  # all events being tracked (may or may not have owned)

        # Performer + venue rollups: weight by current market tickets
        def rollup(rows_in, group_key, name_key, id_key):
            agg: dict = {}
            for r in rows_in:
                gid = r.get(group_key)
                if gid is None: continue
                slot = agg.setdefault(gid, {
                    id_key: gid, name_key: r.get(name_key.replace("name", "name")),
                    "weighted_market_pct_num": 0.0, "weighted_market_pct_den": 0,
                    "weighted_owned_pct_num": 0.0,  "weighted_owned_pct_den":  0,
                    "events_count": 0, "owned_tix_total": 0, "market_tix_total": 0,
                })
                slot["events_count"] += 1
                slot["market_tix_total"] += int(r.get("cur_market_tix") or 0)
                slot["owned_tix_total"]  += int(r.get("cur_owned_tix") or 0)
                if r.get("delta_market_pct") is not None and (r.get("cur_market_tix") or 0) > 0:
                    slot["weighted_market_pct_num"] += float(r["delta_market_pct"]) * int(r["cur_market_tix"])
                    slot["weighted_market_pct_den"] += int(r["cur_market_tix"])
                if r.get("delta_owned_pct") is not None and (r.get("cur_owned_tix") or 0) > 0:
                    slot["weighted_owned_pct_num"] += float(r["delta_owned_pct"]) * int(r["cur_owned_tix"])
                    slot["weighted_owned_pct_den"] += int(r["cur_owned_tix"])
            out = []
            for slot in agg.values():
                slot["delta_market_pct"] = (round(slot["weighted_market_pct_num"] / slot["weighted_market_pct_den"], 2)
                                           if slot["weighted_market_pct_den"] else None)
                slot["delta_owned_pct"]  = (round(slot["weighted_owned_pct_num"]  / slot["weighted_owned_pct_den"], 2)
                                           if slot["weighted_owned_pct_den"]  else None)
                out.append({
                    id_key: slot[id_key], "name": slot.get(name_key.replace("name", "name")),
                    "events_count": slot["events_count"],
                    "market_tix_total": slot["market_tix_total"],
                    "owned_tix_total": slot["owned_tix_total"],
                    "delta_market_pct": slot["delta_market_pct"],
                    "delta_owned_pct":  slot["delta_owned_pct"],
                })
            return out

        perf_owned  = rollup(owned,  "performer_id", "performer_name", "performer_id")
        perf_market = rollup(market, "performer_id", "performer_name", "performer_id")
        venue_owned  = rollup(owned,  "venue_id", "venue_name", "venue_id")
        venue_market = rollup(market, "venue_id", "venue_name", "venue_id")

        # Build owned lists first, then exclude those entities from the market candidate
        # pool so a single Knicks game doesn't show up twice (top owned-winner AND top
        # market-winner). Market lists fill from the next-best non-owned candidates.
        def dedupe_market(market_pool, owned_w, owned_l, key):
            excluded = {r.get(key) for r in (owned_w + owned_l) if r.get(key) is not None}
            return [r for r in market_pool if r.get(key) not in excluded]

        ev_ow  = top10(owned,  "delta_owned_pct",  desc=True)
        ev_ol  = top10(owned,  "delta_owned_pct",  desc=False)
        ev_market_dedup = dedupe_market(market, ev_ow, ev_ol, "event_id")
        ev_mw  = top10(ev_market_dedup, "delta_market_pct", desc=True)
        ev_ml  = top10(ev_market_dedup, "delta_market_pct", desc=False)

        pf_ow  = top10(perf_owned,  "delta_owned_pct",  desc=True)
        pf_ol  = top10(perf_owned,  "delta_owned_pct",  desc=False)
        pf_market_dedup = dedupe_market(perf_market, pf_ow, pf_ol, "performer_id")
        pf_mw  = top10(pf_market_dedup, "delta_market_pct", desc=True)
        pf_ml  = top10(pf_market_dedup, "delta_market_pct", desc=False)

        vn_ow  = top10(venue_owned,  "delta_owned_pct",  desc=True)
        vn_ol  = top10(venue_owned,  "delta_owned_pct",  desc=False)
        vn_market_dedup = dedupe_market(venue_market, vn_ow, vn_ol, "venue_id")
        vn_mw  = top10(vn_market_dedup, "delta_market_pct", desc=True)
        vn_ml  = top10(vn_market_dedup, "delta_market_pct", desc=False)

        # Notional value movers: rank by abs $ change in (price × tickets) — the
        # mark-to-market on the inventory position. Captures both price drops and
        # inventory drawdowns in one score, which is what an options-style P&L would
        # weight too (no convexity in tickets, so it's pure delta×dS plus dN×price).
        ev_value_winners = top10([r for r in rows_built if r.get("delta_market_val") is not None], "delta_market_val", desc=True)
        ev_value_losers  = top10([r for r in rows_built if r.get("delta_market_val") is not None], "delta_market_val", desc=False)
        ev_owned_value_winners = top10([r for r in rows_built if r.get("delta_owned_val") is not None and (r.get("cur_owned_tix") or 0) > 0], "delta_owned_val", desc=True)
        ev_owned_value_losers  = top10([r for r in rows_built if r.get("delta_owned_val") is not None and (r.get("cur_owned_tix") or 0) > 0], "delta_owned_val", desc=False)

        return {
            "window_hours": window_hours,
            # Caption surfaced by the UI so users understand what they're looking at.
            "ranking": {
                "metric_owned":  "delta_owned_pct",
                "metric_market": "delta_market_pct",
                "metric_value":  "delta_market_val (cur_med × cur_tix − prev_med × prev_tix)",
                "weighting":     "events: unweighted % change. performer/venue rollups: ticket-count-weighted average. Value lists: absolute $ change in inventory mark-to-market.",
                "dedupe_rule":   "market_winners/losers exclude any entity already in owned_winners/losers; market lists fill from next-best non-owned candidates.",
            },
            "events": {
                "owned_winners":  ev_ow,  "owned_losers":  ev_ol,
                "market_winners": ev_mw,  "market_losers": ev_ml,
                "value_winners":  ev_value_winners, "value_losers": ev_value_losers,
                "owned_value_winners": ev_owned_value_winners, "owned_value_losers": ev_owned_value_losers,
            },
            "performers": {"owned_winners": pf_ow, "owned_losers": pf_ol, "market_winners": pf_mw, "market_losers": pf_ml},
            "venues":     {"owned_winners": vn_ow, "owned_losers": vn_ol, "market_winners": vn_mw, "market_losers": vn_ml},
        }

    @router.get("/api/portfolio")
    def portfolio(
        performer_id: int | None = None,
        venue_id: int | None = None,
        watchlist_only: bool = False,
        include_inactive: bool = False,
        _=Depends(require_auth),
    ):
        """Aggregated portfolio across multiple events.

        Filters (one required):
            performer_id    - events where this performer is primary OR in performer_ids[]
            venue_id        - events at this venue
            watchlist_only  - events that originated from any watchlist row (via watch_sources)

        `include_inactive`: by default we exclude events flagged ghost / completed /
        cancelled / postponed via the event_lifecycle view, so portfolio totals
        don't double-count playoff brackets that the team got eliminated from.

        Returns: { filter, events: [...latest metric per event with `lifecycle`...],
                   aggregate: {...rollups...}, inactive_excluded_count }
        """
        if not (performer_id or venue_id or watchlist_only):
            raise HTTPException(400, "Provide performer_id, venue_id, or watchlist_only=true")

        db = get_require_sb()()

        # 1) Resolve event_ids matching the filter
        if performer_id is not None:
            # Single query: primary OR in performer_ids[]. PostgREST .or_() takes the filters
            # comma-separated; cs.{N} is the array-contains operator.
            ev_a = (
                db.table("events").select("id")
                .or_(f"primary_performer_id.eq.{int(performer_id)},performer_ids.cs.{{{int(performer_id)}}}")
                .execute().data
            ) or []
            event_ids = [r["id"] for r in ev_a]
        elif venue_id is not None:
            ev_a = db.table("events").select("id").eq("venue_id", venue_id).execute().data or []
            event_ids = [r["id"] for r in ev_a]
        else:
            ws = db.table("watch_sources").select("event_id").execute().data or []
            event_ids = list({r["event_id"] for r in ws})

        if not event_ids:
            return {
                "filter": {"performer_id": performer_id, "venue_id": venue_id, "watchlist_only": watchlist_only},
                "events": [],
                "aggregate": {
                    "events_count": 0, "tickets_total": 0, "owned_tickets_total": 0,
                    "owned_share_weighted": None, "retail_value_total": 0,
                    "owned_retail_value_total": 0, "retail_median_avg_weighted": None,
                    "events_with_owned": 0,
                },
            }

        # 2) Pull event metadata
        ev_meta = (
            db.table("events")
            .select("id,name,occurs_at_local,venue_id,venue_name,venue_location,primary_performer_id,primary_performer_name,state")
            .in_("id", event_ids)
            .execute()
        ).data or []
        # Operator-ignored events (state='ignored', e.g. pseudo-events like The
        # Wizard of Oz at Sphere) never surface on terminal portfolio views.
        # Client-side filter: PostgREST .neq() would also drop NULL-state rows.
        ev_meta = [e for e in ev_meta if (e.get("state") or "") != "ignored"]
        event_ids = [e["id"] for e in ev_meta]
        if not event_ids:
            return {
                "filter": {"performer_id": performer_id, "venue_id": venue_id, "watchlist_only": watchlist_only},
                "events": [],
                "aggregate": {
                    "events_count": 0, "tickets_total": 0, "owned_tickets_total": 0,
                    "owned_share_weighted": None, "retail_value_total": 0,
                    "owned_retail_value_total": 0, "retail_median_avg_weighted": None,
                    "events_with_owned": 0,
                },
            }

        # 2b) For performer-filtered queries, look up the performer's home venue(s)
        # AND classification so we can tag is_home for sports only.
        # HOME/AWAY only applies when what_event_type='game' (per TEvo taxonomy:
        # Sports=343 maps to 'game', Concerts/Comedy/Theater do not — Taylor
        # Swift at MSG isn't "home", the venue just hosts).
        home_venue_ids: set[int] = set()
        is_sports_performer: bool = False
        perf_classification: dict | None = None
        if performer_id is not None:
            phv_rows = (
                db.table("performer_home_venues")
                .select("venue_id")
                .eq("performer_id", performer_id)
                .execute()
            ).data or []
            home_venue_ids = {int(r["venue_id"]) for r in phv_rows if r.get("venue_id") is not None}

            pm_rows = (
                db.table("performer_metadata")
                .select("what_event_type, top_category_name, parent_category_name, category_name, genre")
                .eq("performer_id", performer_id).limit(1)
                .execute()
            ).data or []
            if pm_rows:
                perf_classification = pm_rows[0]
                is_sports_performer = (perf_classification.get("what_event_type") == "game")

        # 3) Pull latest metrics row per event
        ev_metrics = (
            db.table("latest_event_metrics")
            .select(
                "event_id,captured_at,tickets_count,groups_count,sections_count,"
                "retail_min,retail_median,retail_p75,retail_p90,retail_max,retail_sum,"
                "getin_price,owned_groups_count,owned_tickets_count,owned_share,owned_median_retail,"
                "price_dispersion,tail_premium,top5_concentration"
            )
            .in_("event_id", event_ids)
            .execute()
        ).data or []
        metrics_by_id = {m["event_id"]: m for m in ev_metrics}

        # 3.5) Lifecycle classification for each event. Used to exclude ghosts
        # (eliminated playoff brackets, completed games, cancellations) from
        # aggregates by default. Each event row also gets a `lifecycle` block
        # so the UI can show a status badge.
        lc_rows = (
            db.table("event_lifecycle").select("event_id,status,is_active,confidence,reasons")
            .in_("event_id", event_ids).execute()
        ).data or []
        lifecycle_by_id = {r["event_id"]: r for r in lc_rows}
        inactive_excluded_count = 0
        if not include_inactive:
            before = len(event_ids)
            active_ids = {r["event_id"] for r in lc_rows if r.get("is_active")}
            # Keep events that are either active or have no lifecycle row (defensive — shouldn't happen)
            ev_meta = [e for e in ev_meta if e["id"] in active_ids or e["id"] not in lifecycle_by_id]
            inactive_excluded_count = before - len(ev_meta)

        # 4) Merge per-event
        out_events = []
        for ev in ev_meta:
            m = metrics_by_id.get(ev["id"], {})
            # is_home: only meaningful for sports performers. Concerts/comedy/
            # theater performers don't have a home venue concept (the venue just
            # hosts). Gate on what_event_type='game' from performer_metadata.
            is_home = None
            if performer_id is not None and is_sports_performer:
                if ev.get("venue_id") is not None:
                    is_home = int(ev["venue_id"]) in home_venue_ids
            out_events.append({
                "id": ev["id"],
                "name": ev["name"],
                "occurs_at_local": ev["occurs_at_local"],
                "state": ev.get("state"),
                "venue_id": ev["venue_id"],
                "venue_name": ev["venue_name"],
                "venue_location": ev["venue_location"],
                "primary_performer_id": ev["primary_performer_id"],
                "primary_performer_name": ev["primary_performer_name"],
                "is_home": is_home,
                "captured_at": m.get("captured_at"),
                "tickets_count": m.get("tickets_count"),
                "groups_count": m.get("groups_count"),
                "sections_count": m.get("sections_count"),
                "retail_min": m.get("retail_min"),
                "retail_median": m.get("retail_median"),
                "retail_p75": m.get("retail_p75"),
                "retail_p90": m.get("retail_p90"),
                "retail_max": m.get("retail_max"),
                "retail_sum": m.get("retail_sum"),
                "getin_price": m.get("getin_price"),
                "owned_groups_count": m.get("owned_groups_count"),
                "owned_tickets_count": m.get("owned_tickets_count"),
                "owned_share": m.get("owned_share"),
                "owned_median_retail": m.get("owned_median_retail"),
                "price_dispersion": m.get("price_dispersion"),
                "tail_premium": m.get("tail_premium"),
                "top5_concentration": m.get("top5_concentration"),
                "lifecycle": lifecycle_by_id.get(ev["id"]),  # status badge data
            })

        # Sort: events with metrics first, soonest first
        out_events.sort(key=lambda e: (e["captured_at"] is None, e.get("occurs_at_local") or ""))

        # 5) Aggregate
        def fnum(v):
            try:
                return float(v) if v is not None else 0.0
            except (TypeError, ValueError):
                return 0.0

        tickets_total = sum(int(e["tickets_count"] or 0) for e in out_events)
        owned_tickets_total = sum(int(e["owned_tickets_count"] or 0) for e in out_events)
        retail_value_total = sum(fnum(e["retail_sum"]) for e in out_events)
        owned_retail_value_total = sum(
            int(e["owned_tickets_count"] or 0) * fnum(e["owned_median_retail"])
            for e in out_events
        )
        events_with_owned = sum(1 for e in out_events if (e["owned_tickets_count"] or 0) > 0)

        # Quantity-weighted retail median
        weighted_num = 0.0
        weighted_den = 0
        for e in out_events:
            if e["retail_median"] is not None and (e["tickets_count"] or 0) > 0:
                weighted_num += fnum(e["retail_median"]) * int(e["tickets_count"])
                weighted_den += int(e["tickets_count"])
        retail_median_avg_weighted = (weighted_num / weighted_den) if weighted_den > 0 else None

        return {
            "filter": {
                "performer_id": performer_id,
                "venue_id": venue_id,
                "watchlist_only": watchlist_only,
                "include_inactive": include_inactive,
            },
            "performer_classification": perf_classification,    # null when not perf-filtered
            "is_sports_performer": is_sports_performer,         # gates the HOME/AWAY UI
            "events": out_events,
            "inactive_excluded_count": inactive_excluded_count,  # ghost / completed / cancelled events filtered out
            "aggregate": {
                "events_count": len(out_events),
                "tickets_total": tickets_total,
                "owned_tickets_total": owned_tickets_total,
                "owned_share_weighted": (owned_tickets_total / tickets_total) if tickets_total > 0 else None,
                "retail_value_total": round(retail_value_total, 2),
                "owned_retail_value_total": round(owned_retail_value_total, 2),
                "retail_median_avg_weighted": round(retail_median_avg_weighted, 2) if retail_median_avg_weighted is not None else None,
                "events_with_owned": events_with_owned,
            },
        }

    return router
