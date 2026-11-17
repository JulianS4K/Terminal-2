"""Public ticket-price tracker (`/prices`) — page shells + JSON reads.

Four public, no-login pages (home table, event page, performer page, venue
page) and the three JSON reads behind them. Every DB read goes through the
SERVICE-ROLE client to the `price_tracker_*` SQL functions
(mig 20261013190000), which are revoked from anon/authenticated — so nothing
new is reachable through PostgREST by a browser.

Only market data leaves this router: event/venue/performer names, the EVO
get-in price + its history, per-zone get-in, weather, the naive forecast
direction, and outbound marketplace links. Never owned inventory, orders,
wholesale prices or brokerage names.

Responses are cached in-process for a short TTL — the underlying metrics move
at most every few minutes, and the home table is the same for every visitor.
"""
from __future__ import annotations

import datetime as _dt
import os
import threading
import time
from typing import Any, Callable, Optional

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import HTMLResponse

CATEGORIES = frozenset({
    "nfl", "mlb", "nba", "nhl", "wnba", "mls", "college",
    "concerts", "theater", "comedy", "sports", "other",
})
WHEN = frozenset({"upcoming", "past", "all"})
SORTS = frozenset({"price", "date", "popular"})

# ticketsdata_event_xref.platform -> (key, display name, market kind)
_TD_PLATFORMS = {
    "VD": ("vivid", "Vivid Seats", "resale"),
    "SH": ("stubhub", "StubHub", "resale"),
    "SG": ("seatgeek", "SeatGeek", "resale"),
    "GT": ("gametime", "Gametime", "resale"),
    "TP": ("tickpick", "TickPick", "resale"),
    "TM": ("ticketmaster", "Ticketmaster", "primary"),
}
_LINK_ORDER = ["vivid", "stubhub", "seatgeek", "gametime", "tickpick", "ticketmaster", "axs"]


class _TTLCache:
    """Tiny thread-safe TTL cache; evicts the oldest entry past `max_items`."""

    def __init__(self, ttl: float, max_items: int = 512):
        self.ttl = ttl
        self.max_items = max_items
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
                oldest = min(self._d, key=lambda k: self._d[k][0])
                self._d.pop(oldest, None)
            self._d[key] = (time.monotonic(), value)


def _safe_url(url: Any) -> Optional[str]:
    """Only pass through absolute http(s) links — never javascript:/data: etc."""
    if not isinstance(url, str):
        return None
    u = url.strip()
    if u.startswith("http://"):
        u = "https://" + u[len("http://"):]
    return u if u.startswith("https://") else None


def build_links(source_links: Optional[dict], axs_url: Optional[str] = None) -> list[dict]:
    """Shape get_event_source_links() output into ordered outbound buy links."""
    out: dict[str, dict] = {}
    src = source_links or {}
    for platform, url in (src.get("td") or {}).items():
        meta = _TD_PLATFORMS.get(str(platform).upper())
        safe = _safe_url(url)
        if meta and safe:
            key, name, kind = meta
            out[key] = {"key": key, "name": name, "kind": kind, "url": safe}
    sg = _safe_url(src.get("sg_url"))
    if sg and "seatgeek" not in out:
        out["seatgeek"] = {"key": "seatgeek", "name": "SeatGeek", "kind": "resale", "url": sg}
    axs = _safe_url(axs_url)
    if axs:
        out["axs"] = {"key": "axs", "name": "AXS", "kind": "primary", "url": axs}
    return [out[k] for k in _LINK_ORDER if k in out]


def _parse_day(v: Optional[str], name: str) -> Optional[str]:
    if v in (None, ""):
        return None
    try:
        return _dt.date.fromisoformat(v).isoformat()
    except ValueError:
        raise HTTPException(400, f"{name} must be YYYY-MM-DD")


