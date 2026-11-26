"""Read the AXS watch's events through TicketsData, one at a time, from a worker (operator
2026-11-24: "build the worker-side reader").

The database-side cascade (axs_watch_tick, mig 20261124190000) fires its reads through pg_net, whose
worker sends the outbound queue in batches: a read waits a minute or more in the queue behind the
other jobs' calls, and two AXS reads in one batch reach TicketsData together, which refuses the
second ("Please wait at least 3 seconds between AXS requests"). Held to one in flight, the cascade
managed about one read a minute. This worker reads sequentially, `spacing` seconds apart (3 s, the
rule), about eight a minute: a full pass over the 200 events in 25 minutes.

What to read and what a read means stay in the database (mig 20261125000000), so both readers behave
the same:
  axs_watch_next(limit)   the events due now, most overdue first, within the day's credit cap, hot
                          only over it; empty unless `axs_watch_config.reader = 'worker'`; a `hold_s`
                          while TicketsData is failing.
  axs_watch_record(...)   one read's result: TicketsData's JSON, or the HTTP status it answered, or the
                          transport error. The database parses it, ingests the event with its listings
                          (or its failure), charges the credit and writes the ledger row.

One read is `GET /fetch?platform=axs&event_url=...` (ticketsdata_client.py, GET only; RULE 2). The
client itself retries a 429, 503 or 504 once or twice with a pause, so a refusal reaching this module
is one that outlasted that.

Runs inside the web service (server.py) when AXS_WATCH_READER_LIVE=1:

    AXS_WATCH_READER_LIVE=1                 on
    AXS_WATCH_READER_INTERVAL_SECONDS=15    the pause when nothing is due (the tick's own cadence)
"""
from __future__ import annotations

import os
import re
import socket
import time
from datetime import datetime, timezone
from typing import Any, Callable

Rpc = Callable[[str, dict], Any]
ERROR_MAX = 200
DEFAULT_SPACING_S = 3.0
DEFAULT_BATCH = 20
_HTTP_STATUS = re.compile(r"HTTP (\d{3})")
# this worker's name for the database's lease (mig 20261125020000): one worker reads at a time, so the two
# instances a deploy runs side by side do not both read (and draw TicketsData's three-second 429)
WORKER_ID = f"{socket.gethostname()}:{os.getpid()}"
# a transport error names the URL it was sent to, and TicketsData takes the login in the query string: the query is
# never recorded, and a username= / password= value is masked wherever else it appears
_QUERY = re.compile(r"\?[^\s)'\"]*")
_LOGIN = re.compile(r"(username|password)=[^&\s)'\"]*", re.IGNORECASE)


def _why(exc: BaseException) -> str:
    text = _LOGIN.sub(r"\1=<redacted>", _QUERY.sub("?<redacted>", str(exc)))
    return f"{type(exc).__name__}: {text}"[:ERROR_MAX]


def read_one(td: Any, rpc: Rpc, event: dict) -> dict:
    """One event read through TicketsData and recorded. Returns what the database made of it
    (outcome, error, listings, request_id)."""
    fired_at = datetime.now(timezone.utc).isoformat()
    params: dict[str, Any] = {"p_event_id": str(event["id"]), "p_fired_at": fired_at,
                              "p_status_code": None, "p_content": None, "p_timed_out": False, "p_error_msg": None}
    try:
        params["p_content"], params["p_status_code"] = td.fetch("axs", event["url"]), 200
    except Exception as exc:  # noqa: BLE001 - every failure is this event's failed poll, recorded as such
        status = _HTTP_STATUS.search(str(exc))
        if status:
            params["p_status_code"] = int(status.group(1))   # TicketsData answered: the database classifies the status
        else:
            params["p_timed_out"], params["p_error_msg"] = True, _why(exc)   # no answer: a timeout
    return rpc("axs_watch_record", params)


def run(td: Any, rpc: Rpc, *, spacing_s: float | None = None, batch: int = DEFAULT_BATCH,
        idle_s: float = 15.0, worker: str | None = None, sleep: Callable[[float], None] = time.sleep,
        clock: Callable[[], float] = time.monotonic) -> dict:
    """One batch: ask the database what to read (naming this worker, so only one reads at a time),
    read each `spacing_s` apart (the database's `spacing_ms` unless given), record each. Returns what
    was done and `pause_s`, how long the caller should wait before the next batch: the database's hold
    (the upstream failing, or another worker's lease), `idle_s` when nothing was due, nothing when
    there was work (the next batch follows at once)."""
    asked = rpc("axs_watch_next", {"p_limit": batch, "p_worker": worker or WORKER_ID}) or {}
    events = asked.get("events") or []
    spacing = spacing_s if spacing_s is not None else float(asked.get("spacing_ms") or DEFAULT_SPACING_S * 1000) / 1000.0
    done = {"asked": len(events), "ok": 0, "failed": 0, "listings": 0, "reason": asked.get("reason"),
            "hold_s": asked.get("hold_s"), "daily_cap": asked.get("daily_cap"), "fired_today": asked.get("fired_today")}
    last: float | None = None
    for event in events:
        if last is not None:
            wait = spacing - (clock() - last)
            if wait > 0:
                sleep(wait)
        last = clock()
        got = read_one(td, rpc, event)
        if got.get("outcome") in ("ok", "empty"):
            done["ok"] += 1
            done["listings"] += int(got.get("listings") or 0)
        else:
            done["failed"] += 1
    done["pause_s"] = float(asked.get("hold_s") or 0) or (idle_s if not events else 0.0)
    return done


