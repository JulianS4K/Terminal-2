"""Full-coverage tests for seatgeek_client.py. No real HTTP / Supabase calls.

Transport is mocked by monkeypatching the client's `session.get`. DB is a small
fake exposing the `.table(...).insert/upsert/update/delete/eq/in_/execute` and
`.rpc(...).execute()` chains the client uses.
"""
from __future__ import annotations

import pytest

import seatgeek_client as sg


# ====================================================================
# Fakes
# ====================================================================

class _FakeResp:
    def __init__(self, status, payload=None, headers=None, raise_json=False, text="body"):
        self.status_code = status
        # Mirror requests.Response.ok (status < 400) — the shared retry loop
        # (core/http_retry.py) short-circuits on it like the real client does.
        self.ok = status < 400
        self._payload = payload if payload is not None else {}
        self.headers = headers or {}
        self.text = text
        self._raise_json = raise_json

    def json(self):
        if self._raise_json:
            raise ValueError("no json")
        return self._payload


class _RpcResult:
    def __init__(self, data):
        self.data = data


class _FakeRpc:
    """Stands in for db.rpc(...).execute() — returns canned data per call."""
    def __init__(self, owner, name, params):
        self._owner = owner
        self._name = name
        self._params = params

    def execute(self):
        self._owner.rpc_calls.append((self._name, self._params))
        if self._owner.rpc_raises:
            raise RuntimeError("rpc boom")
        if callable(self._owner.rpc_data):
            return _RpcResult(self._owner.rpc_data(self._name, self._params))
        return _RpcResult(self._owner.rpc_data)


class _Table:
    """Captures table ops and returns canned upsert/insert results."""
    def __init__(self, owner, name):
        self._owner = owner
        self._name = name
        self._op = None

    def insert(self, payload):
        self._owner.ops.append((self._name, "insert", payload))
        if self._owner.insert_raises:
            raise RuntimeError("insert boom")
        return self

    def upsert(self, rows, on_conflict=None):
        self._owner.ops.append((self._name, "upsert", rows, on_conflict))
        if self._owner.upsert_raises:
            raise RuntimeError("upsert boom")
        self._pending = self._owner.upsert_data
        return self

    def update(self, payload):
        self._owner.ops.append((self._name, "update", payload))
        return self

    def delete(self):
        self._owner.ops.append((self._name, "delete"))
        return self

    def eq(self, *a, **k):
        return self

    def in_(self, *a, **k):
        return self

    def execute(self):
        return _RpcResult(getattr(self, "_pending", None))


class _FakeDB:
    def __init__(self, *, rpc_data=None, rpc_raises=False, secret=None,
                 secret_raises=False, upsert_data=None, upsert_raises=False,
                 insert_raises=False):
        self.ops = []
        self.rpc_calls = []
        self.rpc_data = rpc_data
        self.rpc_raises = rpc_raises
        self._secret = secret
        self._secret_raises = secret_raises
        self.upsert_data = upsert_data if upsert_data is not None else []
        self.upsert_raises = upsert_raises
        self.insert_raises = insert_raises

    def table(self, name):
        return _Table(self, name)

    def rpc(self, name, params):
        # get_app_secret path (token resolution) is special-cased.
        if name == "get_app_secret":
            if self._secret_raises:
                class _Boom:
                    def execute(self_inner):
                        raise RuntimeError("vault boom")
                return _Boom()

            secret = self._secret

            class _SecretRpc:
                def execute(self_inner):
                    return _RpcResult(secret)
            return _SecretRpc()
        return _FakeRpc(self, name, params)


def _client(monkeypatch, *, db=None, token="tok"):
    if token is not None:
        monkeypatch.setenv("SEATGEEK_API_TOKEN", token)
    else:
        monkeypatch.delenv("SEATGEEK_API_TOKEN", raising=False)
    return sg.SeatGeekClient(db=db)


def _patch_get(monkeypatch, client, responder):
    """responder(url, params, timeout) -> _FakeResp."""
    monkeypatch.setattr(client.session, "get", responder)


# ====================================================================
# read-only guard
# ====================================================================

def test_assert_readonly_allows_get():
    sg._assert_readonly_method("GET")
    sg._assert_readonly_method("get")


def test_assert_readonly_raises_on_writes():
    for method in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(sg.SeatGeekError) as exc:
            sg._assert_readonly_method(method)
        assert "READ-ONLY violation" in str(exc.value)


# ====================================================================
# construction / token resolution
# ====================================================================

def test_explicit_token_wins(monkeypatch):
    monkeypatch.delenv("SEATGEEK_API_TOKEN", raising=False)
    c = sg.SeatGeekClient(api_token="explicit")
    assert c.api_token == "explicit"
    assert c.session.headers["Accept"] == "application/json"


def test_token_from_env(monkeypatch):
    monkeypatch.setenv("SEATGEEK_API_TOKEN", "env-tok")
    c = sg.SeatGeekClient()
    assert c.api_token == "env-tok"


