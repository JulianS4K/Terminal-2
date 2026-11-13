"""StubHub API wiring — stubhub_client.py + routers/stubhub_oauth.py.

Operator 2026-11-13: "wire the api but keep turned off and read only till we get tokens".
These tests pin the three promises: OFF by default, read-only (GET + read:* scopes),
and the connect flow never handling a secret. No real HTTP call is made.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
testclient = pytest.importorskip("fastapi.testclient")

from fastapi import FastAPI  # noqa: E402

import stubhub_client as shc  # noqa: E402
from routers.stubhub_oauth import build_stubhub_oauth_router  # noqa: E402


# ---------- client: off by default ----------

def test_client_refuses_while_switched_off(monkeypatch):
    monkeypatch.delenv("STUBHUB_API_ENABLED", raising=False)
    with pytest.raises(shc.StubHubDisabledError):
        shc.StubHubClient(access_token="t" * 20)


def test_client_needs_a_token_when_on(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    monkeypatch.delenv("STUBHUB_ACCESS_TOKEN", raising=False)
    with pytest.raises(shc.StubHubError):
        shc.StubHubClient(db=None)


# ---------- client: read-only ----------

def test_scopes_are_read_only():
    assert shc.assert_read_scopes("read:sales read:sellerlistings") == ["read:sales", "read:sellerlistings"]
    for bad in ("write:sales", "read:sales write:sellerlistings", "write:webhooks", "read:anything"):
        with pytest.raises(shc.StubHubReadOnlyError):
            shc.assert_read_scopes(bad)
    assert all(s.startswith("read:") for s in shc.READ_SCOPES)


class _Resp:
    def __init__(self, status=200, body=None):
        self.status_code, self._body = status, body if body is not None else {"ok": True}
        self.ok = 200 <= status < 300
        self.text = ""

    def json(self):
        return self._body


def test_get_is_a_bearer_get_on_the_api_root(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    monkeypatch.delenv("STUBHUB_ENV", raising=False)
    seen = {}

    def fake_get(url, headers=None, params=None, timeout=None):
        seen.update(url=url, headers=headers, params=params)
        return _Resp(200, {"items": []})

    monkeypatch.setattr(shc.requests, "get", fake_get)
    c = shc.StubHubClient(access_token="tok123")
    assert c.sales(page=2, page_size=None) == {"items": []}
    assert seen["url"] == "https://api.stubhub.net/v2/sales"
    assert seen["headers"]["Authorization"] == "Bearer tok123"
    assert seen["params"] == {"page": 2}
    c.sale("A/1")
    assert seen["url"] == "https://api.stubhub.net/v2/sales/A%2F1"
    c.seller_listings()
    assert seen["url"] == "https://api.stubhub.net/v2/sellerlistings"


def test_sandbox_root_and_bad_paths(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    monkeypatch.setenv("STUBHUB_ENV", "sandbox")
    c = shc.StubHubClient(access_token="tok123")
    assert c.base_url == "https://sandbox.api.stubhub.net/v2"
    for bad in ("sales", "https://evil.example/x", "//evil.example/x"):
        with pytest.raises(shc.StubHubError):
            c.get(bad)


def test_http_error_raises(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    monkeypatch.setattr(shc.requests, "get", lambda *a, **k: _Resp(401))
    with pytest.raises(shc.StubHubError):
        shc.StubHubClient(access_token="tok123").sales()


def test_client_has_no_write_methods():
    names = {n.lower().lstrip("_") for n in dir(shc.StubHubClient) if not n.startswith("__")}
    verbs = ("post", "put", "patch", "delete", "create", "update", "confirm", "fulfil", "upload", "send", "list_")
    assert not [n for n in names if n.startswith(verbs)]


# ---------- router ----------

class _Exec:
    def __init__(self, data=None, exc=None):
        self._data, self._exc = data, exc

    def execute(self):
        if self._exc:
            raise self._exc
        return type("R", (), {"data": self._data})()


class _Table:
    def __init__(self, row):
        self.row = row

    def select(self, *_a, **_k):
        return self

    def limit(self, *_a):
        return _Exec([self.row])


class FakeDB:
    def __init__(self, rpc_data=None, rpc_exc=None):
        self.calls = []
        self.rpc_data, self.rpc_exc = rpc_data, rpc_exc

    def rpc(self, fn, params):
        self.calls.append((fn, params))
        return _Exec(self.rpc_data, self.rpc_exc)

    def table(self, name):
        return _Table({"enabled": False} if name == "stubhub_api_config" else {"expires_at": None})


def _client(db):
    app = FastAPI()
    app.include_router(build_stubhub_oauth_router(get_require_sb=lambda: (lambda: db),
                                                  require_auth=lambda: {"email": "op@s4kent.com"}))
    return testclient.TestClient(app)


GOOD_STATE = "ab" * 24


def test_router_is_off_by_default(monkeypatch):
    monkeypatch.delenv("STUBHUB_API_ENABLED", raising=False)
    db = FakeDB(rpc_data="https://account.stubhub.com/authorize?x=1")
    c = _client(db)
    assert c.get("/api/admin/stubhub/connect").status_code == 503
    r = c.get(f"/api/stubhub/oauth/callback?code=abc&state={GOOD_STATE}")
    assert r.status_code == 503
    assert db.calls == []          # nothing reached the DB, so nothing reached StubHub
    s = c.get("/api/admin/stubhub/status").json()
    assert s["env_switch_on"] is False and s["config"]["enabled"] is False


def test_connect_returns_the_authorize_url(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    db = FakeDB(rpc_data="https://account.stubhub.com/authorize?client_id=c&scope=read:sales")
    r = _client(db).get("/api/admin/stubhub/connect")
    assert r.status_code == 200 and r.json()["authorize_url"].startswith("https://account.stubhub.com/authorize")
    assert db.calls == [("stubhub_oauth_begin", {"p_created_by": "op@s4kent.com"})]


def test_connect_explains_a_switched_off_config(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    db = FakeDB(rpc_exc=Exception("StubHub API is switched off (stubhub_api_config.enabled = false)"))
    r = _client(db).get("/api/admin/stubhub/connect")
    assert r.status_code == 409 and "switched off" in r.json()["detail"]


def test_callback_passes_state_and_code_and_reports(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    db = FakeDB(rpc_data="connected")
    r = _client(db).get(f"/api/stubhub/oauth/callback?code=the-code&state={GOOD_STATE}")
    assert r.status_code == 200 and "StubHub connected" in r.text
    assert db.calls == [("stubhub_oauth_complete", {"p_state": GOOD_STATE, "p_code": "the-code"})]


def test_callback_rejects_bad_state_without_a_db_call(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    db = FakeDB(rpc_data="connected")
    c = _client(db)
    assert c.get("/api/stubhub/oauth/callback?code=x&state=not-hex").status_code == 400
    assert c.get(f"/api/stubhub/oauth/callback?state={GOOD_STATE}").status_code == 400
    assert c.get("/api/stubhub/oauth/callback?error=access_denied").status_code == 400
    assert db.calls == []


def test_callback_reports_refused_write_scope_and_hides_db_errors(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    r = _client(FakeDB(rpc_data="write_scope_refused")).get(
        f"/api/stubhub/oauth/callback?code=x&state={GOOD_STATE}")
    assert r.status_code == 400 and "read-only" in r.text
    r = _client(FakeDB(rpc_exc=Exception("relation secret_thing does not exist"))).get(
        f"/api/stubhub/oauth/callback?code=x&state={GOOD_STATE}")
    assert r.status_code == 502 and "secret_thing" not in r.text


# ---------- coverage of the remaining client + router branches ----------

def test_explicit_env_choice_overrides_env_var(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    monkeypatch.setenv("STUBHUB_ENV", "sandbox")
    assert shc.StubHubClient(access_token="t", sandbox=False).base_url == shc.StubHubClient.PROD_BASE_URL
    monkeypatch.setenv("STUBHUB_ENV", "production")
    assert shc.StubHubClient(access_token="t", sandbox=True).base_url == shc.StubHubClient.SANDBOX_BASE_URL


def test_network_error_and_non_json_body(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")

    def boom(*_a, **_k):
        raise shc.requests.ConnectionError("down")

    monkeypatch.setattr(shc.requests, "get", boom)
    with pytest.raises(shc.StubHubError) as exc:
        shc.StubHubClient(access_token="t").sales()
    assert "network error" in str(exc.value)

    class _Text(_Resp):
        def json(self):
            raise ValueError("not json")

    monkeypatch.setattr(shc.requests, "get", lambda *a, **k: _Text(200))
    assert shc.StubHubClient(access_token="t").sales() == {"raw_text": ""}


def test_recent_updates_and_single_listing_paths(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    monkeypatch.delenv("STUBHUB_ENV", raising=False)
    seen = []
    monkeypatch.setattr(shc.requests, "get", lambda url, **_k: seen.append(url) or _Resp(200, {}))
    c = shc.StubHubClient(access_token="t")
    c.sales_recent_updates()
    c.seller_listing(42)
    assert seen == ["https://api.stubhub.net/v2/sales/recentupdates",
                    "https://api.stubhub.net/v2/sellerlistings/42"]


def test_vault_lookup_failure_is_reported_without_the_value(monkeypatch, capsys):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    monkeypatch.delenv("STUBHUB_ACCESS_TOKEN", raising=False)

    class _BadDB:
        def rpc(self, *_a, **_k):
            raise PermissionError("secret STUBHUB_ACCESS_TOKEN is not in the app whitelist")

    with pytest.raises(shc.StubHubError):
        shc.StubHubClient(db=_BadDB())
    out = capsys.readouterr().out
    assert "vault lookup failed: PermissionError" in out and "whitelist" not in out


def test_connect_rejects_a_non_https_authorize_url(monkeypatch):
    monkeypatch.setenv("STUBHUB_API_ENABLED", "1")
    r = _client(FakeDB(rpc_data=None)).get("/api/admin/stubhub/connect")
    assert r.status_code == 502
