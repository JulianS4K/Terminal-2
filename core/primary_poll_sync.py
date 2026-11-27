"""Poll the primary box offices we read ourselves and store their events and listings
(operator 2026-11-23: "we're gonna push the list of events and their respective listings out, if
poller fails to run for an event, do not send listing information").

One run, per source (sitickets, timberwolves, ims):
  1. read the source's list of events. If that fails, `primary_poll_source_failed()` marks every
     upcoming event of the source failed and deletes its listings.
  2. ask `primary_poll_due()` which of the listed events are due: each event has its own cadence,
     by its date, its median price and the tickets listed (operator 2026-11-23: "create update cadances
     based on event date and median price", "also adjust cadance based on a qty listed", "Let's set
     longest interval to 1 hour"), and a random slot inside it ("Redraw every cycle, just poll the
     data. For events day of draw every 10 mins"): every 10 minutes on the day of the event, every 30
     minutes or every hour before. The worker wakes every 10 minutes. For each event that is due,
     read its listings and send the event to `primary_poll_ingest()`, one event a
     call: with its listings when the read worked, or with ok = false and the reason when it did
     not, which deletes that event's stored listings.
  3. `primary_poll_run_done()` with the ids the source listed: from then on the feeds serve the
     events of this pull only (operator 2026-11-23: "for the api only push out newest pull").

The feed (routers/primary_poll_feed.py) sends listings only for an event whose last poll succeeded
within the feed's age limit (35 minutes after a good read, or until 20 minutes after the event's next slot,
whichever is later: migs 20261123190030, 20261123194030), so a run that never happens withholds them too. Mig 20261123171030.

This module makes no upstream call itself (RULE 2): the GETs are in sitickets_client.py,
jump_client.py and ims_client.py.
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
    done = {"events": len(events), "ok": 0, "failed": 0, "listings": 0, "not_stored": 0, "skipped": 0}
    ids = [str(event["id"]) for event in events]
    # each event has its own cadence, by its date, its median price and the tickets listed (mig 20261123194030): only the ones
    # that are due are read. Not knowing what is due, everything is read: fresher than needed is safe.
    try:
        asked = rpc("primary_poll_due", {"p_source": source, "p_event_ids": ids})
    except Exception:  # noqa: BLE001
        asked = None
    due = set(asked) if isinstance(asked, list) else set(ids)
    for event in events:
        if str(event["id"]) not in due:
            done["skipped"] += 1
            continue
        try:
            listings, error = read_listings(event), None
        except Exception as exc:  # noqa: BLE001 - this event's poll failed; the others go on
            listings, error = [], _why(exc)
        # built after the read: reading an event's listings may fill the event's own fields (its order limits)
        row = {**_public(event), "listings": listings, "ok": error is None}
        if error:
            row["error"] = error
        try:
            rpc("primary_poll_ingest", {"p_source": source, "p_events": [row]})
        except Exception:  # noqa: BLE001 - not stored: the feed's age limit withholds its listings
            done["not_stored"] += 1
            continue
        done["ok" if row["ok"] else "failed"] += 1
        done["listings"] += len(row["listings"])
    try:
        rpc("primary_poll_run_done", {"p_source": source, "p_run": uuid.uuid4().hex, "p_event_ids": ids})
    except Exception as exc:  # noqa: BLE001 - the feeds keep the previous pull; its listings age out
        done["run_not_closed"] = _why(exc)
    return done


SOURCES = ("sitickets", "timberwolves", "ims")


def sources_from(text: str | None) -> tuple[str, ...]:
    """The sources a worker polls, from PRIMARY_POLL_SOURCES ("sitickets,timberwolves"); all of them
    when it is not set. An unknown name is an error: a typo must not silently poll nothing."""
    names = tuple(n.strip().lower() for n in (text or "").split(",") if n.strip()) or SOURCES
    unknown = [n for n in names if n not in SOURCES]
    if unknown:
        raise ValueError(f"unknown primary poll source: {unknown[0]}")
    return names


def run(rpc: Rpc, sitickets: Any, jump: Any, sources: tuple[str, ...] | None = None, ims: Any = None) -> dict:
    """One run over the sources asked for (all the ones it was given a client for, when none is named);
    returns what it did, per source. Each source has ONE poller: where the browser worker
    (core/primary_poll_browser.py) reads the Timberwolves, this worker must not be given `timberwolves`,
    or the two would overwrite each other every cycle. `ims` is the Indy 500's section prices (operator
    2026-11-24: "build the indy 500 section price poller"): one event, read from two public pages."""
    readers = {
        "sitickets": (sitickets.all_events, sitickets.listings),
        "timberwolves": (lambda: jump.events("timberwolves"), lambda event: jump.listings("timberwolves", event)),
    }
    if ims is not None:
        readers["ims"] = (ims.events, ims.listings)
    return {source: poll_source(rpc, source, *readers[source]) for source in sources or tuple(readers)}
