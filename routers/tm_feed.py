"""Ticketmaster catalogue feeds, served inside the sub finder API next to the MLB feed.

Operator 2026-11-18: "add the tmr discovery feed into the mlb api and push out and ping, then add
the sites it pairs to vivid, seatgeek, tickpick etc when it maps as a seperate get call".

    GET /api/v1/subs/tm/events      every upcoming Ticketmaster event we hold, with the EVO event
                                    it matched, if any (view v_tm_discovery_feed)
    GET /api/v1/subs/tm/markets     one row per event that matched an EVO event, with the id of the
                                    same event on SeatGeek, Vivid Seats, TickPick, StubHub, GoTickets
                                    and AXS where we can pair it (view v_tm_discovery_markets)
    GET /api/v1/subs/tm/changes     every change we detected to an event's status, date, start time
                                    or venue, oldest first (view v_tm_discovery_changes)

Both take:
        ?date_from=2026-11-20&date_to=2026-11-30
        &segment=Sports          Sports | Music | Arts & Theatre | ... (as Ticketmaster names it)
        &state=NY                the venue's state code
        &status=onsale           onsale | offsale | cancelled | postponed | rescheduled
        &since=2026-11-18T00:00:00Z   rows that changed at or after this time
        &format=json|csv         (default json)
        &limit=1000&offset=0     (limit max 5000)
/tm/events also takes  &mapped=true|false  (matched to an EVO event or not)
                       &q=knicks garden    a search: every word must be in the event's name, its
                                           teams or performers, its venue or its city (mig 20261121171530)
                       &products=true      include parking, add-ons and packages (left out by default)
                       &safetix=true|false only events with (or without) SafeTix
                       &detail=false       only the core columns, about a quarter of the size
                       &primary=true|false Ticketmaster itself is the seller (true), or it is a resale page or
                                           another ticketer's event (false); events not in the bulk feed match neither
                       &source=tmr         one seller type as the bulk feed names it: ticketmaster | tmr (resale) |
                                           universe | ticketweb | third-party primary | frontgate | other
/tm/events carries everything Ticketmaster returns for the event (operator 2026-11-18: "add and push
all of them out including buy limits", mig 20261118223540): the ticket limit as its sentence, the
numbers in it and the single limit when there is one; SafeTix and all-in pricing; on-sale end;
end, access and doors times; notes; teams or performers with their links; add-ons; and the venue's
address, coordinates, market, box office, parking and accessibility notes.
/tm/markets also takes &site=vivid         only events paired to that site: seatgeek | vivid |
                                           tickpick | stubhub | gotickets | axs
/tm/changes takes      &after_id=120       resume after the last change_id you read (or &since=)
                       &kind=status_changed,time_changed   status_changed | date_changed | time_changed |
                                           venue_changed
                       &format=json|csv&limit=1000
`since` on /tm/events also returns an event whose status, date, time or venue changed (asked
2026-11-21: "A way to get events whose status or time changed"; mig 20261121171530). A change is
seen when the collector next re-reads the event, which is once a week.

The events come from Ticketmaster's bulk Discovery Feed, loaded once a day (core/tm_feed_sync.py,
mig 20261122030530), which also says who really sells each event (`source`, `tm_primary`). The
search API is called only for Ticketmaster-primary events that are new or changed, for the detail
the feed lacks (ticket limit, SafeTix, presales), under two hard budgets a day, 1,000 calls and 250
(migs 20261117180000, 20261121223530): names, dates, venues, status and on-sale dates. No prices and no inventory. The views are mig 20261118220530. This module only answers the
query: it reads our own tables and makes no upstream call (RULE 2).
"""
from __future__ import annotations

import re
import unicodedata
from typing import Any

from routers.mlb_feed import _bool, _csv, _date, _err, _paging, _since

EVENT_VIEW = "v_tm_discovery_feed"
MARKET_VIEW = "v_tm_discovery_markets"
CHANGES_VIEW = "v_tm_discovery_changes"
CHANGE_KINDS = ("status_changed", "date_changed", "time_changed", "venue_changed")
CHANGE_COLUMNS = ("change_id", "detected_at", "kind", "old_value", "new_value", "tm_event_id", "name", "event_date",
                  "start_local_time", "status", "segment", "venue_name", "venue_city", "venue_state", "ticket_url",
                  "tevo_event_id")