# ── the queue path (mig 20261126030000) ──────────────────────────────────────────────────────
# The database holds a real work queue instead of recomputing a due list on every call:
#   axs_queue_claim(worker, limit)   up to `queue_lanes` items, each with a release_at — the
#                                    pacer's slot. The slots are allocated 3 s apart in ONE
#                                    serialised place, so several reader processes cannot
#                                    together break TicketsData's rule the way per-process
#                                    spacing would.
#   axs_queue_ack(queue_id, ...)     resolves the item AND settles the read (ingest, band,
#                                    credit). Acking twice is harmless and charges once, so a
#                                    worker that loses an answer may simply send it again.
# At most one unresolved item exists per event, enforced by a unique partial index rather than
# by a check in the caller — which is the whole reason for the queue: a scheduling bug then
# costs nothing instead of three quarters of the budget (mig 20261126023000 cost 76%).
def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _seconds_until(when: Any, now: Callable[[], datetime] = _utcnow) -> float:
    """How long to wait for a release_at the database handed us. Anything unparseable means
    'no wait' — the database already serialised the slot, so a bad string must not stall the
    worker, and the 3-second floor is re-applied by the next claim anyway."""
    if not when:
        return 0.0
    try:
        at = when if isinstance(when, datetime) else datetime.fromisoformat(str(when).replace("Z", "+00:00"))
    except ValueError:
        return 0.0
    if at.tzinfo is None:
        at = at.replace(tzinfo=timezone.utc)
    return max(0.0, (at - now()).total_seconds())


def read_one_queued(td: Any, rpc: Rpc, item: dict) -> dict:
    """One queued event read through TicketsData and acked. Returns what the database made of it."""
    params: dict[str, Any] = {"p_queue_id": item["queue_id"], "p_status_code": None, "p_content": None,
                              "p_timed_out": False, "p_error_msg": None}
    try:
        params["p_content"], params["p_status_code"] = td.fetch("axs", item["url"]), 200
    except Exception as exc:  # noqa: BLE001 - every failure is this event's failed poll, recorded as such
        status = _HTTP_STATUS.search(str(exc))
        if status:
            params["p_status_code"] = int(status.group(1))   # TicketsData answered: the database classifies it
        else:
            params["p_timed_out"], params["p_error_msg"] = True, _why(exc)   # no answer: a timeout
    return rpc("axs_queue_ack", params)


def run_queue(td: Any, rpc: Rpc, *, batch: int | None = None, idle_s: float = 15.0,
              worker: str | None = None, sleep: Callable[[float], None] = time.sleep,
              now: Callable[[], datetime] = _utcnow) -> dict:
    """One pass over the queue: claim, wait for each item's release_at, read, ack.

    Returns what was done and `pause_s`, how long the caller should wait before claiming again:
    the database's hold (the upstream failing, every lane busy, the queue switched off), `idle_s`
    when the queue was empty, nothing when there was work."""
    asked = rpc("axs_queue_claim", {"p_worker": worker or WORKER_ID, "p_limit": batch}) or {}
    items = asked.get("items") or []
    done = {"claimed": len(items), "ok": 0, "failed": 0, "listings": 0, "reason": asked.get("reason"),
            "hold_s": asked.get("hold_s"), "lanes": asked.get("lanes"), "in_flight": asked.get("in_flight"),
            "daily_cap": asked.get("daily_cap"), "fired_today": asked.get("fired_today"),
            "depth": asked.get("depth")}
    for item in items:
        wait = _seconds_until(item.get("release_at"), now)
        if wait > 0:
            sleep(wait)            # the pacer's slot: never send before it
        got = read_one_queued(td, rpc, item) or {}
        if got.get("outcome") in ("ok", "empty"):
            done["ok"] += 1
            done["listings"] += int(got.get("listings") or 0)
        else:
            done["failed"] += 1
    done["pause_s"] = float(asked.get("hold_s") or 0) or (idle_s if not items else 0.0)
    return done
