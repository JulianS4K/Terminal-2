"""S4K Terminal as an MCP server — /mcp (Streamable HTTP, stateless, JSON).

Callers authenticate with a bearer API key (``Authorization: Bearer s4k_...``).
The key is hashed (sha256) and resolved by ``mcp_verify_key`` (migs
20261008150000 + 20261021190000) to a tier plus its limits:

- ``external`` (anyone who signed up at /developers): public market data —
  event/performer/venue search, SeatGeek market sales pace, price history +
  zone prices + forecast, the daily top-selling chart, performer trends,
  multi-source price movers, competing events, prediction markets, sports
  state, news, weather, every SeatGeek sale per event, the market by seating
  zone (live + daily history), per-game demand context from the feature store,
  the learned price model's predictions, a per-feed freshness report, and
  read-only queries over a whitelist of public views.
- ``internal`` (our team): everything external gets, plus our book — pickups,
  per-event orders across every source, home stats, the market chart with our
  positions excluded, owned events, what we poll, and the wider ``query_view``
  whitelist (owned / wholesale zone columns).

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
import html
import inspect
import json
import re
import statistics
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
from mcp.types import EmbeddedResource, TextContent, TextResourceContents, ToolAnnotations

from routers import seatmap as _seatmap  # the same read-only TEvo map fetch as /api/store/seatmap

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
    # per-zone market captures (TEvo) — wholesale and owned columns stay internal
    "zone_metrics": ("event_id", "captured_at", "zone", "zone_source", "tickets_count",
                     "groups_count", "sections_count", "retail_min", "retail_p25", "retail_median",
                     "retail_mean", "retail_p75", "retail_p90", "retail_max", "getin_price"),
    # the daily feature store (one row per event × zone × day) — public market + context only
    "zone_price_observations": (
        "event_id", "zone", "zone_source", "capture_date", "captured_at", "performer_id",
        "performer_name", "venue_id", "venue_capacity", "venue_is_indoor", "opponent_performer_id",
        "opponent_name", "espn_event_id", "espn_league", "home_away", "event_local_ts", "event_date",
        "event_dow", "event_is_weekend", "event_start_bucket", "days_to_event", "event_month",
        "season_year", "holiday_name", "tickets_count", "groups_count", "sections_count",
        "retail_min", "retail_p25", "retail_median", "retail_mean", "retail_p75", "retail_p90",
        "retail_max", "getin_price", "fill_rate", "home_wins", "home_losses", "home_win_pct",
        "home_games_back", "home_playoff_seed", "home_streak", "opp_wins", "opp_losses",
        "opp_win_pct", "opp_games_back", "opp_playoff_seed", "opp_streak", "mkt_spread",
        "mkt_over_under", "mkt_home_ml", "mkt_away_ml", "mkt_home_win_prob", "game_attendance",
        "star_athlete_name", "star_out", "star_injury_status", "home_injured_count",
        "star_athlete_pv", "roster_wiki_pv_sum", "perf_popularity", "perf_daily_price_median",
        "perf_daily_getin_median", "market_competing_events", "is_rivalry", "rivalry_name",
        "rivalry_intensity", "wx_temp_f", "wx_precip_pct", "wx_wind_mph", "wx_summary",
        "wx_has_alert", "primary_getin", "primary_median", "primary_listings",
        "primary_flip_margin_pct", "primary_signal", "vel_prev_capture_date", "vel_tickets_sold",
        "vel_getin_delta_pct", "vel_median_delta_pct", "buzz_home_news_7d", "is_national_tv",
        "broadcast_networks"),
    # latest learned price-model predictions (Knicks home games; scripts/train_knicks_price.py)
    "v_ml_knicks_price_latest": ("run_id", "model", "trained_at", "sg_event_id", "tevo_event_id",
                                 "opponent", "occurs_at", "zone", "predicted_price", "p10", "p90",
                                 "ctx_zone_getin", "ctx_zone_median", "predicted_vs_zone_getin"),
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
    "zone_metrics": EXTERNAL_QUERY_VIEWS["zone_metrics"]
    + ("wholesale_min", "wholesale_median", "owned_groups_count", "owned_tickets_count",
       "owned_share", "owned_median_retail"),
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
ZONE_COLS = ",".join(EXTERNAL_QUERY_VIEWS["zone_metrics"])
THIN_ZONE_TICKETS = 10          # zone_prices: below this, flag the zone `thin`
INJURY_MAX_AGE_DAYS = 7         # team_report: injury notes not re-seen since are dropped
ZONE_TREND_COLS = ("zone,capture_date,days_to_event,tickets_count,getin_price,retail_p25,"
                   "retail_median,retail_p75,vel_tickets_sold,vel_getin_delta_pct,vel_median_delta_pct")
# event-level context in the feature store (same on every zone row of a day)
GAME_CONTEXT_COLS = (
    "capture_date", "performer_id", "performer_name", "opponent_name", "home_away", "espn_league",
    "event_local_ts", "event_dow", "event_is_weekend", "days_to_event", "holiday_name",
    "venue_capacity", "venue_is_indoor", "home_wins", "home_losses", "home_win_pct",
    "home_games_back", "home_playoff_seed", "home_streak", "opp_wins", "opp_losses", "opp_win_pct",
    "opp_games_back", "opp_playoff_seed", "opp_streak", "mkt_spread", "mkt_over_under",
    "mkt_home_ml", "mkt_away_ml", "mkt_home_win_prob", "game_attendance", "star_athlete_name",
    "star_out", "star_injury_status", "home_injured_count", "star_athlete_pv", "roster_wiki_pv_sum",
    "perf_popularity", "perf_daily_price_median", "perf_daily_getin_median",
    "market_competing_events", "is_rivalry", "rivalry_name", "rivalry_intensity", "wx_temp_f",
    "wx_precip_pct", "wx_wind_mph", "wx_summary", "wx_has_alert", "primary_getin",
    "primary_median", "primary_listings", "primary_flip_margin_pct", "primary_signal",
    "buzz_home_news_7d", "is_national_tv", "broadcast_networks")
ML_MODEL = "knicks_price_ridge_v1"
ML_PRED_COLS = ",".join(EXTERNAL_QUERY_VIEWS["v_ml_knicks_price_latest"])
ML_RUN_COLS = "run_id,model,trained_at,n_train,n_test,games_train,games_test,metrics,status"


def _pctl(xs: list[float], q: float) -> float | None:
    """Nearest-rank percentile of an already sorted list (None when empty)."""
    if not xs:
        return None
    return xs[min(len(xs) - 1, max(0, int(round(q * (len(xs) - 1)))))]


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


def event_sales(db, event_id: int, days: int = 30, section: str | None = None,
                min_quantity: int = 1, limit: int = 200) -> dict:
    """Individual SeatGeek sales for one event (all sellers): sale time (UTC), price per
    ticket, quantity, section, row — newest first — plus a summary (count, tickets,
    min / p25 / median / p75 / max price). `section` narrows to one section (case-insensitive
    fragment, e.g. "226" or "floor"). Covers every game we poll: sales are pulled daily, every
    6 h inside 48 h of the event and once after it. Event ids are TEvo ids."""
    days = _clamp(days, 1, 365, 30)
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    q = db.table("seatgeek_sales_snapshots") \
        .select("sg_sale_id,sale_at_utc,broadcast_price,quantity,section,row,pulled_at") \
        .eq("tevo_event_id", event_id).gte("sale_at_utc", since)
    if section and str(section).strip():
        q = q.ilike("section", f"%{str(section).strip()[:40]}%")
    rows = q.order("sale_at_utc", desc=True).limit(5000).execute().data or []
    seen: dict[Any, dict] = {}
    pulled = None
    for r in rows:
        pulled = max(pulled or "", str(r.get("pulled_at") or ""))
        if (r.get("quantity") or 0) >= _clamp(min_quantity, 1, 100, 1):
            seen.setdefault(r.get("sg_sale_id"), r)
    sales = [{k: v for k, v in s.items() if k != "pulled_at"} for s in seen.values()]
    prices = sorted(float(s["broadcast_price"]) for s in sales if s.get("broadcast_price") is not None)
    summary = {"sales": len(sales), "tickets": sum(int(s.get("quantity") or 0) for s in sales),
               "price_min": prices[0] if prices else None, "price_p25": _pctl(prices, 0.25),
               "price_median": _pctl(prices, 0.5), "price_p75": _pctl(prices, 0.75),
               "price_max": prices[-1] if prices else None,
               "last_sale_at": sales[0]["sale_at_utc"] if sales else None}
    return {"event_id": event_id, "days": days, "section": section, "summary": summary,
            "sales": sales[:_clamp(limit, 1, MAX_ROWS, 200)], "freshness": _as_of(pulled or None),
            "note": "price = seller's price per ticket before fees (SeatGeek broadcast_price)"}


def zone_prices(db, event_id: int) -> dict:
    """The market for an event by seating zone right now (e.g. "Lower Center", "Upper
    Corner"): tickets, listings, sections, get-in, p25 / median / p75 / p90 asks per zone from
    the latest capture, and each zone's change vs ~24 h earlier. Zones are curated per venue
    where we have a map, otherwise generic (lower / club / upper / floor). Event ids are TEvo ids."""
    since = (datetime.now(timezone.utc) - timedelta(hours=36)).isoformat()
    rows = db.table("zone_metrics").select(ZONE_COLS).eq("event_id", event_id) \
        .gte("captured_at", since).order("captured_at", desc=True).limit(3000).execute().data or []
    if not rows:
        return {"event_id": event_id, "zones": [], "freshness": _as_of(None),
                "note": "no zone capture in the last 36 h — the event may not be polled"}
    latest: dict[str, dict] = {}
    day_ago: dict[str, dict] = {}
    for r in rows:  # newest first
        z = r.get("zone")
        if z not in latest:
            latest[z] = r
        try:
            t = datetime.fromisoformat(str(r["captured_at"]).replace("Z", "+00:00"))
        except (KeyError, ValueError):
            continue
        if datetime.now(timezone.utc) - t >= timedelta(hours=24) and z not in day_ago:
            day_ago[z] = r

    def _chg(now, then):
        return round((float(now) - float(then)) / float(then) * 100, 1) if now and then else None

    zones = []
    for z, r in latest.items():
        prev = day_ago.get(z) or {}
        zones.append({**{k: v for k, v in r.items() if k != "event_id"},
                      "getin_change_24h_pct": _chg(r.get("getin_price"), prev.get("getin_price")),
                      "median_change_24h_pct": _chg(r.get("retail_median"), prev.get("retail_median")),
                      "tickets_change_24h": (r.get("tickets_count") or 0) - prev["tickets_count"]
                      if prev.get("tickets_count") is not None else None})
    for z in zones:  # few tickets → one listing moves the "median"; say so instead of hiding it
        z["thin"] = (z.get("tickets_count") or 0) < THIN_ZONE_TICKETS
    zones.sort(key=lambda x: -(float(x.get("retail_median") or 0)))
    out = {"event_id": event_id, "zones": zones, "count": len(zones),
           "freshness": _as_of(rows[0].get("captured_at"))}
    thin = [z["zone"] for z in zones if z["thin"]]
    if thin:
        out["note"] = (f"{len(thin)} of {len(zones)} zones have fewer than {THIN_ZONE_TICKETS} tickets on "
                       "TEvo (`thin`: true) — their medians rest on a listing or two; check "
                       "`event_sales` (what actually sold) and `team_report` (SeatGeek depth)")
    return out


def zone_trend(db, event_id: int, zone: str | None = None, days: int = 60) -> dict:
    """Daily history per seating zone for an event from the feature store: tickets listed,
    get-in, p25 / median / p75 ask, and the day-over-day change (tickets sold, get-in and
    median move). `zone` narrows to one zone (exact name from `zone_prices`). Built nightly."""
    days = _clamp(days, 1, 365, 60)
    since = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")
    q = db.table("zone_price_observations").select(ZONE_TREND_COLS).eq("event_id", event_id) \
        .gte("capture_date", since)
    if zone and str(zone).strip():
        q = q.eq("zone", str(zone).strip()[:60])
    rows = q.order("capture_date").limit(2000).execute().data or []
    series: dict[str, list] = {}
    for r in rows:
        series.setdefault(r.pop("zone", None), []).append(r)
    last = rows[-1]["capture_date"] if rows else None
    return {"event_id": event_id, "days": days, "zones": series, "count": len(rows),
            "freshness": _as_of(last)}


def form_mult(ctx: dict | None) -> float:
    """Team-form price factor — mirrors SQL `_price_form_mult` (mig 20261027190000):
    1 + 0.30·(home win% − .5)·g/(g+15) + 0.15·(away win% − .5)·g/(g+15), clamped 0.85–1.15,
    g = games played, so the first weeks of a season barely move it."""
    adj = 0.0
    for side, coef in (("home", 0.30), ("away", 0.15)):
        rec = str(((ctx or {}).get(side) or {}).get("record") or "")
        parts = rec.split("-")
        if len(parts) < 2 or not (parts[0].isdigit() and parts[1].isdigit()):
            continue
        w, losses = int(parts[0]), int(parts[1])
        g = w + losses
        if g:
            adj += coef * (w / g - 0.5) * g / (g + 15)
    return round(max(0.85, min(1.15, 1 + adj)), 4)


def game_context(db, event_id: int, capture_date: str | None = None) -> dict:
    """What drives demand for one game, live: both teams' records, streaks and seeds, the
    team-form price factor (`form_mult`), players out per side, Reddit / X buzz, attendance
    rank, weather alert, and the prediction-market win odds per team (Kalshi / Polymarket).
    Plus the nightly feature-store row (`feature_store`: betting line, star player and
    injury status, rivalry, national TV, primary vs resale, holiday, competing events) for
    the latest day or `capture_date` (YYYY-MM-DD) — marked stale when it is behind.
    Event ids are TEvo ids."""
    live = _strip_book(_rpc(db, "get_event_demand_context", {"p_event_id": event_id}) or {})
    live.pop("note", None)  # internal explainer for the forecaster
    odds = prediction_markets(db, event_id=event_id, limit=10)
    q = db.table("zone_price_observations").select(",".join(GAME_CONTEXT_COLS)).eq("event_id", event_id)
    if capture_date:
        q = q.eq("capture_date", str(capture_date)[:10])
    rows = q.order("capture_date", desc=True).limit(1).execute().data or []
    fs = rows[0] if rows else None
    notes = []
    if not live:
        notes.append("no live demand context — the event may not be a team game we track")
    if fs is None:
        notes.append("no feature-store row yet (built nightly for polled events)")
    elif fs.get("opponent_name") is None and fs.get("mkt_spread") is None:
        notes.append("feature store has no ESPN link for this game yet (no opponent / betting line); "
                     "records and win odds above come from the live context and prediction markets")
    out = {"event_id": event_id, "live": live or None, "form_mult": form_mult(live or {}),
           "win_odds": [{"team": m.get("team_name"), "yes_price": m.get("yes_price"),
                         "source": m.get("source"), "volume": m.get("volume"),
                         "updated_at": m.get("updated_at")} for m in odds.get("markets", [])],
           "feature_store": fs, "capture_date": fs["capture_date"] if fs else None,
           "freshness": {"live": _as_of(((live or {}).get("home") or {}).get("as_of")),
                         "win_odds": odds.get("freshness"),
                         "feature_store": _as_of(fs["capture_date"] if fs else None)}}
    if notes:
        out["data_notes"] = notes
    return out


def model_price_prediction(db, event_id: int | None = None, limit: int = 200) -> dict:
    """The learned price model's expected sale price per zone for upcoming games, with a
    p10–p90 band and the zone's current get-in / median for comparison, plus the model's
    held-out accuracy (median absolute % error vs simple baselines). Retrained daily on
    every catalogued sale. Coverage today: New York Knicks home games. Pass `event_id`
    (TEvo id) for one game, or omit it for all of them."""
    q = db.table("v_ml_knicks_price_latest").select(ML_PRED_COLS)
    if event_id is not None:
        q = q.eq("tevo_event_id", event_id)
    rows = q.order("occurs_at").order("zone").limit(_clamp(limit, 1, MAX_ROWS, 200)).execute().data or []
    run = db.table("ml_model_runs").select(ML_RUN_COLS).eq("model", ML_MODEL).eq("status", "ok") \
        .order("run_id", desc=True).limit(1).execute().data or []
    out = {"model": ML_MODEL, "predictions": rows, "count": len(rows),
           "run": run[0] if run else None,
           "freshness": _as_of(run[0]["trained_at"] if run else None),
           "method": "ridge regression on log price over catalogued sales (zone, level, row band, "
                     "opponent, time to tip, weekday, quantity) and the zone/event market at sale "
                     "time; band = held-out residual p10-p90. Price = pair sold now, before fees."}
    if not run:
        out["note"] = "the model has not completed a training run yet"
    return out


# --------------------------------------------------------------------------
# Seat map — the venue map coloured by price, returned as an artifact
# --------------------------------------------------------------------------
SEATMAP_TTL_S = 86400.0                    # maps are immutable per venue/configuration
_svg_cache = _TTLCache(SEATMAP_TTL_S, max_items=32)
SEATMAP_COLORS = ("#d6eaf8", "#85c1e9", "#3498db", "#21618c", "#0b2e4a")   # cheap → expensive
SEATMAP_NODATA = "#d5d8dc"
CONTENT_TOOLS = frozenset({"seat_map"})   # return MCP content blocks, not a JSON object
_SECTION_TAG = re.compile(
    r"<(polygon|path|rect|ellipse|circle|polyline)\b([^>]*?)\bdata-section-id=\"([^\"]+)\"([^>]*?)(/?)>", re.I)
_SVG_UNSAFE = (re.compile(r"<script\b.*?</script\s*>", re.I | re.S),
               re.compile(r"<foreignObject\b.*?</foreignObject\s*>", re.I | re.S),
               re.compile(r"\son[a-z]+\s*=\s*(\"[^\"]*\"|'[^']*')", re.I))


def _seatmap_svg(venue_id: int, configuration_id: int) -> str | None:
    """The TEvo map SVG for a venue configuration (public read host, GET only — same
    fetch as routers/seatmap.py), scripts and event handlers stripped, cached for a day."""
    key = ("svg", venue_id, configuration_id)
    hit = _svg_cache.get(key)
    if hit is not None:
        return hit or None
    try:
        r = _seatmap._fetch_tevo_seatmap_file(venue_id, configuration_id, "map.svg", "image/svg+xml")
        svg = r.text
    except Exception:
        svg = ""
    for pat in _SVG_UNSAFE:
        svg = pat.sub("", svg)
    _svg_cache.put(key, svg)
    return svg or None


def _norm_section(s: Any) -> str:
    return " ".join(str(s or "").lower().split())


def _seatmap_values(db, event_id: int, metric: str, days: int) -> tuple[dict[str, list], Any]:
    """Per marketplace section: the values to colour by, and the as-of time.
    sold → every distinct SeatGeek sale price in `days`; ask → the latest TEvo capture's
    median ask per section, weighted by tickets (each section's value repeated per ticket
    would be heavy, so (value, weight) pairs)."""
    out: dict[str, list] = {}
    if metric == "ask":
        rows = db.table("section_metrics").select("section,tickets_count,retail_median,captured_at") \
            .eq("event_id", event_id).order("captured_at", desc=True).limit(600).execute().data or []
        latest = rows[0]["captured_at"] if rows else None
        for r in rows:
            if r.get("captured_at") == latest and r.get("retail_median") is not None:
                out.setdefault(_norm_section(r.get("section")), []).append(
                    (float(r["retail_median"]), int(r.get("tickets_count") or 1)))
        return out, latest
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows = db.table("seatgeek_sales_snapshots").select("sg_sale_id,section,broadcast_price,pulled_at") \
        .eq("tevo_event_id", event_id).gte("sale_at_utc", since).limit(5000).execute().data or []
    seen: dict[Any, dict] = {}
    pulled = None
    for r in rows:
        pulled = max(pulled or "", str(r.get("pulled_at") or ""))
        seen.setdefault(r.get("sg_sale_id"), r)
    for r in seen.values():
        if r.get("broadcast_price") is not None:
            out.setdefault(_norm_section(r.get("section")), []).append((float(r["broadcast_price"]), 1))
    return out, pulled or None


def _weighted_median(pairs: list[tuple[float, int]]) -> float:
    pts = sorted(pairs)
    half, run = sum(w for _, w in pts) / 2, 0
    for v, w in pts:
        run += w
        if run >= half:
            return v
    return pts[-1][0]  # pragma: no cover — unreachable for non-empty input


def seat_map(db, event_id: int, metric: str = "sold", days: int = 30) -> list[TextContent | EmbeddedResource]:
    """The event's seat map coloured by price per section — an artifact you can show the
    user. metric = sold (median SeatGeek sale price per section over `days`, default) or ask
    (median TEvo asking price per section right now). Returns a JSON summary (legend, the
    priced sections, sections we could not place), the coloured map as an SVG resource and a
    self-contained HTML page (map + legend + section table) — render the HTML resource as an
    artifact. Sections without data are grey. Event ids are TEvo ids."""
    metric = "ask" if str(metric).lower() == "ask" else "sold"
    days = _clamp(days, 1, 180, 30)

    def _text(obj: dict) -> list:
        return [TextContent(type="text", text=json.dumps(obj, default=str))]

    ev = (db.table("events").select("id,name,occurs_at_local,venue_id,venue_name,configuration_id,configuration_name")
          .eq("id", event_id).limit(1).execute().data or [])
    if not ev:
        return _text({"error": f"event {event_id} not found"})
    ev = ev[0]
    venue, cfg = ev.get("venue_id"), ev.get("configuration_id")
    svg = _seatmap_svg(int(venue), int(cfg)) if venue and cfg else None
    if not svg:
        return _text({"error": "no seat map for this event's venue configuration", "event": ev})

    svg_keys = {_norm_section(m[2]): m[2] for m in _SECTION_TAG.findall(svg)}  # normalized → as drawn
    by_last: dict[str, list[str]] = {}
    for k in svg_keys:
        by_last.setdefault(k.split()[-1], []).append(k)
    platform = "evo" if metric == "ask" else "sg"
    cw_rows = db.table("venue_section_map").select("section_raw,seatmap_key,configuration_id") \
        .eq("tevo_venue_id", venue).eq("platform", platform).in_("configuration_id", [cfg, 0]) \
        .limit(2000).execute().data or []
    crosswalk: dict[str, str] = {}
    for r in sorted(cw_rows, key=lambda r: r.get("configuration_id") != cfg):  # this configuration first
        crosswalk.setdefault(_norm_section(r.get("section_raw")), _norm_section(r.get("seatmap_key")))

    values, as_of = _seatmap_values(db, event_id, metric, days)
    placed: dict[str, list] = {}
    unplaced: dict[str, int] = {}
    for sec, pairs in values.items():
        key = crosswalk.get(sec)
        if key not in svg_keys:
            cands = by_last.get(sec.split()[-1] if sec else "", [])
            key = cands[0] if len(cands) == 1 else None
        if key:
            placed.setdefault(key, []).extend(pairs)
        else:
            unplaced[sec] = sum(w for _, w in pairs)

    priced = {k: (_weighted_median(p), sum(w for _, w in p)) for k, p in placed.items()}
    vals = sorted(v for v, _ in priced.values())
    breaks = [vals[min(len(vals) - 1, int(len(vals) * q / 5))] for q in range(1, 5)] if vals else []

    def _color(v: float) -> str:
        return SEATMAP_COLORS[sum(1 for b in breaks if v >= b)]

    unit = "median sale" if metric == "sold" else "median ask"

    def _paint(m: re.Match) -> str:
        tag, pre, sec_id, post, close = m.groups()
        attrs = re.sub(r'\sfill="[^"]*"', "", f"{pre}{post}")
        hit = priced.get(_norm_section(sec_id))
        fill = _color(hit[0]) if hit else SEATMAP_NODATA
        title = (f"{sec_id}: ${hit[0]:,.0f} {unit} ({hit[1]} {'sales' if metric == 'sold' else 'tickets'})"
                 if hit else f"{sec_id}: no data")
        open_tag = f'<{tag}{attrs} data-section-id="{html.escape(sec_id)}" fill="{fill}">'
        return f"{open_tag}<title>{html.escape(title)}</title></{tag}>" if close else f"{open_tag}<title>{html.escape(title)}</title>"

    painted = _SECTION_TAG.sub(_paint, svg)
    edges = [vals[0]] + breaks + [vals[-1]] if vals else []
    legend = [{"color": SEATMAP_COLORS[i], "from": round(edges[i]), "to": round(edges[i + 1])}
              for i in range(len(edges) - 1)] if edges else []
    top = sorted(({"section": svg_keys[k], "price": round(v), ("sales" if metric == "sold" else "tickets"): n}
                  for k, (v, n) in priced.items()), key=lambda r: -r["price"])
    summary = {
        "event": {k: ev.get(k) for k in ("id", "name", "occurs_at_local", "venue_name", "configuration_name")},
        "metric": metric, "days": days if metric == "sold" else None,
        "sections_on_map": len(svg_keys), "sections_priced": len(priced),
        "sections_unplaced": dict(sorted(unplaced.items(), key=lambda kv: -kv[1])[:20]),
        "legend": legend, "sections": top[:60],
        "median_overall": round(statistics.median(vals)) if vals else None,
        "freshness": _as_of(as_of),
        "artifact": "the text/html resource is a self-contained page (map, legend, table) — show it "
                    "to the user as an artifact; the image/svg+xml resource is the map alone",
    }
    title = f"{ev.get('name')} — {'sold prices' if metric == 'sold' else 'asking prices'} by section"
    legend_html = "".join(f'<span class="sw" style="background:{x["color"]}"></span>${x["from"]:,}–${x["to"]:,} '
                          for x in legend) + f'<span class="sw" style="background:{SEATMAP_NODATA}"></span>no data'
    rows_html = "".join(f"<tr><td>{html.escape(r['section'])}</td><td>${r['price']:,}</td>"
                        f"<td>{r.get('sales', r.get('tickets'))}</td></tr>" for r in top[:40])
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title>
<style>:root{{color-scheme:light dark;--bg:#fff;--fg:#1b1f24;--mut:#5f6b7a;--line:#e3e7ec}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111418;--fg:#e8ebef;--mut:#9aa5b1;--line:#2a3038}}}}
body{{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,sans-serif}}
h1{{font-size:18px;margin:0 0 4px}}p{{margin:0 0 12px;color:var(--mut)}}
.map svg{{width:100%;height:auto;max-width:900px;display:block}}
.legend{{margin:8px 0 12px}}.sw{{display:inline-block;width:14px;height:14px;border-radius:3px;margin:0 4px 0 10px;vertical-align:-2px}}
table{{border-collapse:collapse;margin-top:16px;min-width:280px}}td,th{{padding:4px 10px;border-bottom:1px solid var(--line);text-align:left}}
</style></head><body><h1>{html.escape(str(ev.get('name')))}</h1>
<p>{html.escape(str(ev.get('venue_name') or ''))} · {html.escape(str(ev.get('occurs_at_local') or '')[:16].replace('T', ' '))} ·
{'median sale price per section, last ' + str(days) + ' days (SeatGeek, before fees)' if metric == 'sold' else 'median asking price per section now (TEvo)'}
· {len(priced)} of {len(svg_keys)} sections priced · as of {html.escape(str(as_of or 'n/a'))[:16]}</p>
<div class="legend">{legend_html}</div><div class="map">{painted}</div>
<table><tr><th>Section</th><th>{'Median sale' if metric == 'sold' else 'Median ask'}</th><th>{'Sales' if metric == 'sold' else 'Tickets'}</th></tr>{rows_html}</table>
</body></html>"""
    base = f"s4k://seatmap/{event_id}/{metric}"
    return [TextContent(type="text", text=json.dumps(summary, default=str)),
            EmbeddedResource(type="resource", resource=TextResourceContents(
                uri=f"{base}.svg", mime_type="image/svg+xml", text=painted)),
            EmbeddedResource(type="resource", resource=TextResourceContents(
                uri=f"{base}.html", mime_type="text/html", text=page))]


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
    category's sold-to-ask ratio, section and opponent priors capped at 2x the live ask,
    demand context: chart rank, injuries, attendance, weather, and team form —
    `form_mult` from both teams' win/loss records). Every forecast carries
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
                      "and section/opponent priors (each prior capped at 2x the live ask), scaled by "
                      "demand and team form (form_mult: both teams' win/loss records, shrunk early "
                      "in the season); band = calibrated p25-p75 drift. Each signal carries its "
                      "weight; realized_sample_n = sales used."}


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
    # the injury feed keeps a player's last note after they drop off the report — e.g. preseason
    # "rest" notes; keep only notes seen in the last INJURY_MAX_AGE_DAYS
    fresh, dropped = [], 0
    for inj in out.get("injuries") or []:
        age = _as_of(inj.get("as_of"))["age_hours"] if inj.get("as_of") else None
        if age is None or age <= INJURY_MAX_AGE_DAYS * 24:
            fresh.append(inj)
        else:
            dropped += 1
    if "injuries" in out:
        out["injuries"] = fresh
    if dropped:
        notes.append(f"{dropped} injury note(s) older than {INJURY_MAX_AGE_DAYS} days left out (not on the current report)")
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
    prediction markets, news, zone captures, the daily feature store, the price
    model's predictions). filters: [{column, op, value}], op in
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


