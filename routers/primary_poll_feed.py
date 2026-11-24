"""The primary box offices we poll ourselves, served inside the sub finder API: their events and each
event's listings.

Operator 2026-11-23: "we're gonna push the list of events and their respective listings out, if
poller fails to run for an event, do not send listing information", "also dont send obstructed out".

    GET /api/v1/subs/primary/events     every upcoming event of the polled box offices, with whether its
                                        listings can be sent right now (view v_primary_poll_events_feed)
    GET /api/v1/subs/primary/listings   the listings of the events whose last poll succeeded within
                                        the age limit (view v_primary_poll_listings_feed)

Both take:
        ?source=sitickets|timberwolves|lynx|nccourage|denversummit|reign|bostonlegacy|sounders|northcarolinafc|axs
                                 (a team's own ticket site has no events until it lists single games; `axs` is the
                                 watched list of AXS-sold events read through TicketsData, mig 20261124190000)
        &date_from=2026-11-23&date_to=2027-05-01
        &format=json|csv         (default json)
        &limit=1000&offset=0     (limit max 5000)
/primary/events also takes    &q=red bull new england     every word must be in the name, venue or city
                              &available=true|false       events whose listings can / cannot be sent now
                              &mapped=true|false          matched to an EVO event or not
/primary/listings also takes  &event_id=2297105  &tevo_event_id=3584741  &market=primary|resale  &section=126

Every row carries `tevo_event_id`, the EVO event our mapper matched (null until it has).

Only the newest pull is served (operator 2026-11-23: "for the api only push out newest pull"): an
event's listings are replaced on every read, and /primary/events holds the events of the source's last
completed pull. Each event is read on its own cadence, by its date, its median price and the tickets listed:
every 10 minutes on the day of the event; every 30 minutes up to 2 days away (5 for a Friday, Saturday or Sunday event),
or for a dear or heavily listed one further off; every hour for the rest (`poll_every_minutes`). Each read falls on
a random 10-minute slot inside that interval, redrawn every cycle (`next_poll_at`; mig 20261123194030). Listings
are served for 35 minutes after a good read, or until 20 minutes after the next slot, whichever is later. An event whose poll failed, has not run, or is older than its limit is still in /primary/events,
with listings_available = false and listings_withheld = poll_failed | not_polled | poll_stale; so is an event
that has started (event_started: we stop reading it at its start time, mig 20261124041030). Such an event has
no row in /primary/listings. Listings flagged as an obstructed view are never sent. The views are mig
20261123171030. This module only answers the query: it reads our own tables and makes no upstream
call (RULE 2).
"""
from __future__ import annotations

import re
from typing import Any

import jump_client
from routers.mlb_feed import _bool, _csv, _date, _err, _paging
from routers.tm_feed import _words

EVENTS_VIEW = "v_primary_poll_events_feed"
LISTINGS_VIEW = "v_primary_poll_listings_feed"
SOURCES = ("sitickets", *jump_client.SITES, "axs")   # SI Tickets, every team site on the Jump platform, the AXS watch
MARKETS = ("primary", "resale")
SEARCH_COLUMN = "search_text"          # lower case; filtered on, never returned
EVENT_COLUMNS = ("source", "event_id", "name", "event_date", "start_local_time", "start_utc", "timezone",
                 "venue_name", "venue_city", "venue_state", "ticket_url", "offer_id", "order_min", "order_max",
                 "total_available", "price_min", "price_max", "currency", "listings_available", "listing_count",
                 "listings_as_of", "listings_withheld", "tevo_event_id", "tevo_match_method", "terminal_path",
                 "last_poll_at", "first_seen_at", "last_seen_at", "median_price", "poll_every_minutes", "next_poll_at",
                 "listed_quantity")
LISTING_COLUMNS = ("source", "event_id", "event_name", "tevo_event_id", "event_date", "start_local_time", "listing_id", "market",
                   "area", "section", "seat_row", "seat_low", "seat_high", "seats", "quantity", "allowed_quantities",
                   "max_per_order", "order_min", "order_max", "price", "fee", "all_in_price", "price_includes_tax",
                   "currency", "ticket_type", "delivery", "ada", "aisle", "general_admission", "as_of", "tax", "order_fee",
                   "price_estimated")
