"""Per-performer (and multi-performer) trip planning over our canonical event data.

Bridges `public.v_event_base` rows into the vendored gigtrip optimizer (see `gigtrip/`,
MIT — `NOTICE.md`) and returns a JSON-serializable plan. Pure compute: no writes, no
upstream API calls — it only reads event geography/dates we already hold.

Split so the planning logic is testable offline:
  - `plan_from_rows(...)` — pure: rows -> itinerary dict (no DB).
  - `fetch_performer_rows(db, ...)` / `plan_performer_trip(db, ...)` — thin Supabase wrappers.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from .budget_optimizer import plan_by_date_2b, plan_optimal_2b
from .city_centroids import centroid_for
from .retail import DEFAULT_AWAY_MARGIN, DEFAULT_CLEAR_AT, price_leg, summarize_package
from .gigtrip.model import Constraints, Event, Itinerary
from .gigtrip.optimizer import plan_by_date, plan_optimal


# --------------------------------------------------------------------------- #
# row mapping + serialization
# --------------------------------------------------------------------------- #
def row_to_event(r: dict) -> Event:
    """Map one v_event_base-shaped row into a gigtrip Event.

    PostgREST returns numerics as strings, so lat/lon/date are coerced defensively.
    """
    d = r.get("event_date")
    day = d if isinstance(d, date) else date.fromisoformat(str(d)[:10])
    return Event(
        id=str(r["tevo_event_id"]),
        title=(r.get("primary_performer_name") or r.get("event_name") or "").strip(),
        kind="music",
        day=day,
        city=r.get("venue_city") or "",
        venue=r.get("venue_name") or "",
        lat=float(r["venue_lat"]),
        lon=float(r["venue_lon"]),
    )


def _event_dict(e: Event, meta: dict[int, dict]) -> dict:
    m = meta.get(int(e.id), {})
    return {
        "event_id": int(e.id),
        "performer": e.title,
        "venue": e.venue,
        "city": e.city,
        "date": e.day.isoformat(),
        "lat": e.lat,
        "lon": e.lon,
        "coord_source": m.get("coord_source", "venue"),  # "venue" (precise) | "city" (centroid)
        "owned": m.get("owned"),                          # EVO owned tickets at this event
        "getin": m.get("getin"),                          # EVO retail get-in price
        "ticket_cost": m.get("ticket_cost"),              # getin x max(0, qty - owned)
        "cost_known": m.get("cost_known", True),
    }


def _itin_dict(it: Itinerary, meta: dict[int, dict]) -> dict:
    return {
        "count": it.count,
        "value": round(it.value, 4),
        "travel_km": round(it.travel_km, 1),
        "spend_usd": round(sum((meta.get(int(e.id), {}).get("ticket_cost") or 0.0)
                               for e in it.events), 2),
        "events": [_event_dict(e, meta) for e in it.events],
    }


def _ticket_cost(getin, owned, qty: int):
    """Cost to attend a show with `qty` tickets — owned tickets are free.
    Returns (cost, known); an unknown price with a remaining buy-need -> (0.0, False)."""
    need = max(0, qty - int(owned or 0))
    if need == 0:
        return 0.0, True                 # fully covered by tickets we already own
    if getin is None:
        return 0.0, False                # price unknown -> don't let it block the budget
    return round(float(getin) * need, 2), True


# --------------------------------------------------------------------------- #
# pure planning (no DB) — unit-testable
# --------------------------------------------------------------------------- #
def plan_from_rows(rows: list[dict], home: dict, budget_km: float,
                   start: date, end: date, prefs: dict[str, float] | None = None,
                   max_events: int | None = None, max_km_per_day: float = 1200.0,
                   budget_usd: float | None = None, qty: int = 1) -> dict:
    """Build the optimal itinerary (and the sort-by-date baseline) from raw rows.

    `home` is {"name", "lat", "lon"}. `prefs` maps lowercased performer title -> weight;
    when omitted every distinct performer is weighted 1.0.

    When `budget_usd` is given, the trip must also fit a ticket-spend budget: each show
    costs `getin x max(0, qty - owned)` (owned tickets free), pulled from `_getin`/`_owned`
    attached to the rows. Travel-km and spend are then BOTH enforced by the 2-budget solver.
    """
    usable = [r for r in rows if r.get("venue_lat") is not None
              and r.get("venue_lon") is not None]
    events = [row_to_event(r) for r in usable]
    if prefs is None:
        prefs = {e.title.lower(): 1.0 for e in events}

    qty = max(1, int(qty or 1))
    costs: dict[int, float] = {}
    meta: dict[int, dict] = {}
    n_unpriced = 0
    for r in usable:
        eid = int(r["tevo_event_id"])
        getin, owned = r.get("_getin"), r.get("_owned")
        cst, known = _ticket_cost(getin, owned, qty)
        if not known:
            n_unpriced += 1
        costs[eid] = cst
        meta[eid] = {
            "coord_source": r.get("_coord_source", "venue"),
            "owned": int(owned) if owned is not None else None,
            "getin": round(float(getin), 2) if getin is not None else None,
            "ticket_cost": cst,
            "cost_known": known,
        }

    c = Constraints(
        home_name=home["name"], home_lat=float(home["lat"]), home_lon=float(home["lon"]),
        start=start, end=end, max_travel_km=float(budget_km),
        max_events=max_events, max_km_per_day=max_km_per_day,
    )

    if budget_usd is not None:
        optimal, _ = plan_optimal_2b(events, prefs, c, costs, float(budget_usd))
        baseline, _ = plan_by_date_2b(events, prefs, c, costs, float(budget_usd))
    else:
        optimal = plan_optimal(events, prefs, c)
        baseline = plan_by_date(events, prefs, c)

    titles = sorted({e.title for e in events})
    performer_label = titles[0] if len(titles) == 1 else f"{len(titles)} performers"
    n_city = sum(1 for m in meta.values() if m["coord_source"] == "city")

    return {
        "performer": performer_label,
        "home": home,
        "budget_km": float(budget_km),
        "budget_usd": float(budget_usd) if budget_usd is not None else None,
        "qty_per_show": qty,
        "window": {"start": start.isoformat(), "end": end.isoformat()},
        "tour_date_count": len(events),
        "coord_coverage": {
            "venue": len(usable) - n_city,        # precise venue geocode
            "city_fallback": n_city,              # approximated to city centroid
            "dropped_no_coords": len(rows) - len(usable),  # neither available -> excluded
        },
        "unpriced_events": n_unpriced,
        "optimal": _itin_dict(optimal, meta),
        "baseline_by_date": _itin_dict(baseline, meta),
        "shows_gained": optimal.count - baseline.count,
        "all_dates": [_event_dict(e, meta) for e in sorted(events, key=lambda e: (e.day, e.id))],
    }


# --------------------------------------------------------------------------- #
# DB-backed entry points (Supabase client) — used by app.py routes
# --------------------------------------------------------------------------- #
_SELECT = ("tevo_event_id, event_name, primary_performer_name, venue_name, "
           "venue_city, venue_state, event_date, venue_lat, venue_lon")


def fetch_performer_rows(db, performer_id: int, start: date, end: date,
                         limit: int = 500) -> list[dict]:
    """Upcoming events for one performer from v_event_base, calendar order.

    Returns ALL in-window rows (including those without a precise venue geocode); the
    city-centroid fallback fills coords for the un-geocoded ones before planning.
    """
    return (db.table("v_event_base")
            .select(_SELECT)
            .eq("tevo_performer_id", performer_id)
            .gte("event_date", start.isoformat())
            .lte("event_date", end.isoformat())
            .order("event_date")
            .limit(limit)
            .execute().data) or []


def _apply_coord_fallback(db, rows: list[dict]) -> None:
    """In-place: tag rows with a precise venue geocode as coord_source='venue'; for the rest,
    resolve EVO's `events.venue_location` 'City, ST' text to a city centroid (coord_source=
    'city'). Rows that resolve to neither keep NULL coords and are dropped at plan time."""
    missing = []
    for r in rows:
        if r.get("venue_lat") is not None and r.get("venue_lon") is not None:
            r["_coord_source"] = "venue"
        else:
            missing.append(r)
    if not missing:
        return
    ids = [int(r["tevo_event_id"]) for r in missing]
    locs = (db.table("events").select("id, venue_location")
            .in_("id", ids).execute().data) or []
    locmap = {int(x["id"]): x.get("venue_location") for x in locs}
    for r in missing:
        c = centroid_for(locmap.get(int(r["tevo_event_id"])))
        if c:
            r["venue_lat"], r["venue_lon"], r["_coord_source"] = c[0], c[1], "city"


def fetch_event_costs(db, ids: list[int], lookback_days: int = 21) -> dict[int, dict]:
    """Latest EVO get-in price + owned-ticket count per event, from event_listing_snapshot_daily.

    Returns {event_id: {"getin": float|None, "owned": int}}; events with no recent snapshot
    are simply absent (treated as no price / 0 owned downstream).
    """
    if not ids:
        return {}
    since = (date.today() - timedelta(days=lookback_days)).isoformat()
    rows = (db.table("event_listing_snapshot_daily")
            .select("event_id, evo_retail_getin, evo_owned_tickets, captured_at")
            .in_("event_id", ids)
            .gte("snapshot_date", since)
            .order("captured_at", desc=True)
            .limit(4000)
            .execute().data) or []
    out: dict[int, dict] = {}
    for r in rows:
        eid = int(r["event_id"])
        if eid in out:                       # first seen = latest (ordered captured_at desc)
            continue
        g = r.get("evo_retail_getin")
        out[eid] = {
            "getin": float(g) if g is not None else None,
            "owned": int(r.get("evo_owned_tickets") or 0),
        }
    return out


def plan_performer_trip(db, performer_id: int, home_lat: float, home_lon: float,
                        budget_km: float, start: date, end: date,
                        home_name: str = "Home", max_events: int | None = None,
                        max_km_per_day: float = 1200.0,
                        budget_usd: float | None = None, qty: int = 1) -> dict:
    """End-to-end: pull a performer's upcoming dates (+ EVO price/owned) and plan the trip."""
    rows = fetch_performer_rows(db, performer_id, start, end)
    _apply_coord_fallback(db, rows)
    costs = fetch_event_costs(db, [int(r["tevo_event_id"]) for r in rows])
    for r in rows:
        c = costs.get(int(r["tevo_event_id"]))
        if c:
            r["_getin"], r["_owned"] = c["getin"], c["owned"]
    home = {"name": home_name, "lat": home_lat, "lon": home_lon}
    payload = plan_from_rows(rows, home, budget_km, start, end,
                             max_events=max_events, max_km_per_day=max_km_per_day,
                             budget_usd=budget_usd, qty=qty)
    payload["performer_id"] = int(performer_id)
    return payload


