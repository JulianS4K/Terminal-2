"""D0 orders data/DB helpers — shared by the standalone D2 dashboard app
(`d2_dashboard/main.py`) and the D0 unified-shell mount.

Mirrors the `core/broker_helpers.py` / `core/store_events.py` precedent: the
DB-touching fetchers take a live supabase client (`sb`) as their first argument
and issue read-only queries. This module holds no client bootstrap and imports
NOTHING from `d2_dashboard.main`, `routers/`, or `server.py` — one-directional
(main/routers -> core, never reverse), so the standalone shim in main.py can
import these back by name and keep its route handlers + monkeypatch surface
intact.

Extracted verbatim from d2_dashboard/main.py (consolidation slice 2). The five
fetchers that previously read the `_sb()` singleton internally now receive an
explicit `sb` parameter; main.py injects `_sb()` at the call site.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from typing import Any


# ---------- Coercion helpers ----------

def _to_int(v: Any) -> int | None:
    try:
        return int(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _to_float(v: Any) -> float | None:
    try:
        return float(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


# ---------- SQL-backed fetchers ----------

# All 5 sources are mirrored to public.unified_orders by upstream crons (see
# migration 20260513230100_unified_orders_with_tickpick_vivid). /api/d2/orders
# is SQL-only — no broker-API calls in the data path.
# 2026-05-16 rewire: SG source is now the broker firehose (seatgeek_sales_snapshots)
# instead of the dormant seller-side (seatgeek_orders, no new rows in 11 months).
# Live SG signal is the third-party market: ~67k sales/hr captured. The
# unified_orders view already exposes this as source='seatgeek_sales' with
# canonical_status hardcoded to 'fulfilled' (terminal) — so Active-pill SG rows
# will be 0 by construction; All-pill shows the firehose.
# 2026-09-01: +s4kcs — the S4K CRM open sell-side book (mig 20260901180000),
# polled every 10 min. In unified_orders it surfaces StubHub + Gametime ONLY;
# the CRM's other four markets are already ingested natively and would
# double-count. Its per-row marketplace rides on unified_orders.source_type.
_SQL_BACKED_SOURCES = frozenset({"evo", "seatgeek_sales", "seatdata", "tickpick",
                                 "vivid", "s4kcs"})

_ALL_SOURCES = ("evo", "seatgeek_sales", "seatdata", "tickpick", "vivid", "s4kcs")


def _fetch_cron_freshness(sb) -> dict[str, dict]:
    """Call public.d2_cron_freshness() and reduce to one row per source —
    preferring the 'queue' phase as the canonical 'when did the upstream
    pull last fire.' Returns empty dict when Supabase isn't configured.

    Shape per source: {jobname, phase, schedule, active, last_run, last_status}.
    Front-end uses last_run + schedule to render 'last pull: 12m ago · every 30m'."""
    if sb is None:
        return {}
    try:
        res = sb.rpc("d2_cron_freshness").execute()
        rows = res.data or []
        by_source: dict[str, dict] = {}
        for r in rows:
            src = r.get("source")
            if not src:
                continue
            # Prefer the queue-phase row; fall back to whatever's available.
            if src not in by_source or r.get("phase") == "queue":
                by_source[src] = r
        return by_source
    except Exception as e:
        import sys as _sys
        print(f"[d2_dashboard] cron freshness pull failed: {e!r}", file=_sys.stderr, flush=True)
        return {}


# In-process cache for the v_event_base window. Events don't churn fast —
# a 60s TTL is comfortably within human attention spans and slashes one
# round-trip per dashboard refresh.
_EVENT_WINDOW_CACHE: dict = {"at": 0.0, "rows": []}
_EVENT_WINDOW_TTL_SEC = 60


def _pull_event_window(sb, days_back: int = 1, days_forward: int = 120) -> list[dict]:
    """Pull a window of upcoming events from v_event_base for fuzzy-matching
    tickpick / vivid order responses to canonical tevo_event_ids. Cached
    in-process for 60s so repeated /api/d2/orders refreshes during the
    auto-poll don't re-query the view. Empty list when Supabase isn't
    configured."""
    import time as _time
    now = _time.time()
    if (now - _EVENT_WINDOW_CACHE["at"]) < _EVENT_WINDOW_TTL_SEC and _EVENT_WINDOW_CACHE["rows"]:
        return _EVENT_WINDOW_CACHE["rows"]
    if sb is None:
        return []
    from datetime import datetime, timedelta, timezone
    cur = datetime.now(timezone.utc)
    lo = (cur - timedelta(days=days_back)).isoformat()
    hi = (cur + timedelta(days=days_forward)).isoformat()
    try:
        res = (
            sb.table("v_event_base")
            .select("tevo_event_id,event_name,event_at_local,event_at_utc")
            .gte("event_at_utc", lo)
            .lte("event_at_utc", hi)
            .execute()
        )
        rows = res.data or []
        _EVENT_WINDOW_CACHE["at"] = now
        _EVENT_WINDOW_CACHE["rows"] = rows
        return rows
    except Exception as e:
        import sys as _sys
        print(f"[d2_dashboard] event window pull failed: {e!r}", file=_sys.stderr, flush=True)
        return []


# Terminal canonical_status values from public.order_status_xref. Used by
# the active-only default filter on /api/d2/orders. Rows with NULL
# canonical_status (sources whose source_status didn't match an xref row)
# are also surfaced in the active view — they're "unknown" and probably
# need operator attention more than the known-terminal rows.
_ACTIVE_STATUSES = ("pending", "accepted", "substitution")


def _fetch_unified_orders_page(sb, per_page: int, page: int = 1, include_terminal: bool = False) -> dict | None:
    """Pull a balanced page of rows from unified_orders, joined to
    v_event_base for event_name + event_date. Returns None when Supabase
    isn't configured.

    Balanced means: per_page is split across SQL-backed sources rather
    than taken globally newest-first. Globally-newest skewed to whoever's
    cron was most active (operator 2026-05-14 saw 100% evo on page 1
    because SG/seatdata cron had stalled at 2026-05-09; only the live
    evo cron contributed recent created_at). This way every source with
    rows gets surface area on every page."""
    if sb is None:
        return None
    try:
        n_sources = max(1, len(_SQL_BACKED_SOURCES))
        per_source = max(1, per_page // n_sources)
        start = max(0, (page - 1) * per_source)
        end = start + per_source - 1

        all_uo_rows: list[dict] = []
        per_source_as_of: dict[str, str] = {}
        per_source_count: dict[str, int] = {}
        any_error = None

        # One PostgREST query per source, fanned out in parallel. unified_orders
        # carries native event_name + event_date per source as of migration
        # 20260514000000 — no JOIN to v_event_base needed except for sources
        # that don't surface their own event info (seatdata).
        #
        # 2026-05-14: profiled the previous sequential loop at ~400ms total
        # for 4 sources (~100ms RTT × 4). The SQL itself is ~3ms per query;
        # the wall-clock was PostgREST round-trip latency. Parallelizing
        # drops total to ~max(per-source), ~100ms.
        def _pull_one(src: str) -> tuple[str, list[dict], str | None]:
            try:
                q = (
                    sb.table("unified_orders")
                    .select("source,source_order_id,tevo_event_id,source_status,canonical_status,is_terminal,quantity,gross_value,created_at,last_seen_at,event_name,event_date")
                    .eq("source", src)
                )
                if not include_terminal:
                    # Active-only default: hide rows in known-terminal states
                    # (fulfilled/rejected/cancelled). NULL canonical_status
                    # (xref miss on an unknown source_status) is treated as
                    # active — those usually warrant operator attention.
                    q = q.or_(f"canonical_status.is.null,canonical_status.in.({','.join(_ACTIVE_STATUSES)})")
                res = q.order("created_at", desc=True).range(start, end).execute()
                return src, (res.data or []), None
            except Exception as e:
                return src, [], _scrub_err(f"unified_orders.sql.{src}", e)

        sources_to_pull = sorted(_SQL_BACKED_SOURCES)
        with ThreadPoolExecutor(max_workers=len(sources_to_pull)) as ex:
            for src, rows_for_src, err in ex.map(_pull_one, sources_to_pull):
                if err:
                    any_error = err
                for r in rows_for_src:
                    all_uo_rows.append(r)
                    ls = r.get("last_seen_at")
                    if ls and (per_source_as_of.get(src, "") < ls):
                        per_source_as_of[src] = ls
                    per_source_count[src] = per_source_count.get(src, 0) + 1

        # Fallback: rows whose native event_name is NULL (seatdata, or any
        # source whose ingest left the field blank) get v_event_base via
        # tevo_event_id, same as before.
        missing_event_ids = list({
            r["tevo_event_id"] for r in all_uo_rows
            if r.get("tevo_event_id") and not r.get("event_name")
        })
        events_by_id: dict = {}
        if missing_event_ids:
            ev_res = (
                sb.table("v_event_base")
                .select("tevo_event_id,event_name,event_at_local,event_at_utc")
                .in_("tevo_event_id", missing_event_ids)
                .execute()
            )
            events_by_id = {e["tevo_event_id"]: e for e in (ev_res.data or [])}
        rows = []
        for r in all_uo_rows:
            event_name = r.get("event_name")
            event_date = r.get("event_date")
            if not event_name:
                ev = events_by_id.get(r.get("tevo_event_id")) or {}
                event_name = ev.get("event_name")
                event_date = ev.get("event_at_local") or ev.get("event_at_utc")
            rows.append({
                "source": r.get("source") or "",
                "order_id": str(r.get("source_order_id") or ""),
                "event_name": event_name,
                "event_date": event_date,
                "qty": _to_int(r.get("quantity")),
                "status": r.get("source_status"),
                "canonical_status": r.get("canonical_status"),
                "amount": _to_float(r.get("gross_value")),
                "currency": None,
                "ordered_at": r.get("created_at"),
            })
        result = {
            "rows": rows,
            "per_source_count": per_source_count,
            "per_source_as_of": per_source_as_of,
        }
        if any_error:
            result["error"] = any_error
        return result
    except Exception as e:
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}, "error": _scrub_err("unified_orders.sql", e)}


# Column projection shared by the unified_orders page fetchers.
_UO_PAGE_SELECT = (
    "source,source_type,source_order_id,tevo_event_id,source_status,canonical_status,"
    "is_terminal,quantity,gross_value,created_at,last_seen_at,event_name,event_date"
)


def _build_order_rows(sb, all_uo_rows: list[dict]) -> list[dict]:
    """Map raw unified_orders rows → API row dicts, back-filling event_name +
    event_date from v_event_base for any row whose source left them null
    (same fallback the balanced fan-out uses)."""
    missing_event_ids = list({
        r["tevo_event_id"] for r in all_uo_rows
        if r.get("tevo_event_id") and not r.get("event_name")
    })
    events_by_id: dict = {}
    if missing_event_ids:
        ev_res = (
            sb.table("v_event_base")
            .select("tevo_event_id,event_name,event_at_local,event_at_utc")
            .in_("tevo_event_id", missing_event_ids)
            .execute()
        )
        events_by_id = {e["tevo_event_id"]: e for e in (ev_res.data or [])}
    rows = []
    for r in all_uo_rows:
        event_name = r.get("event_name")
        event_date = r.get("event_date")
        if not event_name:
            ev = events_by_id.get(r.get("tevo_event_id")) or {}
            event_name = ev.get("event_name")
            event_date = ev.get("event_at_local") or ev.get("event_at_utc")
        rows.append({
            "source": r.get("source") or "",
            # For s4kcs this is the marketplace (StubHub / Gametime), which the
            # view has no dedicated column for; evo uses it for its order type.
            "source_type": r.get("source_type"),
            "order_id": str(r.get("source_order_id") or ""),
            "event_name": event_name,
            "event_date": event_date,
            "qty": _to_int(r.get("quantity")),
            "status": r.get("source_status"),
            "canonical_status": r.get("canonical_status"),
            "amount": _to_float(r.get("gross_value")),
            "currency": None,
            "ordered_at": r.get("created_at"),
        })
    return rows


def _fetch_filtered_orders(
    sb,
    source: str,
    per_page: int,
    page: int = 1,
    include_terminal: bool = False,
    q: str | None = None,
    when: str = "all",
) -> dict | None:
    """Server-side filtered + paginated order fetch backing the terminal's
    Source / Search / Date controls. Returns None when Supabase isn't wired.

    Crucially this honours an explicit single-source selection: when `source`
    names one SQL-backed source it gets the FULL per_page window (so the
    operator can page through ALL of e.g. EVO's book), instead of the
    balanced fan-out's per_page//n_sources cap that only ever surfaces the
    first ~20 rows of each source on page 1. `source='all'` keeps the
    balanced split so every source gets surface area.

    Filters are all pushed down to SQL:
      - include_terminal=False → active-only (hide terminal canonical_status)
      - q                      → event_name ILIKE %q%
      - when='upcoming'        → event_date >= now()-12h
      - when='past'            → event_date <  now()-12h

    Shape matches `_fetch_unified_orders_page` plus a `has_more` flag derived
    from whether any pulled source filled its page window (drives the
    Next-page control without an extra count(*) round-trip)."""
    if sb is None:
        return None
    try:
        single = source != "all" and source in _SQL_BACKED_SOURCES
        sources_to_pull = [source] if single else sorted(_SQL_BACKED_SOURCES)
        per_source = per_page if single else max(1, per_page // max(1, len(sources_to_pull)))
        start = max(0, (page - 1) * per_source)
        end = start + per_source - 1

        cutoff = None
        if when in ("upcoming", "past"):
            from datetime import datetime, timedelta, timezone
            cutoff = (datetime.now(timezone.utc) - timedelta(hours=12)).isoformat()

        def _pull_one(src: str) -> tuple[str, list[dict], str | None]:
            try:
                query = (
                    sb.table("unified_orders")
                    .select(_UO_PAGE_SELECT)
                    .eq("source", src)
                )
                if not include_terminal:
                    query = query.or_(f"canonical_status.is.null,canonical_status.in.({','.join(_ACTIVE_STATUSES)})")
                if q:
                    query = query.ilike("event_name", f"%{q}%")
                if cutoff is not None and when == "upcoming":
                    query = query.gte("event_date", cutoff)
                elif cutoff is not None and when == "past":
                    query = query.lt("event_date", cutoff)
                res = query.order("created_at", desc=True).range(start, end).execute()
                return src, (res.data or []), None
            except Exception as e:
                return src, [], _scrub_err(f"unified_orders.filtered.{src}", e)

        all_uo_rows: list[dict] = []
        per_source_as_of: dict[str, str] = {}
        per_source_count: dict[str, int] = {}
        per_source_filled: dict[str, bool] = {}
        any_error = None
        with ThreadPoolExecutor(max_workers=len(sources_to_pull)) as ex:
            for src, rows_for_src, err in ex.map(_pull_one, sources_to_pull):
                if err:
                    any_error = err
                per_source_filled[src] = len(rows_for_src) >= per_source
                for r in rows_for_src:
                    all_uo_rows.append(r)
                    ls = r.get("last_seen_at")
                    if ls and (per_source_as_of.get(src, "") < ls):
                        per_source_as_of[src] = ls
                    per_source_count[src] = per_source_count.get(src, 0) + 1

        rows = _build_order_rows(sb, all_uo_rows)
        result = {
            "rows": rows,
            "per_source_count": per_source_count,
            "per_source_as_of": per_source_as_of,
            "has_more": any(per_source_filled.values()),
        }
        if any_error:
            result["error"] = any_error
        return result
    except Exception as e:
        return {
            "rows": [], "per_source_count": {}, "per_source_as_of": {},
            "has_more": False, "error": _scrub_err("unified_orders.filtered", e),
        }


# ---------- Fan-out helpers ----------

_SAFE_CLIENT_ERROR_NAMES = frozenset({
    "TickPickError", "EvoError", "SeatGeekError", "VividError", "SeatDataError",
    "GoTicketsError",
})


def _scrub_err(source: str, exc: Exception) -> str:
    """Log full exception server-side (operator sees in Render logs); return a
    safe message to the client.

    Typed client errors (e.g. TickPickError("HTTP 401")) are constructed by
    the client modules to carry only an HTTP status code — no URLs, tokens,
    or response bodies. Those are passed through so the operator sees what's
    actually wrong (401 vs 404 vs 502) instead of an opaque "upstream error".
    Anything else is scrubbed to the generic message."""
    import sys as _sys
    print(f"[d2_dashboard] {source} fetch failed: {exc!r}", file=_sys.stderr, flush=True)
    if type(exc).__name__ in _SAFE_CLIENT_ERROR_NAMES:
        msg = str(exc).strip()
        # Belt-and-suspenders: even for typed errors, refuse anything that
        # looks like it carries a URL or a long token.
        if msg and "://" not in msg and len(msg) <= 120:
            return msg
    return "upstream error"


def _fetch_unified_orders_fast(sb, per_page: int, include_terminal: bool = False) -> dict | None:
    """First-paint fast path: one global query, upcoming-only, sorted by
    event_date ASC. No per-source split, no v_event_base join, no API call.
    Operator can see the soonest events to triage in <200ms while the
    full orders feed loads in a second phase.

    "Upcoming" = event_date >= now() - 12h, matching the dashboard's
    default Hide-Past-12h filter. Filter pushed down to SQL so we don't
    waste bandwidth on rows the client would hide anyway.

    `include_terminal=False` (default) further filters to non-terminal
    canonical_status (the primary tab's active-only view)."""
    if sb is None:
        return None
    from datetime import datetime, timedelta, timezone
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=12)).isoformat()
    try:
        q = (
            sb.table("unified_orders")
            .select("source,source_order_id,tevo_event_id,source_status,canonical_status,is_terminal,quantity,gross_value,created_at,last_seen_at,event_name,event_date")
            .gte("event_date", cutoff)
        )
        if not include_terminal:
            q = q.or_(f"canonical_status.is.null,canonical_status.in.({','.join(_ACTIVE_STATUSES)})")
        res = q.order("event_date", desc=False, nullsfirst=False).limit(per_page).execute()
        rows_out = []
        per_source_count: dict[str, int] = {}
        per_source_as_of: dict[str, str] = {}
        for r in (res.data or []):
            src = r.get("source") or ""
            rows_out.append({
                "source": src,
                "order_id": str(r.get("source_order_id") or ""),
                "event_name": r.get("event_name"),
                "event_date": r.get("event_date"),
                "qty": _to_int(r.get("quantity")),
                "status": r.get("source_status"),
                "canonical_status": r.get("canonical_status"),
                "amount": _to_float(r.get("gross_value")),
                "currency": None,
                "ordered_at": r.get("created_at"),
            })
            per_source_count[src] = per_source_count.get(src, 0) + 1
            ls = r.get("last_seen_at")
            if ls and (per_source_as_of.get(src, "") < ls):
                per_source_as_of[src] = ls
        return {
            "rows": rows_out,
            "per_source_count": per_source_count,
            "per_source_as_of": per_source_as_of,
        }
    except Exception as e:
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}, "error": _scrub_err("unified_orders.fast", e)}