def polling_coverage(db) -> dict:
    """What we poll (internal): the team and league pins, how many upcoming games each
    covers and on which sources (evo / gt / sg), and the last 24 h of SeatGeek sales pulls
    (ok / rate-limited / failed, new sales stored)."""
    pins = db.table("listings_poll_pins").select("pin_key,performer_id,venue_name,sources,enabled") \
        .limit(500).execute().data or []
    leagues = db.table("listings_poll_league_pins").select("league,sources,enabled") \
        .limit(100).execute().data or []
    games = db.table("v_listings_poll_pinned_events").select("tevo_event_id,pin_key,sources,hours_to_event") \
        .limit(20000).execute().data or []
    per_pin: dict[str, dict] = {}
    for g in games:
        p = per_pin.setdefault(g.get("pin_key"), {"games": 0, "next_48h": 0, "sources": {}})
        p["games"] += 1
        if (g.get("hours_to_event") or 1e9) <= 48:
            p["next_48h"] += 1
        for s in g.get("sources") or []:
            p["sources"][s] = p["sources"].get(s, 0) + 1
    since = (datetime.now(timezone.utc) - timedelta(hours=24)).isoformat()
    pulls = db.table("sg_broker_pending").select("rows_persisted").eq("scope", "sales") \
        .gte("fired_at", since).limit(20000).execute().data or []
    rp = [r.get("rows_persisted") for r in pulls]
    return {"pins": pins, "league_pins": leagues, "games_by_pin": per_pin, "games_total": len(games),
            "sg_sales_pulls_24h": {"pulls": len(rp), "ok": sum(1 for x in rp if x is not None and x >= 0),
                                   "rate_limited": rp.count(-429), "failed": rp.count(-1),
                                   "pending": rp.count(None),
                                   "new_sales": sum(x for x in rp if x and x > 0)}}


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
    price_forecast, team_report, event_sales, zone_prices, zone_trend, game_context,
    model_price_prediction, seat_map, data_freshness, query_public_view, get_started)