# --------------------------------------------------------------------------- #
# Retail "tour with the artist" agent — dual-mode (owned-splits / market-sourced)
# --------------------------------------------------------------------------- #
_TOUR_SELECT = ("tevo_event_id, event_name, primary_performer_name, venue_name, "
                "venue_city, venue_state, event_date, venue_lat, venue_lon")


def fetch_event_pricing(db, ids: list[int], lookback_days: int = 21) -> dict[int, dict]:
    """Latest EVO owned + ask + market context per event (event_listing_snapshot_daily)."""
    if not ids:
        return {}
    since = (date.today() - timedelta(days=lookback_days)).isoformat()
    rows = (db.table("event_listing_snapshot_daily")
            .select("event_id, evo_owned_tickets, evo_owned_median, evo_retail_getin, "
                    "evo_retail_median, evo_tickets_count, captured_at")
            .in_("event_id", ids)
            .gte("snapshot_date", since)
            .order("captured_at", desc=True)
            .limit(6000)
            .execute().data) or []
    out: dict[int, dict] = {}
    for r in rows:
        eid = int(r["event_id"])
        if eid in out:
            continue
        def _f(k):
            v = r.get(k)
            return float(v) if v is not None else None
        out[eid] = {
            "owned": int(r.get("evo_owned_tickets") or 0),
            "our_ask": _f("evo_owned_median"),
            "getin": _f("evo_retail_getin"),
            "med": _f("evo_retail_median"),
            "qty": int(r.get("evo_tickets_count") or 0),
        }
    return out


