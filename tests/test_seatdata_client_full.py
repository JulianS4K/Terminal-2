"""Full-coverage tests for seatdata_client.py — no real HTTP / Supabase.

HTTP is monkeypatched at the requests.Session boundary; the DB is a Fake
object exposing rpc()/table() that mirror the supabase-py call chain. We
exercise: construction + vault key resolution, the read-only guard
(sanctioned POST path vs. everything else), the _request transport (429
backoff, gzip decode, json fallback), budget enforcement (BudgetExceeded),
every public endpoint's success + error branch, and the DB persistence
helpers (store_sales dedupe/hash, link_event, _log_pull).
"""
from __future__ import annotations

import gzip
import json

import pytest

import seatdata_client as sd
from seatdata_client import SeatDataClient, SeatDataError, BudgetExceeded


# ============================================================
# Fakes
# ============================================================

class _FakeRpcResult:
    def __init__(self, data):
        self.data = data


class _FakeVaultDB:
    """Minimal DB exposing rpc(get_app_secret).execute() for key resolution."""
    def __init__(self, secret, raise_on_lookup=False):
        self._secret = secret
        self._raise = raise_on_lookup

    def rpc(self, name, params):
        assert name == "get_app_secret"
        if self._raise:
            raise RuntimeError("boom")
        self._pending = self._secret
        return self

    def execute(self):
        return _FakeRpcResult(self._pending)


class _Tbl:
    """Records insert()/upsert() calls and returns a canned result."""
    def __init__(self, parent, name):
        self.parent = parent
        self.name = name
        self._payload = None

    def insert(self, payload):
        self._payload = payload
        if self.parent.raise_on_insert:
            raise RuntimeError("insert boom")
        self.parent.inserts.append((self.name, payload))
        return self

    def upsert(self, payload, on_conflict=None):
        self._payload = payload
        if self.parent.raise_on_upsert:
            raise RuntimeError("upsert boom")
        self.parent.upserts.append((self.name, payload, on_conflict))
        return self

    def execute(self):
        return _FakeRpcResult(self.parent.upsert_data)


class _RpcCall:
    def __init__(self, parent, name, params):
        self.parent = parent
        self.name = name
        self.params = params

    def execute(self):
        self.parent.rpc_calls.append((self.name, self.params))
        if self.name in self.parent.rpc_raises:
            raise RuntimeError(f"rpc {self.name} boom")
        return _FakeRpcResult(self.parent.rpc_results.get(self.name))


class _FakeDB:
    """Full-featured fake supabase client for the budget/log/store paths."""
    def __init__(self, *, budget=None, rpc_results=None, rpc_raises=(),
                 upsert_data=None, raise_on_insert=False,
                 raise_on_upsert=False):
        self.rpc_results = dict(rpc_results or {})
        if budget is not None:
            self.rpc_results["seatdata_check_budget"] = budget
        self.rpc_raises = set(rpc_raises)
        self.rpc_calls = []
        self.inserts = []
        self.upserts = []
        self.upsert_data = upsert_data if upsert_data is not None else []
        self.raise_on_insert = raise_on_insert
        self.raise_on_upsert = raise_on_upsert

    def rpc(self, name, params=None):
        return _RpcCall(self, name, params)

    def table(self, name):
        return _Tbl(self, name)


class _FakeResp:
    def __init__(self, status, *, payload=None, content=b"", headers=None,
                 text="", raise_json=False):
        self.status_code = status
        self._payload = payload
        self.content = content
        self.headers = headers or {}
        self.text = text
        self._raise_json = raise_json

    def json(self):
        if self._raise_json:
            raise ValueError("no json")
        return self._payload


def _make_client(monkeypatch, db=None, responses=None, capture=None):
    """Build a SeatDataClient with an explicit api_key and a stubbed session.

    `responses` is a list of _FakeResp consumed in order per request().
    `capture` (optional list) records (method, url, params, json) tuples.
    """
    c = SeatDataClient(api_key="k", db=db)
    seq = list(responses or [])

    def fake_request(method, url, params=None, json=None, timeout=None):
        if capture is not None:
            capture.append((method, url, params, json))
        return seq.pop(0)

    monkeypatch.setattr(c.session, "request", fake_request)
    return c


