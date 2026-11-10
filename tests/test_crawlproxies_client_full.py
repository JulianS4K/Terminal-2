"""Tests for crawlproxies_client. No real HTTP — requests.get is monkeypatched
at the boundary (house style: tests/test_bandsintown_client_full.py)."""
from __future__ import annotations

import pytest
import requests

import crawlproxies_client as cp


class _FakeResp:
    def __init__(self, status, *, json_payload=None, json_raises=False,
                 text="", headers=None):
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
    seq = iter(responses if isinstance(responses, list) else [responses] * 50)

    def fake_get(url, **kwargs):
        if captured is not None:
            captured.append((url, kwargs))
        return next(seq)

    monkeypatch.setattr(cp.requests, "get", fake_get)
    monkeypatch.setattr(cp.time, "sleep", lambda s: None)


@pytest.fixture
def client(monkeypatch):
    monkeypatch.delenv("CRAWLPROXIES_API_KEY", raising=False)
    return cp.CrawlProxiesClient("  crawl_user_test  ")


# ---------- key resolution ----------

def test_key_from_argument_is_stripped(client):
    assert client.api_key == "crawl_user_test"


def test_key_from_env(monkeypatch):
    monkeypatch.setenv("CRAWLPROXIES_API_KEY", "crawl_user_env")
    assert cp.CrawlProxiesClient().api_key == "crawl_user_env"


def test_key_from_vault(monkeypatch):
    monkeypatch.delenv("CRAWLPROXIES_API_KEY", raising=False)
    seen = {}

    class _Rpc:
        def execute(self):
            return type("R", (), {"data": "crawl_user_vault"})()

    class _Db:
        def rpc(self, name, args):
            seen["call"] = (name, args)
            return _Rpc()

    c = cp.CrawlProxiesClient(db=_Db())
    assert c.api_key == "crawl_user_vault"
    assert seen["call"] == ("get_app_secret", {"p_name": "CRAWLPROXIES_API_KEY"})


def test_missing_key_raises(monkeypatch):
    monkeypatch.delenv("CRAWLPROXIES_API_KEY", raising=False)
    with pytest.raises(cp.CrawlProxiesError, match="CRAWLPROXIES_API_KEY not found"):
        cp.CrawlProxiesClient()


# ---------- transport ----------

def test_account_sends_bearer_and_hits_v1(monkeypatch, client):
    cap = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"username": "u", "balance_cents": 2450}), cap)
    assert client.get_account()["balance_cents"] == 2450
    url, kw = cap[0]
    assert url == "https://crawlproxies.com/api/user/v1/account"
    assert kw["headers"]["Authorization"] == "Bearer crawl_user_test"
    assert kw["params"] == {}


def test_error_surfaces_detail_and_status(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(401, json_payload={"detail": "missing or revoked key"}))
    with pytest.raises(cp.CrawlProxiesError) as exc:
        client.get_account()
    assert exc.value.status_code == 401
    assert "revoked key" in str(exc.value)
    assert "crawl_user_test" not in str(exc.value)


def test_422_detail_list_is_flattened(monkeypatch, client):
    body = {"detail": [{"loc": ["query", "limit"], "msg": "too big", "type": "x"}]}
    _patch_get(monkeypatch, _FakeResp(422, json_payload=body))
    with pytest.raises(cp.CrawlProxiesError, match=r"query\.limit: too big"):
        client.list_plans()


def test_429_is_retried(monkeypatch, client):
    cap = []
    _patch_get(monkeypatch, [_FakeResp(429, headers={"Retry-After": "1"}),
                             _FakeResp(200, json_payload={"ok": 1})], cap)
    assert client.get_account() == {"ok": 1}
    assert len(cap) == 2


def test_network_error_wrapped(monkeypatch, client):
    def boom(url, **kw):
        raise requests.ConnectionError("down")
    monkeypatch.setattr(cp.requests, "get", boom)
    with pytest.raises(cp.CrawlProxiesError, match="network error: ConnectionError"):
        client.get_account()


