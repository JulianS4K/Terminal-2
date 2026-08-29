"""Behavioural tests for the S4K Marketplace Orders client.

Covers the transport contract that matters for a read-only upstream: the key
never leaves the header, auth failures are terminal rather than retried, 429
honours the server's Retry-After, and partial-success responses are reported
honestly. No test makes a real HTTP call.

RULE-2 guard assertions live in tests/test_readonly_guards.py alongside the
other clients; this file is the endpoint/error-path suite.
"""
from __future__ import annotations

import pytest
import requests

from s4k_marketplace_client import (
    MARKETS,
    ORDER_COLUMNS,
    PATHS,
    S4KMarketplaceAuthError,
    S4KMarketplaceClient,
    S4KMarketplaceError,
    S4KMarketplaceRateLimited,
    _vault_secret,
    sources_covered,
)


class FakeResp:
    def __init__(self, status_code=200, payload=None, text="", headers=None,
                 bad_json=False):
        self.status_code = status_code
        self._payload = payload if payload is not None else {"ok": True}
        self.text = text
        self.headers = headers or {}
        self._bad_json = bad_json

    def json(self):
        if self._bad_json:
            raise ValueError("not json")
        return self._payload


@pytest.fixture(autouse=True)
def _no_sleep(monkeypatch):
    """Retry backoff must not actually sleep during tests."""
    monkeypatch.setattr("s4k_marketplace_client.time.sleep", lambda *_: None)


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("S4K_MARKETPLACE_API_KEY", "s4k_TESTKEY_NOT_REAL")
    return S4KMarketplaceClient()


def _responder(client, monkeypatch, responses):
    """Queue a list of FakeResp/exceptions; record each call's kwargs."""
    calls = []
    seq = list(responses)

    def _get(url, headers=None, params=None, timeout=None):
        calls.append({"url": url, "headers": headers or {}, "params": params,
                      "timeout": timeout})
        item = seq.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    monkeypatch.setattr(client._session, "get", _get)
    return calls


# ---------- construction / credential resolution ----------

def test_api_key_prefers_explicit_arg_over_env(monkeypatch):
    monkeypatch.setenv("S4K_MARKETPLACE_API_KEY", "from_env")
    assert S4KMarketplaceClient("explicit").api_key == "explicit"


def test_api_key_falls_back_to_vault_when_env_absent(monkeypatch):
    monkeypatch.delenv("S4K_MARKETPLACE_API_KEY", raising=False)

    class _DB:
        def rpc(self, *_a, **_k):
            class _R:
                data = "from_vault"

                def execute(self_inner):
                    return self_inner
            return _R()

    assert S4KMarketplaceClient(db=_DB()).api_key == "from_vault"


def test_vault_secret_reports_failure_without_leaking_value(capsys):
    class _DB:
        def rpc(self, *_a, **_k):
            raise RuntimeError("boom")

    assert _vault_secret(_DB(), "SOME_KEY") is None
    out = capsys.readouterr().out
    assert "vault lookup for SOME_KEY failed" in out


def test_base_url_overridable_by_arg_and_env(monkeypatch):
    monkeypatch.setenv("S4K_MARKETPLACE_API_KEY", "k")
    monkeypatch.setenv("S4K_MARKETPLACE_BASE_URL", "https://env.example/")
    assert S4KMarketplaceClient().base_url == "https://env.example"
    assert S4KMarketplaceClient(base_url="https://arg.example/").base_url == "https://arg.example"


def test_default_base_url_is_the_crm_host(monkeypatch):
    monkeypatch.setenv("S4K_MARKETPLACE_API_KEY", "k")
    monkeypatch.delenv("S4K_MARKETPLACE_BASE_URL", raising=False)
    assert S4KMarketplaceClient().base_url == "https://crm.s4kcs.com"


# ---------- transport contract ----------

