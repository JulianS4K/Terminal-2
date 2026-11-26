"""SI Tickets box-office reader (read-only).

SI Tickets (sitickets.com) is the primary ticketer of Sports Illustrated Stadium in Harrison, NJ
(Red Bull New York). Its public pages carry the data as JSON inside the HTML, so this module reads
two kinds of page and nothing else:

  events(venue_slug)   the venue page: the events SI sells there as the box office
  listings(event)      an event page: every seat block on sale, with section, row, seats, the
                       quantities a buyer may take, and per ticket the price before fees and tax,
                       the fee, the tax and the all-in price (price + fee + tax), plus the fee
                       charged once an order. A general admission block has no seats and is flagged

Operator 2026-11-23: "poll all the games for si ... every 10 mins", "for si only red bull stadium",
"remove membership and season listings". Widened 2026-11-26: "ping all those and add any primary box-office
automatically in for both": every venue SI lists is checked, and a venue's events come in as soon as SI sells
them as the box office there (the page's own `primary` flag); resale events are never read (all_events). No key, no login, no cookie. Nothing is ever written to
SI Tickets (RULE 2): no cart, no hold, no order.
"""
from __future__ import annotations

import json
import re
import time
from datetime import datetime, timezone
from typing import Any, Callable
from zoneinfo import ZoneInfo
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
# the venue's time zone: SI writes an event's start in the venue's local time, so this is what turns it into
# a moment. The poll needs the moment: an event that has started is no longer read (operator 2026-11-24:
# "fix the game day wart, end it at tipoff"; mig 20261124041030). A venue not listed gets no start time.
VENUE_TIMEZONES = {"sports-illustrated-stadium": "America/New_York"}
# where a venue is not in VENUE_TIMEZONES, its state's zone (the zone most of the state keeps)
STATE_TIMEZONES = {
    **dict.fromkeys(("CT", "DC", "DE", "FL", "GA", "IN", "MA", "MD", "ME", "MI", "NC", "NH", "NJ", "NY", "OH", "PA",
                     "RI", "SC", "VA", "VT", "WV"), "America/New_York"),
    **dict.fromkeys(("AL", "AR", "IA", "IL", "KS", "KY", "LA", "MN", "MO", "MS", "ND", "NE", "OK", "SD", "TN", "TX",
                     "WI"), "America/Chicago"),
    **dict.fromkeys(("CO", "ID", "MT", "NM", "UT", "WY"), "America/Denver"),
    "AZ": "America/Phoenix", **dict.fromkeys(("CA", "NV", "OR", "WA"), "America/Los_Angeles"),
    "AK": "America/Anchorage", "HI": "Pacific/Honolulu",
}
# the venues SI listed on 2026-11-26 (all resale then, operator 2026-11-26: "add any primary box-office
# automatically"). Each run also adds the venues of SI's own /discover page. A venue where SI sells nothing as
# the box office is read again only after QUIET_RECHECK_S, so its page is not asked for every 10 minutes.
KNOWN_VENUES = (
    "madison-square-garden", "hackensack-meridian-health-theatre-at-the-count-basie-center-for-the-arts",
    "sony-hall", "webster-hall", "keswick-theatre", "warsaw", "levity-live-comedy-club-at-palisades-center",
    "shi-stadium",
)
QUIET_RECHECK_S = 6 * 3600
_quiet_until: dict[str, float] = {}
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
        zone = VENUE_TIMEZONES.get(venue_slug) or STATE_TIMEZONES.get(
            str(ev.get("venue_state") or venue.get("state") or "").upper())
        start = (datetime.fromisoformat(f"{local.group(1)}T{local.group(2)}").replace(tzinfo=ZoneInfo(zone))
                 .astimezone(timezone.utc).isoformat() if local and zone else None)
        out.append({
            "id": str(ev["event_id"]), "name": name,
            "local_date": local.group(1) if local else None, "local_time": local.group(2) if local else None,
            "start_utc": start, "timezone": zone if start else None,
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
        total = all_in.get(g.get("tti"))
        splits = g.get("tsp") or []
        if isinstance(total, dict):
            # the page's own all-in breakdown for this ticket type: price + fee + tax = all-in, per ticket.
            # Its fee (2.84 on an 82.03 ticket) is the one in the total; the listing's own figure (2.68) is not.
            fee = round((total.get("processingFee") or 0) + (total.get("convenienceFee") or 0), 2)
            tax, paid, order_fee = total.get("tax"), total.get("allIn"), total.get("processingFeeFlat")
        else:
            fee, tax, paid, order_fee = g.get("tpf"), None, None, None
        out.append({
            "id": str(g["ti"]), "market": "primary", "area": None,
            "section": _text(g.get("tus")), "row": _text(g.get("tur")),
            "seat_low": _text(g.get("tls")), "seat_high": _text(g.get("ths")),
            "seats": [s.rsplit(":", 1)[-1] for s in g.get("tsi") or [] if isinstance(s, str)] or None,
            "qty": g.get("tq"), "allowed_quantities": splits,
            # the most one order may take is the largest quantity the page lets a buyer pick. The page's own
            # `tmc` agrees with it on every seated block and reads 1 on a general admission block that sells
            # 1 to 10 (HSBC SVNS, 2026-11-24), so it is only the fallback
            "max_per_order": max(splits) if splits else g.get("tmc"),
            "price": g.get("tp"), "fee": fee, "tax": tax, "all_in": paid, "order_fee": order_fee,
            "price_includes_tax": False, "price_estimated": False,
            "ticket_type": kind.get("n"), "delivery": g.get("tf"),
            # general admission (`iga`): one block with no row or seats ("GA" in place of the row)
            "ada": bool(g.get("ia")), "obstructed": False, "aisle": None, "ga": bool(g.get("iga")),
        })
    return out


def _text(value: Any) -> str | None:
    return None if value is None else str(value)


def events(venue_slug: str = VENUE_SLUG) -> list[dict]:
    if not SLUG_OK.match(venue_slug):
        raise SiTicketsError("not a venue slug")
    return parse_events(page_props(_get(f"/venue/{venue_slug}")), venue_slug)


def slug_of(name: str) -> str:
    """A venue's slug on SI as the site makes it from the name ("Sony Hall" -> "sony-hall")."""
    return re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")


def discovered_venues() -> list[str]:
    """The venues of the events SI shows on its own /discover page, as slugs."""
    found = []
    for ev in page_props(_get("/discover")).get("events") or []:
        slug = ev.get("venue_slug") or slug_of(ev.get("venue_name") or "")
        if slug and SLUG_OK.match(slug) and slug not in found:
            found.append(slug)
    return found


def all_events(now: Callable[[], float] = time.time) -> list[dict]:
    """The box-office events of every venue SI sells for: Sports Illustrated Stadium (its page failing fails the
    read, as before), then every other venue SI lists. A venue whose page fails, or where SI sells nothing as the
    box office, is skipped and asked again after QUIET_RECHECK_S."""
    out = {e["id"]: e for e in events(VENUE_SLUG)}
    try:
        extra = discovered_venues()
    except SiTicketsError:
        extra = []
    for slug in dict.fromkeys((*KNOWN_VENUES, *extra)):
        if slug == VENUE_SLUG or _quiet_until.get(slug, 0) > now():
            continue
        try:
            found = events(slug)
        except SiTicketsError:
            found = []
        if not found:
            _quiet_until[slug] = now() + QUIET_RECHECK_S
        for e in found:
            out.setdefault(e["id"], e)
    return list(out.values())


def listings(event: dict) -> list[dict]:
    """The listings of one of `events()`'s events. An event whose page is not a plain event page
    (a deposit or series sold through another flow) raises: there is nothing to read."""
    slug = event.get("_slug") or ""
    if not SLUG_OK.match(slug):
        raise SiTicketsError("this event has no listing page")
    return parse_listings(page_props(_get(f"/event/{slug}")))
