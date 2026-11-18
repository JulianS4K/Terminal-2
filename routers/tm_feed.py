"""Ticketmaster catalogue feeds, served inside the sub finder API next to the MLB feed.

Operator 2026-11-18: "add the tmr discovery feed into the mlb api and push out and ping, then add
the sites it pairs to vivid, seatgeek, tickpick etc when it maps as a seperate get call".

    GET /api/v1/subs/tm/events      every upcoming Ticketmaster event we hold, with the EVO event
                                    it matched, if any (view v_tm_discovery_feed)
    GET /api/v1/subs/tm/markets     one row per event that matched an EVO event, with the id of the
                                    same event on SeatGeek, Vivid Seats, TickPick, StubHub, GoTickets
                                    and AXS where we can pair it (view v_tm_discovery_markets)

Both take:
        ?date_from=2026-11-20&date_to=2026-11-30
        &segment=Sports          Sports | Music | Arts & Theatre | ... (as Ticketmaster names it)
        &state=NY                the venue's state code
        &status=onsale           onsale | offsale | cancelled | postponed | rescheduled
        &since=2026-11-18T00:00:00Z   rows that changed at or after this time
        &format=json|csv         (default json)
        &limit=1000&offset=0     (limit max 5000)
/tm/events also takes  &mapped=true|false  (matched to an EVO event or not)
                       &products=true      include parking, add-ons and packages (left out by default)
                       &safetix=true|false only events with (or without) SafeTix
                       &detail=false       only the core columns, about a quarter of the size
/tm/events carries everything Ticketmaster returns for the event (operator 2026-11-18: "add and push
all of them out including buy limits", mig 20261118223540): the ticket limit as its sentence, the
numbers in it and the single limit when there is one; SafeTix and all-in pricing; on-sale end;
end, access and doors times; notes; teams or performers with their links; add-ons; and the venue's
address, coordinates, market, box office, parking and accessibility notes.
/tm/markets also takes &site=vivid         only events paired to that site: seatgeek | vivid |
                                           tickpick | stubhub | gotickets | axs

The events come from Ticketmaster's Discovery catalogue, collected by `tm_discovery_tick` under a
hard budget of 100 calls a day (mig 20261117180000): names, dates, venues, status and on-sale
dates. No prices and no inventory. The views are mig 20261118220530. This module only answers the
query: it reads our own tables and makes no upstream call (RULE 2).
"""
from __future__ import annotations

import re
from typing import Any

from routers.mlb_feed import _bool, _csv, _date, _err, _paging, _since

EVENT_VIEW = "v_tm_discovery_feed"
MARKET_VIEW = "v_tm_discovery_markets"
STATUSES = ("onsale", "offsale", "cancelled", "postponed", "rescheduled")
SITES = {"seatgeek": "seatgeek_event_id", "vivid": "vivid_event_id", "tickpick": "tickpick_event_id",
         "stubhub": "stubhub_event_id", "gotickets": "gotickets_event_id", "axs": "axs_event_id"}
_SEGMENT = re.compile(r"^[A-Za-z&/ ]{1,40}$")
_STATE = re.compile(r"^[A-Za-z]{2}$")
EVENT_COLUMNS = ("tm_event_id", "name", "ticket_url", "event_date", "start_local_time", "start_utc", "date_tbd",
                 "time_tba", "status", "segment", "genre", "sub_genre", "tm_venue_id", "venue_name", "venue_city",
                 "venue_state", "venue_country", "venue_timezone", "attraction_names", "public_onsale", "presales",
                 "ticket_limit", "is_product", "tevo_event_id", "tevo_match_method", "tevo_event_name",
                 "tevo_start_local", "terminal_path", "first_seen_at", "last_seen_at", "changed_at")
# the rest of what Ticketmaster returns for the event (mig 20261118223540); left out with detail=false
DETAIL_COLUMNS = ("public_onsale_end", "ticket_limit_numbers", "ticket_limit_count", "safetix", "all_in_pricing",
                  "end_date", "end_local_time", "end_utc", "spans_multiple_days", "access_start_utc",
                  "access_end_utc", "doors_local_time", "doors_utc", "please_note", "info", "description",
                  "more_info_url", "ticket_text", "classification_type", "classification_sub_type", "family",
                  "attractions", "products", "venue_address", "venue_postal_code", "venue_latitude",
                  "venue_longitude", "venue_url", "venue_markets", "venue_upcoming_events", "venue_box_office",
                  "venue_parking", "venue_general_info", "venue_accessible_seating", "venue_ada")
