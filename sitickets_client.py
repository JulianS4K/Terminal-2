"""SI Tickets box-office reader (read-only).

SI Tickets (sitickets.com) is the primary ticketer of Sports Illustrated Stadium in Harrison, NJ
(Red Bull New York). Its public pages carry the data as JSON inside the HTML, so this module reads
two kinds of page and nothing else:

  events(venue_slug)   the venue page: the events SI sells there as the box office
  listings(event)      an event page: every seat block on sale, with section, row, seats, the
                       quantities a buyer may take, price, fee and the all-in price

Operator 2026-11-23: "poll all the games for si ... every 10 mins", "for si only red bull stadium",
"remove membership and season listings". No key, no login, no cookie. Nothing is ever written to
SI Tickets (RULE 2): no cart, no hold, no order.
"""
from __future__ import annotations

import json
import re
from typing import Any
from urllib.parse import quote

import requests

from core.readonly_guard import build_readonly_guard

# RULE 2 — READ-ONLY. GETs of public pages; any other method raises before a network call.
# Paired with the static check in scripts/check_readonly.py and tests/test_readonly_guards.py.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class SiTicketsError(RuntimeError):
    pass


class SiTicketsReadOnlyError(SiTicketsError):
    """Raised when a non-GET method is attempted against SI Tickets."""


# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    SiTicketsReadOnlyError, ALLOWED_HTTP_METHODS,
    "Reading public pages only — never a cart, hold or order on SI Tickets.",
)

BASE = "https://www.sitickets.com"
VENUE_SLUG = "sports-illustrated-stadium"
USER_AGENT = "S4K-primary-poll/1.0"
TIMEOUT_S = 30
SLUG_OK = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# season packages, memberships and their deposits are not single events (operator 2026-11-23)
NOT_AN_EVENT = re.compile(r"membership|member|season|deposit", re.IGNORECASE)
_NEXT_DATA = re.compile(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', re.DOTALL)
_LOCAL = re.compile(r"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})")


def _get(path: str) -> str:
    _assert_readonly_method("GET")
    resp = requests.get(BASE + path, headers={"User-Agent": USER_AGENT, "Accept": "text/html"}, timeout=TIMEOUT_S)
    if resp.status_code != 200:
        raise SiTicketsError(f"HTTP {resp.status_code} for {path}")
    return resp.text


def page_props(html: str) -> dict:
    """The page's own data: the `pageProps` of the JSON the site embeds in every page."""
    found = _NEXT_DATA.search(html)
    if not found:
        raise SiTicketsError("the page carries no data")
    try:
        return json.loads(found.group(1))["props"]["pageProps"]
    except (ValueError, KeyError, TypeError) as exc:
        raise SiTicketsError("the page's data could not be read") from exc


def parse_events(props: dict, venue_slug: str = VENUE_SLUG) -> list[dict]:
    """The venue page's events that SI sells as the box office, without packages and memberships."""
    venue = props.get("venueData") or {}
    out = []
    for ev in props.get("venueEventsData") or []:
        name = (ev.get("event_name") or "").strip()
        if not ev.get("primary") or not name or NOT_AN_EVENT.search(name):
            continue
        # SI writes the venue's local time with a Z; it is not UTC (the page shows the same hour)
        local = _LOCAL.match(ev.get("occurs_at") or "")
        slug = ev.get("event_slug") or ""
        out.append({
            "id": str(ev["event_id"]), "name": name,
            "local_date": local.group(1) if local else None, "local_time": local.group(2) if local else None,
            "start_utc": None, "timezone": None,
            "venue": ev.get("venue_name") or venue.get("name"), "city": ev.get("venue_city") or venue.get("city"),
            "state": ev.get("venue_state") or venue.get("state"),
            "url": f"{BASE}/event/{quote(slug)}" if slug else None,
            "offer_id": None, "order_min": None, "order_max": None,
            "total_available": None, "price_min": None, "price_max": None,
            "_slug": slug,
        })
    return out


def parse_listings(props: dict) -> list[dict]:
    """An event page's seat blocks. Raises when the page has no box-office listing data."""
    if props.get("ticketGroupsError"):
        raise SiTicketsError("the page reports a listing error")
    data = props.get("ticketData")
    if not isinstance(data, dict) or not isinstance(data.get("ticketingGroups"), list):
        raise SiTicketsError("the page carries no box-office listings")
    all_in = data.get("allInPrices") or {}
    out = []
    for g in data["ticketingGroups"]:
        kind = (g.get("tps") or [{}])[0]
        total = all_in.get(g.get("tti")) or {}
        splits = g.get("tsp") or []
        out.append({
            "id": str(g["ti"]), "market": "primary", "area": None,
            "section": _text(g.get("tus")), "row": _text(g.get("tur")),
            "seat_low": _text(g.get("tls")), "seat_high": _text(g.get("ths")),
            "seats": [s.rsplit(":", 1)[-1] for s in g.get("tsi") or [] if isinstance(s, str)] or None,
            "qty": g.get("tq"), "allowed_quantities": splits,
            "max_per_order": g.get("tmc") or (max(splits) if splits else None),
            "price": g.get("tp"), "fee": g.get("tpf"), "all_in": total.get("allIn"), "price_includes_tax": False,
            "ticket_type": kind.get("n"), "delivery": g.get("tf"),
            "ada": bool(g.get("ia")), "obstructed": False, "aisle": None, "ga": None,
        })
    return out


def _text(value: Any) -> str | None:
    return None if value is None else str(value)


def events(venue_slug: str = VENUE_SLUG) -> list[dict]:
    if not SLUG_OK.match(venue_slug):
        raise SiTicketsError("not a venue slug")
    return parse_events(page_props(_get(f"/venue/{venue_slug}")), venue_slug)


def listings(event: dict) -> list[dict]:
    """The listings of one of `events()`'s events. An event whose page is not a plain event page
    (a deposit or series sold through another flow) raises: there is nothing to read."""
    slug = event.get("_slug") or ""
    if not SLUG_OK.match(slug):
        raise SiTicketsError("this event has no listing page")
    return parse_listings(page_props(_get(f"/event/{slug}")))
