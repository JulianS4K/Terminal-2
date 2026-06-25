"""Tests for the shared broker HTTP transport (broker_http.py).

Locks in the unified retry/backoff + Vault-secret helpers that every
read-only ``*_client.py`` now routes through, including the call-shape
contract the existing client tests rely on (extra kwargs pass straight to the
getter; no spurious ``headers=None``). No real HTTP or real sleeping.
"""
from __future__ import annotations

import pytest

import broker_http


# ---------- vault_secret ----------

class _Rpc:
    def __init__(self, data):
        self._data = data

    def execute(self):
        return type("R", (), {"data": self._data})()


class _DB:
    def __init__(self, data=None, raises=False):
        self._data = data
        self._raises = raises
        self.calls = []

    def rpc(self, name, params):
        self.calls.append((name, params))
        if self._raises:
            raise RuntimeError("boom")
        return _Rpc(self._data)


def test_vault_secret_none_db_returns_none():
    assert broker_http.vault_secret(None, "X") is None


def test_vault_secret_reads_get_app_secret():
    db = _DB(data="sekret")
    assert broker_http.vault_secret(db, "MY_KEY") == "sekret"
    assert db.calls == [("get_app_secret", {"p_name": "MY_KEY"})]


def test_vault_secret_swallows_failures_without_leaking(capsys):
    db = _DB(raises=True)
    assert broker_http.vault_secret(db, "MY_KEY", log_prefix="axs") is None
    out = capsys.readouterr().out
    assert "axs" in out and "MY_KEY" in out  # failure logged, value never present


# ---------- retry_delay ----------

class _Resp:
    def __init__(self, status, headers=None):
        self.status_code = status
        self.headers = headers or {}


def test_retry_delay_honors_numeric_retry_after():
    assert broker_http.retry_delay(_Resp(429, {"Retry-After": "7"}), 1) == 7.0


def test_retry_delay_exponential_when_no_header():
    # base 0.5 -> 0.5, 1.0, 2.0 for attempts 1, 2, 3
    assert broker_http.retry_delay(_Resp(503), 1, base=0.5) == 0.5
    assert broker_http.retry_delay(_Resp(503), 2, base=0.5) == 1.0
    assert broker_http.retry_delay(_Resp(503), 3, base=0.5) == 2.0


def test_retry_delay_caps():
    assert broker_http.retry_delay(_Resp(503), 10, base=1.0, cap=30.0) == 30.0


def test_retry_delay_ignores_nonnumeric_retry_after():
    # "Mon, 01 Jan ..." style headers fall back to exponential
    assert broker_http.retry_delay(_Resp(429, {"Retry-After": "soon"}), 1, base=0.5) == 0.5


def test_retry_delay_jitter_adds_subsecond():
    base = broker_http.retry_delay(_Resp(503), 1, base=0.5, jitter=False)
    jit = broker_http.retry_delay(_Resp(503), 1, base=0.5, jitter=True)
    assert base == 0.5
    assert 0.5 <= jit < 1.5


# ---------- get_with_retry ----------

class _FakeGetter:
    """Returns the queued responses in order; records every call's kwargs."""
    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []

    def __call__(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return self._responses.pop(0)


@pytest.fixture(autouse=True)
def _no_sleep(monkeypatch):
    monkeypatch.setattr(broker_http.time, "sleep", lambda _s: None)


def test_returns_first_response_when_not_retryable():
    g = _FakeGetter([_Resp(200)])
    r = broker_http.get_with_retry("http://x", getter=g, timeout=5)
    assert r.status_code == 200
    assert len(g.calls) == 1


def test_retries_then_succeeds():
    g = _FakeGetter([_Resp(503), _Resp(503), _Resp(200)])
    r = broker_http.get_with_retry("http://x", getter=g, timeout=5)
    assert r.status_code == 200
    assert len(g.calls) == 3


def test_stops_at_max_attempts_and_returns_last():
    g = _FakeGetter([_Resp(503)] * 9)
    r = broker_http.get_with_retry("http://x", getter=g, timeout=5, max_attempts=4)
    assert r.status_code == 503
    assert len(g.calls) == 4  # 1 initial + 3 retries


def test_does_not_retry_status_outside_set():
    # 401 (scope-denied on SeatGeek) must never be retried.
    g = _FakeGetter([_Resp(401), _Resp(200)])
    r = broker_http.get_with_retry("http://x", getter=g, timeout=5)
    assert r.status_code == 401
    assert len(g.calls) == 1


def test_kwargs_pass_through_to_getter_with_timeout():
    g = _FakeGetter([_Resp(200)])
    broker_http.get_with_retry("http://x", getter=g, timeout=9, params={"a": 1},
                               headers={"H": "v"})
    url, kwargs = g.calls[0]
    assert url == "http://x"
    assert kwargs == {"timeout": 9, "params": {"a": 1}, "headers": {"H": "v"}}


def test_default_getter_is_requests_get(monkeypatch):
    # No getter -> resolves requests.get at call time (so a monkeypatch of
    # requests.get, as the ticketsdata test does, is honored).
    captured = {}

    def fake_get(url, **kwargs):
        captured["url"] = url
        captured["kwargs"] = kwargs
        return _Resp(200)

    monkeypatch.setattr(broker_http.requests, "get", fake_get)
    broker_http.get_with_retry("http://y", timeout=3, params={"q": 1})
    assert captured["url"] == "http://y"
    assert captured["kwargs"] == {"timeout": 3, "params": {"q": 1}}
