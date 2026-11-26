"""The AXS watch's worker-side reader (core/axs_watch_reader.py; operator 2026-11-24: "build the
worker-side reader"): one read through TicketsData recorded as the database classifies it, the batch
spaced 3 s apart, the hold while the upstream fails, the pause when nothing is due."""
from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core import axs_watch_reader as reader  # noqa: E402


class _TD:
    """A TicketsData client that answers per event URL: a body, or raises."""

    def __init__(self, answers):
        self.answers, self.calls = answers, []

    def fetch(self, platform, url):
        self.calls.append((platform, url))
        answer = self.answers[url]
        if isinstance(answer, Exception):
            raise answer
        return answer


def _rpc(asked, recorded, log):
    def call(name, params):
        log.append((name, params))
        if name == "axs_watch_next":
            return asked
        assert name == "axs_watch_record"
        return recorded(params)
    return call


BODY = {"status": "ok", "quota_remaining": 249000, "response_s": 8.1, "body": {"event": {"id": "1"}, "listings": []}}


def test_read_one_records_the_body_the_status_or_the_transport_error():
    log = []
    td = _TD({"u1": BODY, "u2": RuntimeError("HTTP 429 on GET /fetch"), "u3": TimeoutError("read timed out")})
    rpc = _rpc({}, lambda p: {"outcome": "ok", "listings": 3, "request_id": 1000000000000}, log)

    got = reader.read_one(td, rpc, {"id": 11, "url": "u1"})
    assert got["outcome"] == "ok" and td.calls == [("axs", "u1")]
    name, params = log[-1]
    assert name == "axs_watch_record" and params["p_event_id"] == "11" and params["p_status_code"] == 200
    assert params["p_content"] == BODY and params["p_timed_out"] is False and params["p_error_msg"] is None
    assert params["p_fired_at"].endswith("+00:00")

    reader.read_one(td, rpc, {"id": "12", "url": "u2"})           # TicketsData answered 429: the database classifies it
    params = log[-1][1]
    assert params["p_status_code"] == 429 and params["p_content"] is None and params["p_timed_out"] is False

    reader.read_one(td, rpc, {"id": "13", "url": "u3"})           # no answer: a timeout, with the reason
    params = log[-1][1]
    assert params["p_status_code"] is None and params["p_timed_out"] is True
    assert params["p_error_msg"] == "TimeoutError: read timed out"


def test_read_one_never_records_the_login_a_transport_error_carries():
    log = []
    exc = ConnectionError("HTTPSConnectionPool(host='ticketsdata.com', port=443): Max retries exceeded with url: "
                          "/fetch?platform=axs&event_url=https%3A%2F%2Fwww.axs.com%2Fe%2F1&username=ops%40s4k.example&password=hunter2 "
                          "(x); also password=hunter2 and USERNAME=ops")
    reader.read_one(_TD({"u": exc}), _rpc({}, lambda p: {"outcome": "timeout"}, log), {"id": "1", "url": "u"})
    msg = log[-1][1]["p_error_msg"]
    assert msg.startswith("ConnectionError: HTTPSConnectionPool(host='ticketsdata.com', port=443): Max retries exceeded with url: /fetch?<redacted> (x)")
    assert "hunter2" not in msg and "ops" not in msg and "password=<redacted>" in msg and "USERNAME=<redacted>" in msg
    assert len(msg) <= reader.ERROR_MAX