MARKET_COLUMNS = ("tm_event_id", "name", "event_date", "start_local_time", "status", "segment", "genre", "venue_name",
                  "venue_city", "venue_state", "ticketmaster_url", "tevo_event_id", "tevo_event_name",
                  "tevo_match_method", "seatgeek_event_id", "seatgeek_url", "vivid_event_id", "tickpick_event_id",
                  "stubhub_event_id", "gotickets_event_id", "axs_event_id", "aq_short_event_id", "sites_paired",
                  "terminal_path", "changed_at")


def _common(q: Any) -> dict:
    """The filters both feeds share, checked. Raises ValueError naming the bad parameter."""
    segment = (q.get("segment") or "").strip()
    if segment and not _SEGMENT.match(segment):
        raise ValueError("segment")
    state = (q.get("state") or "").strip().upper()
    if state and not _STATE.match(state):
        raise ValueError("state")
    status = (q.get("status") or "").strip().lower()
    if status and status not in STATUSES:
        raise ValueError("status")
    fmt = (q.get("format") or "json").strip().lower()
    if fmt not in ("json", "csv"):
        raise ValueError("format")
    limit, offset = _paging(q)
    return {"segment": segment, "state": state, "status": status, "fmt": fmt, "limit": limit, "offset": offset,
            "date_from": _date(q.get("date_from")), "date_to": _date(q.get("date_to")), "since": _since(q.get("since"))}


def _filtered(sel: Any, f: dict) -> Any:
    if f["date_from"]:
        sel = sel.gte("event_date", f["date_from"])
    if f["date_to"]:
        sel = sel.lte("event_date", f["date_to"])
    if f["segment"]:
        sel = sel.ilike("segment", f["segment"])
    if f["state"]:
        sel = sel.eq("venue_state", f["state"])
    if f["status"]:
        sel = sel.eq("status", f["status"])
    if f["since"]:
        sel = sel.gte("changed_at", f["since"])
    return sel


def _answer(sel: Any, f: dict, columns: tuple, key: str, filename: str) -> Any:
    try:
        rows = (sel.order("event_date").order("start_local_time").order("tm_event_id")
                .range(f["offset"], f["offset"] + f["limit"] - 1).execute().data) or []
    except Exception as exc:  # noqa: BLE001 - surfaced as a 502 with the class only
        return _err(502, "upstream_error", type(exc).__name__)
    if f["fmt"] == "csv":
        return _csv(rows, columns, filename)
    nxt = f["offset"] + f["limit"] if len(rows) == f["limit"] else None
    return {"count": len(rows), "offset": f["offset"], "next_offset": nxt, key: rows}


def events_response(db: Any, params: Any) -> Any:
    """GET /tm/events: a dict (JSON), a CSV Response, or a JSONResponse error."""
    try:
        f = _common(params)
        mapped, products = _bool(params.get("mapped")), _bool(params.get("products"))
        safetix, detail = _bool(params.get("safetix")), _bool(params.get("detail"))
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")
    columns = EVENT_COLUMNS if detail is False else EVENT_COLUMNS + DETAIL_COLUMNS
    sel = _filtered(db.table(EVENT_VIEW).select(",".join(columns)), f)
    if mapped is True:
        sel = sel.not_.is_("tevo_event_id", "null")
    elif mapped is False:
        sel = sel.is_("tevo_event_id", "null")
    if not products:                       # parking, add-ons and packages are not events
        sel = sel.eq("is_product", False)
    if safetix is not None:
        sel = sel.eq("safetix", safetix)
    return _answer(sel, f, columns, "events", "tm_events.csv")


def markets_response(db: Any, params: Any) -> Any:
    """GET /tm/markets: the other sites each mapped Ticketmaster event pairs to."""
    try:
        f = _common(params)
        site = (params.get("site") or "").strip().lower()
        if site and site not in SITES:
            raise ValueError("site")
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")
    sel = _filtered(db.table(MARKET_VIEW).select(",".join(MARKET_COLUMNS)), f)
    if site:
        sel = sel.not_.is_(SITES[site], "null")
    return _answer(sel, f, MARKET_COLUMNS, "events", "tm_markets.csv")