def _timed(label: str, fn, *args, _timings: dict, **kwargs):
    """Run `fn` and stash its wall-clock duration into `_timings[label]`.
    Lets the parallel fan-out attribute time per-leg without each fetcher
    knowing about the timing dict."""
    import time as _time
    t = _time.perf_counter()
    try:
        return fn(*args, **kwargs)
    finally:
        _timings[label] = (_time.perf_counter() - t) * 1000


# ---------- Deep-order (single-order detail) fetchers ----------

def _deep_order_evo_sql(sb, order_id: str) -> dict:
    res = sb.table("evo_orders").select("*").eq("evo_order_id", order_id).limit(1).execute()
    return (res.data or [None])[0] or {}


def _deep_order_seatgeek_sales_sql(sb, order_id: str) -> dict:
    # Broker firehose row keyed by sg_sale_id (text). Schema:
    # sg_sale_id, sg_event_id, broadcast_price, quantity, section, row,
    # stock_type, delivery_method, in_hand_date, is_instant, seller_notes,
    # sale_at_utc, aq_short_event_id, venue_short_id, pulled_at, raw.
    res = sb.table("seatgeek_sales_snapshots").select("*").eq("sg_sale_id", order_id).limit(1).execute()
    return (res.data or [None])[0] or {}


def _deep_order_tickpick_sql(sb, order_id: str) -> dict:
    res = sb.table("tickpick_orders").select("*").eq("tp_order_id", order_id).limit(1).execute()
    return (res.data or [None])[0] or {}