def test_key_is_sent_as_header_and_never_in_url_or_params(client, monkeypatch):
    calls = _responder(client, monkeypatch, [FakeResp()])
    client.ping()
    c = calls[0]
    assert c["headers"]["X-API-Key"] == "s4k_TESTKEY_NOT_REAL"
    assert "s4k_TESTKEY_NOT_REAL" not in c["url"]
    assert "s4k_TESTKEY_NOT_REAL" not in str(c["params"])
    assert c["url"] == "https://crm.s4kcs.com/api/v1/ping"


@pytest.mark.parametrize("status", [401, 403])
def test_auth_failures_are_terminal_and_not_retried(client, monkeypatch, status):
    """A revoked/expired key must stop the caller — retrying cannot help, and
    hammering a rejected key is how a key gets banned."""
    calls = _responder(client, monkeypatch, [FakeResp(status_code=status)])
    with pytest.raises(S4KMarketplaceAuthError):
        client.ping()
    assert len(calls) == 1


def test_429_honours_retry_after_then_succeeds(client, monkeypatch):
    slept = []
    monkeypatch.setattr("s4k_marketplace_client.time.sleep", slept.append)
    _responder(client, monkeypatch, [
        FakeResp(status_code=429, headers={"Retry-After": "7"}),
        FakeResp(payload={"ok": True}),
    ])
    assert client.ping() == {"ok": True}
    assert slept == [7]


def test_429_with_unparseable_retry_after_falls_back_to_backoff(client, monkeypatch):
    slept = []
    monkeypatch.setattr("s4k_marketplace_client.time.sleep", slept.append)
    _responder(client, monkeypatch, [
        FakeResp(status_code=429, headers={"Retry-After": "soon"}),
        FakeResp(payload={"ok": True}),
    ])
    assert client.ping() == {"ok": True}
    assert slept == [1]


def test_429_exhausted_raises_with_retry_after(client, monkeypatch):
    _responder(client, monkeypatch, [
        FakeResp(status_code=429, headers={"Retry-After": "3"}),
        FakeResp(status_code=429, headers={"Retry-After": "3"}),
        FakeResp(status_code=429, headers={"Retry-After": "3"}),
    ])
    with pytest.raises(S4KMarketplaceRateLimited) as exc:
        client.ping()
    assert exc.value.retry_after == 3


def test_5xx_is_retried_then_succeeds(client, monkeypatch):
    calls = _responder(client, monkeypatch, [
        FakeResp(status_code=503), FakeResp(payload={"ok": True}),
    ])
    assert client.ping() == {"ok": True}
    assert len(calls) == 2


def test_5xx_on_final_attempt_raises(client, monkeypatch):
    _responder(client, monkeypatch, [FakeResp(status_code=502)] * 3)
    with pytest.raises(S4KMarketplaceError, match="returned 502"):
        client.ping()


def test_other_4xx_raises_immediately(client, monkeypatch):
    calls = _responder(client, monkeypatch, [FakeResp(status_code=404)])
    with pytest.raises(S4KMarketplaceError, match="returned 404"):
        client.ping()
    assert len(calls) == 1


def test_network_error_is_retried_then_succeeds(client, monkeypatch):
    calls = _responder(client, monkeypatch, [
        requests.RequestException("conn reset"), FakeResp(payload={"ok": True}),
    ])
    assert client.ping() == {"ok": True}
    assert len(calls) == 2


def test_network_error_exhausted_raises_without_leaking_request_repr(client, monkeypatch):
    """The requests exception repr can carry headers — and therefore the key —
    so the raised message must name only the type and path."""
    _responder(client, monkeypatch, [requests.RequestException("s4k_TESTKEY_NOT_REAL leaked")] * 3)
    with pytest.raises(S4KMarketplaceError) as exc:
        client.ping()
    assert "s4k_TESTKEY_NOT_REAL" not in str(exc.value)
    assert "RequestException" in str(exc.value)


def test_non_json_body_raises(client, monkeypatch):
    _responder(client, monkeypatch, [FakeResp(bad_json=True)])
    with pytest.raises(S4KMarketplaceError, match="non-JSON"):
        client.ping()