def fetch_event_listings(db, ids: list[int], qty: int, lookback_hours: int = 36,
                         cap: int = 12000) -> dict[int, dict]:
    """Auto-select a concrete listing per event that satisfies `qty` and is cheapest.

    From the EVO firehose (`listings_snapshots`): qualifying = `quantity >= qty` AND
    `qty in splits` (the listing can be sold in exactly that size). Returns the latest,
    cheapest qualifying ticket group per event (ties prefer our owned inventory), with seat
    detail — the real tickets the package binds to. Events with no qualifying listing are
    absent (the planner falls back to the model price).
    """
    if not ids:
        return {}
    since = (datetime.now(timezone.utc) - timedelta(hours=lookback_hours)).isoformat()
    rows = (db.table("listings_snapshots")
            .select("event_id, tevo_ticket_group_id, section, row, quantity, retail_price, "
                    "is_owned, eticket, instant_delivery, format, captured_at")
            .in_("event_id", ids)
            .gte("captured_at", since)
            .gte("quantity", qty)
            .contains("splits", [qty])
            .not_.is_("retail_price", "null")
            .order("captured_at", desc=True)
            .limit(cap)
            .execute().data) or []

    seen: set[tuple] = set()
    best: dict[int, dict] = {}
    counts: dict[int, int] = {}
    for r in rows:
        key = (r["event_id"], r["tevo_ticket_group_id"])
        if key in seen:                       # first seen = latest snapshot of this group
            continue
        seen.add(key)
        eid = int(r["event_id"])
        counts[eid] = counts.get(eid, 0) + 1
        price = float(r["retail_price"])
        owned = bool(r.get("is_owned"))
        cur = best.get(eid)
        if cur is None or price < cur["unit_price"] - 1e-9 or (
                abs(price - cur["unit_price"]) <= 1e-9 and owned and not cur["is_owned"]):
            best[eid] = {
                "ticket_group_id": int(r["tevo_ticket_group_id"]),
                "section": r.get("section"), "row": r.get("row"),
                "available_qty": int(r["quantity"]), "unit_price": round(price, 2),
                "is_owned": owned, "eticket": bool(r.get("eticket")),
                "instant": bool(r.get("instant_delivery")), "format": r.get("format"),
            }
    for eid, c in best.items():
        c["candidates"] = counts.get(eid, 0)
    return best


