"""Coverage closure for ticketsdata_client.py — the branches the existing
tests/test_ticketsdata_client.py leaves uncovered: operator-disabled platform
guard, the Vault-lookup exception path, from_env/from_vault constructors, the
_get retry/backoff matrix + non-ok/auth/quota/JSON-fallback branches, and the
per-endpoint required-arg validators. No real HTTP — requests is monkeypatched.
"""
from __future__ import annotations

import pytest

import ticketsdata_client as td


class _FakeResp:
    def __init__(self, status_code=200, *, json_data=None, text="", headers=None, raise_json=False):
        self.status_code = status_code
        self.ok = 200 <= status_code < 400
        self._json = json_data if json_data is not None else {}
        self.text = text
        self.headers = headers or {}
        self._raise_json = raise_json

    def json(self):
        if self._raise_json:
            raise ValueError("no json")
        return self._json


def _client():
    return td.TicketsDataClient(username="u@example.com", password="pw")


# ---------- _validate_platform: operator-disabled (lines 102-104) ----------

def test_operator_disabled_platform_raises():
    with pytest.raises(td.TicketsDataError, match="operator-disabled"):
        td._validate_platform("dice")
    with pytest.raises(td.TicketsDataError, match="operator-disabled"):
        td._validate_platform("eventbrite")


# ---------- _vault_secret exception path (lines 116-118) ----------

def test_vault_secret_swallows_exception(capsys):
    class _BoomDB:
        def rpc(self, *a, **k):
            raise RuntimeError("vault unreachable")
    assert td._vault_secret(_BoomDB(), "TICKETSDATA_USERNAME") is None
    out = capsys.readouterr().out
    assert "vault lookup" in out and "vault unreachable" in out
    # the secret name is named but never the value
    assert "TICKETSDATA_USERNAME" in out


# ---------- from_env / from_vault constructors (lines 150, 156) ----------

def test_from_env_reads_environment(monkeypatch):
    monkeypatch.setenv("TICKETSDATA_USERNAME", "env-user@example.com")
    monkeypatch.setenv("TICKETSDATA_PASSWORD", "env-pw")
    c = td.TicketsDataClient.from_env(timeout=12)
    assert c._username == "env-user@example.com"
    assert c.timeout == 12


def test_from_vault_resolves_from_db(monkeypatch):
    monkeypatch.delenv("TICKETSDATA_USERNAME", raising=False)
    monkeypatch.delenv("TICKETSDATA_PASSWORD", raising=False)

    class _Res:
        def __init__(self, data):
            self.data = data

    class _VaultDB:
        def __init__(self):
            self._name = None
            self._secrets = {
                "TICKETSDATA_USERNAME": "vault-user@example.com",
                "TICKETSDATA_PASSWORD": "vault-pw",
            }
        def rpc(self, name, params):
            self._name = params["p_name"]
            return self
        def execute(self):
            return _Res(self._secrets.get(self._name))

    c = td.TicketsDataClient.from_vault(_VaultDB())
    assert c._username == "vault-user@example.com"


# ---------- _get retry/backoff matrix (lines 174-181) ----------

def _seq_get(monkeypatch, responses):
    calls = {"n": 0}
    def _get(url, params=None, timeout=None):
        r = responses[min(calls["n"], len(responses) - 1)]
        calls["n"] += 1
        return r
    monkeypatch.setattr(td.requests, "get", _get)
    monkeypatch.setattr(td.time, "sleep", lambda *_: None)
    return calls


def test_get_retries_503_then_succeeds(monkeypatch):
    calls = _seq_get(monkeypatch, [
        _FakeResp(503),
        _FakeResp(200, json_data={"ok": True}),
    ])
    assert _client()._get("/fetch", {"platform": "vividseats"}) == {"ok": True}
    assert calls["n"] == 2