def build_prices_router(
    static_dir: str,
    *,
    get_require_sb: Callable[[], Callable],
    cache_ttl: float = 120.0,
) -> APIRouter:
    router = APIRouter()
    cache = _TTLCache(cache_ttl)

    pages_dir = os.path.join(static_dir, "prices")

    def _page(name: str) -> HTMLResponse:
        with open(os.path.join(pages_dir, name), "r", encoding="utf-8") as f:
            body = f.read()
        return HTMLResponse(body, headers={"Cache-Control": "no-cache, must-revalidate"})

    @router.api_route("/prices", methods=["GET", "HEAD"])
    def prices_home_page():
        return _page("index.html")

    @router.api_route("/prices/event/{event_id}", methods=["GET", "HEAD"])
    def prices_event_page(event_id: int):
        return _page("event.html")

    @router.api_route("/prices/performer/{performer_id}", methods=["GET", "HEAD"])
    def prices_performer_page(performer_id: int):
        return _page("list.html")

    @router.api_route("/prices/venue/{venue_id}", methods=["GET", "HEAD"])
    def prices_venue_page(venue_id: int):
        return _page("list.html")

    def _rpc(fn: str, params: dict):
        db = get_require_sb()()
        try:
            return db.rpc(fn, params).execute().data
        except Exception:  # noqa: BLE001 - surface any DB failure as a clean 502
            raise HTTPException(502, "price data temporarily unavailable")

    @router.get("/api/prices/events")
    def prices_events(
        performer_id: Optional[int] = Query(None, ge=1),
        venue_id: Optional[int] = Query(None, ge=1),
        category: Optional[str] = None,
        when: str = "upcoming",
        day_from: Optional[str] = None,
        day_to: Optional[str] = None,
        sort: str = "price",
        limit: int = Query(100, ge=1, le=200),
    ):
        if category is not None and category not in CATEGORIES:
            raise HTTPException(400, "unknown category")
        if when not in WHEN:
            raise HTTPException(400, "when must be upcoming|past|all")
        if sort not in SORTS:
            raise HTTPException(400, "sort must be price|date|popular")
        params = {
            "p_performer_id": performer_id,
            "p_venue_id": venue_id,
            "p_category": category,
            "p_when": when,
            "p_day_from": _parse_day(day_from, "day_from"),
            "p_day_to": _parse_day(day_to, "day_to"),
            "p_sort": sort,
            "p_limit": limit,
        }
        key = ("events", tuple(sorted(params.items())))
        hit = cache.get(key)
        if hit is not None:
            return hit
        data = _rpc("price_tracker_events", params) or {"entity": None, "total": 0, "rows": []}
        cache.put(key, data)
        return data

    @router.get("/api/prices/event/{event_id}")
    def prices_event(event_id: int):
        key = ("event", event_id)
        hit = cache.get(key)
        if hit is not None:
            return hit
        data = _rpc("price_tracker_event", {"p_event_id": event_id})
        if not data:
            raise HTTPException(404, "event not found")
        # Outbound marketplace links are best-effort: a failure here must not
        # take the price page down.
        db = get_require_sb()()
        source_links, axs_url = None, None
        try:
            source_links = db.rpc("get_event_source_links", {"p_event_id": event_id}).execute().data
        except Exception:  # noqa: BLE001
            source_links = None
        try:
            rows = (
                db.table("axs_events").select("event_url")
                .eq("tevo_event_id", event_id).eq("active", True).limit(1).execute().data
            ) or []
            axs_url = rows[0].get("event_url") if rows else None
        except Exception:  # noqa: BLE001
            axs_url = None
        data = dict(data)
        data["links"] = build_links(source_links, axs_url)
        cache.put(key, data)
        return data

    @router.get("/api/prices/search")
    def prices_search(q: str = Query("", max_length=80)):
        term = " ".join(q.split())
        if len(term) < 2:
            return {"performers": [], "venues": [], "events": []}
        key = ("search", term.lower())
        hit = cache.get(key)
        if hit is not None:
            return hit
        data = _rpc("price_tracker_search", {"p_q": term, "p_limit": 6}) or {
            "performers": [], "venues": [], "events": []}
        cache.put(key, data)
        return data

    return router