def test_non_json_body_raises(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(200, json_raises=True, text="<html>"))
    with pytest.raises(cp.CrawlProxiesError, match="not JSON"):
        client.get_account()


# ---------- plans ----------

def test_list_plans_params_and_validation(monkeypatch, client):
    cap = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"plans": [], "total": 0}), cap)
    client.list_plans(status="active", limit=10, offset=20)
    assert cap[0][1]["params"] == {"status": "active", "limit": 10, "offset": 20}
    with pytest.raises(cp.CrawlProxiesError):
        client.list_plans(status="provisioning")


def test_iter_plans_paginates(monkeypatch, client):
    pages = [
        _FakeResp(200, json_payload={"plans": [{"plan_id": "a"}, {"plan_id": "b"}], "total": 3}),
        _FakeResp(200, json_payload={"plans": [{"plan_id": "c"}], "total": 3}),
    ]
    cap = []
    _patch_get(monkeypatch, pages, cap)
    assert [p["plan_id"] for p in client.iter_plans(page_size=2)] == ["a", "b", "c"]
    assert [kw["params"]["offset"] for _, kw in cap] == [0, 2]


def test_plan_id_is_path_encoded(monkeypatch, client):
    cap = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"plan_id": "x"}), cap)
    client.get_plan("plan_a/../b")
    assert cap[0][0].endswith("/plans/plan_a%2F..%2Fb")
    with pytest.raises(cp.CrawlProxiesError, match="plan_id is required"):
        client.get_plan("  ")


def test_usage_params_and_validation(monkeypatch, client):
    cap = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"points": []}), cap)
    client.get_plan_usage("plan_1", range="7d", utc_offset_minutes=-300)
    assert cap[0][0].endswith("/plans/plan_1/usage")
    assert cap[0][1]["params"] == {"range": "7d", "utc_offset_minutes": -300}
    with pytest.raises(cp.CrawlProxiesError):
        client.get_plan_usage("plan_1", range="90d")
    with pytest.raises(cp.CrawlProxiesError):
        client.get_plan_usage("plan_1", utc_offset_minutes=900)


# ---------- proxy list ----------

def test_proxy_list_json(monkeypatch, client):
    cap = []
    body = {"proxies": ["203.0.113.10:777:U:P"], "count": 1, "total": 50, "stale": False}
    _patch_get(monkeypatch, _FakeResp(200, json_payload=body), cap)
    assert client.get_proxy_list("plan_dc", limit="all", shuffle=True) == body
    assert cap[0][1]["params"] == {"protocol": "http", "limit": "all",
                                   "shuffle": "true", "format": "json"}


def test_proxy_list_text_format_uses_headers(monkeypatch, client):
    cap = []
    resp = _FakeResp(200, text="203.0.113.10:666\n203.0.113.11:666\n",
                     headers={"X-Count": "2", "X-Total": "40", "X-Stale": "true"})
    _patch_get(monkeypatch, resp, cap)
    out = client.get_proxy_list("plan_dc", protocol="socks5", format="hostport", limit=2)
    assert out["proxies"] == ["203.0.113.10:666", "203.0.113.11:666"]
    assert (out["count"], out["total"], out["stale"]) == (2, 40, True)
    assert cap[0][1]["headers"]["Accept"] == "text/plain"


def test_proxy_list_validation(client):
    for kw in ({"limit": 0}, {"limit": "many"}, {"protocol": "https"}, {"format": "csv"}):
        with pytest.raises(cp.CrawlProxiesError):
            client.get_proxy_list("plan_dc", **kw)


def test_proxy_list_409_not_datacenter(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(409, json_payload={"detail": "Not an active Datacenter plan."}))
    with pytest.raises(cp.CrawlProxiesError) as exc:
        client.get_proxy_list("plan_res")
    assert exc.value.status_code == 409


# ---------- billing ----------

def test_transactions_and_payments(monkeypatch, client):
    cap = []
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"transactions": [], "payments": []}), cap)
    client.list_transactions(type="refund", limit=5)
    client.list_payments(offset=10)
    assert cap[0][0].endswith("/transactions")
    assert cap[0][1]["params"] == {"type": "refund", "limit": 5, "offset": 0}
    assert cap[1][0].endswith("/payments")
    assert cap[1][1]["params"] == {"limit": 50, "offset": 10}
    with pytest.raises(cp.CrawlProxiesError):
        client.list_transactions(type="chargeback")


