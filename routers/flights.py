"""D0 · FLIGHTS — Google-Flights-shaped ticket search over the book.

The buy-side twin of the broker desk: instead of "what is my position worth",
this answers "when + where should I buy, and is today a good price". The three
Google Flights primitives map onto data we already collect:

    Google Flights            FLIGHTS (tickets)
    ----------------------    ---------------------------------------------
    route + date search       performer / city / date-range search over
                              `events`
    price graph + date grid   cheapest get-in per event DATE across the
                              matched set (`event_listing_snapshot_daily`)
    "prices are currently      today's best get-in vs the event's OWN
     low/typical/high"        trailing 30d distribution (same table, which
                              has indefinite retention → real baselines)
    booking options per       one row per marketplace (SH/GT/VD/TM/TP live
     airline                  via TicketsData, EVO via `latest_event_metrics`,
                              SG via the daily snapshot columns)

Two data layers, deliberately:

  * BREADTH — `event_listing_snapshot_daily` (3 slots/day, indefinite
    retention, ~12.6k events/day). Every searchable event gets a current
    price, a history series, and a typical-price baseline from it.
  * DEPTH — `ticketsdata_listings_snapshots` (live per-listing rows). Only
    the TD-polled subset (credit-budgeted, low hundreds of events) has live
    cross-marketplace inventory, so it powers the per-event "booking options"
    + cheapest-listings panel and degrades to the daily columns when absent.

Read-only: every route is a SELECT through the service-role client. No writes,
no upstream calls (CLAUDE.md §1 + §2 — TicketsData data is read from what the
pollers already landed, this never triggers a paid fetch).

ID landmine (PROJECT_BIBLE §0): `event_listing_snapshot_daily.event_id` and
`latest_event_metrics.event_id` are TEvo event ids, but
`ticketsdata_listings_snapshots.event_id` is the PLATFORM-NATIVE id. The live
layer is reached tevo → `aq_event_map` → `ticketsdata_event_xref` →
(platform, native id). Never join a TD listing on a tevo id.
"""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone
from functools import partial
from typing import Any, Callable

from fastapi import APIRouter, Depends, HTTPException

from core.concurrency import run_parallel

# What a price INCLUDES. The daily snapshot table is not one basis: its
# populate function (`compute_event_listing_snapshot`) computes every TD column
# from `list_price` EXCEPT TickPick, which uses `price_with_fees`
#   eff_price = CASE WHEN platform = 'TP' THEN price_with_fees ELSE list_price END
# (mig 20260606160000 — TickPick is an all-in marketplace, its list_price is a
# seller base value that ran 5.6x low). The TEvo exchange get-in and the SG
# broker feed are likewise pre-fee. The LIVE listing layer, by contrast, reads
# `price_with_fees` for every platform. So "cheapest" is only meaningful WITHIN
# a basis — comparing an all-in $43 against a pre-fee $38 says nothing.
BASIS_ALL_IN = "all_in"      # what a buyer actually pays at checkout
BASIS_PRE_FEE = "pre_fee"    # list/ask before checkout fees

# One entry per marketplace we can price from the daily snapshot table:
#   key, display label, get-in column, median column, depth column, fee basis
DAILY_SOURCES: tuple[tuple[str, str, str, str, str, str], ...] = (
    ("evo", "EVO", "evo_retail_getin", "evo_retail_median", "evo_tickets_count", BASIS_PRE_FEE),
    ("sh", "StubHub", "td_sh_getin", "td_sh_median", "td_sh_listings", BASIS_PRE_FEE),
    ("gt", "Gametime", "td_gt_getin", "td_gt_median", "td_gt_listings", BASIS_PRE_FEE),
    ("vd", "VividSeats", "td_vd_getin", "td_vd_median", "td_vd_listings", BASIS_PRE_FEE),
    ("tp", "TickPick", "td_tp_getin", "td_tp_median", "td_tp_listings", BASIS_ALL_IN),
    ("tm", "Ticketmaster", "td_tm_getin", "td_tm_median", "td_tm_listings", BASIS_PRE_FEE),
    ("sg", "SeatGeek", "sg_all_getin", "sg_all_median", "sg_all_listings", BASIS_PRE_FEE),
)