def test_run_reads_the_batch_spaced_apart_and_counts_what_the_database_made_of_each():
    log, slept, now = [], [], {"t": 100.0}

    def clock():
        return now["t"]

    def sleep(s):
        slept.append(round(s, 2))
        now["t"] += s

    outcomes = {"21": {"outcome": "ok", "listings": 5}, "22": {"outcome": "upstream_error", "error": "HTTP 429 from TicketsData"},
                "23": {"outcome": "empty", "listings": 0}}
    asked = {"events": [{"id": "21", "url": "a"}, {"id": "22", "url": "b"}, {"id": "23", "url": "c"}],
             "spacing_ms": 3000, "daily_cap": 10180, "fired_today": 12}
    td = _TD({"a": BODY, "b": RuntimeError("HTTP 429 on GET /fetch"), "c": BODY})

    def recorded(params):
        now["t"] += 1.0                                     # each read takes a second
        return outcomes[params["p_event_id"]]

    out = reader.run(td, _rpc(asked, recorded, log), sleep=sleep, clock=clock)
    assert out == {"asked": 3, "ok": 2, "failed": 1, "listings": 5, "reason": None, "hold_s": None,
                   "daily_cap": 10180, "fired_today": 12, "pause_s": 0.0}
    assert slept == [2.0, 2.0]                              # 3 s between the starts of two reads, a second of it spent reading
    assert log[0] == ("axs_watch_next", {"p_limit": 20, "p_worker": reader.WORKER_ID})
    assert reader.WORKER_ID.endswith(":%d" % __import__("os").getpid()) and ":" in reader.WORKER_ID
    assert [p["p_event_id"] for n, p in log if n == "axs_watch_record"] == ["21", "22", "23"]


def test_run_does_not_sleep_when_the_read_outlasted_the_spacing_and_takes_the_spacing_given():
    log, slept, now = [], [], {"t": 0.0}

    def recorded(params):
        now["t"] += 10.0                                    # a slow read: longer than the spacing
        return {"outcome": "ok", "listings": 1}

    asked = {"events": [{"id": "1", "url": "a"}, {"id": "2", "url": "a"}], "spacing_ms": 3000}
    out = reader.run(_TD({"a": BODY}), _rpc(asked, recorded, log), spacing_s=1.5, batch=5, worker="web-1:7",
                     sleep=lambda s: slept.append(s), clock=lambda: now["t"])
    assert slept == [] and out["ok"] == 2 and out["listings"] == 2
    assert log[0] == ("axs_watch_next", {"p_limit": 5, "p_worker": "web-1:7"})


def test_run_idles_when_nothing_is_due_and_holds_while_the_upstream_fails():
    log = []
    out = reader.run(_TD({}), _rpc({"events": [], "reason": "the database reads (axs_watch_config.reader)"}, None, log),
                     idle_s=15.0, sleep=lambda s: None, clock=lambda: 0.0)
    assert out["asked"] == 0 and out["pause_s"] == 15.0 and out["reason"].startswith("the database reads")

    out = reader.run(_TD({}), _rpc({"events": [], "hold_s": 60, "upstream_errors": 3}, None, log),
                     sleep=lambda s: None, clock=lambda: 0.0)
    assert out["hold_s"] == 60 and out["pause_s"] == 60.0

    out = reader.run(_TD({}), _rpc(None, None, log), sleep=lambda s: None, clock=lambda: 0.0)   # nothing answered at all
    assert out["asked"] == 0 and out["pause_s"] == 15.0

    held = {"events": [], "hold_s": 10, "reason": "another worker holds the lease", "lease_holder": "web-0:3"}
    out = reader.run(_TD({}), _rpc(held, None, log), sleep=lambda s: None, clock=lambda: 0.0)    # the other instance at a deploy
    assert out["asked"] == 0 and out["pause_s"] == 10.0 and out["reason"] == "another worker holds the lease"


# ── the queue path (mig 20261126030000) ──────────────────────────────────────────────────────

def _queue_rpc(claim, acked, log):
    def call(name, params):
        log.append((name, params))
        if name == "axs_queue_claim":
            return claim
        assert name == "axs_queue_ack"
        return acked(params)
    return call


