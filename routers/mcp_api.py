"""S4K Terminal as an MCP server — /mcp (Streamable HTTP, stateless, JSON).

Callers authenticate with a bearer API key (``Authorization: Bearer s4k_...``).
The key is hashed (sha256) and resolved by ``mcp_verify_key`` (migs
20261008150000 + 20261021190000) to a tier plus its limits:

- ``external`` (anyone who signed up at /developers): public market data —
  event/performer/venue search, SeatGeek market sales pace, price history +
  zone prices + forecast, the daily top-selling chart, performer trends,
  multi-source price movers, competing events, prediction markets, sports
  state, news, weather, a per-feed freshness report, and read-only queries
  over a whitelist of public views.
- ``internal`` (our team): everything external gets, plus our book — pickups,
  per-event orders across every source, home stats, the market chart with our
  positions excluded, owned events, and the wider ``query_view`` whitelist.

Each tier is its own MCP server, so an external caller never even sees the
internal tool list, and every external column list is explicit — no owned
counts, order rows, buyer data or wholesale prices leave the internal tier.
Every tool answers with the as-of timestamps of the rows it used; the
``data_freshness`` tool says how fresh each feed is right now (the TEvo get-in
feed has been paused since 2026-09-27 and is labelled so).

Per key: ``rate_per_min`` is enforced in-process (sliding window, same limiter
as the HTTP routes) and ``daily_quota`` against ``mcp_usage_daily``; each
request is counted with ``mcp_count_call``. All reads go through the
service-role client; nothing here writes except the usage stamp, and no
upstream marketplace API is called (CLAUDE.md rules 1-2).
"""
from __future__ import annotations

import contextlib
import hashlib
import inspect
import json
import threading
import time
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import anyio
from mcp.server.mcpserver import MCPServer
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations

INTERNAL, EXTERNAL = "internal", "external"
DEFAULT_RATE_PER_MIN, DEFAULT_DAILY_QUOTA = 60, 2000
CACHE_TTL_S = 60.0
STALE_AFTER_H = 48.0

# --------------------------------------------------------------------------
# query_view whitelists: view → columns a caller may select/filter/sort on.
# EXTERNAL = public market data only (no owned counts, orders, buyer PII).
# INTERNAL adds our book and the owned columns.
# --------------------------------------------------------------------------
EXTERNAL_QUERY_VIEWS: dict[str, tuple[str, ...]] = {
    "events": ("id", "name", "occurs_at_local", "venue_id", "venue_name", "venue_location",
               "event_type", "primary_performer_id", "primary_performer_name", "popularity_score"),
    "seatgeek_sales_snapshots": ("tevo_event_id", "sg_event_id", "sg_sale_id", "sale_at_utc",
                                 "broadcast_price", "quantity", "section", "row"),
    "event_listing_snapshot_daily": ("event_id", "snapshot_date", "captured_at",
                                     "evo_tickets_count", "evo_retail_getin", "evo_retail_median",
                                     "sg_all_listings", "sg_all_tickets", "sg_all_getin",
                                     "sg_all_median", "amalgam_getin", "amalgam_median"),
    "event_competitors_snapshot": ("tevo_event_id", "competitors_count", "competitors",
                                   "refreshed_at"),
    "sg_market_chart": ("chart_date", "rank", "prev_rank", "peak_rank", "days_on_chart",
                        "chart_score", "blended_score", "pct_volume", "pct_median", "ma7_volume",
                        "ma7_median", "ma7_gross", "days_with_sales", "platform_breadth",
                        "market_median_all", "tevo_event_id", "sg_event_id", "sg_event_name",
                        "sg_venue_name", "sg_datetime_utc"),
    "performer_metrics_daily": ("performer_id", "snapshot_date", "split", "performer_name",
                                "what_event_type", "event_count", "evo_tickets_total",
                                "sg_all_tickets_total", "getin_min", "getin_median", "price_min",
                                "price_median", "price_p90"),
    "prediction_markets": ("source", "market_id", "league", "market_type", "title", "question",
                           "team_name", "event_date", "close_time", "yes_price", "no_price",
                           "last_price", "volume", "url", "status", "updated_at"),
    "v_reddit_news_ticker": ("reddit_post_id", "subreddit", "league", "title", "permalink",
                             "link_url", "link_flair_text", "created_utc"),
}
QUERY_VIEWS: dict[str, tuple[str, ...]] = {
    **EXTERNAL_QUERY_VIEWS,
    "event_listing_snapshot_daily": EXTERNAL_QUERY_VIEWS["event_listing_snapshot_daily"]
    + ("evo_owned_tickets", "sg_owned_tickets"),
    "v_s4kcs_orders": ("source", "s4k_order_id", "order_status", "event_name", "event_date",
                       "venue_name", "venue_city", "venue_state", "section", "row", "quantity",
                       "price_per_ticket", "purchase_date", "delivery", "inhand_date",
                       "tevo_event_id"),
    "seatgeek_orders": ("sg_order_id", "status", "created_at_sg", "sg_event_id", "sg_event_name",
                        "sale_price", "sale_section", "sale_row", "sale_quantity",
                        "payment_total", "tevo_event_id"),
}
FILTER_OPS = ("eq", "neq", "gt", "gte", "lt", "lte", "ilike", "in")
MAX_ROWS = 500

PUBLIC_EVENT_COLS = "id,name,occurs_at_local,venue_id,venue_name,venue_location,event_type," \
                    "primary_performer_id,primary_performer_name,popularity_score"