def fetch_tour_events(db, performer_id: int, start: date, end: date,
                      side: str = "auto") -> tuple[list[dict], str]:
    """Return (rows, mode). For a TEAM performer the tour defaults to AWAY games (the team is
    a participant but not the host/primary) — that's the multi-city road trip. For a concert
    performer there are no away appearances, so we use its own (primary) events.

    side: 'auto' (team->away, else concert), 'away' (force away), 'home'/'concert' (primary).
    """
    end_excl = (end + timedelta(days=1)).isoformat()
    away_ids: list[int] = []
    if side in ("auto", "away"):
        away = (db.table("events").select("id")
                .contains("performer_ids", [performer_id])
                .neq("primary_performer_id", performer_id)
                .gte("occurs_at_local", start.isoformat())
                .lt("occurs_at_local", end_excl)
                .limit(300).execute().data) or []
        away_ids = [int(r["id"]) for r in away]

    use_away = side == "away" or (side == "auto" and len(away_ids) >= 3)
    if use_away and away_ids:
        rows = (db.table("v_event_base").select(_TOUR_SELECT)
                .in_("tevo_event_id", away_ids)
                .order("event_date").limit(500).execute().data) or []
        return rows, "team_away"

    return fetch_performer_rows(db, performer_id, start, end), (
        "team_home" if away_ids else "concert")


