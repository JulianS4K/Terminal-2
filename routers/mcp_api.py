"""S4K Terminal as an MCP server — /mcp (Streamable HTTP, stateless, JSON).

Callers authenticate with a bearer API key (``Authorization: Bearer s4k_...``).
The key is hashed (sha256) and resolved by ``mcp_verify_key`` (mig
20261008150000) to a tier:

- ``external`` (partners): public market data only — event search and an
  event's SeatGeek market + nearby competing events.
- ``internal`` (our team): everything external gets, plus our book — pickups,
  per-event orders across every source, home stats, the market chart, owned
  events, and ``query_view`` (whitelisted read-only queries).

Each tier is its own MCP server, so an external caller never even sees the
internal tool list. All reads go through the service-role client; nothing here
writes to the database except ``mcp_verify_key``'s last-used stamp, and no
upstream marketplace API is called (CLAUDE.md rules 1-2).
"""
from __future__ import annotations

import contextlib
import hashlib
import inspect
import json
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from typing import Any

import anyio
from mcp.server.mcpserver import MCPServer
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations

INTERNAL, EXTERNAL = "internal", "external"

# query_view whitelist: view → columns a caller may select/filter/sort on.
# Deliberately excludes buyer PII (seatgeek_orders pickup_email/phone, raw JSON).
QUERY_VIEWS: dict[str, tuple[str, ...]] = {
    "events": ("id", "name", "occurs_at_local", "venue_id", "venue_name", "event_type",
               "primary_performer_id", "primary_performer_name", "popularity_score"),
    "v_s4kcs_orders": ("source", "s4k_order_id", "order_status", "event_name", "event_date",
                       "venue_name", "venue_city", "venue_state", "section", "row", "quantity",
                       "price_per_ticket", "purchase_date", "delivery", "inhand_date",
                       "tevo_event_id"),
    "seatgeek_orders": ("sg_order_id", "status", "created_at_sg", "sg_event_id", "sg_event_name",
                        "sale_price", "sale_section", "sale_row", "sale_quantity",
                        "payment_total", "tevo_event_id"),
    "seatgeek_sales_snapshots": ("tevo_event_id", "sg_event_id", "sg_sale_id", "sale_at_utc",
                                 "broadcast_price", "quantity", "section", "row"),
    "event_listing_snapshot_daily": ("event_id", "snapshot_date", "captured_at",
                                     "evo_tickets_count", "evo_owned_tickets", "evo_retail_getin",
                                     "evo_retail_median", "sg_all_listings", "sg_all_tickets",
                                     "sg_owned_tickets", "sg_all_getin", "sg_all_median",
                                     "amalgam_getin", "amalgam_median"),
    "event_competitors_snapshot": ("tevo_event_id", "competitors_count", "competitors",
                                   "refreshed_at"),
}
FILTER_OPS = ("eq", "neq", "gt", "gte", "lt", "lte", "ilike", "in")
MAX_ROWS = 500


def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def _clamp(v: Any, lo: int, hi: int, default: int) -> int:
    try:
        n = int(v)
    except (TypeError, ValueError):
        return default
    return max(lo, min(n, hi))


# --------------------------------------------------------------------------
# Tool bodies — plain functions over a Supabase client (unit-testable).
# --------------------------------------------------------------------------

def search_events(db, query: str = "", date_from: str | None = None,
                  date_to: str | None = None, limit: int = 20) -> dict:
    """Find events by name (case-insensitive) and local date range (YYYY-MM-DD)."""
    limit = _clamp(limit, 1, 100, 20)
    q = db.table("events").select("id,name,occurs_at_local,venue_name,event_type")
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
    ev = db.table("events").select("id,name,occurs_at_local,venue_name,event_type") \
        .eq("id", event_id).limit(1).execute().data or []
    if not ev:
        return {"error": f"event {event_id} not found"}
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    sales = db.table("seatgeek_sales_snapshots").select("sg_sale_id,sale_at_utc,quantity,broadcast_price") \
        .eq("tevo_event_id", event_id).gte("sale_at_utc", since).limit(5000).execute().data or []
    seen: dict[Any, dict] = {}
    for s in sales:
        seen.setdefault(s.get("sg_sale_id"), s)
    per_day: dict[str, dict] = {}
    for s in seen.values():
        d = str(s.get("sale_at_utc") or "")[:10]
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
                            "daily": daily},
        "competing_events": comp[0] if comp else {"competitors_count": 0, "competitors": []},
    }