# TicketsData platform code → display label, for the live booking-options rows.
TD_PLATFORM_LABELS = {
    "SH": "StubHub", "GT": "Gametime", "VD": "VividSeats",
    "TP": "TickPick", "TM": "Ticketmaster", "SG": "SeatGeek",
}

_DAILY_COLS = ",".join(
    ["event_id", "snapshot_date", "snapshot_slot", "captured_at",
     "amalgam_getin", "amalgam_median", "amalgam_source_count"]
    + [c for _k, _l, g, m, d, _b in DAILY_SOURCES for c in (g, m, d)]
)

_EVENT_COLS = ("id,name,occurs_at_local,venue_name,venue_location,"
               "primary_performer_id,primary_performer_name,event_type,state")

# Search knobs. Candidate cap bounds the follow-up price reads (one row per
# event per snapshot slot), so it is the real cost lever on this endpoint.
MAX_CANDIDATES = 220
BASELINE_DAYS = 30          # trailing window the "typical price" is drawn from
CURRENT_LOOKBACK_DAYS = 3   # how stale a "current" price may be before we drop it
DEAL_DISCOUNT_FLOOR = 0.30  # a 30%-below-typical price scores a full deal point


# --------------------------------------------------------------------------
# pure helpers (no DB) — the price math, kept side-effect free so it is
# directly testable and so a handler stays a thin read + assemble.
# --------------------------------------------------------------------------

def _num(v: Any) -> float | None:
    """Coerce a numeric-ish DB value to float; None for null/blank/garbage."""
    if v is None or v == "":
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if f > 0 else None


def _median(vals: list[float]) -> float | None:
    if not vals:
        return None
    s = sorted(vals)
    mid = len(s) // 2
    return s[mid] if len(s) % 2 else (s[mid - 1] + s[mid]) / 2


def _pctile(vals: list[float], p: float) -> float | None:
    """Nearest-rank percentile (p in 0..1). Small samples, so no interpolation."""
    if not vals:
        return None
    s = sorted(vals)
    idx = min(len(s) - 1, max(0, round(p * (len(s) - 1))))
    return s[idx]


def _clean_term(q: str | None) -> str:
    """Sanitize free text before it reaches a PostgREST `or=` filter string.

    PostgREST parses `or=(...)` as a comma/paren-delimited expression, so a
    raw comma or paren in user text would change the filter's SHAPE, not just
    its value. Keep letters/digits/space and a short punctuation allowlist.
    """
    if not q:
        return ""
    return re.sub(r"[^A-Za-z0-9 &._'\-]", " ", q).strip()[:60]


def _iso_day(d: date) -> str:
    return d.isoformat()


def _window(date_from: str | None, date_to: str | None, days: int,
            today: date) -> tuple[str, str]:
    """Resolve the search date window to [from, exclusive-to) day strings.

    `events.occurs_at_local` is TEXT ("2026-08-28T19:00:00-05:00"), so the
    range is a lexical prefix compare — the upper bound must be exclusive on
    the day AFTER date_to or same-day evening events fall out.
    """
    try:
        start = date.fromisoformat(date_from) if date_from else today
        end = date.fromisoformat(date_to) if date_to else start + timedelta(days=days)
    except ValueError:
        raise HTTPException(400, "date_from / date_to must be YYYY-MM-DD")
    if end < start:
        raise HTTPException(400, "date_to must not precede date_from")
    end = min(end, start + timedelta(days=365))
    return _iso_day(start), _iso_day(end + timedelta(days=1))