# ============================================================
# Read-only guard
# ============================================================

def test_guard_allows_get_any_path():
    sd._assert_readonly_method("GET")
    sd._assert_readonly_method("get", "v1/events/search")


def test_guard_allows_sanctioned_post():
    sd._assert_readonly_method("POST", "v0.4/events/event-request-add")
    sd._assert_readonly_method("POST", "/v0.4/events/event-request-add")
    sd._assert_readonly_method("POST", "v0.4/events/event-request-add?x=1")


def test_guard_rejects_unsanctioned_post():
    for path in ("v0.3/salesdata/get", "", None):
        with pytest.raises(SeatDataError) as exc:
            sd._assert_readonly_method("POST", path)
        assert "READ-ONLY violation" in str(exc.value)


def test_guard_rejects_other_methods():
    for method in ("PUT", "PATCH", "DELETE"):
        with pytest.raises(SeatDataError):
            sd._assert_readonly_method(method)


# ============================================================
# Construction / key resolution
# ============================================================

def test_init_uses_explicit_key(monkeypatch):
    monkeypatch.delenv("SEATDATA_API_KEY", raising=False)
    c = SeatDataClient(api_key="explicit")
    assert c.api_key == "explicit"
    assert c.session.headers["Authorization"] == "Bearer explicit"


def test_init_uses_env_key(monkeypatch):
    monkeypatch.setenv("SEATDATA_API_KEY", "env-key")
    c = SeatDataClient()
    assert c.api_key == "env-key"


def test_init_resolves_scalar_from_vault(monkeypatch):
    monkeypatch.delenv("SEATDATA_API_KEY", raising=False)
    c = SeatDataClient(db=_FakeVaultDB("vault-scalar"))
    assert c.api_key == "vault-scalar"


def test_init_resolves_dict_value_from_vault(monkeypatch):
    monkeypatch.delenv("SEATDATA_API_KEY", raising=False)
    c = SeatDataClient(db=_FakeVaultDB({"value": "from-value"}))
    assert c.api_key == "from-value"


def test_init_resolves_dict_func_name_from_vault(monkeypatch):
    monkeypatch.delenv("SEATDATA_API_KEY", raising=False)
    c = SeatDataClient(db=_FakeVaultDB({"get_app_secret": "func-named"}))
    assert c.api_key == "func-named"


def test_init_vault_lookup_exception_then_no_key_raises(monkeypatch, capsys):
    monkeypatch.delenv("SEATDATA_API_KEY", raising=False)
    with pytest.raises(SeatDataError) as exc:
        SeatDataClient(db=_FakeVaultDB(None, raise_on_lookup=True))
    assert "SEATDATA_API_KEY not found" in str(exc.value)
    assert "vault lookup failed" in capsys.readouterr().out


def test_init_no_key_no_db_raises(monkeypatch):
    monkeypatch.delenv("SEATDATA_API_KEY", raising=False)
    with pytest.raises(SeatDataError):
        SeatDataClient()


# ============================================================
# _request transport
# ============================================================

def test_request_json_success(monkeypatch):
    cap = []
    c = _make_client(monkeypatch, responses=[_FakeResp(200, payload={"ok": 1},
                     headers={"X": "1"})], capture=cap)
    status, body, headers = c._request("GET", "/v1/account")
    assert status == 200 and body == {"ok": 1} and headers == {"X": "1"}
    assert cap[0][1] == "https://seatdata.io/api/v1/account"


def test_request_json_value_error_falls_back_to_raw(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(200, raise_json=True,
                     text="not-json")])
    status, body, _ = c._request("GET", "v1/account")
    assert body == {"raw": "not-json"}


def test_request_gzip_decode(monkeypatch):
    raw = gzip.compress(json.dumps([{"a": 1}]).encode())
    c = _make_client(monkeypatch, responses=[_FakeResp(200, content=raw,
                     headers={"Content-Encoding": "gzip"})])
    status, body, _ = c._request("GET", "v0.3/salesdata/get", expect_gzip=True)
    assert body == [{"a": 1}]