def test_iter_payments_stops_on_short_page(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(200, json_payload={"payments": [{"id": "p1"}], "total": None}))
    assert [p["id"] for p in client.iter_payments(page_size=5)] == ["p1"]


# ---------- proxy wiring helpers ----------

def test_requests_proxies_http_and_socks():
    http = cp.requests_proxies("203.0.113.10:777:us er:p@ss:w")
    assert http["http"] == "http://us%20er:p%40ss%3Aw@203.0.113.10:777"
    assert http["https"] == http["http"]
    socks = cp.requests_proxies("203.0.113.10:666:u:p", "socks5")
    assert socks["https"] == "socks5h://u:p@203.0.113.10:666"
    with pytest.raises(cp.CrawlProxiesError):
        cp.requests_proxies("203.0.113.10:777")


def test_gateway_proxies():
    plan = {"proxy_username": "u", "proxy_password": "p",
            "connection": {"hostname": "geo.crawlproxies.com", "port_http": 8080, "port_socks": 1080}}
    assert cp.gateway_proxies(plan)["http"] == "http://u:p@geo.crawlproxies.com:8080"
    assert cp.gateway_proxies(plan, "socks5")["http"] == "socks5h://u:p@geo.crawlproxies.com:1080"
    with pytest.raises(cp.CrawlProxiesError, match="Datacenter"):
        cp.gateway_proxies({"connection": {"mode": "ip_list"}})
    with pytest.raises(cp.CrawlProxiesError, match="no usable gateway"):
        cp.gateway_proxies({"connection": {"hostname": "h"}})


def test_error_with_non_json_body_uses_text(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(502, json_raises=True, text="  Bad Gateway  "))
    with pytest.raises(cp.CrawlProxiesError, match="HTTP 502: Bad Gateway"):
        client.get_account()


def test_error_without_detail_key(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(500, json_payload=["oops"]))
    with pytest.raises(cp.CrawlProxiesError, match=r"HTTP 500: \['oops'\]"):
        client.get_account()


def test_detail_list_with_non_dict_items(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(422, json_payload={"detail": ["bad"]}))
    with pytest.raises(cp.CrawlProxiesError, match="HTTP 422: bad"):
        client.get_account()


def test_iter_transactions_unfiltered_paginates(monkeypatch, client):
    cap = []
    _patch_get(monkeypatch, [
        _FakeResp(200, json_payload={"transactions": [{"id": "t1"}], "total": 2}),
        _FakeResp(200, json_payload={"transactions": [{"id": "t2"}], "total": 2}),
    ], cap)
    assert [t["id"] for t in client.iter_transactions(page_size=1)] == ["t1", "t2"]
    assert "type" not in cap[0][1]["params"]


def test_non_dict_json_body_returns_empty(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(200, json_payload=[1, 2]))
    assert client.get_account() == {}


def test_proxy_list_text_without_headers(monkeypatch, client):
    _patch_get(monkeypatch, _FakeResp(200, text="a:1:u:p\n\nb:1:u:p", headers={}))
    out = client.get_proxy_list("plan_dc", format="standard")
    assert (out["count"], out["total"], out["stale"]) == (2, None, False)


def test_key_falls_back_to_operator_vault_name(monkeypatch):
    monkeypatch.delenv("CRAWLPROXIES_API_KEY", raising=False)
    asked = []

    class _Rpc:
        def __init__(self, name):
            self.name = name

        def execute(self):
            return type("R", (), {"data": "crawl_user_x" if self.name == "crawlproxies" else None})()

    class _Db:
        def rpc(self, fn, args):
            asked.append(args["p_name"])
            return _Rpc(args["p_name"])

    assert cp.CrawlProxiesClient(db=_Db()).api_key == "crawl_user_x"
    assert asked == ["CRAWLPROXIES_API_KEY", "crawlproxies"]