def _event_day(occurs_at_local: str | None) -> str | None:
    """Local calendar day of an event ('2026-08-28T19:00:00-05:00' → date)."""
    if not occurs_at_local or len(occurs_at_local) < 10:
        return None
    return occurs_at_local[:10]


def _row_sources(row: dict) -> list[dict]:
    """Per-marketplace prices present on one daily snapshot row."""
    out = []
    for key, label, getin_col, median_col, depth_col, basis in DAILY_SOURCES:
        getin = _num(row.get(getin_col))
        median = _num(row.get(median_col))
        if getin is None and median is None:
            continue
        depth = row.get(depth_col)
        out.append({
            "source": key, "label": label, "basis": basis,
            "getin": getin, "median": median,
            "depth": int(depth) if isinstance(depth, (int, float)) else None,
        })
    return out


def _best_of(sources: list[dict]) -> tuple[float | None, str | None, str | None]:
    """Cheapest get-in — compared only WITHIN one fee basis.

    All-in prices win the tie-break when any are present: that is what a buyer
    pays, and every pre-fee number in the same row would only grow at checkout.
    Ranking across bases is the bug this exists to prevent — it would let a
    $43 all-in price lose to a $38 pre-fee one that costs $46 at the door.
    """
    priced = [s for s in sources if s.get("getin") is not None]
    if not priced:
        return None, None, None
    all_in = [s for s in priced if s.get("basis") == BASIS_ALL_IN]
    best = min(all_in or priced, key=lambda s: s["getin"])
    return best["getin"], best["source"], best.get("basis")


def _anchor_source(rows: list[dict]) -> str | None:
    """The one marketplace a price HISTORY should be measured on.

    Cross-source coverage is ragged — TicketsData polling is credit-budgeted, so
    a given event has StubHub/Vivid/Gametime prices on some days and not others
    (98.5% of daily rows carry a single source at all). Taking min-across-
    whatever-exists per day makes the series jump when a marketplace appears or
    disappears, and the verdict then fires "great price" on a coverage change
    rather than a price move. Anchoring the series to the source with the most
    days in the window (ties broken by DAILY_SOURCES order) keeps every point
    on one basis and one market, so a move in the line is a move in the price.
    """
    counts: dict[str, int] = {}
    for row in rows:
        for s in _row_sources(row):
            if s["getin"] is not None:
                counts[s["source"]] = counts.get(s["source"], 0) + 1
    if not counts:
        return None
    order = {entry[0]: i for i, entry in enumerate(DAILY_SOURCES)}
    return min(counts, key=lambda k: (-counts[k], order[k]))


def _source_price(row: dict | None, source: str | None) -> float | None:
    """That one anchor source's get-in on a given row (None when absent)."""
    if row is None or source is None:
        return None
    hit = next((s for s in _row_sources(row) if s["source"] == source), None)
    return hit["getin"] if hit else None


def _pick_current(rows: list[dict]) -> dict | None:
    """Freshest daily row for one event (latest date, then latest capture)."""
    dated = [r for r in rows if r.get("snapshot_date")]
    if not dated:
        return None
    return max(dated, key=lambda r: (r["snapshot_date"], r.get("captured_at") or ""))


def _daily_series(rows: list[dict], anchor: str | None) -> list[dict]:
    """One point per day, all read off the SAME marketplace (`anchor`).

    A day where the anchor has no price is dropped rather than back-filled from
    another source — a gap is honest, a substituted source is a fake move.
    """
    by_day: dict[str, dict] = {}
    for r in rows:
        day = r.get("snapshot_date")
        if not day:
            continue
        prev = by_day.get(day)
        if prev is None or (r.get("captured_at") or "") >= (prev.get("captured_at") or ""):
            by_day[day] = r
    series = []
    for day in sorted(by_day):
        row = by_day[day]
        srcs = _row_sources(row)
        hit = next((s for s in srcs if s["source"] == anchor), None)
        if hit is None or hit["getin"] is None:
            continue
        series.append({
            "date": day, "price": round(hit["getin"], 2), "source": hit["source"],
            "basis": hit["basis"], "sources": len(srcs),
            "median": round(hit["median"], 2) if hit["median"] is not None else None,
        })
    return series


