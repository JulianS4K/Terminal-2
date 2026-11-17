"""Tests for the API-only sub finder service (core/subs_only.py).

Pins: it serves the same router and nothing else, builds its database client once and only when
both settings are present, limits callers by their own address, and leaves /healthz alone.
"""
from __future__ import annotations

import pytest

fastapi = pytest.importorskip("fastapi")
from fastapi.testclient import TestClient  # noqa: E402

from core import subs_only as so  # noqa: E402
from routers.mcp_api import hash_key  # noqa: E402

KEY = "s4k_ext_test"
ENV = {"SUPABASE_URL": "https://example.invalid", "SUPABASE_SERVICE_ROLE_KEY": "k"}


class _Rpc:
    def __init__(self, db, name, args):
        self.db, self.name, self.args = db, name, args

    def execute(self):
        self.db.rpcs.append(self.name)
        if self.name == "mcp_verify_key":
            ok = self.args["p_key_hash"] == hash_key(KEY)
            return type("R", (), {"data": [{"id": 5, "label": "crm sub finder read"}] if ok else []})()
        return type("R", (), {"data": {"mcp_count_call": None, "sub_finder_key_gate": {"account_id": 4},
                                       "sub_finder_access": {"find": True}}.get(self.name)})()


class _DB:
    def __init__(self):
        self.rpcs = []

    def rpc(self, name, args):
        return _Rpc(self, name, args)


def test_window_limiter_allows_n_per_window_and_forgets_old_calls():
    now = [100.0]
    lim = so.WindowLimiter(clock=lambda: now[0])
    assert [lim.check("a", 2, 60.0) for _ in range(3)] == [True, True, False]
    assert lim.check("b", 2, 60.0)                       # another key has its own window
    now[0] += 61
    assert lim.check("a", 2, 60.0)                       # the old calls have aged out


def test_the_service_is_the_sub_finder_router_and_a_health_route_only():
    made = []
    db = _DB()
    app = so.build_app(ENV, client_factory=lambda url, key: made.append((url, key)) or db)
    paths = set(app.openapi()["paths"])
    assert "/healthz" in paths and "/api/v1/subs/ping" in paths and "/api/v1/subs/orders/{order_number}/buy" in paths
    assert all(p == "/healthz" or p.startswith("/api/v1/subs/") for p in paths)      # no storefront, no docs
    c = TestClient(app)
    assert c.get("/healthz").json() == {"ok": True, "service": "subs-api", "configured": True}
    assert made == []                                                               # nothing built until a keyed call
    r = c.get("/api/v1/subs/ping", headers={"x-api-key": KEY, "x-forwarded-for": "203.0.113.7, 172.71.150.51",
                                             "cf-connecting-ip": "203.0.113.7"})
    assert r.status_code == 200 and r.json()["key_label"] == "crm sub finder read"
    # this stub's gate names no header, so the address is the last forwarded hop (the settings live in the database)
    assert r.json()["scopes"] == ["subs:find"] and r.json()["your_ip"] == "172.71.150.51"
    c.get("/api/v1/subs/ping", headers={"x-api-key": KEY})
    assert made == [("https://example.invalid", "k")]                               # one client, reused
    assert c.get("/api/v1/subs/ping", headers={"x-api-key": "wrong"}).status_code == 401
    assert c.get("/docs").status_code == 404 and c.get("/openapi.json").status_code == 404


@pytest.mark.parametrize("env", [{}, {"SUPABASE_URL": "https://example.invalid"}, {"SUPABASE_SERVICE_ROLE_KEY": "k"}])
def test_without_both_settings_every_keyed_call_is_refused_and_health_says_so(env):
    made = []
    c = TestClient(so.build_app(env, client_factory=lambda *a: made.append(a)))
    assert c.get("/healthz").json()["configured"] is False
    assert c.get("/api/v1/subs/ping", headers={"x-api-key": KEY}).status_code == 401
    assert made == []


def test_callers_are_limited_by_their_own_address_and_health_is_not(monkeypatch):
    monkeypatch.setattr(so, "PER_IP_CALLS", 2)
    c = TestClient(so.build_app(ENV, client_factory=lambda *a: _DB()))
    via = lambda caller, edge: {"x-api-key": KEY, "x-forwarded-for": f"{caller}, {edge}", "cf-connecting-ip": caller}  # noqa: E731
    # one caller through two different edges shares one allowance
    assert c.get("/api/v1/subs/ping", headers=via("203.0.113.7", "172.71.150.51")).status_code == 200
    assert c.get("/api/v1/subs/ping", headers=via("203.0.113.7", "172.68.22.192")).status_code == 200
    r = c.get("/api/v1/subs/ping", headers=via("203.0.113.7", "104.22.105.66"))
    assert r.status_code == 429 and r.json() == {"error": "rate_limited", "retry_after_seconds": 60}
    assert r.headers["retry-after"] == "60"
    # another caller behind the same edge is not affected, and neither is the health poll
    assert c.get("/api/v1/subs/ping", headers=via("198.51.100.9", "172.71.150.51")).status_code == 200
    assert all(c.get("/healthz").status_code == 200 for _ in range(5))


def test_the_module_builds_an_app_from_the_process_environment():
    assert set(so.app.openapi()["paths"]) >= {"/healthz", "/api/v1/subs/ping"}


def test_a_caller_with_no_address_at_all_shares_one_bucket(monkeypatch):
    monkeypatch.setattr(so, "PER_IP_CALLS", 1)
    seen = []
    real = so.WindowLimiter.check
    monkeypatch.setattr(so.WindowLimiter, "check", lambda self, key, n, w: seen.append(key) or real(self, key, n, w))
    app = so.build_app(ENV, client_factory=lambda *a: _DB())

    async def call(headers, client):
        sent = []

        async def receive():
            return {"type": "http.request", "body": b"", "more_body": False}

        async def send(m):
            sent.append(m)

        await app({"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1", "method": "GET",
                   "scheme": "http", "path": "/api/v1/subs/ping", "raw_path": b"/api/v1/subs/ping",
                   "query_string": b"", "headers": headers, "client": client, "server": ("t", 80),
                   "root_path": ""}, receive, send)
        return sent[0]["status"]

    import asyncio
    assert asyncio.run(call([], None)) == 401                       # no peer, no headers: counted as "unknown"
    assert asyncio.run(call([(b"x-forwarded-for", b" , ")], None)) == 429
    assert seen[0] == "ip:unknown" and seen[1] == "ip:unknown"