SEARCH_COLUMN = "search_text"          # lower case, accents removed; filtered on, never returned
MAX_QUERY, MAX_WORDS = 80, 6
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
# what Ticketmaster's bulk feed adds (mig 20261122030530): who really sells the event, the ids
# Ticketmaster's own pages use, and the seat map link and outlets the collector now keeps
FEED_COLUMNS = ("source", "tm_primary", "official_seller", "brand_name", "transactable", "hot_event",
                "legacy_event_id", "legacy_venue_id", "promoter_names", "in_feed", "seatmap_url", "outlets",
                "detail_read_at")
SLIM_FEED_COLUMNS = ("source", "tm_primary")       # the two that come with detail=false as well
_SOURCE = re.compile(r"^[a-z][a-z -]{1,29}$")
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


def _words(q: str | None) -> list[str]:
    """The words of a search, as `search_text` holds them: lower case, accents removed, letters and
    digits only ("AC/DC" is `ac` and `dc`). One-letter words are dropped. Raises ValueError("q")
    when the text is too long or holds nothing to search for."""
    text = (q or "").strip()
    if not text:
        return []
    if len(text) > MAX_QUERY:
        raise ValueError("q")
    folded = "".join(c for c in unicodedata.normalize("NFKD", text.lower()) if not unicodedata.combining(c))
    words = [w for w in re.findall(r"[a-z0-9]+", folded) if len(w) > 1][:MAX_WORDS]
    if not words:
        raise ValueError("q")
    return words


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


def _answer(sel: Any, f: dict, columns: tuple, key: str, filename: str, id_column: str = "tm_event_id") -> Any:
    try:
        rows = (sel.order("event_date").order("start_local_time").order(id_column)
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
        words = _words(params.get("q"))
        primary = _bool(params.get("primary"))
        source = (params.get("source") or "").strip().lower()
        if source and not _SOURCE.match(source):
            raise ValueError("source")
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")
    columns = (EVENT_COLUMNS + SLIM_FEED_COLUMNS if detail is False
               else EVENT_COLUMNS + DETAIL_COLUMNS + FEED_COLUMNS)
    sel = _filtered(db.table(EVENT_VIEW).select(",".join(columns)), f)
    if mapped is True:
        sel = sel.not_.is_("tevo_event_id", "null")
    elif mapped is False:
        sel = sel.is_("tevo_event_id", "null")
    if not products:                       # parking, add-ons and packages are not events
        sel = sel.eq("is_product", False)
    if safetix is not None:
        sel = sel.eq("safetix", safetix)
    if primary is not None:                # Ticketmaster itself sells it (the feed's SOURCE), or does not
        sel = sel.eq("tm_primary", primary)
    if source:
        sel = sel.eq("source", source)
    for word in words:                     # every word, anywhere in name, performers, venue or city
        sel = sel.ilike(SEARCH_COLUMN, f"%{word}%")
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


def changes_response(db: Any, params: Any) -> Any:
    """GET /tm/changes: each change to an event's status, date, start time or venue, oldest first.
    `next_after_id` is the cursor for the next page."""
    q = params
    try:
        after_id = int(q["after_id"]) if q.get("after_id") else None
        if after_id is not None and after_id < 0:
            raise ValueError("after_id")
        since = _since(q.get("since"))
        kinds = [k.strip().lower() for k in (q.get("kind") or "").split(",") if k.strip()]
        if any(k not in CHANGE_KINDS for k in kinds):
            raise ValueError("kind")
        fmt = (q.get("format") or "json").strip().lower()
        if fmt not in ("json", "csv"):
            raise ValueError("format")
        limit, _ = _paging(q)
    except (ValueError, KeyError) as exc:
        return _err(422, "invalid", f"invalid parameter: {exc}")
    sel = db.table(CHANGES_VIEW).select(",".join(CHANGE_COLUMNS))
    if after_id is not None:
        sel = sel.gt("change_id", after_id)
    if since:
        sel = sel.gte("detected_at", since)
    if kinds:
        sel = sel.in_("kind", kinds)
    try:
        rows = sel.order("change_id").limit(limit).execute().data or []
    except Exception as exc:  # noqa: BLE001 - surfaced as a 502 with the class only
        return _err(502, "upstream_error", type(exc).__name__)
    if fmt == "csv":
        return _csv(rows, CHANGE_COLUMNS, "tm_changes.csv")
    nxt = rows[-1]["change_id"] if len(rows) == limit else None
    return {"count": len(rows), "next_after_id": nxt, "changes": rows}