def _deep_order_vivid_sql(sb, order_id: str) -> dict:
    res = sb.table("vivid_orders").select("*").eq("vivid_order_id", order_id).limit(1).execute()
    return (res.data or [None])[0] or {}


def _deep_order_gotickets(c, order_id: str) -> dict:
    # GoTickets has no SQL backing (no list endpoint upstream, no ingest
    # cron yet). The by-id API call is the only way to surface a GoTickets
    # order in the dashboard. Tracked for future SQL conversion when the
    # canonical lane ships a `gotickets_orders` table + unified_orders UNION.
    return c.get_sale(order_id)


def _deep_order_s4kcs_sql(sb, order_id: str) -> dict:
    # Reads the view, not the raw table, so a Vivid row carries the price from
    # our own vivid_orders book (the CRM ships those with none).
    res = sb.table("v_s4kcs_orders").select("*").eq("s4k_order_id", order_id).limit(1).execute()
    return (res.data or [{}])[0]


# Dispatch: SQL sources use the "_sb" sentinel (the Supabase client);
# gotickets keeps the upstream client factory until SQL backing exists.
# The factory-name strings are resolved by main.py's order_detail route
# against its own module namespace (getattr(main, "_sb"/"_gotickets_client")),
# so the client bootstrap stays in main.py while the fetchers live here.
_DEEP_ORDER = {
    "evo":            ("_sb",               _deep_order_evo_sql),
    "seatgeek_sales": ("_sb",               _deep_order_seatgeek_sales_sql),
    "tickpick":       ("_sb",               _deep_order_tickpick_sql),
    "vivid":          ("_sb",               _deep_order_vivid_sql),
    "s4kcs":          ("_sb",               _deep_order_s4kcs_sql),
    "gotickets":      ("_gotickets_client", _deep_order_gotickets),
}