def plan_tour_package(rows: list[dict], home: dict, qty: int, budget_km: float,
                      start: date, end: date, budget_usd: float | None = None,
                      max_events: int | None = None, max_km_per_day: float = 1200.0,
                      clear_at: float = DEFAULT_CLEAR_AT,
                      away_margin: float = DEFAULT_AWAY_MARGIN, mode: str = "concert") -> dict:
    """Pure: route the multi-city tour (within travel + fan-$ budget) and price every leg via
    the dual-mode retail model. Rows carry `_owned/_our_ask/_getin/_med/_qty` + coords."""
    qty = max(1, int(qty))
    usable = [r for r in rows if r.get("venue_lat") is not None and r.get("venue_lon") is not None]
    events = [row_to_event(r) for r in usable]
    prefs = {e.title.lower(): 1.0 for e in events}

    legmeta: dict[int, dict] = {}
    costs: dict[int, float] = {}
    for r in usable:
        eid = int(r["tevo_event_id"])
        listing = r.get("_listing")
        if listing and listing.get("unit_price") is not None:
            # auto-selected a real ticket group that fits qty -> bind to those seats
            pl = {
                "unit_price": listing["unit_price"],
                "sourcing": "owned" if listing.get("is_owned") else "market",
                "selection": "listing",
                "owned": r.get("_owned") or 0,
                "market_median": round(float(r["_med"]), 2) if r.get("_med") is not None else None,
                "seats": {k: listing.get(k) for k in
                          ("ticket_group_id", "section", "row", "available_qty",
                           "is_owned", "eticket", "instant", "format", "candidates")},
                "moved": qty if listing.get("is_owned") else 0,
            }
        else:
            # no live qualifying listing -> fall back to the model price (estimate)
            pl = price_leg(qty, r.get("_owned"), r.get("_our_ask"), r.get("_getin"),
                           r.get("_med"), r.get("_qty"), clear_at, away_margin)
            pl["selection"] = "estimate"
        pl["city"] = r.get("venue_city")
        pl["event_name"] = r.get("event_name")
        pl["coord_source"] = r.get("_coord_source", "venue")
        legmeta[eid] = pl
        u = pl.get("unit_price")
        costs[eid] = (u * qty) if u is not None else 0.0    # the fan's spend at this stop

    c = Constraints(home_name=home["name"], home_lat=float(home["lat"]), home_lon=float(home["lon"]),
                    start=start, end=end, max_travel_km=float(budget_km),
                    max_events=max_events, max_km_per_day=max_km_per_day)
    spend_cap = float(budget_usd) if budget_usd is not None else 1e12
    optimal, _ = plan_optimal_2b(events, prefs, c, costs, spend_cap)
    picked = {int(e.id) for e in optimal.events}

    def _leg(e, selected):
        m = dict(legmeta[int(e.id)])
        m.update(event_id=int(e.id), date=e.day.isoformat(),
                 city=(e.city or m.get("city")), venue=e.venue, selected=selected)
        return m

    pkg_legs = [_leg(e, True) for e in optimal.events]
    summ = summarize_package(pkg_legs, qty)
    return {
        "mode": mode,
        "qty_per_show": qty,
        "home": home,
        "budget_km": float(budget_km),
        "budget_usd": budget_usd,
        "window": {"start": start.isoformat(), "end": end.isoformat()},
        "stops_available": len(events),
        "package": {
            "legs": pkg_legs,
            "count": len(pkg_legs),
            "cities": len({l["city"] for l in pkg_legs if l.get("city")}),
            "travel_km": round(optimal.travel_km, 1),
            **summ,
        },
        "all_stops": [_leg(e, int(e.id) in picked)
                      for e in sorted(events, key=lambda e: (e.day, e.id))],
    }


def plan_performer_tour(db, performer_id: int, home_lat: float, home_lon: float,
                        qty: int, budget_km: float, start: date, end: date,
                        home_name: str = "Home", budget_usd: float | None = None,
                        side: str = "auto", clear_at: float = DEFAULT_CLEAR_AT,
                        away_margin: float = DEFAULT_AWAY_MARGIN,
                        max_events: int | None = None) -> dict:
    """End-to-end retail tour package: detect concert vs team-away, route + dual-mode price."""
    rows, mode = fetch_tour_events(db, performer_id, start, end, side)
    _apply_coord_fallback(db, rows)
    ids = [int(r["tevo_event_id"]) for r in rows]
    pricing = fetch_event_pricing(db, ids)
    listings = fetch_event_listings(db, ids, max(1, int(qty)))   # auto-select real seats
    for r in rows:
        eid = int(r["tevo_event_id"])
        p = pricing.get(eid)
        if p:
            r["_owned"], r["_our_ask"] = p["owned"], p["our_ask"]
            r["_getin"], r["_med"], r["_qty"] = p["getin"], p["med"], p["qty"]
        r["_listing"] = listings.get(eid)
    home = {"name": home_name, "lat": home_lat, "lon": home_lon}
    payload = plan_tour_package(rows, home, qty, budget_km, start, end,
                                budget_usd=budget_usd, max_events=max_events,
                                clear_at=clear_at, away_margin=away_margin, mode=mode)
    payload["performer_id"] = int(performer_id)
    return payload
