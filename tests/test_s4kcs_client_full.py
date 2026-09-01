"""Full line+branch coverage for s4kcs_client. No real HTTP — every
requests.get is monkeypatched at the boundary. Mirrors the house style in
tests/test_bandsintown_client_full.py.
"""
from __future__ import annotations

import pytest
import requests

import s4kcs_client as s4k


# ====================================================================
# Shared fake HTTP response + get patcher
# ====================================================================

class _FakeResp:
    def __init__(self, status, *, json_payload=None, json_raises=False,
                 text="raw-body", headers=None):
        self.status_code = status
        self.ok = 200 <= status < 300
        self._json_payload = json_payload
        self._json_raises = json_raises
        self.text = text
        self.headers = headers or {}

    def json(self):
        if self._json_raises:
            raise ValueError("no json")
        return self._json_payload


def _patch_get(monkeypatch, responses, captured=None):
    if isinstance(responses, _FakeResp):
        seq, single = None, responses
    else:
        seq, single = iter(responses), None

    def fake_get(url, **kwargs):
        if captured is not None:
            captured.append((url, kwargs))
        return single if single is not None else next(seq)

    monkeypatch.setattr(s4k.requests, "get", fake_get)


@pytest.fixture(autouse=True)
def _clear_cache(monkeypatch):
    # The orders cache is module-level by design (it must survive per-request
    # client construction), so each test starts from empty.
    s4k._ORDERS_CACHE.clear()
    monkeypatch.delenv("S4KCS_API_KEY", raising=False)
    yield
    s4k._ORDERS_CACHE.clear()


def _client(**kw):
    return s4k.S4KCSClient("s4k_testkey", **kw)


# ====================================================================
# Key resolution
# ====================================================================

def test_key_from_argument():
    assert _client().api_key == "s4k_testkey"


def test_key_is_stripped():
    # The vault copy under 'crm.s4kcs.com' was seeded with a leading space,
    # which makes the X-API-Key header invalid. Strip defensively.
    assert s4k.S4KCSClient(" s4k_padded ").api_key == "s4k_padded"


def test_key_from_env(monkeypatch):
    monkeypatch.setenv("S4KCS_API_KEY", "env-key")
    assert s4k.S4KCSClient().api_key == "env-key"


class _VaultDB:
    """Minimal supabase-py stand-in for the get_app_secret RPC."""

    def __init__(self, value):
        self._value = value
        self.asked = []

    def rpc(self, name, args):
        self.asked.append((name, args["p_name"]))
        return self

    def execute(self):
        return type("_R", (), {"data": self._value})()


def test_key_from_vault():
    db = _VaultDB("vault-key")
    assert s4k.S4KCSClient(db=db).api_key == "vault-key"
    # One name owns this secret — the EVENUEDESK_API_KEY duplicate was deleted.
    assert db.asked == [("get_app_secret", "crm.s4kcs.com")]


def test_missing_vault_value_falls_through_to_the_missing_key_error():
    with pytest.raises(s4k.S4KCSError):
        s4k.S4KCSClient(db=_VaultDB(None))


def test_missing_key_raises_with_actionable_message():
    with pytest.raises(s4k.S4KCSError) as exc:
        s4k.S4KCSClient()
    assert "S4KCS_API_KEY" in str(exc.value)
    assert "crm.s4kcs.com" in str(exc.value)


# ====================================================================
# RULE 2 read-only guard
# ====================================================================

def test_assert_readonly_raises_on_writes():
    for method in ("POST", "PUT", "PATCH", "DELETE"):
        with pytest.raises(s4k.S4KCSReadOnlyError) as exc:
            s4k._assert_readonly_method(method)
        assert "RULE 2" in str(exc.value)


def test_assert_readonly_allows_get():
    assert s4k._assert_readonly_method("GET") is None


def test_allowed_methods_is_get_only():
    assert s4k.ALLOWED_HTTP_METHODS == frozenset({"GET"})


# ====================================================================
# Transport
# ====================================================================

def test_get_sends_api_key_header_and_drops_none_params(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"ok": True}), captured)
    c = _client()
    assert c.ping() == {"ok": True}
    url, kwargs = captured[0]
    assert url == "https://crm.s4kcs.com/api/v1/ping"
    assert kwargs["headers"]["X-API-Key"] == "s4k_testkey"


