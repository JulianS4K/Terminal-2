"""The same event's id on every marketplace, added to each event feed the sub finder API serves.

Operator 2026-11-22: "include the cross maps in all event mapping you push out, marketplace id".

Every event row of /tm/events, /axs/events, /seatgeek/events, /mlb/events and /mlb/schedule carries
the ids we hold for that event on the other sites. They are read for one page of rows at a time
from `feed_market_ids(p_source, p_ids)` (mig 20261122035530), which reads the hub (aq_event_map),
the cross-map (event_xmap) and, for Vivid Seats and TickPick, those sites' catalogues, in the order
GET /tm/markets reads them. A null means we hold no pairing with that site, not that the site does
not list the event.

    xmap_tevo_event_id      the EVO event: the feed's own match, else the cross-map's
    ticketmaster_event_id   seatgeek_event_id   stubhub_event_id   vivid_event_id
    tickpick_event_id       gotickets_event_id  axs_event_id       aq_short_event_id (Automatiq)

Reads our own tables only: no upstream call (RULE 2).
"""
from __future__ import annotations

from typing import Any

RPC = "feed_market_ids"
ALL = ("xmap_tevo_event_id", "ticketmaster_event_id", "seatgeek_event_id", "stubhub_event_id", "vivid_event_id",
       "tickpick_event_id", "gotickets_event_id", "axs_event_id", "aq_short_event_id")


def columns(*own: str) -> tuple:
    """The marketplace id columns a feed adds: all of them but the ones it already serves."""
    return tuple(c for c in ALL if c not in own)


def add(db: Any, rows: list, source: str, id_column: str, cols: tuple) -> list:
    """`rows` with `cols` added to each, read in one call for the whole page. `source` names the
    feed's own id (`ticketmaster`, `axs`, `seatgeek` or `tevo`) and `id_column` the row key that
    holds it. A row with no id, or an id we hold no pairing for, gets nulls. Raises what the
    database call raises: the caller answers 502."""
    ids = sorted({str(r[id_column]) for r in rows if r.get(id_column) is not None})
    found: dict = {}
    if ids:
        data = db.rpc(RPC, {"p_source": source, "p_ids": ids}).execute().data or []
        found = {str(d.get("source_id")): d for d in data}
    return [{**r, **{c: found.get(str(r.get(id_column)), {}).get(c) for c in cols}} for r in rows]