MARKET_CHART_COLS = ",".join(EXTERNAL_QUERY_VIEWS["sg_market_chart"])
PERFORMER_COLS = ",".join(EXTERNAL_QUERY_VIEWS["performer_metrics_daily"])
PREDICTION_COLS = ",".join(EXTERNAL_QUERY_VIEWS["prediction_markets"])
NEWS_COLS = ",".join(EXTERNAL_QUERY_VIEWS["v_reddit_news_ticker"])
SPORTS_COLS = ("espn_event_id,espn_league,captured_at,state,status_short,home_team_id,away_team_id,"
               "home_score,away_score,odds_provider,spread,over_under,home_ml,away_ml,"
               "home_win_prob,attendance")
WEATHER_COLS = ("tevo_event_id,event_name,occurs_at_local,venue_name,is_indoor,days_to_event,"
                "weather_kind,temp_f,precip_in,precip_pct,wind_mph,weather_summary,weather_alerts,"
                "fcst_temp_f,fcst_precip_pct,fcst_wind_mph,fcst_summary,climo_avg_temp_f,"
                "climo_precip_pct,climo_modal_summary")
# event_movers_agg: per-source recent/prior medians (owned columns deliberately absent)
MOVER_SOURCES = {"ev": "tevo", "sg": "seatgeek", "sh": "stubhub", "gt": "gametime", "vd": "vivid"}
MOVER_COLS = "event_id,window_days,computed_at,days_to_event," + ",".join(
    f"{p}_price_recent,{p}_price_prior,{p}_cur_price" for p in MOVER_SOURCES)


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def _clamp(v: Any, lo: int, hi: int, default: int) -> int:
    try:
        n = int(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(n, hi))


def _as_of(ts: Any) -> dict:
    """Freshness block for a row timestamp: when, how old, and whether it is
    older than STALE_AFTER_H (so a bot never mistakes a paused feed for live)."""
    if not ts:
        return {"as_of": None, "age_hours": None, "stale": True}
    try:
        t = datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - t).total_seconds() / 3600
    except ValueError:
        return {"as_of": ts, "age_hours": None, "stale": True}
    return {"as_of": ts, "age_hours": round(age, 1), "stale": age > STALE_AFTER_H}


class _TTLCache:
    """Tiny thread-safe TTL cache (same shape as routers/prices.py)."""

    def __init__(self, ttl: float, max_items: int = 256):
        self.ttl, self.max_items = ttl, max_items
        self._d: dict[Any, tuple[float, Any]] = {}
        self._lock = threading.Lock()

    def get(self, key):
        with self._lock:
            hit = self._d.get(key)
            if hit is None or time.monotonic() - hit[0] > self.ttl:
                return None
            return hit[1]

    def put(self, key, value):
        with self._lock:
            if len(self._d) >= self.max_items and key not in self._d:
                self._d.pop(min(self._d, key=lambda k: self._d[k][0]), None)
            self._d[key] = (time.monotonic(), value)


_cache = _TTLCache(CACHE_TTL_S)


def reset_cache() -> None:
    """Drop every cached tool answer (tests; ops after a data backfill)."""
    with _cache._lock:
        _cache._d.clear()


def _cached(fn: Callable) -> Callable:
    """Cache a tool's result for CACHE_TTL_S keyed by its non-db arguments —
    for the shared, slow-moving answers (chart, movers, freshness)."""
    def wrapper(db, *args, **kwargs):
        key = (fn.__name__, args, tuple(sorted(kwargs.items())))
        hit = _cache.get(key)
        if hit is not None:
            return hit
        out = fn(db, *args, **kwargs)
        _cache.put(key, out)
        return out
    wrapper.__name__, wrapper.__doc__, wrapper.__wrapped__ = fn.__name__, fn.__doc__, fn  # type: ignore[attr-defined]
    wrapper.__signature__ = inspect.signature(fn)  # type: ignore[attr-defined]
    wrapper.__annotations__ = dict(fn.__annotations__)
    return wrapper


def _rpc(db, name: str, args: dict | None = None):
    return db.rpc(name, args or {}).execute().data


# --------------------------------------------------------------------------
# External tools — public market data. Plain functions over a Supabase client.
# --------------------------------------------------------------------------

def search(db, query: str, limit: int = 8) -> dict:
    """Find performers, venues and upcoming events matching a name fragment
    (min 2 chars). Returns ids to feed the other tools."""
    out = _rpc(db, "price_tracker_search", {"p_q": (query or "").strip()[:80],
                                            "p_limit": _clamp(limit, 1, 25, 8)}) or {}
    return {"query": query, **out}


def search_events(db, query: str = "", date_from: str | None = None,
                  date_to: str | None = None, limit: int = 20) -> dict:
    """Find events by name (case-insensitive) and local date range (YYYY-MM-DD)."""
    limit = _clamp(limit, 1, 100, 20)
    q = db.table("events").select(PUBLIC_EVENT_COLS)
    if query and query.strip():
        q = q.ilike("name", f"%{query.strip()}%")
    q = q.gte("occurs_at_local", (date_from or datetime.now(timezone.utc).strftime("%Y-%m-%d"))[:10])
    if date_to:
        q = q.lte("occurs_at_local", date_to[:10] + "T23:59:59")
    rows = q.order("occurs_at_local").limit(limit).execute().data or []
    return {"events": rows, "count": len(rows)}