def test_request_gzip_uncompressed_branch(monkeypatch):
    # expect_gzip but no gzip Content-Encoding -> uses raw content directly.
    raw = json.dumps({"listings": []}).encode()
    c = _make_client(monkeypatch, responses=[_FakeResp(200, content=raw,
                     headers={})])
    status, body, _ = c._request("GET", "v0.1.1/listings/get", expect_gzip=True)
    assert body == {"listings": []}


def test_request_gzip_app_level_without_header(monkeypatch):
    # Regression: an application-level gzipped body served WITHOUT a
    # Content-Encoding header (the normal case — requests strips transport
    # gzip, so any gzip left here is in the payload). The old header-gated
    # decode handed raw gzip bytes to json.loads (crash); the magic-byte sniff
    # decodes it correctly.
    raw = gzip.compress(json.dumps([{"sale": 1}]).encode())
    c = _make_client(monkeypatch, responses=[_FakeResp(200, content=raw, headers={})])
    status, body, _ = c._request("GET", "v0.3/salesdata/get", expect_gzip=True)
    assert body == [{"sale": 1}]


def test_request_gzip_decode_failure_raises_clean(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(200, content=b"bad",
                     headers={"Content-Encoding": "gzip"})])
    with pytest.raises(SeatDataError) as exc:
        c._request("GET", "v0.3/salesdata/get", expect_gzip=True)
    # message must NOT leak the underlying exception payload, only the type
    assert "failed to decode gzip JSON" in str(exc.value)
    assert "bad" not in str(exc.value)


def test_request_429_backoff_then_success(monkeypatch):
    slept = []
    monkeypatch.setattr(sd.time, "sleep", lambda s: slept.append(s))
    monkeypatch.setattr(sd.random, "random", lambda: 0.0)
    c = _make_client(monkeypatch, responses=[
        _FakeResp(429, headers={"Retry-After": "2"}),
        _FakeResp(429, headers={}),           # no Retry-After -> backoff
        _FakeResp(200, payload={"ok": 1}),
    ])
    status, body, _ = c._request("GET", "v1/account")
    assert status == 200 and body == {"ok": 1}
    assert slept == [2.0, 2.0]  # first uses Retry-After=2, second uses backoff=2


def test_request_429_invalid_retry_after_uses_backoff(monkeypatch):
    slept = []
    monkeypatch.setattr(sd.time, "sleep", lambda s: slept.append(s))
    monkeypatch.setattr(sd.random, "random", lambda: 0.0)
    c = _make_client(monkeypatch, responses=[
        _FakeResp(429, headers={"Retry-After": "not-a-number"}),
        _FakeResp(200, payload={"ok": 1}),
    ])
    status, _, _ = c._request("GET", "v1/account")
    assert status == 200 and slept == [1.0]  # falls back to initial backoff


def test_request_429_exhausts_retries(monkeypatch):
    monkeypatch.setattr(sd.time, "sleep", lambda s: None)
    monkeypatch.setattr(sd.random, "random", lambda: 0.0)
    # max_429_retries=1: attempt 1 retries, attempt 2 (>1) returns the 429.
    c = _make_client(monkeypatch, responses=[
        _FakeResp(429, headers={}),
        _FakeResp(429, payload={"err": "rate"}),
    ])
    status, body, _ = c._request("GET", "v1/account", max_429_retries=1)
    assert status == 429 and body == {"err": "rate"}


# ============================================================
# Free endpoints: account / usage / search
# ============================================================

def test_account_success_logs(monkeypatch):
    db = _FakeDB()
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(200, payload={"plan": "basic"})])
    assert c.account() == {"plan": "basic"}
    assert ("seatdata_increment_budget", {"p_endpoint": "v1/account", "p_was_charged": False}) in db.rpc_calls
    assert db.inserts[0][0] == "seatdata_pull_log"


def test_account_error_raises(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(500, payload={"e": 1})])
    with pytest.raises(SeatDataError):
        c.account()


def test_usage_success_and_error(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(200, payload={"used": 5})])
    assert c.usage() == {"used": 5}
    c2 = _make_client(monkeypatch, responses=[_FakeResp(503, payload={})])
    with pytest.raises(SeatDataError):
        c2.usage()