def _baseline(series: list[dict], current: float | None,
              anchor: str | None = None) -> dict:
    """Price insights for one event, from its OWN trailing price history.

    Mirrors the Google Flights verdict ("prices are currently low / typical /
    high") but computed per event rather than per route: the typical price is
    the median of the event's trailing daily get-ins, the band is p25..p75,
    and the trend compares the last week against the week before it.

    `current` MUST be the anchor source's price, not the row's cheapest — the
    verdict compares like with like or it is noise (see `_anchor_source`).
    """
    prices = [p["price"] for p in series]
    typical = _median(prices)
    low = _pctile(prices, 0.25)
    high = _pctile(prices, 0.75)
    recent = [p["price"] for p in series[-7:]]
    prior = [p["price"] for p in series[-21:-7]]
    recent_avg, prior_avg = _median(recent), _median(prior)
    trend = "flat"
    trend_pct = None
    if recent_avg is not None and prior_avg is not None:
        trend_pct = (recent_avg - prior_avg) / prior_avg
        if trend_pct >= 0.05:
            trend = "rising"
        elif trend_pct <= -0.05:
            trend = "falling"

    delta_pct = None
    verdict = "unknown"
    if current is not None and typical:
        delta_pct = (current - typical) / typical
        # Order matters: "deal" is the bottom quartile AND below the median, so
        # a flat history priced at its own typical reads "typical", not a deal.
        if current < typical:
            verdict = "deal" if (low is not None and current <= low) else "low"
        elif high is not None and current > high:
            verdict = "high"
        else:
            verdict = "typical"

    return {
        "source": anchor,
        "basis": next((e[5] for e in DAILY_SOURCES if e[0] == anchor), None),
        "typical": round(typical, 2) if typical else None,
        "band_low": round(low, 2) if low else None,
        "band_high": round(high, 2) if high else None,
        "cheapest_seen": round(min(prices), 2) if prices else None,
        "days_observed": len(prices),
        "delta_pct": round(delta_pct, 4) if delta_pct is not None else None,
        "verdict": verdict,
        "trend": trend,
        "trend_pct": round(trend_pct, 4) if trend_pct is not None else None,
    }


def _rank_pct(value: float, sorted_vals: list[float]) -> float:
    """Share of the result set priced at or above `value` (1.0 = cheapest)."""
    if not sorted_vals:
        return 0.0
    below = sum(1 for v in sorted_vals if v < value)
    return 1.0 - (below / len(sorted_vals))


def _score(price: float | None, all_prices: list[float], base: dict,
           source_count: int) -> float:
    """Google-Flights "Best" blend: mostly price, then deal quality, then how
    many independent marketplaces agree (confidence in the number)."""
    if price is None:
        return 0.0
    w_price = _rank_pct(price, all_prices)
    delta = base.get("delta_pct")
    w_deal = 0.0 if delta is None else max(0.0, min(1.0, -delta / DEAL_DISCOUNT_FLOOR))
    w_conf = min(source_count, 4) / 4
    return round(100 * (0.55 * w_price + 0.30 * w_deal + 0.15 * w_conf), 1)


def _reasons(item: dict, cheapest: float | None) -> list[str]:
    """Short human "why this row" chips, in the Google Flights idiom."""
    out = []
    base = item["insights"]
    if item["price"] is not None and cheapest is not None and item["price"] <= cheapest:
        out.append("Cheapest in this search")
    delta = base.get("delta_pct")
    if delta is not None and delta <= -0.05:
        out.append(f"{abs(round(delta * 100))}% below its usual price")
    elif delta is not None and delta >= 0.15:
        out.append(f"{round(delta * 100)}% above its usual price")
    if base.get("trend") == "falling":
        out.append("Prices falling this week")
    elif base.get("trend") == "rising":
        out.append("Prices rising this week")
    if item["source_count"] >= 3:
        out.append(f"{item['source_count']} marketplaces compared")
    return out


