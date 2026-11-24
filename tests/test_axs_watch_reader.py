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
                          "(Caused by NewConnectionError('x')); also password=hunter2 and USERNAME=ops elsewhere")
    reader.read_one(_TD({"u": exc}), _rpc({}, lambda p: {"outcome": "timeout"}, log), {"id": "1", "url": "u"})
    msg = log[-1][1]["p_error_msg"]
    assert msg.startswith("ConnectionError: HTTPSConnectionPool(host='ticketsdata.com', port=443): Max retries exceeded with url: /fetch?<redacted> ")
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
    assert log[0] == ("axs_watch_next", {"p_limit": 20})
    assert [p["p_event_id"] for n, p in log if n == "axs_watch_record"] == ["21", "22", "23"]


def test_run_does_not_sleep_when_the_read_outlasted_the_spacing_and_takes_the_spacing_given():
    log, slept, now = [], [], {"t": 0.0}

    def recorded(params):
        now["t"] += 10.0                                    # a slow read: longer than the spacing
        return {"outcome": "ok", "listings": 1}

    asked = {"events": [{"id": "1", "url": "a"}, {"id": "2", "url": "a"}], "spacing_ms": 3000}
    out = reader.run(_TD({"a": BODY}), _rpc(asked, recorded, log), spacing_s=1.5, batch=5,
                     sleep=lambda s: slept.append(s), clock=lambda: now["t"])
    assert slept == [] and out["ok"] == 2 and out["listings"] == 2
    assert log[0] == ("axs_watch_next", {"p_limit": 5})


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
