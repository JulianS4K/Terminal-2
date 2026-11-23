"""Poll the primary box offices we read ourselves and store their events and listings
(operator 2026-11-23: "we're gonna push the list of events and their respective listings out, if
poller fails to run for an event, do not send listing information").

One run, per source (sitickets, timberwolves):
  1. read the source's list of events. If that fails, `primary_poll_source_failed()` marks every
     upcoming event of the source failed and deletes its listings.
  2. for each event, read its listings and send the event to `primary_poll_ingest()`, one event a
     call: with its listings when the read worked, or with ok = false and the reason when it did
     not, which deletes that event's stored listings.
  3. `primary_poll_run_done()` with the ids the source listed: from then on the feeds serve the
     events of this pull only (operator 2026-11-23: "for the api only push out newest pull").

The feed (routers/primary_poll_feed.py) sends listings only for an event whose last poll succeeded
within 15 minutes, so a run that never happens withholds them too. Mig 20261123171030.

This module makes no upstream call itself (RULE 2): the GETs are in sitickets_client.py and
jump_client.py.
"""
from __future__ import annotations

import uuid
from typing import Any, Callable

Rpc = Callable[[str, dict], Any]
ERROR_MAX = 200


def _why(exc: BaseException) -> str:
    return f"{type(exc).__name__}: {exc}"[:ERROR_MAX]


def _public(event: dict) -> dict:
    """The event as the database takes it: without the client's own keys (the ones with a _)."""
    return {k: v for k, v in event.items() if not k.startswith("_")}


def poll_source(rpc: Rpc, source: str, list_events: Callable[[], list], read_listings: Callable[[dict], list]) -> dict:
    try:
        events = list_events()
    except Exception as exc:  # noqa: BLE001 - any failure to list means no event was polled
        marked = rpc("primary_poll_source_failed", {"p_source": source, "p_error": _why(exc)})
        return {"events": 0, "ok": 0, "failed": 0, "listings": 0, "list_error": _why(exc), "marked_failed": marked}
    done = {"events": len(events), "ok": 0, "failed": 0, "listings": 0, "not_stored": 0}
    for event in events:
        row = _public(event)
        try:
            row["listings"] = read_listings(event)
            row["ok"] = True
        except Exception as exc:  # noqa: BLE001 - this event's poll failed; the others go on
            row["listings"], row["ok"], row["error"] = [], False, _why(exc)
        try:
            rpc("primary_poll_ingest", {"p_source": source, "p_events": [row]})
        except Exception:  # noqa: BLE001 - not stored: the feed's age limit withholds its listings
            done["not_stored"] += 1
            continue
        done["ok" if row["ok"] else "failed"] += 1
        done["listings"] += len(row["listings"])
    try:
        rpc("primary_poll_run_done", {"p_source": source, "p_run": uuid.uuid4().hex,
                                      "p_event_ids": [str(event["id"]) for event in events]})
    except Exception as exc:  # noqa: BLE001 - the feeds keep the previous pull; its listings age out
        done["run_not_closed"] = _why(exc)
    return done


def run(rpc: Rpc, sitickets: Any, jump: Any) -> dict:
    """One run over every source; returns what it did, per source."""
    return {
        "sitickets": poll_source(rpc, "sitickets", sitickets.events, sitickets.listings),
        "timberwolves": poll_source(rpc, "timberwolves", lambda: jump.events("timberwolves"),
                                    lambda event: jump.listings("timberwolves", event)),
    }