def _calendar(items: list[dict]) -> list[dict]:
    """The date grid: cheapest event per calendar day across the matched set."""
    by_day: dict[str, dict] = {}
    for it in items:
        day = it.get("event_date")
        price = it.get("price")
        if not day or price is None:
            continue
        slot = by_day.setdefault(day, {"date": day, "price": price, "events": 0,
                                       "event_id": it["event_id"],
                                       "event_name": it["name"]})
        slot["events"] += 1
        if price < slot["price"]:
            slot.update({"price": price, "event_id": it["event_id"],
                         "event_name": it["name"]})
    days = sorted(by_day.values(), key=lambda d: d["date"])
    prices = [d["price"] for d in days]
    floor = min(prices) if prices else None
    for d in days:
        d["price"] = round(d["price"], 2)
        d["is_cheapest"] = floor is not None and d["price"] <= round(floor, 2)
    return days


def _live_options(xrefs: list[dict], listing_batches: list[list[dict]]) -> tuple[list[dict], list[dict]]:
    """Per-marketplace booking options + the pooled cheapest live listings.

    Each batch is the newest-first listing rows for one xref; only the rows
    sharing that batch's newest `captured_at` are the current inventory (an
    older poll's rows are a different snapshot of the same event).
    """
    options: list[dict] = []
    pooled: list[dict] = []
    for xref, batch in zip(xrefs, listing_batches):
        rows = [r for r in batch if not r.get("is_parking")]
        if not rows:
            continue
        newest = max(r.get("captured_at") or "" for r in rows)
        rows = [r for r in rows if (r.get("captured_at") or "") == newest]
        prices = [p for p in (_num(r.get("price_with_fees")) or _num(r.get("list_price"))
                              for r in rows) if p is not None]
        if not prices:
            continue
        platform = xref.get("platform") or ""
        options.append({
            "source": platform.lower(),
            "platform": platform,
            "label": TD_PLATFORM_LABELS.get(platform, platform),
            # the live layer reads price_with_fees for every platform
            "basis": BASIS_ALL_IN,
            "getin": round(min(prices), 2),
            "median": round(_median(prices) or 0, 2),
            "listings": len(rows),
            "tickets": sum(int(r.get("quantity") or 0) for r in rows),
            "captured_at": newest,
            "event_url": xref.get("event_url"),
            "live": True,
        })
        for r in rows:
            price = _num(r.get("price_with_fees")) or _num(r.get("list_price"))
            if price is None:
                continue
            pooled.append({
                "platform": platform,
                "label": TD_PLATFORM_LABELS.get(platform, platform),
                "section": r.get("section"), "row": r.get("row"),
                "quantity": int(r.get("quantity") or 0),
                "price": round(price, 2),
                "event_url": xref.get("event_url"),
            })
    options.sort(key=lambda o: o["getin"])
    return options, pooled


def _cheapest_listings(pooled: list[dict], qty: int, limit: int) -> list[dict]:
    """The "fare" rows: cheapest live listings that can seat `qty` together."""
    ok = [p for p in pooled if p["quantity"] >= qty]
    ok.sort(key=lambda p: (p["price"], -p["quantity"]))
    return ok[:limit]


def _days_out(occurs_at_local: str | None, today: date) -> int | None:
    day = _event_day(occurs_at_local)
    if not day:
        return None
    try:
        return (date.fromisoformat(day) - today).days
    except ValueError:  # pragma: no cover - _event_day already shape-checks
        return None


# --------------------------------------------------------------------------
# router
# --------------------------------------------------------------------------