def test_run_queue_waits_for_each_release_at_then_reads_and_acks():
    """The pacer's slot is honoured: the worker sleeps until release_at before sending, and acks
    by queue_id. The slots are 3 s apart because the database allocated them that way."""
    from datetime import datetime, timedelta, timezone
    base = datetime(2026, 11, 26, 3, 0, 0, tzinfo=timezone.utc)
    claim = {"items": [{"queue_id": 11, "id": "A", "url": "u/A", "every_min": 30,
                        "release_at": (base + timedelta(seconds=3)).isoformat()},
                       {"queue_id": 12, "id": "B", "url": "u/B", "every_min": 60,
                        "release_at": (base + timedelta(seconds=6)).isoformat()}],
             "lanes": 2, "in_flight": 2, "spacing_ms": 3000}
    td, slept, log = _TD({"u/A": BODY, "u/B": BODY}), [], []
    out = reader.run_queue(td, _queue_rpc(claim, lambda p: {"outcome": "ok", "listings": 2}, log),
                           sleep=slept.append, now=lambda: base, worker="w1")
    assert out["claimed"] == 2 and out["ok"] == 2 and out["failed"] == 0
    assert out["listings"] == 4 and out["pause_s"] == 0.0
    assert slept == [3.0, 6.0]                       # each slot waited for, from the same clock
    assert [c[1] for c in td.calls] == ["u/A", "u/B"]
    assert [p["p_queue_id"] for n, p in log if n == "axs_queue_ack"] == [11, 12]


def test_run_queue_does_not_sleep_for_a_slot_already_due():
    from datetime import datetime, timedelta, timezone
    base = datetime(2026, 11, 26, 3, 0, 0, tzinfo=timezone.utc)
    claim = {"items": [{"queue_id": 1, "id": "A", "url": "u/A",
                        "release_at": (base - timedelta(seconds=5)).isoformat()}]}
    slept = []
    reader.run_queue(_TD({"u/A": BODY}), _queue_rpc(claim, lambda p: {"outcome": "ok"}, []),
                     sleep=slept.append, now=lambda: base)
    assert slept == []


def test_run_queue_passes_the_hold_through_and_claims_nothing():
    """The queue off, every lane busy, or the upstream failing: the database says hold and the
    worker must not invent work."""
    for claim in ({"items": [], "reason": "the queue is off (axs_watch_config.queue_enabled)"},
                  {"items": [], "hold_s": 2, "reason": "all lanes busy"},
                  {"items": [], "hold_s": 60, "upstream_errors": 3}):
        td = _TD({})
        out = reader.run_queue(td, _queue_rpc(claim, lambda p: {}, []), sleep=lambda s: None, idle_s=15.0)
        assert out["claimed"] == 0 and td.calls == []
        assert out["pause_s"] == (float(claim["hold_s"]) if claim.get("hold_s") else 15.0)


def test_run_queue_records_a_transport_failure_as_a_timeout_and_an_http_status_as_itself():
    claim = {"items": [{"queue_id": 7, "id": "A", "url": "u/A"},
                       {"queue_id": 8, "id": "B", "url": "u/B"}]}
    td = _TD({"u/A": RuntimeError("connection reset by peer"),
              "u/B": RuntimeError("HTTP 503 on GET /fetch")})
    log = []
    out = reader.run_queue(td, _queue_rpc(claim, lambda p: {"outcome": "timeout"}, log), sleep=lambda s: None)
    acks = [p for n, p in log if n == "axs_queue_ack"]
    assert acks[0]["p_timed_out"] is True and acks[0]["p_status_code"] is None
    assert "connection reset" in acks[0]["p_error_msg"]
    assert acks[1]["p_status_code"] == 503 and acks[1]["p_timed_out"] is False
    assert out["failed"] == 2


def test_seconds_until_is_forgiving_about_what_the_database_hands_back():
    """A release_at that cannot be parsed must not stall the worker: the database already
    serialised the slot, and the next claim re-applies the floor."""
    from datetime import datetime, timezone
    base = datetime(2026, 11, 26, 3, 0, 0, tzinfo=timezone.utc)
    assert reader._seconds_until(None, lambda: base) == 0.0
    assert reader._seconds_until("", lambda: base) == 0.0
    assert reader._seconds_until("not a timestamp", lambda: base) == 0.0
    assert reader._seconds_until("2026-11-26T03:00:09Z", lambda: base) == 9.0        # trailing Z
    assert reader._seconds_until("2026-11-26T03:00:09", lambda: base) == 9.0         # naive, assumed UTC
    assert reader._seconds_until(base, lambda: base) == 0.0                          # a datetime straight through