_TOKEN = re.compile(r"^[A-Za-z0-9 ._:=/+-]{1,160}$")


def _token(q: Any, name: str) -> str:
    """A free-text filter value (an event id, a section): checked, because it goes into the query."""
    value = (q.get(name) or "").strip()
    if value and not _TOKEN.match(value):
        raise ValueError(name)
    return value


def _one_of(q: Any, name: str, allowed: tuple) -> str:
    value = (q.get(name) or "").strip().lower()
    if value and value not in allowed:
        raise ValueError(name)
    return value


def _common(q: Any) -> dict:
    fmt = (q.get("format") or "json").strip().lower()
    if fmt not in ("json", "csv"):
        raise ValueError("format")
    limit, offset = _paging(q)
    return {"fmt": fmt, "limit": limit, "offset": offset, "source": _one_of(q, "source", SOURCES),
            "date_from": _date(q.get("date_from")), "date_to": _date(q.get("date_to"))}


def _filtered(sel: Any, f: dict) -> Any:
    if f["source"]:
        sel = sel.eq("source", f["source"])
    if f["date_from"]:
        sel = sel.gte("event_date", f["date_from"])
    if f["date_to"]:
        sel = sel.lte("event_date", f["date_to"])
    return sel


def _page(sel: Any, f: dict, columns: tuple, key: str, filename: str, order: tuple) -> Any:
    try:
        for column in order:
            sel = sel.order(column)
        rows = sel.range(f["offset"], f["offset"] + f["limit"] - 1).execute().data or []
    except Exception as exc:  # noqa: BLE001 - surfaced as a 502 with the class only
        return _err(502, "upstream_error", type(exc).__name__)
    if f["fmt"] == "csv":
        return _csv(rows, columns, filename)
    nxt = f["offset"] + f["limit"] if len(rows) == f["limit"] else None
    return {"count": len(rows), "offset": f["offset"], "next_offset": nxt, key: rows}


def events_response(db: Any, params: Any) -> Any:
    """GET /primary/events: a dict (JSON), a CSV Response, or a JSONResponse error."""
    try:
        f = _common(params)
        available, words = _bool(params.get("available")), _words(params.get("q"))
        mapped = _bool(params.get("mapped"))
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")
    sel = _filtered(db.table(EVENTS_VIEW).select(",".join(EVENT_COLUMNS)), f)
    if available is not None:
        sel = sel.eq("listings_available", available)
    if mapped is True:
        sel = sel.not_.is_("tevo_event_id", "null")
    elif mapped is False:
        sel = sel.is_("tevo_event_id", "null")
    for word in words:
        sel = sel.ilike(SEARCH_COLUMN, f"%{word}%")
    return _page(sel, f, EVENT_COLUMNS, "events", "primary_events.csv",
                 ("event_date", "start_local_time", "source", "event_id"))


def listings_response(db: Any, params: Any) -> Any:
    """GET /primary/listings: only events whose last poll succeeded within the age limit have rows."""
    try:
        f = _common(params)
        event_id, section = _token(params, "event_id"), _token(params, "section")
        tevo_event_id = (params.get("tevo_event_id") or "").strip()
        if tevo_event_id and not tevo_event_id.isdigit():
            raise ValueError("tevo_event_id")
        market = _one_of(params, "market", MARKETS)
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")
    sel = _filtered(db.table(LISTINGS_VIEW).select(",".join(LISTING_COLUMNS)), f)
    if event_id:
        sel = sel.eq("event_id", event_id)
    if tevo_event_id:
        sel = sel.eq("tevo_event_id", int(tevo_event_id))
    if market:
        sel = sel.eq("market", market)
    if section:
        sel = sel.eq("section", section)
    return _page(sel, f, LISTING_COLUMNS, "listings", "primary_listings.csv",
                 ("event_date", "source", "event_id", "price", "listing_id"))