def test_search_events_success(monkeypatch):
    cap = []
    c = _make_client(monkeypatch, responses=[_FakeResp(200,
                     payload={"data": [{"id": 1}, {"id": 2}]})], capture=cap)
    body = c.search_events(event_name="show", limit=500, historical=True)
    assert len(body["data"]) == 2
    params = cap[0][2]
    assert params["limit"] == 200  # clamped
    assert params["historical"] == "true"
    assert params["event_name"] == "show"
    assert "venue_name" not in params  # None values dropped


def test_search_events_non_dict_body_rows_zero(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(200, payload=["x"])])
    # body is a list -> isinstance dict False -> rows 0 path
    assert c.search_events() == ["x"]


def test_search_events_error(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(400, payload={})])
    with pytest.raises(SeatDataError):
        c.search_events()


def test_search_events_iter_paginates(monkeypatch):
    c = _make_client(monkeypatch, responses=[
        _FakeResp(200, payload={"data": [{"id": 1}], "has_more": True, "next_cursor": "c2"}),
        _FakeResp(200, payload={"data": [{"id": 2}], "has_more": True, "next_cursor": None}),
    ])
    ids = [item["id"] for item in c.search_events_iter()]
    assert ids == [1, 2]  # stops when next_cursor is falsy despite has_more


def test_search_events_iter_stops_on_no_more(monkeypatch):
    c = _make_client(monkeypatch, responses=[
        _FakeResp(200, payload={"data": [{"id": 1}], "has_more": False}),
    ])
    assert [i["id"] for i in c.search_events_iter()] == [1]


# ============================================================
# Budget enforcement
# ============================================================

def test_check_budget_no_db_returns_envelope():
    c = SeatDataClient(api_key="k")
    env = c._check_budget()
    assert env["allowed"] is True and env["reason"] == "no_db_attached"


def test_check_budget_with_db():
    c = SeatDataClient(api_key="k", db=_FakeDB(budget={"allowed": True, "used": 1}))
    assert c._check_budget() == {"allowed": True, "used": 1}


def test_check_budget_db_returns_none_envelope():
    c = SeatDataClient(api_key="k", db=_FakeDB(rpc_results={"seatdata_check_budget": None}))
    assert c._check_budget() == {}


def test_ensure_budget_raises_when_exhausted():
    db = _FakeDB(budget={"allowed": False, "reason": "daily_cap", "used": 100,
                         "daily_cap": 100, "monthly_used": 200, "monthly_cap": 2000})
    c = SeatDataClient(api_key="k", db=db)
    with pytest.raises(BudgetExceeded) as exc:
        c._ensure_budget_or_raise()
    assert "daily_cap" in str(exc.value)


def test_increment_budget_no_db_noop():
    SeatDataClient(api_key="k")._increment_budget("x", True)  # no raise


def test_increment_budget_swallows_errors(capsys):
    db = _FakeDB(rpc_raises={"seatdata_increment_budget"})
    SeatDataClient(api_key="k", db=db)._increment_budget("ep", True)
    assert "budget increment failed" in capsys.readouterr().out


# ============================================================
# _log_pull
# ============================================================

def test_log_pull_no_db_noop():
    SeatDataClient(api_key="k")._log_pull("ep", None, None, False, 200, None, None)


def test_log_pull_swallows_errors(capsys):
    db = _FakeDB(raise_on_insert=True)
    SeatDataClient(api_key="k", db=db)._log_pull("ep", 1, 2, True, 200, 3, None)
    assert "pull log failed" in capsys.readouterr().out


# ============================================================
# event_stats (paid)
# ============================================================

def test_event_stats_first_page_charged(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(200,
                     payload={"data": [{"p": 1}]})])
    body = c.event_stats(42, tevo_event_id=7)
    assert body["data"] == [{"p": 1}]
    inc = [r for r in db.rpc_calls if r[0] == "seatdata_increment_budget"][0]
    assert inc[1] == {"p_endpoint": "v1/events_stats", "p_was_charged": True}