def test_token_from_vault(monkeypatch):
    monkeypatch.delenv("SEATGEEK_API_TOKEN", raising=False)
    db = _FakeDB(secret="vault-tok")
    c = sg.SeatGeekClient(db=db)
    assert c.api_token == "vault-tok"


def test_token_vault_non_string_ignored(monkeypatch):
    monkeypatch.delenv("SEATGEEK_API_TOKEN", raising=False)
    db = _FakeDB(secret={"not": "a string"})
    with pytest.raises(sg.SeatGeekError):
        sg.SeatGeekClient(db=db)


def test_token_vault_lookup_exception(monkeypatch, capsys):
    monkeypatch.delenv("SEATGEEK_API_TOKEN", raising=False)
    db = _FakeDB(secret_raises=True)
    with pytest.raises(sg.SeatGeekError):
        sg.SeatGeekClient(db=db)
    assert "vault lookup failed" in capsys.readouterr().out


def test_no_token_raises(monkeypatch):
    monkeypatch.delenv("SEATGEEK_API_TOKEN", raising=False)
    with pytest.raises(sg.SeatGeekError) as exc:
        sg.SeatGeekClient()
    assert "SEATGEEK_API_TOKEN not found" in str(exc.value)


# ====================================================================
# _log_pull
# ====================================================================

def test_log_pull_noop_without_db(monkeypatch):
    c = _client(monkeypatch)
    c._log_pull("x", tevo_event_id=1, sg_event_id=2, status=200, rows=0,
                cache_hit=None, refreshed_at_utc=None)  # no raise, no db


def test_log_pull_inserts(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    c._log_pull("listings", tevo_event_id=1, sg_event_id=2, status=200, rows=3,
                cache_hit=True, refreshed_at_utc="t", meta={"k": "v"})
    assert db.ops[0][0] == "seatgeek_pull_log"
    assert db.ops[0][1] == "insert"


def test_log_pull_swallows_insert_error(monkeypatch, capsys):
    db = _FakeDB(insert_raises=True)
    c = _client(monkeypatch, db=db)
    c._log_pull("listings", tevo_event_id=1, sg_event_id=2, status=200, rows=3,
                cache_hit=True, refreshed_at_utc="t")
    assert "pull log failed" in capsys.readouterr().out


# ====================================================================
# _get — params cleaning, 429 retry, json fallback
# ====================================================================

def test_get_cleans_params_and_returns(monkeypatch):
    c = _client(monkeypatch)
    captured = {}

    def responder(url, params=None, timeout=None):
        captured["url"] = url
        captured["params"] = params
        captured["timeout"] = timeout
        return _FakeResp(200, {"ok": True})

    _patch_get(monkeypatch, c, responder)
    status, body = c._get("/listings", params={"event_id": 7, "flag": True,
                                               "off": False, "skip": None})
    assert status == 200 and body == {"ok": True}
    assert captured["url"].endswith("/listings")
    assert captured["params"]["token"] == "tok"
    assert captured["params"]["event_id"] == 7
    assert captured["params"]["flag"] == 1       # bool True -> 1
    assert captured["params"]["off"] == 0        # bool False -> 0
    assert "skip" not in captured["params"]      # None dropped
    assert captured["timeout"] == c.timeout_s


def test_get_json_value_error_fallback(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, raise_json=True, text="plain"))
    status, body = c._get("/listings")
    assert status == 200 and body == {"raw_text": "plain"}