def build_flights_router(get_require_sb: Callable[[], Callable],
                         require_auth: Callable) -> APIRouter:
    router = APIRouter()

    def _today() -> date:
        return datetime.now(timezone.utc).date()

    def _candidates(db: Any, q: str, city: str, day_from: str, day_to: str,
                    limit: int) -> list[dict]:
        """Events matching the search box, cheapest-first sorted later."""
        sel = (db.table("events").select(_EVENT_COLS)
                 .neq("state", "ignored")
                 .gte("occurs_at_local", day_from)
                 .lt("occurs_at_local", day_to))
        term = _clean_term(q)
        if term:
            pat = f"*{term}*"
            sel = sel.or_(f"name.ilike.{pat},primary_performer_name.ilike.{pat}")
        place = _clean_term(city)
        if place:
            sel = sel.or_(f"venue_location.ilike.*{place}*,venue_name.ilike.*{place}*")
        return sel.order("occurs_at_local").limit(limit).execute().data or []

    def _price_rows(db: Any, event_ids: list[int], since: str,
                    until: str | None = None, slot: str | None = None) -> list[dict]:
        sel = (db.table("event_listing_snapshot_daily").select(_DAILY_COLS)
                 .in_("event_id", event_ids)
                 .gte("snapshot_date", since))
        if until:
            sel = sel.lt("snapshot_date", until)
        if slot:
            sel = sel.eq("snapshot_slot", slot)
        return sel.order("snapshot_date").limit(20000).execute().data or []

    @router.get("/api/broker/flights/search")
    def flights_search(
        q: str | None = None,
        city: str | None = None,
        date_from: str | None = None,
        date_to: str | None = None,
        days: int = 60,
        max_price: float | None = None,
        min_sources: int = 1,
        sort: str = "best",
        limit: int = 60,
        _=Depends(require_auth),
    ):
        """Search results + the price graph, in one round-trip.

        Returns `results` (ranked events, each with today's cheapest get-in,
        its per-marketplace breakdown, and a typical-price verdict) and
        `calendar` (cheapest event per day across the whole matched set — the
        date grid the FE draws above the list).
        """
        if sort not in ("best", "price", "date", "deal"):
            raise HTTPException(400, "sort must be best, price, date or deal")
        days = max(1, min(int(days), 365))
        limit = max(1, min(int(limit), 200))
        today = _today()
        day_from, day_to = _window(date_from, date_to, days, today)

        db = get_require_sb()()
        events = _candidates(db, q or "", city or "", day_from, day_to, MAX_CANDIDATES)
        if not events:
            return {"results": [], "calendar": [], "meta": {
                "candidates": 0, "priced": 0, "window": [day_from, day_to],
                "sort": sort}}

        ids = [int(e["id"]) for e in events]
        current_since = _iso_day(today - timedelta(days=CURRENT_LOOKBACK_DAYS))
        baseline_since = _iso_day(today - timedelta(days=BASELINE_DAYS))
        current_rows, history_rows = run_parallel([
            lambda: _price_rows(db, ids, current_since),
            lambda: _price_rows(db, ids, baseline_since, until=current_since,
                                slot="evening"),
        ])

        by_event_current: dict[int, list[dict]] = {}
        for r in current_rows:
            by_event_current.setdefault(int(r["event_id"]), []).append(r)
        by_event_history: dict[int, list[dict]] = {}
        for r in history_rows:
            by_event_history.setdefault(int(r["event_id"]), []).append(r)

        items: list[dict[str, Any]] = []
        for ev in events:
            eid = int(ev["id"])
            current = _pick_current(by_event_current.get(eid, []))
            if current is None:
                continue
            sources = _row_sources(current)
            price, price_source, price_basis = _best_of(sources)
            if price is None:
                continue
            if max_price is not None and price > max_price:
                continue
            if len(sources) < min_sources:
                continue
            # The headline is the cheapest comparable price to BUY at; the
            # verdict is measured on one anchor market across the window, so
            # the two can name different sources. Both are labelled.
            history = by_event_history.get(eid, [])
            anchor = _anchor_source(history + [current])
            series = _daily_series(history, anchor)
            insights = _baseline(series, _source_price(current, anchor), anchor)
            items.append({
                "event_id": eid,
                "name": ev.get("name"),
                "performer": ev.get("primary_performer_name"),
                "performer_id": ev.get("primary_performer_id"),
                "venue": ev.get("venue_name"),
                "location": ev.get("venue_location"),
                "occurs_at_local": ev.get("occurs_at_local"),
                "event_date": _event_day(ev.get("occurs_at_local")),
                "days_out": _days_out(ev.get("occurs_at_local"), today),
                "event_type": ev.get("event_type"),
                "price": round(price, 2),
                "price_source": price_source,
                "price_basis": price_basis,
                "sources": sources,
                "source_count": len(sources),
                "priced_at": current.get("captured_at"),
                "insights": insights,
                "spark": [p["price"] for p in series[-21:]],
            })

        all_prices = sorted(it["price"] for it in items)
        cheapest = all_prices[0] if all_prices else None
        for it in items:
            it["score"] = _score(it["price"], all_prices, it["insights"],
                                 it["source_count"])
            it["reasons"] = _reasons(it, cheapest)

        calendar = _calendar(items)

        if sort == "price":
            items.sort(key=lambda i: i["price"])
        elif sort == "date":
            items.sort(key=lambda i: i["occurs_at_local"] or "")
        elif sort == "deal":
            items.sort(key=lambda i: i["insights"].get("delta_pct") or 0.0)
        else:
            items.sort(key=lambda i: -float(i["score"]))

        return {
            "results": items[:limit],
            "calendar": calendar,
            "meta": {
                "candidates": len(events),
                "priced": len(items),
                "window": [day_from, day_to],
                "sort": sort,
                "cheapest": cheapest,
            },
        }

    @router.get("/api/broker/flights/event/{event_id}")
    def flights_event(event_id: int, qty: int = 1, history_days: int = 90,
                      _=Depends(require_auth)):
        """One event's booking options — the "which site, what seat" panel.

        Live per-marketplace inventory (TicketsData listings landed by the
        pollers) when we have it, the daily cross-source columns otherwise,
        plus the full price history + insights behind the verdict chip.
        """
        qty = max(1, min(int(qty), 12))
        history_days = max(7, min(int(history_days), 365))
        today = _today()
        db = get_require_sb()()

        ev = (db.table("events").select(_EVENT_COLS)
                .eq("id", event_id).limit(1).execute().data or [])
        if not ev:
            raise HTTPException(404, "event not found")
        event = ev[0]

        since = _iso_day(today - timedelta(days=history_days))
        rows, aq_rows, evo_rows = run_parallel([
            lambda: _price_rows(db, [event_id], since),
            lambda: (db.table("aq_event_map").select("aq_short_event_id")
                       .eq("tevo_event_id", event_id).limit(20).execute().data or []),
            lambda: (db.table("latest_event_metrics")
                       .select("event_id,captured_at,getin_price,retail_median,"
                               "tickets_count,groups_count")
                       .eq("event_id", event_id).limit(1).execute().data or []),
        ])

        current_row = _pick_current(rows)
        anchor = _anchor_source(rows)
        series = _daily_series(rows, anchor)
        daily_sources = _row_sources(current_row) if current_row else []
        insights = _baseline([p for p in series if p["date"] < _iso_day(today)],
                             _source_price(current_row, anchor), anchor)

        # Live layer: tevo → aq short ids → TD xrefs → newest listing batch.
        short_ids = [r["aq_short_event_id"] for r in aq_rows if r.get("aq_short_event_id")]
        xrefs: list[dict] = []
        if short_ids:
            xrefs = (db.table("ticketsdata_event_xref")
                       .select("platform,event_id,event_url,last_fetched_at")
                       .in_("aq_short_event_id", short_ids)
                       .eq("active", True)
                       .gte("last_fetched_at",
                            (datetime.now(timezone.utc) - timedelta(days=7)).isoformat())
                       .limit(20).execute().data or [])

        def _batch(xref: dict) -> list[dict]:
            return (db.table("ticketsdata_listings_snapshots")
                      .select("platform,captured_at,section,row,quantity,"
                              "list_price,price_with_fees,is_parking")
                      .eq("event_id", xref["event_id"])
                      .eq("platform", xref["platform"])
                      .order("captured_at", desc=True)
                      .limit(1500).execute().data or [])

        batches = run_parallel([partial(_batch, x) for x in xrefs]) if xrefs else []
        options, pooled = _live_options(xrefs, batches)

        # Marketplaces with no live pull fall back to their daily-snapshot
        # price so the comparison table still shows every source we can see.
        live_keys = {o["source"] for o in options}
        for s in daily_sources:
            if s["source"] in live_keys:
                continue
            options.append({
                "source": s["source"], "platform": s["source"].upper(),
                "label": s["label"], "basis": s["basis"],
                "getin": s["getin"], "median": s["median"],
                "listings": s["depth"], "tickets": None,
                "captured_at": current_row.get("captured_at") if current_row else None,
                "event_url": None, "live": False,
            })
        evo = evo_rows[0] if evo_rows else None
        if evo and _num(evo.get("getin_price")) is not None:
            options = [o for o in options if o["source"] != "evo"]
            options.append({
                "source": "evo", "platform": "EVO", "label": "EVO (our book)",
                "basis": BASIS_PRE_FEE,   # TEvo exchange ask, before fees
                "getin": _num(evo.get("getin_price")),
                "median": _num(evo.get("retail_median")),
                "listings": evo.get("groups_count"),
                "tickets": evo.get("tickets_count"),
                "captured_at": evo.get("captured_at"), "event_url": None,
                "live": True,
            })
        options.sort(key=lambda o: (o["getin"] is None, o["getin"] or 0))

        best_price, best_source, best_basis = _best_of(options)
        return {
            "event": {
                "event_id": event_id,
                "name": event.get("name"),
                "performer": event.get("primary_performer_name"),
                "performer_id": event.get("primary_performer_id"),
                "venue": event.get("venue_name"),
                "location": event.get("venue_location"),
                "occurs_at_local": event.get("occurs_at_local"),
                "event_date": _event_day(event.get("occurs_at_local")),
                "days_out": _days_out(event.get("occurs_at_local"), today),
            },
            "price": best_price,
            "price_source": best_source,
            "price_basis": best_basis,
            "options": options,
            "listings": _cheapest_listings(pooled, qty, 30),
            "listings_qty": qty,
            "live_platforms": sorted(live_keys),
            "history": series,
            "insights": insights,
        }

    @router.get("/api/broker/flights/suggest")
    def flights_suggest(q: str, limit: int = 8, _=Depends(require_auth)):
        """Typeahead for the WHO box — performers with upcoming events."""
        term = _clean_term(q)
        limit = max(1, min(int(limit), 20))
        if len(term) < 2:
            return {"suggestions": []}
        db = get_require_sb()()
        rows = (db.table("events")
                  .select("primary_performer_id,primary_performer_name,event_type")
                  .neq("state", "ignored")
                  .gte("occurs_at_local", _iso_day(_today()))
                  .ilike("primary_performer_name", f"*{term}*")
                  .order("occurs_at_local")
                  .limit(400).execute().data or [])
        seen: dict[int, dict] = {}
        for r in rows:
            pid = r.get("primary_performer_id")
            name = r.get("primary_performer_name")
            if pid is None or not name:
                continue
            hit = seen.setdefault(int(pid), {
                "performer_id": int(pid), "name": name,
                "event_type": r.get("event_type"), "events": 0})
            hit["events"] += 1
        out = sorted(seen.values(), key=lambda s: -s["events"])[:limit]
        return {"suggestions": out}

    return router
