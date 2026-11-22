"""The same event's id on every marketplace, added to each event feed the sub finder API serves.

Operator 2026-11-22: "include the cross maps in all event mapping you push out, marketplace id".

Every event row of /tm/events, /axs/events, /seatgeek/events, /mlb/events and /mlb/schedule carries
the ids we hold for that event on the other sites. They are read for one page of rows, 500 ids a call,
from `feed_market_ids(p_source, p_ids)` (migs 20261122035530, 20261122210530), which reads the hub (aq_event_map),
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
CHUNK = 500   # ids a call: a 5,000-id call ran past the 8-second statement limit on a first read (2026-11-22)
ALL = ("xmap_tevo_event_id", "ticketmaster_event_id", "seatgeek_event_id", "stubhub_event_id", "vivid_event_id",
       "tickpick_event_id", "gotickets_event_id", "axs_event_id", "aq_short_event_id")


def columns(*own: str) -> tuple:
    """The marketplace id columns a feed adds: all of them but the ones it already serves."""
    return tuple(c for c in ALL if c not in own)


def _ask(db: Any, source: str, ids: list) -> list:
    """One chunk's pairings. A failed read is sent once more: it only reads, and the first try
    leaves the data in memory, so the second is quick."""
    for last in (False, True):
        try:
            return db.rpc(RPC, {"p_source": source, "p_ids": ids}).execute().data or []
        except Exception:  # noqa: BLE001 - whatever it was, the second failure is the caller's to answer
            if last:
                raise
    return []  # pragma: no cover - the loop returns or raises


def add(db: Any, rows: list, source: str, id_column: str, cols: tuple) -> list:
    """`rows` with `cols` added to each. `source` names the feed's own id (`ticketmaster`, `axs`,
    `seatgeek` or `tevo`) and `id_column` the row key that holds it. The ids of the page are asked
    for CHUNK at a time, so no single read comes near the database API's time limit. A row with no
    id, or an id we hold no pairing for, gets nulls. Raises what the database call raises on its
    second failure: the caller answers 502."""
    ids = sorted({str(r[id_column]) for r in rows if r.get(id_column) is not None})
    found: dict = {}
    for start in range(0, len(ids), CHUNK):
        for d in _ask(db, source, ids[start:start + CHUNK]):
            found[str(d.get("source_id"))] = d
    return [{**r, **{c: found.get(str(r.get(id_column)), {}).get(c) for c in cols}} for r in rows]