# ---------- Metrics tab (CEO view) ----------

def _today_start_utc() -> "datetime":
    """Midnight ET (America/New_York) expressed in UTC. Used by the
    `today` window on /api/d2/metrics so the Today card doesn't reset
    at 8 PM ET (which would read as a bug to the operator)."""
    from datetime import datetime, timezone
    try:
        from zoneinfo import ZoneInfo
        et = ZoneInfo("America/New_York")
    except Exception:
        # Python without tzdata; fall back to UTC midnight (acceptable
        # degradation — operator notices the wrong day boundary).
        from datetime import timezone as _tz
        et = _tz.utc
    now_et = datetime.now(et)
    start_et = now_et.replace(hour=0, minute=0, second=0, microsecond=0)
    return start_et.astimezone(timezone.utc)


def _metrics_window_rows(sb, p_start, p_end) -> list[dict]:
    res = sb.rpc("d2_metrics_window", {"p_start": p_start.isoformat(), "p_end": p_end.isoformat()}).execute()
    return res.data or []


def _metrics_hourly_buckets(sb, p_start, p_end) -> list[dict]:
    res = sb.rpc("d2_metrics_hourly_buckets", {"p_start": p_start.isoformat(), "p_end": p_end.isoformat()}).execute()
    return res.data or []