def test_get_429_retry_then_success(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(sg.time, "sleep", lambda *_: None)
    monkeypatch.setattr(sg.random, "random", lambda: 0.0)
    calls = {"n": 0}

    def responder(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            return _FakeResp(429, headers={"Retry-After": "2"})
        return _FakeResp(200, {"done": True})

    _patch_get(monkeypatch, c, responder)
    status, body = c._get("/listings")
    assert status == 200 and body == {"done": True}
    assert calls["n"] == 2


def test_get_429_retry_after_unparseable_uses_backoff(monkeypatch):
    c = _client(monkeypatch)
    sleeps = []
    monkeypatch.setattr(sg.time, "sleep", lambda s: sleeps.append(s))
    monkeypatch.setattr(sg.random, "random", lambda: 0.0)
    calls = {"n": 0}

    def responder(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            return _FakeResp(429, headers={"Retry-After": "not-a-number"})
        return _FakeResp(200, {"ok": 1})

    _patch_get(monkeypatch, c, responder)
    c._get("/listings")
    assert sleeps == [1.0]  # backoff default used on ValueError


def test_get_429_no_retry_after_header(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(sg.time, "sleep", lambda *_: None)
    monkeypatch.setattr(sg.random, "random", lambda: 0.0)
    calls = {"n": 0}

    def responder(*a, **k):
        calls["n"] += 1
        return _FakeResp(429) if calls["n"] == 1 else _FakeResp(200, {"ok": 1})

    _patch_get(monkeypatch, c, responder)
    status, _ = c._get("/listings")
    assert status == 200


def test_get_429_exhausts_retries(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(sg.time, "sleep", lambda *_: None)
    monkeypatch.setattr(sg.random, "random", lambda: 0.0)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(429, {"err": 1}))
    status, body = c._get("/listings", max_429_retries=2)
    # After max retries the 429 is returned rather than retried forever.
    assert status == 429


# ====================================================================
# _parse_iso / _hash_listing
# ====================================================================

def test_parse_iso():
    assert sg.SeatGeekClient._parse_iso(None) is None
    assert sg.SeatGeekClient._parse_iso("") is None
    assert sg.SeatGeekClient._parse_iso("2026-01-01T00:00:00Z") == "2026-01-01T00:00:00+00:00"
    assert sg.SeatGeekClient._parse_iso("2026-01-01T00:00:00+00:00") == "2026-01-01T00:00:00+00:00"
    assert sg.SeatGeekClient._parse_iso(123) == 123  # non-str passthrough


def test_hash_listing_stable_and_changes():
    a = {"sglid": 1, "pf": 100, "q": 2}
    h1 = sg.SeatGeekClient._hash_listing(a)
    h2 = sg.SeatGeekClient._hash_listing(dict(a))
    assert h1 == h2 and len(h1) == 32
    b = dict(a, pf=101)
    assert sg.SeatGeekClient._hash_listing(b) != h1


def test_hash_seller_listing():
    h = sg.SeatGeekClient._hash_seller_listing({"sg_listing_id": 9, "cost": 5})
    assert len(h) == 32


# ====================================================================
# listings()
# ====================================================================

def test_listings_success_v1(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    body = {"event": {"name": "Show"}, "listings": [{"sglid": 1}], "cache_hit": False,
            "refreshed_at_utc": "t"}
    captured = {}

    def responder(url, params=None, timeout=None):
        captured["url"] = url
        return _FakeResp(200, body)

    _patch_get(monkeypatch, c, responder)
    out = c.listings(42, tevo_event_id=7)
    assert out == body
    assert captured["url"].endswith("/listings")
    assert any(op[0] == "seatgeek_pull_log" for op in db.ops)


def test_listings_v2_path(monkeypatch):
    c = _client(monkeypatch)
    captured = {}

    def responder(url, params=None, timeout=None):
        captured["url"] = url
        return _FakeResp(200, {"listings": []})

    _patch_get(monkeypatch, c, responder)
    c.listings(42, v2=True)
    assert captured["url"].endswith("/v2/listings")


def test_listings_non_dict_body_returns_default(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, []))
    out = c.listings(1)
    assert out == {"event": None, "listings": []}


def test_listings_401_scope_error(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    body = {"error": {"message": "no scope"}}
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(401, body))
    with pytest.raises(sg.SeatGeekScopeError) as exc:
        c.listings(1)
    assert "scope denied" in str(exc.value)


def test_listings_other_error(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(500, {"error": {"message": "boom"}}))
    with pytest.raises(sg.SeatGeekError) as exc:
        c.listings(1)
    assert "returned 500" in str(exc.value)


def test_listings_error_non_dict_body(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(500, ["a", "b"]))
    with pytest.raises(sg.SeatGeekError):
        c.listings(1)


# ====================================================================
# sales()
# ====================================================================

def test_sales_success(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    body = {"event": {"name": "S"}, "sales": [{"id": 1}], "cache_hit": True,
            "refreshed_at_utc": "t"}
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, body))
    assert c.sales(5, tevo_event_id=9) == body


def test_sales_non_dict_default(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, []))
    assert c.sales(5) == {"event": None, "sales": []}


def test_sales_401(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(401, {"error": {"message": "x"}}))
    with pytest.raises(sg.SeatGeekScopeError):
        c.sales(5)


def test_sales_other_error_non_dict(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(503, "down"))
    with pytest.raises(sg.SeatGeekError):
        c.sales(5)


# ====================================================================
# purchases()
# ====================================================================

def test_purchases_success(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, {"purchases": [1]}))
    assert c.purchases(event_id=3) == {"purchases": [1]}


def test_purchases_non_dict_default(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, []))
    assert c.purchases() == {"purchases": []}


def test_purchases_401(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(401, {"error": {"message": "no"}}))
    with pytest.raises(sg.SeatGeekScopeError):
        c.purchases()


def test_purchases_other_error_non_dict(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(500, "err"))
    with pytest.raises(sg.SeatGeekError):
        c.purchases(per_page=99)


# ====================================================================
# link_event()
# ====================================================================

def test_link_event_noop_without_db(monkeypatch):
    c = _client(monkeypatch)
    c.link_event(1, 2)  # no raise