def test_missing_key_fails_closed_before_any_request(monkeypatch):
    monkeypatch.delenv("S4K_MARKETPLACE_API_KEY", raising=False)
    c = S4KMarketplaceClient(db=None)

    def _boom(*_a, **_k):  # pragma: no cover - must never be reached
        raise AssertionError("a request was made without a key")

    monkeypatch.setattr(c._session, "get", _boom)
    with pytest.raises(S4KMarketplaceAuthError):
        c.ping()


def test_live_fetch_gets_a_longer_timeout_than_metadata(client, monkeypatch):
    calls = _responder(client, monkeypatch, [FakeResp(), FakeResp(), FakeResp()])
    client.ping()
    client.orders()
    client.orders_for_market("gametime")
    assert calls[0]["timeout"] == client.DEFAULT_TIMEOUT
    # Both the exact path and the per-market path take the live-fetch timeout.
    assert calls[1]["timeout"] == client.LIVE_FETCH_TIMEOUT
    assert calls[2]["timeout"] == client.LIVE_FETCH_TIMEOUT


# ---------- endpoints ----------

def test_metadata_endpoints_hit_their_documented_paths(client, monkeypatch):
    calls = _responder(client, monkeypatch, [FakeResp() for _ in range(5)])
    client.marketplaces()
    client.columns()
    client.schedule()
    client.exports()
    client.ping()
    paths = [c["url"].rsplit("/api/v1", 1)[1] for c in calls]
    assert paths == [PATHS["marketplaces"], PATHS["columns"], PATHS["schedule"],
                     PATHS["exports"], PATHS["ping"]]


def test_export_latest_returns_raw_csv_text(client, monkeypatch):
    calls = _responder(client, monkeypatch, [FakeResp(text="a,b\n1,2\n")])
    assert client.export_latest_csv() == "a,b\n1,2\n"
    assert calls[0]["headers"]["Accept"] == "text/csv"


def test_orders_forwards_only_supplied_filters(client, monkeypatch):
    calls = _responder(client, monkeypatch, [FakeResp(), FakeResp()])
    client.orders(markets="TickPick,StubHub", ev_from="2026-09-01")
    assert calls[0]["params"] == {"markets": "TickPick,StubHub", "ev_from": "2026-09-01"}
    client.orders()
    assert calls[1]["params"] is None


def test_orders_for_market_slugifies_and_rejects_empty(client, monkeypatch):
    calls = _responder(client, monkeypatch, [FakeResp()])
    client.orders_for_market("Vivid Seats")
    assert calls[0]["url"].endswith("/marketplace/orders/vivid_seats")
    with pytest.raises(S4KMarketplaceError, match="market is required"):
        client.orders_for_market("  ")


# ---------- partial-success semantics ----------

def test_sources_covered_excludes_only_errored_markets():
    payload = {"rows": [], "errors": [{"market": "StubHub", "error": "HTTP 401"}]}
    covered = sources_covered(payload)
    assert "StubHub" not in covered
    assert covered == set(MARKETS) - {"StubHub"}


def test_sources_covered_is_case_insensitive_and_handles_no_errors():
    assert sources_covered({"rows": [], "errors": []}) == set(MARKETS)
    assert "Vivid Seats" not in sources_covered(
        {"rows": [], "errors": [{"market": "vivid seats"}]})


def test_sources_covered_tolerates_missing_and_null_error_entries():
    """A 200 with a malformed errors[] must not crash the reconciliation —
    treating it as 'everything covered' would be the dangerous read, so an
    unnamed error simply removes nothing rather than silently widening scope."""
    assert sources_covered({"rows": []}) == set(MARKETS)
    assert sources_covered({"rows": [], "errors": [None, {}]}) == set(MARKETS)


def test_order_columns_matches_the_live_contract():
    """Guards against a silent column rename upstream; the live
    /marketplace/columns response was captured 2026-08-29."""
    assert ORDER_COLUMNS[0] == "source"
    assert "purchase_date" in ORDER_COLUMNS
    assert len(ORDER_COLUMNS) == 19
    assert len(MARKETS) == 6