def _metrics_top_events(sb, p_start, p_end, p_limit: int = 10) -> list[dict]:
    res = sb.rpc(
        "d2_metrics_top_events",
        {"p_start": p_start.isoformat(), "p_end": p_end.isoformat(), "p_limit": p_limit},
    ).execute()
    return res.data or []


def _metrics_hot_events(sb, p_start, p_end, p_limit: int = 10) -> list[dict]:
    res = sb.rpc(
        "d2_metrics_hot_events",
        {"p_start": p_start.isoformat(), "p_end": p_end.isoformat(), "p_limit": p_limit},
    ).execute()
    return res.data or []


def _metrics_biggest_sales(sb, p_since, p_limit: int = 10) -> list[dict]:
    args = {"p_limit": p_limit}
    if p_since is not None:
        args["p_since"] = p_since.isoformat() if hasattr(p_since, "isoformat") else p_since
    res = sb.rpc("d2_metrics_biggest_sales", args).execute()
    return res.data or []


def _metrics_sales_gaps(sb, p_lookback_hours: int = 24, p_min_gap_minutes: int = 30) -> list[dict]:
    res = sb.rpc(
        "d2_metrics_sales_gaps",
        {"p_lookback_hours": p_lookback_hours, "p_min_gap_minutes": p_min_gap_minutes},
    ).execute()
    return res.data or []