def test_get_retry_after_header_parsed(monkeypatch):
    sleeps = []
    calls = {"n": 0}
    seq = [_FakeResp(429, headers={"Retry-After": "2.5"}), _FakeResp(200, json_data={"ok": 1})]
    def _get(url, params=None, timeout=None):
        r = seq[min(calls["n"], len(seq) - 1)]
        calls["n"] += 1
        return r
    monkeypatch.setattr(td.requests, "get", _get)
    monkeypatch.setattr(td.time, "sleep", lambda d: sleeps.append(d))
    _client()._get("/fetch")
    assert sleeps == [2.5]


def test_get_retry_after_invalid_falls_back(monkeypatch):
    sleeps = []
    calls = {"n": 0}
    seq = [_FakeResp(504, headers={"Retry-After": "soon"}), _FakeResp(200, json_data={})]
    def _get(url, params=None, timeout=None):
        r = seq[min(calls["n"], len(seq) - 1)]
        calls["n"] += 1
        return r
    monkeypatch.setattr(td.requests, "get", _get)
    monkeypatch.setattr(td.time, "sleep", lambda d: sleeps.append(d))
    _client()._get("/fetch")
    assert sleeps == [1.5]  # delays[0] fallback


def test_get_retries_exhausted_raises(monkeypatch):
    _seq_get(monkeypatch, [_FakeResp(503)])
    with pytest.raises(td.TicketsDataError, match="HTTP 503"):
        _client()._get("/fetch")


# ---------- _get terminal status branches (lines 184-195) ----------

def test_get_401_raises_auth(monkeypatch):
    _seq_get(monkeypatch, [_FakeResp(401)])
    with pytest.raises(td.TicketsDataAuthError):
        _client()._get("/fetch")


def test_get_402_raises_quota(monkeypatch):
    _seq_get(monkeypatch, [_FakeResp(402)])
    with pytest.raises(td.TicketsDataQuotaError):
        _client()._get("/fetch")


def test_get_other_error_raises_path_only(monkeypatch):
    _seq_get(monkeypatch, [_FakeResp(500)])
    with pytest.raises(td.TicketsDataError, match=r"HTTP 500 on GET /fetch"):
        _client()._get("/fetch")


def test_get_json_failure_returns_raw_text(monkeypatch):
    _seq_get(monkeypatch, [_FakeResp(200, text="not-json", raise_json=True)])
    assert _client()._get("/fetch") == {"raw_text": "not-json"}


def test_get_non_dict_body_wrapped(monkeypatch):
    _seq_get(monkeypatch, [_FakeResp(200, json_data=[1, 2, 3])])
    assert _client()._get("/fetch") == {"body": [1, 2, 3]}


# ---------- endpoint validators (lines 204, 218, 228-230) ----------

def test_fetch_requires_event_url():
    with pytest.raises(td.TicketsDataError, match="event_url is required for /fetch"):
        _client().fetch("vividseats", "")


def test_fetch_passes_through(monkeypatch):
    captured = {}
    monkeypatch.setattr(td.TicketsDataClient, "_get",
                        lambda self, path, params=None: captured.update(path=path, params=params) or {"ok": 1})
    _client().fetch("vividseats", "https://e", mode="m")
    assert captured["path"] == "/fetch"
    assert captured["params"] == {"platform": "vividseats", "event_url": "https://e", "mode": "m"}


def test_events_requires_a_url():
    with pytest.raises(td.TicketsDataError, match="performer_url / venue_url"):
        _client().events("vividseats")


def test_events_passes_through(monkeypatch):
    captured = {}
    monkeypatch.setattr(td.TicketsDataClient, "_get",
                        lambda self, path, params=None: captured.update(path=path, params=params) or {})
    _client().events("vividseats", performer_url="https://p")
    assert captured["path"] == "/events"
    assert captured["params"]["performer_url"] == "https://p"


def test_match_requires_event_url():
    with pytest.raises(td.TicketsDataError, match="event_url is required for /match"):
        _client().match("")


def test_match_passes_through(monkeypatch):
    captured = {}
    monkeypatch.setattr(td.TicketsDataClient, "_get",
                        lambda self, path, params=None: captured.update(path=path, params=params) or {"r": 1})
    assert _client().match("https://e") == {"r": 1}
    assert captured == {"path": "/match", "params": {"event_url": "https://e"}}
