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

from typing import Callable

import requests
from fastapi import APIRouter, Depends, HTTPException

from core.helpers import clean_section, listings_cadence_seconds
from core.substitutions import find_row_substitutions, find_section_substitutions


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
        return row[0] if row else {"performer_id": performer_id, "logo_default_url": None}

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

    return router