def event_market(db, event_id: int, days: int = 30) -> dict:
    """Public market view of one event: details, SeatGeek sales per day (all
    sellers, distinct sales) and competing events within 20 mi / ±24 h."""
    days = _clamp(days, 1, 180, 30)
    ev = db.table("events").select(PUBLIC_EVENT_COLS).eq("id", event_id).limit(1).execute().data or []
    if not ev:
        return {"error": f"event {event_id} not found"}
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    sales = db.table("seatgeek_sales_snapshots").select("sg_sale_id,sale_at_utc,quantity,broadcast_price") \
        .eq("tevo_event_id", event_id).gte("sale_at_utc", since).limit(5000).execute().data or []
    seen: dict[Any, dict] = {}
    for s in sales:
        seen.setdefault(s.get("sg_sale_id"), s)
    per_day: dict[str, dict] = {}
    latest = None
    for s in seen.values():
        d = str(s.get("sale_at_utc") or "")[:10]
        latest = max(latest or "", str(s.get("sale_at_utc") or ""))
        row = per_day.setdefault(d, {"day": d, "sales": 0, "tickets": 0, "prices": []})
        row["sales"] += 1
        row["tickets"] += int(s.get("quantity") or 0)
        if s.get("broadcast_price") is not None:
            row["prices"].append(float(s["broadcast_price"]))
    daily = []
    for d in sorted(per_day):
        r = per_day[d]
        p = sorted(r.pop("prices"))
        r["median_price"] = p[len(p) // 2] if p else None
        daily.append(r)
    comp = db.table("event_competitors_snapshot").select("competitors_count,competitors,refreshed_at") \
        .eq("tevo_event_id", event_id).limit(1).execute().data or []
    return {
        "event": ev[0],
        "seatgeek_market": {"days": days, "tracked": bool(sales), "total_sales": len(seen),
                            "daily": daily, "last_sale_at": latest or None},
        "competing_events": comp[0] if comp else {"competitors_count": 0, "competitors": []},
    }


def event_prices(db, event_id: int) -> dict:
    """Get-in price history, per-zone get-in, weather and a 24 h direction
    forecast for one event (TEvo-based; this feed is paused since 2026-09-27 —
    check `freshness.stale`). Event ids are TEvo event ids."""
    out = _rpc(db, "price_tracker_event", {"p_event_id": event_id})
    if not out:
        return {"error": f"event {event_id} not found"}
    cur = out.get("current") or {}
    out["freshness"] = _as_of(cur.get("captured_at"))
    return out


@_cached
def top_market_events(db, limit: int = 25, chart_date: str | None = None) -> dict:
    """The daily top-selling events chart (SeatGeek sales across all sellers,
    7-day moving averages, rank moves vs the previous day). Latest day by
    default; pass chart_date=YYYY-MM-DD for history."""
    limit = _clamp(limit, 1, 100, 25)
    if chart_date:
        day = chart_date[:10]
    else:
        head = db.table("sg_market_chart").select("chart_date").order("chart_date", desc=True) \
            .limit(1).execute().data or []
        if not head:
            return {"chart_date": None, "events": [], "freshness": _as_of(None)}
        day = head[0]["chart_date"]
    rows = db.table("sg_market_chart").select(MARKET_CHART_COLS).eq("chart_date", day) \
        .order("rank").limit(limit).execute().data or []
    for r in rows:
        pr = r.get("prev_rank")
        r["rank_change"] = (pr - r["rank"]) if (pr is not None and r.get("rank") is not None) else None
    return {"chart_date": day, "events": rows, "count": len(rows), "freshness": _as_of(day)}


def performer_trend(db, performer_id: int, days: int = 90, split: str = "all") -> dict:
    """Daily trend for one performer/team: upcoming event count, tickets listed
    (TEvo + SeatGeek), get-in and median prices. split = all | home | away."""
    days = _clamp(days, 1, 730, 90)
    split = split if split in ("all", "home", "away") else "all"
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    rows = db.table("performer_metrics_daily").select(PERFORMER_COLS).eq("performer_id", performer_id) \
        .eq("split", split).gte("snapshot_date", since).order("snapshot_date").limit(800).execute().data or []
    last = rows[-1]["snapshot_date"] if rows else None
    return {"performer_id": performer_id, "split": split, "days": days, "series": rows,
            "performer_name": rows[-1].get("performer_name") if rows else None,
            "freshness": _as_of(last)}


@_cached
def price_movers(db, window_days: int = 30, direction: str = "up", source: str = "seatgeek",
                 limit: int = 25) -> dict:
    """Events whose market price moved most, recent window vs the prior one,
    per source (seatgeek | tevo | stubhub | gametime | vivid). window_days =
    event horizon (7 | 15 | 30 | 180 | 365); direction = up | down."""
    window_days = window_days if window_days in (7, 15, 30, 180, 365) else 30
    prefix = next((p for p, n in MOVER_SOURCES.items() if n == source), "sg")
    direction = "down" if str(direction).lower() == "down" else "up"
    limit = _clamp(limit, 1, 100, 25)
    rows = db.table("event_movers_agg").select(MOVER_COLS).eq("window_days", window_days) \
        .limit(5000).execute().data or []
    latest = max((r.get("computed_at") or "" for r in rows), default="")
    scored = []
    for r in rows:
        if r.get("computed_at") != latest:
            continue
        rec, pri = r.get(f"{prefix}_price_recent"), r.get(f"{prefix}_price_prior")
        if rec is None or not pri:
            continue
        pct = (float(rec) - float(pri)) / float(pri) * 100.0
        scored.append({
            "event_id": r["event_id"], "days_to_event": r.get("days_to_event"),
            "source": MOVER_SOURCES[prefix], "price_recent": rec, "price_prior": pri,
            "price_now": r.get(f"{prefix}_cur_price"), "change_pct": round(pct, 1),
            "all_sources": {n: {"recent": r.get(f"{p}_price_recent"), "prior": r.get(f"{p}_price_prior"),
                                "now": r.get(f"{p}_cur_price")} for p, n in MOVER_SOURCES.items()},
        })
    scored.sort(key=lambda x: x["change_pct"], reverse=(direction == "up"))
    top = scored[:limit]
    if top:
        ids = [x["event_id"] for x in top]
        names = {e["id"]: e for e in (db.table("events").select(PUBLIC_EVENT_COLS).in_("id", ids)
                                      .limit(len(ids)).execute().data or [])}
        for x in top:
            x["event"] = names.get(x["event_id"])
    return {"window_days": window_days, "source": MOVER_SOURCES[prefix], "direction": direction,
            "movers": top, "count": len(top), "freshness": _as_of(latest or None)}


def competing_events(db, event_id: int) -> dict:
    """Other events within 20 mi / ±24 h of this one (demand competition)."""
    rows = db.table("event_competitors_snapshot").select("tevo_event_id,competitors_count,competitors,refreshed_at") \
        .eq("tevo_event_id", event_id).limit(1).execute().data or []
    if not rows:
        return {"event_id": event_id, "competitors_count": 0, "competitors": [], "freshness": _as_of(None)}
    r = rows[0]
    return {**r, "freshness": _as_of(r.get("refreshed_at"))}


def prediction_markets(db, event_id: int | None = None, performer_id: int | None = None,
                       league: str | None = None, limit: int = 50) -> dict:
    """Kalshi / Polymarket prices (implied probability 0..1) for a game
    (event_id), a team (performer_id) or a whole league (NFL | NBA | MLB | NHL)."""
    limit = _clamp(limit, 1, 200, 50)
    q = db.table("prediction_markets").select(PREDICTION_COLS)
    if event_id is not None or performer_id is not None:
        xq = db.table("prediction_market_xref").select("market_id")
        xq = xq.eq("tevo_event_id", event_id) if event_id is not None else xq.eq("tevo_performer_id", performer_id)
        ids = [x["market_id"] for x in (xq.limit(limit).execute().data or [])]
        if not ids:
            return {"markets": [], "count": 0, "freshness": _as_of(None)}
        q = q.in_("market_id", ids)
    elif league:
        q = q.eq("league", league.upper()[:8])
    rows = q.order("updated_at", desc=True).limit(limit).execute().data or []
    return {"markets": rows, "count": len(rows),
            "freshness": _as_of(rows[0]["updated_at"] if rows else None)}


def sports_context(db, league: str, espn_event_id: str | None = None, limit: int = 50) -> dict:
    """ESPN game state for a league (NFL | NBA | MLB | NHL | WNBA | MLS | NCAA):
    status, scores, odds (spread / total / moneylines), win probability,
    attendance. Newest snapshots first; narrow with espn_event_id."""
    limit = _clamp(limit, 1, 200, 50)
    q = db.table("espn_event_snapshots").select(SPORTS_COLS).eq("espn_league", (league or "").lower()[:12])
    if espn_event_id:
        q = q.eq("espn_event_id", str(espn_event_id)[:32])
    rows = q.order("captured_at", desc=True).limit(limit).execute().data or []
    return {"league": league, "games": rows, "count": len(rows),
            "freshness": _as_of(rows[0]["captured_at"] if rows else None)}


def news(db, league: str | None = None, query: str | None = None, limit: int = 30) -> dict:
    """Latest Reddit news headlines (48 h window) by league (NFL, NBA, MLB,
    NHL, NCAA-FB, Concerts, Broadway, ...) and/or title fragment."""
    limit = _clamp(limit, 1, 100, 30)
    q = db.table("v_reddit_news_ticker").select(NEWS_COLS)
    if league:
        q = q.ilike("league", league[:24])
    if query and query.strip():
        q = q.ilike("title", f"%{query.strip()[:80]}%")
    rows = q.order("created_utc", desc=True).limit(limit).execute().data or []
    return {"items": rows, "count": len(rows),
            "freshness": _as_of(rows[0]["created_utc"] if rows else None)}


def event_weather(db, event_id: int) -> dict:
    """Forecast (inside 10 days) or climatology for the event's venue + any
    active NWS alerts; indoor venues say so."""
    rows = db.table("v_event_weather_with_fallback").select(WEATHER_COLS) \
        .eq("tevo_event_id", event_id).limit(1).execute().data or []
    return rows[0] if rows else {"error": f"event {event_id} not found"}


FORECAST_MAX_SECTIONS = 5
# Keys of predict_event_clearing_price's answer that describe OUR book — never external.
_BOOK_KEYS = ("own_book_gap",)


def _strip_book(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {k: _strip_book(v) for k, v in obj.items() if k not in _BOOK_KEYS}
    if isinstance(obj, list):
        return [_strip_book(v) for v in obj]
    return obj


def _forecast_sections_by_inventory(db, event_id: int, n: int) -> list[str]:
    """Fallback when an event has no recent sales: its sections with the most
    tickets on the latest TEvo capture (section_metrics PK = event_id, captured_at)."""
    rows = db.table("section_metrics").select("section,tickets_count,is_ancillary,captured_at") \
        .eq("event_id", event_id).order("captured_at", desc=True).limit(400).execute().data or []
    if not rows:
        return []
    latest = rows[0].get("captured_at")
    secs = [r for r in rows if r.get("captured_at") == latest and not r.get("is_ancillary")
            and str(r.get("section") or "").strip()]
    secs.sort(key=lambda r: (-(r.get("tickets_count") or 0), str(r.get("section"))))
    return [str(r["section"]).strip().lower() for r in secs[:n]]


def _guard_forecast(f: dict) -> dict:
    """Label confidence and refuse to publish a prior-only number above the live market.

    With no realized sales the forecaster leans on performer/road-draw priors, which can be
    stale (e.g. a team's summer `cast_price_ref` median) and land above every current ask.
    Then `expected_clearing` is re-anchored to the live ask x the category's sold-to-ask
    ratio and the raw model number is kept as `model_estimate`."""
    n = f.get("realized_sample_n") or 0
    f["confidence"] = "high" if n >= 8 else "medium" if n >= 3 else "low"
    ask = f.get("section_ask_median")
    exp = f.get("expected_clearing")
    if n == 0 and not f.get("section_tickets"):
        f["warning"] = ("no sales and no current listings in this section — the estimate is "
                        "prior-only; check event_market/team_report before using it")
    elif n == 0 and ask and exp and exp > ask:
        anchor = ((f.get("signals") or {}).get("ask_x_ratio") or {}).get("value") \
            or round(ask * (f.get("sold_to_ask_ratio") or 1.0), 2)
        f["model_estimate"] = exp
        f["expected_clearing"] = anchor
        f["lo"] = min(f.get("lo") or anchor, anchor)
        f["hi"] = ask
        f["warning"] = ("no realized sales in this section and the prior-driven model estimate "
                        "was above every current ask, so expected_clearing is anchored to the "
                        "live ask x sold-to-ask ratio (band up to the ask median). Low confidence.")
    return f


def price_forecast(db, event_id: int, section: str | None = None, max_sections: int = 3) -> dict:
    """Predicted clearing price for an event section: `expected_clearing` with a
    `lo`–`hi` band, `price_heading_24h`, the chance of a sale above ask, and the
    signals behind it (recent SeatGeek sales in the section, current asks x the
    category's sold-to-ask ratio, section and opponent priors, demand context:
    chart rank, injuries, attendance, weather). Every forecast carries
    `confidence` (high/medium/low by realized sales used) and a `warning` when it
    rests on priors alone. Pass `section` as it appears on the marketplace
    (e.g. "226", "floor a"); omit it to forecast the best-selling sections from the
    last 30 days, or — with no sales — the sections with the most tickets listed.
    Event ids are TEvo ids."""
    n = _clamp(max_sections, 1, FORECAST_MAX_SECTIONS, 3)
    picked_by = "explicit"
    if section and str(section).strip():
        sections = [str(section).strip()[:60]]
    else:
        since = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
        rows = db.table("seatgeek_sales_snapshots").select("sg_sale_id,section") \
            .eq("tevo_event_id", event_id).gte("sale_at_utc", since).limit(5000).execute().data or []
        counts: dict[str, set] = {}
        for r in rows:
            sec = str(r.get("section") or "").strip()
            if sec:
                counts.setdefault(sec.lower(), set()).add(r.get("sg_sale_id"))
        sections = [s for s, _ in sorted(counts.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:n]]
        picked_by = "sales_30d"
        if not sections:
            sections = _forecast_sections_by_inventory(db, event_id, n)
            picked_by = "listed_inventory"
        if not sections:
            return {"event_id": event_id, "forecasts": [],
                    "note": "no sales in 30 days and no current listings — nothing to price; "
                            "pass `section` explicitly"}
    out = []
    for sec in sections:
        f = _rpc(db, "predict_event_clearing_price", {"p_event_id": event_id, "p_section": sec})
        if f:
            out.append(_guard_forecast(_strip_book(f)))
    return {"event_id": event_id, "forecasts": out, "count": len(out), "sections_picked_by": picked_by,
            "method": "weighted blend of realized section sales, current asks x sold-to-ask ratio "
                      "and section/opponent priors, scaled by demand; band = calibrated p25-p75 "
                      "drift. Each signal carries its weight; realized_sample_n = sales used."}


_LIST_KEYS = ("games", "roster", "injuries", "transactions", "player_value", "espn_news", "reddit",
              "kalshi_futures", "team_market_daily", "sales_daily", "recent_results")


def team_report(db, team: str, since: str | None = None, home_only: bool = True,
                max_games: int = 10, news_limit: int = 8) -> dict:
    """One call for a team's market and context, e.g. team="New York Knicks" or a
    TEvo performer id ("16303"). Returns, per upcoming game (home games by default):
    live TEvo/SeatGeek/GoTickets inventory (get-in, median, p25-p75, tickets), SeatGeek
    sales pace, a daily trend since `since`, Kalshi win odds, weather and a
    `data_quality` flag (live / stale / none). Plus the team: ESPN standing, recent
    results vs the spread, roster, injuries, transactions, player ticket-price value,
    ESPN news, Reddit, Kalshi futures, and the team's daily market + sales history.
    `since` (YYYY-MM-DD) defaults to when we started polling the team's games.
    Metrics are processed, not raw listings. For a price, follow with
    `price_forecast(event_id)`."""
    since_d = None
    if since:
        try:
            since_d = datetime.strptime(str(since)[:10], "%Y-%m-%d").date().isoformat()
        except ValueError:
            return {"error": "since must be YYYY-MM-DD"}
    out = _rpc(db, "mcp_team_report", {
        "p_team": str(team or "").strip()[:80], "p_since": since_d, "p_home_only": bool(home_only),
        "p_max_events": _clamp(max_games, 1, 41, 10), "p_news_limit": _clamp(news_limit, 1, 25, 8)})
    if not isinstance(out, dict):
        return {"error": "no report"}
    out.pop("polling", None)  # which teams we pin is ours — internal `team_book` carries it
    for k in _LIST_KEYS:
        if k in out and out[k] is None:
            out[k] = []
    notes = []
    if out.get("games") is not None and not out.get("reddit"):
        notes.append("no Reddit posts stored for this team in the last 7 days")
    thin = [g["event_id"] for g in out.get("games", []) if g.get("data_quality") != "live"]
    if thin:
        notes.append(f"{len(thin)} game(s) without a TEvo capture in the last 6 h: {thin}")
    if notes:
        out["data_notes"] = notes
    return out


GET_STARTED_PATH = Path(__file__).resolve().parent.parent / "docs" / "mcp_onboarding.md"


def get_started(db) -> dict:
    """Start here on first connect: what this server does, the 4 calls that answer
    most questions (search → team_report / event_market → price_forecast), how
    freshness works, and the full onboarding guide (Markdown)."""
    try:
        guide = GET_STARTED_PATH.read_text(encoding="utf-8")
    except OSError:
        guide = ""
    return {"welcome": INSTRUCTIONS, "quick_start": QUICK_START, "guide_markdown": guide}


@_cached
def data_freshness(db) -> dict:
    """How fresh every feed is right now: as-of time, age, rows in the last
    24 h and the expected cadence. Call this before trusting a number."""
    return _rpc(db, "mcp_data_freshness") or {"feeds": []}


def _query_view(db, views: dict[str, tuple[str, ...]], view: str, columns, filters, order_by,
                descending, limit) -> dict:
    if view not in views:
        return {"error": f"unknown view {view!r}", "views": {k: list(v) for k, v in views.items()}}
    allowed = views[view]
    cols = list(columns or allowed)
    bad = [c for c in cols if c not in allowed]
    if bad:
        return {"error": f"columns not allowed on {view}: {bad}", "allowed": list(allowed)}
    q = db.table(view).select(",".join(cols))
    for f in filters or []:
        col, op, val = f.get("column"), f.get("op", "eq"), f.get("value")
        if col not in allowed:
            return {"error": f"filter column not allowed on {view}: {col!r}", "allowed": list(allowed)}
        if op not in FILTER_OPS:
            return {"error": f"unknown op {op!r}", "ops": list(FILTER_OPS)}
        if op == "in":
            if not isinstance(val, list):
                return {"error": "op 'in' needs a list value"}
            q = q.in_(col, val)
        else:
            q = getattr(q, op)(col, val)
    if order_by:
        if order_by not in allowed:
            return {"error": f"order_by not allowed on {view}: {order_by!r}", "allowed": list(allowed)}
        q = q.order(order_by, desc=bool(descending))
    rows = q.limit(_clamp(limit, 1, MAX_ROWS, 100)).execute().data or []
    return {"view": view, "rows": rows, "count": len(rows)}


def query_public_view(db, view: str, columns: list[str] | None = None,
                      filters: list[dict] | None = None, order_by: str | None = None,
                      descending: bool = False, limit: int = 100) -> dict:
    """Read-only query over a whitelisted PUBLIC view (events, SeatGeek sales,
    daily listing ladder, competitors, market chart, performer metrics,
    prediction markets, news). filters: [{column, op, value}], op in
    eq|neq|gt|gte|lt|lte|ilike|in (value is a list for `in`). Call with an
    unknown view to list views + columns."""
    return _query_view(db, EXTERNAL_QUERY_VIEWS, view, columns, filters, order_by, descending, limit)


# --------------------------------------------------------------------------
# Internal tools — our book. Never on the external server.
# --------------------------------------------------------------------------

def pickups(db, mode: str = "hot", days: int = 4, min_days_out: int = 7,
            max_days_out: int = 365, limit: int = 25) -> dict:
    """Our pickups list: hot = selling now (weighted by days out + lift);
    cold = listed tickets not clearing by event day at the current pace."""
    mode = "cold" if str(mode).lower() == "cold" else "hot"
    lo = _clamp(min_days_out, 0, 730, 7)
    rows = _rpc(db, "get_d0_pickups_v2", {
        "p_mode": mode, "p_window_days": _clamp(days, 1, 14, 4), "p_min_days_out": lo,
        "p_max_days_out": max(lo, _clamp(max_days_out, 0, 730, 365)),
        "p_limit": _clamp(limit, 1, 200, 25),
    }) or []
    return {"mode": mode, "events": rows}


def event_orders(db, event_id: int, days: int = 30) -> dict:
    """Our orders on one event from every book (CRM, SeatGeek, TEvo) with a
    per-day pace next to the SeatGeek market."""
    return _rpc(db, "get_event_orders_daily", {"p_event_id": event_id,
                                              "p_days": _clamp(days, 1, 365, 30)}) or {}


def event_source_links(db, event_id: int) -> dict:
    """Marketplace URLs/ids for one event (SeatGeek, StubHub, Gametime, Vivid, ...)."""
    return _rpc(db, "get_event_source_links", {"p_event_id": event_id}) or {}


def home_stats(db) -> dict:
    """Terminal home: upcoming team-event coverage + each data feed's as-of time."""
    return _rpc(db, "get_home_stats") or {}


def market_chart(db, offset: int = 0, limit: int = 50) -> dict:
    """Top events selling on the market that we hold no position in (our CRM sellers excluded)."""
    rows = _rpc(db, "get_sg_market_chart", {"p_offset": _clamp(offset, 0, 10000, 0),
                                            "p_limit": _clamp(limit, 1, 200, 50)}) or []
    return {"events": rows}


def team_book(db, team: str, since: str | None = None, home_only: bool = False,
              max_games: int = 60) -> dict:
    """Our book on a team (internal): per game since `since` (default 60 days back) our CRM
    sales — orders, tickets, gross, avg per ticket, split by marketplace — SeatGeek order
    count, and owned inventory now vs the market (owned tickets / share / median vs market
    median and get-in); team totals, the 25 latest orders and which polling pins cover the
    team. Rejected/cancelled orders excluded; no buyer details. Pair with `team_report`."""
    since_d = None
    if since:
        try:
            since_d = datetime.strptime(str(since)[:10], "%Y-%m-%d").date().isoformat()
        except ValueError:
            return {"error": "since must be YYYY-MM-DD"}
    return _rpc(db, "mcp_team_book", {
        "p_team": str(team or "").strip()[:80], "p_since": since_d, "p_home_only": bool(home_only),
        "p_max_events": _clamp(max_games, 1, 120, 60)}) or {"error": "no report"}


def owned_events(db, days: int = 30) -> dict:
    """Upcoming events where we own tickets (as of the latest TEvo listing poll)."""
    return {"events": _rpc(db, "get_owned_events_upcoming", {"p_days": _clamp(days, 1, 365, 30)}) or []}


def query_view(db, view: str, columns: list[str] | None = None,
               filters: list[dict] | None = None, order_by: str | None = None,
               descending: bool = False, limit: int = 100) -> dict:
    """Read-only query over a whitelisted view (public views + our order books).
    filters: [{column, op, value}], op in eq|neq|gt|gte|lt|lte|ilike|in
    (value is a list for `in`)."""
    return _query_view(db, QUERY_VIEWS, view, columns, filters, order_by, descending, limit)


EXTERNAL_TOOLS: tuple[Callable, ...] = (
    search, search_events, event_market, event_prices, top_market_events, performer_trend,
    price_movers, competing_events, prediction_markets, sports_context, news, event_weather,
    price_forecast, team_report, data_freshness, query_public_view, get_started)
INTERNAL_TOOLS: tuple[Callable, ...] = EXTERNAL_TOOLS + (
    pickups, event_orders, event_source_links, home_stats, market_chart, owned_events, team_book,
    query_view)

INSTRUCTIONS = (
    "S4K live-event market data (concerts, sports, theater). First time here? Call "
    "`get_started`. Event ids are TEvo event ids; "
    "find them with `search` or `search_events`. Dates are the venue's local time unless a "
    "field says _utc. Every answer carries `freshness` (as_of / age_hours / stale) for the "
    "rows it used — call `data_freshness` to see every feed's current age; the TEvo get-in "
    "price feed (`event_prices`) has been paused since 2026-09-27 and is marked stale. "
    "SeatGeek sales, prediction markets, sports state and news update within minutes; the "
    "chart, movers and performer trends are daily. For a team (e.g. the Knicks) call "
    "`team_report` — live inventory, trends, ESPN, Reddit, Kalshi, roster and weather in one "
    "answer. To predict a price, call `price_forecast` "
    "(per section; omit section for the best sellers) and read `expected_clearing` with its "
    "`lo`-`hi` band, `confidence` and any `warning`. Read-only.")

QUICK_START = [
    "search('knicks') → performer + event ids",
    "team_report('New York Knicks') → every home game: live get-in/median/tickets on TEvo, "
    "SeatGeek and GoTickets, daily trend, Kalshi odds, injuries, roster, news",
    "price_forecast(event_id) → expected clearing price per section with a band and confidence",
    "data_freshness() → how old each feed is before you trust a number",
]


def tool_catalog(tools: tuple[Callable, ...] = EXTERNAL_TOOLS) -> list[dict]:
    """Name + description + parameters per tool (for the /developers page)."""
    out = []
    for fn in tools:
        sig = inspect.signature(getattr(fn, "__wrapped__", fn))
        params = [p.name for p in list(sig.parameters.values())[1:]]
        out.append({"name": fn.__name__, "description": " ".join((fn.__doc__ or "").split()),
                    "parameters": params})
    return out


# --------------------------------------------------------------------------
# MCP wiring
# --------------------------------------------------------------------------

def _make_server(name: str, tools: tuple[Callable, ...], get_db: Callable[[], Any]) -> MCPServer:
    srv = MCPServer(name, instructions=INSTRUCTIONS)
    for fn in tools:
        def bound(*args, __fn=fn, **kwargs):
            return __fn(get_db(), *args, **kwargs)
        bound.__name__, bound.__doc__ = fn.__name__, fn.__doc__
        # Re-expose the tool's own signature minus the leading `db` parameter.
        sig = inspect.signature(getattr(fn, "__wrapped__", fn))
        bound.__signature__ = sig.replace(parameters=list(sig.parameters.values())[1:])
        bound.__annotations__ = {k: v for k, v in fn.__annotations__.items() if k != "db"}
        srv.add_tool(bound, name=fn.__name__, description=fn.__doc__,
                     annotations=ToolAnnotations(readOnlyHint=True, openWorldHint=False))

    # Onboarding on first connect: clients that list resources/prompts surface these next to
    # the tools; `get_started` (a tool) covers clients that only call tools.
    @srv.resource("s4k://onboarding", name="onboarding", title="S4K Market MCP — start here",
                  description="The onboarding guide: connect, the core calls, recipes, limits.",
                  mime_type="text/markdown")
    def _onboarding() -> str:
        return get_started(None)["guide_markdown"]

    @srv.prompt(name="get_started", title="Get started with S4K market data",
                description="Walks a new user through the core calls with a live example.")
    def _get_started_prompt(team: str = "New York Knicks") -> str:
        return (f"Call `get_started`, then `team_report` for {team}. Summarize the next home game's "
                "live get-in and median on each source, the trend, Kalshi odds and injuries, then "
                "call `price_forecast` for that game and report expected_clearing with its band, "
                "confidence and any warning.")
    return srv


def _tool_name(body: bytes) -> str | None:
    """The JSON-RPC method (and tool name for tools/call) of a request body —
    only for the usage stamp; a malformed body just counts as 'rpc'."""
    try:
        msg = json.loads(body or b"{}")
        if isinstance(msg, list):
            msg = msg[0] if msg else {}
        method = msg.get("method")
        if method == "tools/call":
            return str((msg.get("params") or {}).get("name") or "tools/call")[:64]
        return str(method or "rpc")[:64]
    except (ValueError, AttributeError):
        return "rpc"


class MCPApp:
    """ASGI app: authenticate the bearer key, enforce its per-minute rate and
    daily quota, stamp usage, then hand the request to the tier's MCP server.
    ``lifespan()`` must wrap the host app's lifespan."""

    def __init__(self, get_db: Callable[[], Any], limiter: Any | None = None):
        self._get_db = get_db
        self._limiter = limiter
        self._servers = {
            EXTERNAL: _make_server("s4k-market", EXTERNAL_TOOLS, get_db),
            INTERNAL: _make_server("s4k-terminal-internal", INTERNAL_TOOLS, get_db),
        }
        self._managers: dict[str, StreamableHTTPSessionManager] = {}

    @contextlib.asynccontextmanager
    async def lifespan(self):
        # A session manager runs once, so make fresh ones per host startup.
        security = TransportSecuritySettings(enable_dns_rebinding_protection=False)
        managers = {
            tier: StreamableHTTPSessionManager(srv._lowlevel_server, stateless=True, json_response=True,
                                               security_settings=security)
            for tier, srv in self._servers.items()
        }
        async with contextlib.AsyncExitStack() as stack:
            for m in managers.values():
                await stack.enter_async_context(m.run())
            self._managers = managers
            try:
                yield
            finally:
                self._managers = {}

    def resolve_key(self, headers: dict[str, str]) -> dict | None:
        """The key's row (id, tier, limits, calls_today) or None."""
        auth = headers.get("authorization", "")
        key = auth[7:].strip() if auth.lower().startswith("bearer ") else headers.get("x-api-key", "").strip()
        if not key:
            return None
        try:
            rows = self._get_db().rpc("mcp_verify_key", {"p_key_hash": hash_key(key)}).execute().data or []
        except Exception:
            return None
        row = rows[0] if rows else None
        if not row or row.get("tier") not in (INTERNAL, EXTERNAL):
            return None
        return {
            "id": row.get("id"), "tier": row["tier"],
            "rate_per_min": int(row.get("rate_per_min") or DEFAULT_RATE_PER_MIN),
            "daily_quota": int(row.get("daily_quota") or DEFAULT_DAILY_QUOTA),
            "calls_today": int(row.get("calls_today") or 0),
        }

    def resolve_tier(self, headers: dict[str, str]) -> str | None:
        info = self.resolve_key(headers)
        return info["tier"] if info else None

    def _count(self, key_id: Any, tool: str | None) -> None:
        try:
            self._get_db().rpc("mcp_count_call", {"p_key_id": key_id, "p_tool": tool}).execute()
        except Exception:  # noqa: BLE001 - a usage stamp must never fail the request
            pass

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":  # pragma: no cover - websockets/lifespan never routed here
            return
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
        info = await anyio.to_thread.run_sync(self.resolve_key, headers)
        if info is None:
            await _json(send, 401, {"error": "missing or invalid API key",
                                    "signup": "/developers on this host"},
                        {"www-authenticate": 'Bearer realm="s4k-mcp"'})
            return
        if self._limiter is not None and not self._limiter.check(
                f"mcp:{info['id']}", info["rate_per_min"], 60.0):
            await _json(send, 429, {"error": "rate limited", "rate_per_min": info["rate_per_min"],
                                    "retry_after_seconds": 60}, {"retry-after": "60"})
            return
        if info["calls_today"] >= info["daily_quota"]:
            await _json(send, 429, {"error": "daily quota exhausted", "daily_quota": info["daily_quota"],
                                    "resets_at": "00:00 UTC"}, {"retry-after": "3600"})
            return
        manager = self._managers.get(info["tier"])
        if manager is None:
            await _json(send, 503, {"error": "MCP server not started"})
            return
        if scope.get("method") == "POST":
            # Read the body once for the usage stamp, then replay it to the server.
            body, more = b"", True
            while more:
                msg = await receive()
                body += msg.get("body", b"")
                more = msg.get("more_body", False)
            tool = _tool_name(body)
            replayed = False

            async def receive_replay():
                nonlocal replayed
                if not replayed:
                    replayed = True
                    return {"type": "http.request", "body": body, "more_body": False}
                return await receive()

            await anyio.to_thread.run_sync(self._count, info["id"], tool)
            await manager.handle_request(scope, receive_replay, send)
            return
        await manager.handle_request(scope, receive, send)


async def _json(send, status: int, body: dict, extra: dict[str, str] | None = None) -> None:
    payload = json.dumps(body).encode()
    headers = [(b"content-type", b"application/json"), (b"content-length", str(len(payload)).encode())]
    headers += [(k.encode(), v.encode()) for k, v in (extra or {}).items()]
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": payload})