def test_event_stats_continuation_not_charged_skips_budget(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(200, payload={"data": []})])
    c.event_stats(42, starting_after="cur")
    # continuation -> budget check skipped (no seatdata_check_budget call)
    assert not any(r[0] == "seatdata_check_budget" for r in db.rpc_calls)
    inc = [r for r in db.rpc_calls if r[0] == "seatdata_increment_budget"][0]
    assert inc[1]["p_was_charged"] is False


def test_event_stats_non_dict_body(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(200, payload=["x"])])
    assert c.event_stats(1) == ["x"]


def test_event_stats_error_logs_and_raises(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(404, payload={"e": "nope"})])
    with pytest.raises(SeatDataError):
        c.event_stats(99)
    assert db.inserts[-1][1]["http_status"] == 404


def test_event_stats_budget_exhausted(monkeypatch):
    db = _FakeDB(budget={"allowed": False})
    c = _make_client(monkeypatch, db=db, responses=[])
    with pytest.raises(BudgetExceeded):
        c.event_stats(1)


# ============================================================
# salesdata (paid)
# ============================================================

def test_salesdata_success_charged(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    raw = gzip.compress(json.dumps([{"price": 1}, {"price": 2}]).encode())
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(200, content=raw,
                     headers={"Content-Encoding": "gzip"})])
    rows = c.salesdata(10, tevo_event_id=5)
    assert len(rows) == 2
    inc = [r for r in db.rpc_calls if r[0] == "seatdata_increment_budget"][0]
    assert inc[1]["p_was_charged"] is True


def test_salesdata_non_list_returns_empty(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    raw = gzip.compress(json.dumps({"not": "list"}).encode())
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(200, content=raw,
                     headers={"Content-Encoding": "gzip"})])
    assert c.salesdata(10) == []


def test_salesdata_error(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(500, raise_json=True, text="boom")])
    with pytest.raises(SeatDataError):
        c.salesdata(10)
    assert db.inserts[-1][1]["http_status"] == 500


# ============================================================
# listings (paid)
# ============================================================

def test_listings_refreshed_charged(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    raw = gzip.compress(json.dumps({"has_refreshed": 1, "listings": [1, 2, 3]}).encode())
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(200, content=raw,
                     headers={"Content-Encoding": "gzip"})])
    body = c.listings(10, tevo_event_id=5)
    assert len(body["listings"]) == 3
    inc = [r for r in db.rpc_calls if r[0] == "seatdata_increment_budget"][0]
    assert inc[1]["p_was_charged"] is True


def test_listings_not_refreshed_not_charged(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    raw = gzip.compress(json.dumps({"has_refreshed": 0, "listings": []}).encode())
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(200, content=raw,
                     headers={"Content-Encoding": "gzip"})])
    c.listings(10)
    inc = [r for r in db.rpc_calls if r[0] == "seatdata_increment_budget"][0]
    assert inc[1]["p_was_charged"] is False


def test_listings_non_dict_returns_empty(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    raw = gzip.compress(json.dumps(["x"]).encode())
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(200, content=raw,
                     headers={"Content-Encoding": "gzip"})])
    assert c.listings(10) == {}


def test_listings_error(monkeypatch):
    db = _FakeDB(budget={"allowed": True})
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(502, payload={})])
    with pytest.raises(SeatDataError):
        c.listings(10)


# ============================================================
# event_request_add / event_request_status (POST + free)
# ============================================================

def test_event_request_add_success(monkeypatch):
    cap = []
    db = _FakeDB()
    c = _make_client(monkeypatch, db=db, responses=[_FakeResp(202, payload={"job_id": "j1"})],
                     capture=cap)
    assert c.event_request_add("some query")["job_id"] == "j1"
    assert cap[0][0] == "POST"
    assert cap[0][3] == {"search_query": "some query"}


def test_event_request_add_too_long(monkeypatch):
    c = _make_client(monkeypatch, responses=[])
    with pytest.raises(SeatDataError):
        c.event_request_add("x" * 201)


def test_event_request_add_bad_status(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(400, payload={})])
    with pytest.raises(SeatDataError):
        c.event_request_add("q")