INTERNAL_TOOLS: tuple[Callable, ...] = EXTERNAL_TOOLS + (
    pickups, event_orders, event_source_links, home_stats, market_chart, owned_events, team_book,
    polling_coverage, query_view)

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
    "`lo`-`hi` band, `confidence` and any `warning`; for Knicks home games also "
    "`model_price_prediction` (learned per-zone model). Drill down with `event_sales` "
    "(every sale), `zone_prices` (live market by seating zone), `zone_trend` (daily zone "
    "history) and `game_context` (records, line, injuries, buzz, weather). `seat_map` returns the "
    "venue map coloured by price per section as an HTML page — show it as an artifact. Read-only.")

QUICK_START = [
    "search('knicks') → performer + event ids",
    "team_report('New York Knicks') → every home game: live get-in/median/tickets on TEvo, "
    "SeatGeek and GoTickets, daily trend, Kalshi odds, injuries, roster, news",
    "price_forecast(event_id) → expected clearing price per section with a band and confidence",
    "zone_prices(event_id) / event_sales(event_id) → live asks by zone / every sale, newest first",
    "seat_map(event_id) → the venue map coloured by sale price per section (HTML artifact)",
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
        # tools that return MCP content blocks (seat_map: text + SVG + HTML) are unstructured;
        # the rest return JSON objects
        srv.add_tool(bound, name=fn.__name__, description=fn.__doc__,
                     annotations=ToolAnnotations(readOnlyHint=True, openWorldHint=False),
                     structured_output=False if fn.__name__ in CONTENT_TOOLS else None)

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