def test_link_event_upserts(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    c.link_event(1, 2, sg_event_inline={"name": "N", "type": "concert",
                                        "location": "NYC",
                                        "start_data": "2026-01-01T00:00:00Z",
                                        "visible_until_utc": "2026-02-01T00:00:00Z"})
    op = db.ops[0]
    assert op[0] == "seatgeek_event_xref" and op[1] == "upsert"
    row = op[2]
    assert row["sg_event_name"] == "N"
    assert row["sg_start_data"] == "2026-01-01T00:00:00+00:00"


def test_link_event_no_inline(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    c.link_event(1, 2)
    assert db.ops[0][2]["sg_event_name"] is None


# ====================================================================
# store_listings()
# ====================================================================

def test_store_listings_noop_without_db(monkeypatch):
    c = _client(monkeypatch)
    assert c.store_listings(1, 2, [{"sglid": 1}]) == 0


def test_store_listings_empty(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    assert c.store_listings(1, 2, []) == 0


def test_store_listings_inserts_and_coerces(monkeypatch):
    db = _FakeDB(upsert_data=[{"a": 1}, {"b": 2}])
    c = _client(monkeypatch, db=db)
    listings = [{
        "sglid": "55", "id": "disp", "pf": 100, "bp": 90, "ds": 1, "q": 2,
        "sp": [1, 2], "s": "100", "r": "A", "bo": 1, "is_b2b": 0, "idl": 1,
        "sro": 0, "lv": 1, "wa": 0, "ada": "x", "dm": "mobile",
        "ihd": "2026-01-01T00:00:00", "m": "src", "st": "ELECTRONIC", "pn": "notes",
    }, {
        "sglid": None, "ihd": None,  # exercise None branches
    }]
    n = c.store_listings(1, 2, listings, endpoint="v2")
    assert n == 2
    upsert_op = next(o for o in db.ops if o[1] == "upsert")
    rows = upsert_op[2]
    assert rows[0]["sglid"] == 55
    assert rows[0]["is_broker_owned"] is True
    assert rows[0]["is_b2b"] is False
    assert rows[0]["in_hand_date"] == "2026-01-01"
    assert rows[0]["endpoint"] == "v2"
    assert rows[1]["sglid"] is None
    assert rows[1]["is_broker_owned"] is None
    assert rows[1]["in_hand_date"] is None
    # xref last_listings_at update happened
    assert any(o[0] == "seatgeek_event_xref" and o[1] == "update" for o in db.ops)


def test_store_listings_short_ihd_none(monkeypatch):
    db = _FakeDB(upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    c.store_listings(1, 2, [{"sglid": 1, "ihd": "2026"}])  # <10 chars -> None
    rows = next(o for o in db.ops if o[1] == "upsert")[2]
    assert rows[0]["in_hand_date"] is None


def test_store_listings_upsert_error(monkeypatch, capsys):
    db = _FakeDB(upsert_raises=True)
    c = _client(monkeypatch, db=db)
    assert c.store_listings(1, 2, [{"sglid": 1}]) == 0
    assert "store_listings failed" in capsys.readouterr().out


# ====================================================================
# store_sales()
# ====================================================================

def test_store_sales_noop_without_db(monkeypatch):
    c = _client(monkeypatch)
    assert c.store_sales(1, 2, [{"id": 1}]) == 0


def test_store_sales_empty(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    assert c.store_sales(1, 2, []) == 0


def test_store_sales_skips_rows_without_sale_time(monkeypatch):
    db = _FakeDB(upsert_data=[{"a": 1}])
    c = _client(monkeypatch, db=db)
    sales = [
        {"id": "no-time"},  # missing putc -> skipped
        {"id": "ok", "putc": "2026-01-01T00:00:00Z", "bp": 50, "q": 1,
         "s": "100", "r": "A", "st": "E", "dm": "mobile",
         "ihd": "2026-02-01T00:00:00", "idl": 1, "pn": "n"},
    ]
    n = c.store_sales(1, 2, sales)
    assert n == 1
    rows = next(o for o in db.ops if o[1] == "upsert")[2]
    assert len(rows) == 1
    assert rows[0]["sale_at_utc"] == "2026-01-01T00:00:00+00:00"
    assert rows[0]["is_instant"] is True
    assert rows[0]["in_hand_date"] == "2026-02-01"


def test_store_sales_all_skipped_returns_zero(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    assert c.store_sales(1, 2, [{"id": "x"}]) == 0
    # No upsert happened because rows empty
    assert not any(o[1] == "upsert" for o in db.ops)


def test_store_sales_idl_none_branch(monkeypatch):
    db = _FakeDB(upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    c.store_sales(1, 2, [{"id": "ok", "putc": "2026-01-01T00:00:00Z"}])
    rows = next(o for o in db.ops if o[1] == "upsert")[2]
    assert rows[0]["is_instant"] is None
    assert rows[0]["in_hand_date"] is None


def test_store_sales_upsert_error(monkeypatch, capsys):
    db = _FakeDB(upsert_raises=True)
    c = _client(monkeypatch, db=db)
    assert c.store_sales(1, 2, [{"id": "ok", "putc": "2026-01-01T00:00:00Z"}]) == 0
    assert "store_sales failed" in capsys.readouterr().out


# ====================================================================
# _get_seller — mirror of _get
# ====================================================================

def test_get_seller_cleans_and_returns(monkeypatch):
    c = _client(monkeypatch)
    captured = {}

    def responder(url, params=None, timeout=None):
        captured["url"] = url
        captured["params"] = params
        return _FakeResp(200, {"ok": 1})

    _patch_get(monkeypatch, c, responder)
    status, body = c._get_seller("/listings", params={"per_page": 5, "b": True,
                                                       "drop": None})
    assert status == 200 and body == {"ok": 1}
    assert captured["url"].startswith(sg.SELLER_DIRECT_BASE)
    assert captured["params"]["b"] == 1 and "drop" not in captured["params"]


def test_get_seller_json_fallback(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, raise_json=True, text="t"))
    status, body = c._get_seller("/listings")
    assert body == {"raw_text": "t"}


def test_get_seller_429_retry(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(sg.time, "sleep", lambda *_: None)
    monkeypatch.setattr(sg.random, "random", lambda: 0.0)
    calls = {"n": 0}

    def responder(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            return _FakeResp(429, headers={"Retry-After": "1"})
        return _FakeResp(200, {"ok": 1})

    _patch_get(monkeypatch, c, responder)
    assert c._get_seller("/listings")[0] == 200


def test_get_seller_429_unparseable_and_no_header(monkeypatch):
    c = _client(monkeypatch)
    sleeps = []
    monkeypatch.setattr(sg.time, "sleep", lambda s: sleeps.append(s))
    monkeypatch.setattr(sg.random, "random", lambda: 0.0)
    calls = {"n": 0}

    def responder(*a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            return _FakeResp(429, headers={"Retry-After": "abc"})
        if calls["n"] == 2:
            return _FakeResp(429)  # no header
        return _FakeResp(200, {"ok": 1})

    _patch_get(monkeypatch, c, responder)
    assert c._get_seller("/listings")[0] == 200
    assert sleeps == [1.0, 2.0]


def test_get_seller_429_exhausts(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(sg.time, "sleep", lambda *_: None)
    monkeypatch.setattr(sg.random, "random", lambda: 0.0)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(429, {"e": 1}))
    assert c._get_seller("/listings", max_429_retries=1)[0] == 429


# ====================================================================
# seller_listings()
# ====================================================================

def test_seller_listings_success_with_db(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    body = {"listings": [{"a": 1}], "meta": {"total": 100}}
    captured = {}

    def responder(url, params=None, timeout=None):
        captured["params"] = params
        return _FakeResp(200, body)

    _patch_get(monkeypatch, c, responder)
    out = c.seller_listings(event_id=9, per_page=50, page_cursor="cur")
    assert out == body
    assert captured["params"]["event_id"] == 9
    assert captured["params"]["page_cursor"] == "cur"
    assert any(o[0] == "seatgeek_seller_pull_log" for o in db.ops)


def test_seller_listings_log_insert_swallowed(monkeypatch):
    db = _FakeDB(insert_raises=True)
    c = _client(monkeypatch, db=db)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, {"listings": []}))
    # insert raises inside try/except -> swallowed, returns body
    assert c.seller_listings() == {"listings": []}


def test_seller_listings_no_db(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, {"listings": [1]}))
    assert c.seller_listings() == {"listings": [1]}


def test_seller_listings_error_status(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(400, {"e": "bad"}))
    with pytest.raises(sg.SeatGeekError) as exc:
        c.seller_listings()
    assert "returned 400" in str(exc.value)


def test_seller_listings_non_dict_body(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, []))
    assert c.seller_listings() == {"listings": []}


# ====================================================================
# iter_seller_listings()
# ====================================================================

def test_iter_seller_listings_paginates(monkeypatch):
    c = _client(monkeypatch)
    pages = [
        {"listings": [{"i": 1}, {"i": 2}], "meta": {"next_cursor": "c2"}},
        {"listings": [{"i": 3}], "meta": {"next_page_cursor": "c3"}},
        {"listings": [{"i": 4}], "meta": {"page_cursor": "c4"}},
        {"listings": [{"i": 5}], "meta": {}},  # no cursor -> stop
    ]
    seq = iter(pages)
    monkeypatch.setattr(c, "seller_listings", lambda **k: next(seq))
    out = list(c.iter_seller_listings(max_pages=10))
    assert [o["i"] for o in out] == [1, 2, 3, 4, 5]


def test_iter_seller_listings_empty_page_stops(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(c, "seller_listings", lambda **k: {"listings": []})
    assert list(c.iter_seller_listings()) == []


def test_iter_seller_listings_max_pages_cap(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(c, "seller_listings",
                        lambda **k: {"listings": [{"i": 1}], "meta": {"next_cursor": "x"}})
    out = list(c.iter_seller_listings(max_pages=2))
    assert len(out) == 2  # capped at 2 pages * 1 listing


# ====================================================================
# seller_orders()
# ====================================================================

def test_seller_orders_success(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    body = {"orders": [{"id": "o1"}], "meta": {"total": 5}}
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, body))
    assert c.seller_orders("open", page=2) == body
    assert any(o[0] == "seatgeek_seller_pull_log" for o in db.ops)


def test_seller_orders_log_swallowed(monkeypatch):
    db = _FakeDB(insert_raises=True)
    c = _client(monkeypatch, db=db)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, {"orders": [], "meta": {}}))
    assert c.seller_orders("open") == {"orders": [], "meta": {}}


def test_seller_orders_error(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(500, {"e": 1}))
    with pytest.raises(sg.SeatGeekError):
        c.seller_orders("open")


def test_seller_orders_non_dict_body(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, []))
    assert c.seller_orders("open") == {"orders": [], "meta": {}}


# ====================================================================
# iter_seller_orders()
# ====================================================================

def test_iter_seller_orders_stops_on_total(monkeypatch):
    c = _client(monkeypatch)
    pages = {
        1: {"orders": [{"id": 1}, {"id": 2}], "meta": {"total": 3}},
        2: {"orders": [{"id": 3}], "meta": {"total": 3}},
    }
    monkeypatch.setattr(c, "seller_orders", lambda sf, page=1: pages[page])
    out = list(c.iter_seller_orders("open"))
    assert [o["id"] for o in out] == [1, 2, 3]


def test_iter_seller_orders_stops_on_empty(monkeypatch):
    c = _client(monkeypatch)
    monkeypatch.setattr(c, "seller_orders", lambda sf, page=1: {"orders": [], "meta": {}})
    assert list(c.iter_seller_orders("open")) == []


def test_iter_seller_orders_no_total_runs_to_max(monkeypatch):
    c = _client(monkeypatch)
    calls = {"n": 0}

    def fake(sf, page=1):
        calls["n"] += 1
        if page <= 2:
            return {"orders": [{"id": page}], "meta": {}}  # no total
        return {"orders": [], "meta": {}}

    monkeypatch.setattr(c, "seller_orders", fake)
    out = list(c.iter_seller_orders("open", max_pages=10))
    assert [o["id"] for o in out] == [1, 2]


# ====================================================================
# seller_order()
# ====================================================================

def test_seller_order_success(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, {"id": "o1"}))
    assert c.seller_order("o1") == {"id": "o1"}
    assert any(o[0] == "seatgeek_seller_pull_log" for o in db.ops)


def test_seller_order_log_swallowed(monkeypatch):
    db = _FakeDB(insert_raises=True)
    c = _client(monkeypatch, db=db)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, {"id": "o1"}))
    assert c.seller_order("o1") == {"id": "o1"}


def test_seller_order_error_hides_details(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(404, {"id": "secret"}))
    with pytest.raises(sg.SeatGeekError) as exc:
        c.seller_order("o1")
    assert "HTTP 404" in str(exc.value)
    assert "secret" not in str(exc.value)


def test_seller_order_non_dict_body(monkeypatch):
    c = _client(monkeypatch)
    _patch_get(monkeypatch, c, lambda *a, **k: _FakeResp(200, []))
    assert c.seller_order("o1") == {}


# ====================================================================
# store_seller_listings()
# ====================================================================

def test_store_seller_listings_noop_without_db(monkeypatch):
    c = _client(monkeypatch)
    assert c.store_seller_listings([{"event_id": 1}]) == {
        "received": 0, "inserted": 0, "events_seen": 0, "events_linked": 0}


def test_store_seller_listings_empty(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    assert c.store_seller_listings([])["received"] == 0


def test_store_seller_listings_full(monkeypatch):
    # rpc returns int tevo id for the first sg event.
    db = _FakeDB(rpc_data=lambda name, params: 777, upsert_data=[{"a": 1}])
    c = _client(monkeypatch, db=db)
    listings = [
        {"event_id": 100, "event": "Show", "venue": "MSG", "event_date": "2026-01-01",
         "event_time": "20:00", "seller_listing_id": "sl1", "ticket_id": "t1",
         "sg_listing_id": "55", "quantity": 2, "section": "A", "row": "1",
         "seat_from": 1, "seat_thru": 2, "notes": "n", "cost": 50,
         "is_edelivery": True, "is_instant": False,
         "in_hand_date": "2026-02-01T00:00:00"},
        {"event_id": "bad"},  # int() fails -> skipped in both loops via except
        {"no_event_id": 1},   # event_id None -> skipped
        {"event_id": 100, "sg_listing_id": None, "in_hand_date": None},  # dup event, None branches
    ]
    out = c.store_seller_listings(listings)
    assert out["received"] == 4
    assert out["inserted"] == 1
    assert out["events_seen"] == 1     # only sg_eid 100 valid+unique
    assert out["events_linked"] == 1
    upsert_op = next(o for o in db.ops if o[1] == "upsert")
    rows = upsert_op[2]
    assert rows[0]["sg_listing_id"] == 55
    assert rows[0]["tevo_event_id"] == 777
    assert rows[0]["in_hand_date"] == "2026-02-01"
    assert rows[1]["sg_listing_id"] is None
    assert rows[1]["in_hand_date"] is None
    # BUGHUNT-1 regression guard: dedup must key on the NON-NULL composite, not
    # (sg_listing_id, content_hash) — the latter never matches NULL sg_listing_id
    # rows (NULL <> NULL) and duplicates on every re-pull. The second listing
    # above has sg_listing_id=None precisely to exercise that case.
    assert upsert_op[3] == "sg_event_id,content_hash"


def test_store_seller_listings_rpc_dict_return(monkeypatch):
    db = _FakeDB(rpc_data=lambda n, p: {"sg_attempt_event_xref": 888}, upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    out = c.store_seller_listings([{"event_id": 5, "sg_listing_id": 1}])
    assert out["events_linked"] == 1
    rows = next(o for o in db.ops if o[1] == "upsert")[2]
    assert rows[0]["tevo_event_id"] == 888


def test_store_seller_listings_rpc_returns_none(monkeypatch):
    db = _FakeDB(rpc_data=lambda n, p: None, upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    out = c.store_seller_listings([{"event_id": 5, "sg_listing_id": 1}])
    assert out["events_linked"] == 0


def test_store_seller_listings_rpc_raises(monkeypatch, capsys):
    db = _FakeDB(rpc_raises=True, upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    out = c.store_seller_listings([{"event_id": 5, "sg_listing_id": 1}])
    assert out["events_linked"] == 0
    assert "sg_attempt_event_xref failed" in capsys.readouterr().out


def test_store_seller_listings_upsert_error(monkeypatch, capsys):
    db = _FakeDB(rpc_data=lambda n, p: 1, upsert_raises=True)
    c = _client(monkeypatch, db=db)
    out = c.store_seller_listings([{"event_id": 5, "sg_listing_id": 1}])
    assert out["inserted"] == 0 and "error" in out
    assert "store_seller_listings failed" in capsys.readouterr().out


# ====================================================================
# store_seller_orders()
# ====================================================================

def test_store_seller_orders_noop_without_db(monkeypatch):
    c = _client(monkeypatch)
    assert c.store_seller_orders([{"id": "o1"}], "open") == {
        "received": 0, "upserted": 0, "tickets_inserted": 0,
        "events_seen": 0, "events_linked": 0}


def test_store_seller_orders_empty(monkeypatch):
    db = _FakeDB()
    c = _client(monkeypatch, db=db)
    assert c.store_seller_orders([], "open")["received"] == 0


def test_store_seller_orders_full(monkeypatch):
    db = _FakeDB(rpc_data=lambda n, p: 999, upsert_data=[{"x": 1}])
    c = _client(monkeypatch, db=db)
    orders = [
        {
            "id": "o1",
            "event": {"seatgeek_event_id": 200, "name": "Show", "venue": "MSG",
                      "date": "2026-01-01", "time": "20:00"},
            "listing": {"id": "L1", "price": 100, "row": "1", "section": "A",
                        "quantity": 2},
            "payment": {"total": 220, "price": 200, "fees": 10, "tax": 5,
                        "delivery": 5},
            "created": "2026-01-01T00:00:00Z",
            "delivery": "edelivery", "delivery_method": "mobile",
            "stock_type": "ELECTRONIC", "tickets": [
                {"section": "A", "row": "1", "seat": "5", "is_ada": False,
                 "ga": False, "obstructed_view": False,
                 "barcode": {"type": "qr", "value": "B1"},
                 "mobile_passes": ["p1"]},
            ],
        },
        {"id": None},  # skipped (no id)
        {"id": "o2", "event": {"seatgeek_event_id": "bad"}, "tickets": []},  # eid int() fails
        {"id": "o3", "event": {}},  # no seatgeek_event_id
    ]
    out = c.store_seller_orders(orders, "open")
    assert out["received"] == 4
    assert out["upserted"] == 1
    assert out["tickets_inserted"] == 1
    assert out["events_seen"] == 1
    assert out["events_linked"] == 1
    order_op = next(o for o in db.ops if o[0] == "seatgeek_orders" and o[1] == "upsert")
    row = order_op[2][0]
    assert row["sg_order_id"] == "o1"
    assert row["tevo_event_id"] == 999
    assert row["created_at_sg"] == "2026-01-01T00:00:00+00:00"
    assert row["payment_total"] == 220
    # ticket delete + insert happened
    assert any(o[0] == "seatgeek_order_tickets" and o[1] == "delete" for o in db.ops)
    assert any(o[0] == "seatgeek_order_tickets" and o[1] == "insert" for o in db.ops)


def test_store_seller_orders_eid_none_in_order_loop(monkeypatch):
    # event present but seatgeek_event_id None -> events_seen skip, and
    # order-loop sg_eid_i None branch (tevo_event_id None).
    db = _FakeDB(upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    out = c.store_seller_orders(
        [{"id": "o1", "event": {"name": "x"}, "tickets": []}], "open")
    assert out["events_seen"] == 0
    row = next(o for o in db.ops if o[0] == "seatgeek_orders")[2][0]
    assert row["tevo_event_id"] is None


def test_store_seller_orders_eid_bad_in_order_loop(monkeypatch):
    # seatgeek_event_id that fails int() inside the order loop -> sg_eid_i None.
    db = _FakeDB(upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    out = c.store_seller_orders(
        [{"id": "o1", "event": {"seatgeek_event_id": "xx"}, "tickets": []}], "open")
    row = next(o for o in db.ops if o[0] == "seatgeek_orders")[2][0]
    assert row["sg_event_id"] is None
    assert row["tevo_event_id"] is None


def test_store_seller_orders_rpc_dict_and_none(monkeypatch):
    seq = iter([{"sg_attempt_event_xref": 11}, None])
    db = _FakeDB(rpc_data=lambda n, p: next(seq), upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    out = c.store_seller_orders([
        {"id": "o1", "event": {"seatgeek_event_id": 1}, "tickets": []},
        {"id": "o2", "event": {"seatgeek_event_id": 2}, "tickets": []},
    ], "open")
    assert out["events_seen"] == 2
    assert out["events_linked"] == 1  # only first resolved


def test_store_seller_orders_rpc_raises(monkeypatch, capsys):
    db = _FakeDB(rpc_raises=True, upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    out = c.store_seller_orders(
        [{"id": "o1", "event": {"seatgeek_event_id": 1}, "tickets": []}], "open")
    assert out["events_linked"] == 0
    assert "sg_attempt_event_xref failed" in capsys.readouterr().out


def test_store_seller_orders_no_tickets_no_delete(monkeypatch):
    db = _FakeDB(upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    # order has no event id at all and empty tickets -> order_rows present,
    # ticket_rows empty -> no insert, but delete runs on sg_oids.
    c.store_seller_orders([{"id": "o1", "tickets": []}], "open")
    assert any(o[0] == "seatgeek_order_tickets" and o[1] == "delete" for o in db.ops)
    assert not any(o[0] == "seatgeek_order_tickets" and o[1] == "insert" for o in db.ops)


def test_store_seller_orders_all_skipped_no_order_rows(monkeypatch):
    db = _FakeDB(upsert_data=[{}])
    c = _client(monkeypatch, db=db)
    # only an order with no id -> order_rows empty -> no upsert, no delete
    out = c.store_seller_orders([{"id": None}], "open")
    assert out["upserted"] == 0
    assert not any(o[0] == "seatgeek_orders" for o in db.ops)
    assert not any(o[0] == "seatgeek_order_tickets" for o in db.ops)


def test_store_seller_orders_db_error(monkeypatch, capsys):
    db = _FakeDB(upsert_raises=True)
    c = _client(monkeypatch, db=db)
    out = c.store_seller_orders(
        [{"id": "o1", "event": {"seatgeek_event_id": 1}, "tickets": []}], "open")
    assert "error" in out
    assert "store_seller_orders failed" in capsys.readouterr().out


def test_iter_seller_listings_stops_when_cursor_does_not_advance(monkeypatch):
    # Regression: a meta that echoes the *current* page_cursor (no next_cursor)
    # used to make the loop re-request the same page for ALL max_pages,
    # re-yielding duplicates each time. The echo is only detectable after the
    # cursor is sent once and comes back unchanged, so the guard caps the damage
    # at a single redundant fetch (2 total) instead of max_pages (5).
    c = _client(monkeypatch)
    calls = []

    def fake_seller_listings(*, per_page, page_cursor):
        calls.append(page_cursor)
        # Always echoes "C1" back as page_cursor, never a next_cursor.
        return {"listings": [{"id": 1}], "meta": {"page_cursor": "C1"}}

    monkeypatch.setattr(c, "seller_listings", fake_seller_listings)
    out = list(c.iter_seller_listings(max_pages=5))
    # Without the guard this would be 5 fetches / 5 dupes. With it: 2 then stop.
    assert calls == [None, "C1"]
    assert out == [{"id": 1}, {"id": 1}]


def test_iter_seller_listings_runs_to_max_pages_when_cursor_advances(monkeypatch):
    # Advancing cursors with full pages: the loop exits by exhausting max_pages
    # (the natural for-loop fall-through), not via a break.
    c = _client(monkeypatch)
    pages = {None: "A", "A": "B"}  # page1->cursor A, page2->cursor B (advances)

    def fake_seller_listings(*, per_page, page_cursor):
        return {"listings": [{"c": page_cursor}], "meta": {"next_cursor": pages.get(page_cursor)}}

    monkeypatch.setattr(c, "seller_listings", fake_seller_listings)
    out = list(c.iter_seller_listings(max_pages=2))
    assert out == [{"c": None}, {"c": "A"}]  # exactly 2 pages, then range exhausts