def test_event_request_status_ok_and_404(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(200, payload={"state": "done"})])
    assert c.event_request_status("j1") == {"state": "done"}
    c2 = _make_client(monkeypatch, responses=[_FakeResp(404, payload={"e": "missing"})])
    assert c2.event_request_status("j2") == {"e": "missing"}


def test_event_request_status_error(monkeypatch):
    c = _make_client(monkeypatch, responses=[_FakeResp(500, payload={})])
    with pytest.raises(SeatDataError):
        c.event_request_status("j3")


# ============================================================
# DB persistence: store_sales / link_event / _hash_row
# ============================================================

def test_hash_row_deterministic_and_handles_none():
    h1 = SeatDataClient._hash_row("a", None, 3)
    h2 = SeatDataClient._hash_row("a", None, 3)
    assert h1 == h2 and len(h1) == 32
    assert SeatDataClient._hash_row("a") != SeatDataClient._hash_row("b")


def test_store_sales_no_db_returns_zero():
    assert SeatDataClient(api_key="k").store_sales(1, 2, [{"price": 1}]) == 0


def test_store_sales_empty_list_returns_zero():
    c = SeatDataClient(api_key="k", db=_FakeDB())
    assert c.store_sales(1, 2, []) == 0


def test_store_sales_numeric_and_string_timestamps(monkeypatch):
    db = _FakeDB(upsert_data=[{"id": 1}, {"id": 2}])
    c = SeatDataClient(api_key="k", db=db)
    sales = [
        {"timestamp": 1700000000, "quantity": 2, "price": 100, "zone": "L",
         "section": "1", "row": "A"},
        {"timestamp": "2026-05-09T00:00:00Z", "quantity": 1, "price": 200},
        {"timestamp": None, "quantity": 1, "price": 300},  # falsy ts -> None
    ]
    inserted = c.store_sales(7, 8, sales)
    assert inserted == 2
    name, payload, on_conflict = db.upserts[0]
    assert name == "seatdata_sales_snapshots"
    assert on_conflict == "tevo_event_id,content_hash"
    # numeric ts converted to ISO datetime
    assert payload[0]["sale_timestamp"].startswith("2023-11-14")
    assert payload[1]["sale_timestamp"] == "2026-05-09T00:00:00Z"
    assert payload[2]["sale_timestamp"] is None
    assert all(len(r["content_hash"]) == 32 for r in payload)


def test_store_sales_epoch_string_timestamp_coerced(monkeypatch):
    # Regression: an epoch timestamp sent as a STRING ("1700000000") — common in
    # JSON feeds — must be coerced to ISO, not stored verbatim. The old
    # isinstance-only check stored the literal string (bad column value + an
    # unstable content_hash vs the int form, which broke dedup).
    db = _FakeDB(upsert_data=[{"id": 1}])
    c = SeatDataClient(api_key="k", db=db)
    c.store_sales(7, 8, [{"timestamp": "1700000000", "quantity": 1, "price": 50}])
    _, payload, _ = db.upserts[0]
    assert payload[0]["sale_timestamp"].startswith("2023-11-14")  # ISO, not "1700000000"


def test_store_sales_swallows_errors(capsys):
    db = _FakeDB(raise_on_upsert=True)
    c = SeatDataClient(api_key="k", db=db)
    assert c.store_sales(1, 2, [{"price": 1}]) == 0
    assert "store_sales failed" in capsys.readouterr().out


def test_link_event_no_db_noop():
    SeatDataClient(api_key="k").link_event(1, 2)  # no raise


def test_link_event_upserts(monkeypatch):
    db = _FakeDB()
    c = SeatDataClient(api_key="k", db=db)
    c.link_event(1, 2, match_method="auto", confidence=0.9, meta={"k": "v"})
    name, payload, on_conflict = db.upserts[0]
    assert name == "seatdata_event_xref"
    assert on_conflict == "tevo_event_id"
    assert payload["match_method"] == "auto"
    assert payload["match_confidence"] == 0.9
    assert payload["meta"] == {"k": "v"}


def test_link_event_default_meta(monkeypatch):
    db = _FakeDB()
    SeatDataClient(api_key="k", db=db).link_event(1, 2)
    assert db.upserts[0][1]["meta"] == {}