def _rpc(db, name: str, args: dict | None = None):
    return db.rpc(name, args or {}).execute().data


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


def owned_events(db, days: int = 30) -> dict:
    """Upcoming events where we own tickets (as of the latest TEvo listing poll)."""
    return {"events": _rpc(db, "get_owned_events_upcoming", {"p_days": _clamp(days, 1, 365, 30)}) or []}


def query_view(db, view: str, columns: list[str] | None = None,
               filters: list[dict] | None = None, order_by: str | None = None,
               descending: bool = False, limit: int = 100) -> dict:
    """Read-only query over a whitelisted view. filters: [{column, op, value}],
    op in eq|neq|gt|gte|lt|lte|ilike|in (value is a list for `in`)."""
    if view not in QUERY_VIEWS:
        return {"error": f"unknown view {view!r}", "views": {k: list(v) for k, v in QUERY_VIEWS.items()}}
    allowed = QUERY_VIEWS[view]
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


EXTERNAL_TOOLS: tuple[Callable, ...] = (search_events, event_market)
INTERNAL_TOOLS: tuple[Callable, ...] = EXTERNAL_TOOLS + (
    pickups, event_orders, event_source_links, home_stats, market_chart, owned_events, query_view)


# --------------------------------------------------------------------------
# MCP wiring
# --------------------------------------------------------------------------

def _make_server(name: str, tools: tuple[Callable, ...], get_db: Callable[[], Any]) -> MCPServer:
    srv = MCPServer(name, instructions=(
        "S4K ticketing terminal data. Event ids are TEvo event ids. Dates are local "
        "(ET for our order days). Read-only."))
    for fn in tools:
        def bound(*args, __fn=fn, **kwargs):
            return __fn(get_db(), *args, **kwargs)
        bound.__name__, bound.__doc__ = fn.__name__, fn.__doc__
        # Re-expose the tool's own signature minus the leading `db` parameter.
        sig = inspect.signature(fn)
        bound.__signature__ = sig.replace(parameters=list(sig.parameters.values())[1:])
        bound.__annotations__ = {k: v for k, v in fn.__annotations__.items() if k != "db"}
        srv.add_tool(bound, name=fn.__name__, description=fn.__doc__,
                     annotations=ToolAnnotations(readOnlyHint=True, openWorldHint=False))
    return srv


class MCPApp:
    """ASGI app: authenticate the bearer key, then hand the request to the
    tier's MCP server. ``lifespan()`` must wrap the host app's lifespan."""

    def __init__(self, get_db: Callable[[], Any]):
        self._get_db = get_db
        self._servers = {
            EXTERNAL: _make_server("s4k-terminal", EXTERNAL_TOOLS, get_db),
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

    def resolve_tier(self, headers: dict[str, str]) -> str | None:
        auth = headers.get("authorization", "")
        key = auth[7:].strip() if auth.lower().startswith("bearer ") else headers.get("x-api-key", "").strip()
        if not key:
            return None
        try:
            rows = self._get_db().rpc("mcp_verify_key", {"p_key_hash": hash_key(key)}).execute().data or []
        except Exception:
            return None
        tier = rows[0].get("tier") if rows else None
        return tier if tier in (INTERNAL, EXTERNAL) else None

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":  # pragma: no cover - websockets/lifespan never routed here
            return
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
        tier = await anyio.to_thread.run_sync(self.resolve_tier, headers)
        if tier is None:
            await _json(send, 401, {"error": "missing or invalid API key"},
                        {"www-authenticate": 'Bearer realm="s4k-mcp"'})
            return
        manager = self._managers.get(tier)
        if manager is None:
            await _json(send, 503, {"error": "MCP server not started"})
            return
        await manager.handle_request(scope, receive, send)


async def _json(send, status: int, body: dict, extra: dict[str, str] | None = None) -> None:
    payload = json.dumps(body).encode()
    headers = [(b"content-type", b"application/json"), (b"content-length", str(len(payload)).encode())]
    headers += [(k.encode(), v.encode()) for k, v in (extra or {}).items()]
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": payload})