def test_get_raises_on_http_error(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(401))
    with pytest.raises(s4k.S4KCSError) as exc:
        _client().ping()
    assert "HTTP 401" in str(exc.value)


def test_get_wraps_network_errors(monkeypatch):
    def boom(url, **kwargs):
        raise requests.ConnectionError("down")

    monkeypatch.setattr(s4k.requests, "get", boom)
    with pytest.raises(s4k.S4KCSError) as exc:
        _client().ping()
    assert "network error" in str(exc.value)


def test_get_falls_back_to_raw_text_on_bad_json(monkeypatch):
    # A 200 that isn't JSON is surfaced, not swallowed — callers can see what
    # the upstream actually sent.
    _patch_get(monkeypatch, _FakeResp(200, json_raises=True, text="not-json"))
    assert _client().ping() == {"raw_text": "not-json"}


# ====================================================================
# Endpoints
# ====================================================================

def test_ping_non_dict_body_coerced(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=["unexpected"]))
    assert _client().ping() == {}


def test_marketplaces(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"marketplaces": [
        {"name": "StubHub", "key": "stubhub", "configured": True}]}))
    assert _client().marketplaces()[0]["name"] == "StubHub"


def test_marketplaces_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=[]))
    assert _client().marketplaces() == []


def test_columns(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"columns": ["source", "id"]}))
    assert _client().columns() == ["source", "id"]


def test_columns_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload="nope"))
    assert _client().columns() == []


# ====================================================================
# orders() — caching
# ====================================================================

_ROWS = {"count": 1, "rows": [{"source": "StubHub", "id": "644308803",
                              "section": "3", "row": "N", "quantity": 2,
                              "price": 870.34}]}


def test_orders_returns_rows_and_passes_window(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS), captured)
    rows = _client().orders(markets="StubHub", ev_from="2026-09-01", ev_to="2026-09-30")
    assert rows[0]["id"] == "644308803"
    assert captured[0][1]["params"] == {
        "markets": "StubHub", "ev_from": "2026-09-01", "ev_to": "2026-09-30"}


def test_orders_memoises_within_ttl(monkeypatch):
    captured = []
    _patch_get(monkeypatch, [_FakeResp(200, json_payload=_ROWS)], captured)
    c = _client()
    assert c.orders() == c.orders()          # second call served from cache
    assert len(captured) == 1                # …and never hit the network again


def test_orders_refetches_after_ttl(monkeypatch):
    captured = []
    _patch_get(monkeypatch, [_FakeResp(200, json_payload=_ROWS),
                             _FakeResp(200, json_payload={"rows": []})], captured)
    c = _client(cache_ttl=0)  # expire immediately
    c.orders()
    assert c.orders() == []
    assert len(captured) == 2


def test_orders_use_cache_false_forces_refetch(monkeypatch):
    captured = []
    _patch_get(monkeypatch, [_FakeResp(200, json_payload=_ROWS),
                             _FakeResp(200, json_payload={"rows": []})], captured)
    c = _client()
    c.orders()
    assert c.orders(use_cache=False) == []
    assert len(captured) == 2


def test_orders_non_dict_body(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=["surprise"]))
    assert _client().orders() == []


def test_orders_non_list_rows(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"rows": "nope"}))
    assert _client().orders() == []


# ====================================================================
# find_order()
# ====================================================================

def test_find_order_matches_by_id(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS))
    row = _client().find_order("644308803")
    assert row["source"] == "StubHub" and row["row"] == "N"


def test_find_order_tolerates_padding_and_ints(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS))
    c = _client()
    assert c.find_order("  644308803  ") is not None
    assert c.find_order(644308803) is not None  # served from cache


def test_find_order_returns_none_when_absent(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS))
    assert _client().find_order("999") is None


def test_find_order_blank_id_never_fetches(monkeypatch):
    captured = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload=_ROWS), captured)
    assert _client().find_order("   ") is None
    assert captured == []


def test_find_order_skips_rows_without_an_id(monkeypatch):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"rows": [
        {"source": "Gametime"}, {"source": "StubHub", "id": "7"}]}))
    assert _client().find_order("7")["source"] == "StubHub"
