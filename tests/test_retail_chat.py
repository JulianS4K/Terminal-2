"""Tests for the retail-chat proxy endpoints (/api/retail-chat,
/api/store/retail-chat).

The endpoints forward a validated transcript to the deployed `chat` edge
function with a SERVER-SET scope:
  - /api/retail-chat        → scope='all'   (email-gated terminal, full market)
  - /api/store/retail-chat  → scope='owned' (public storefront, owned EVO only)

The security-critical property: the client cannot choose scope. A storefront
caller that smuggles scope='all' in the body is still forwarded as 'owned'.

No real HTTP call is made — requests.post is monkeypatched to capture what the
proxy would send upstream.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app (mirrors tests/test_store_events.py) ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")  # don't gate the terminal route

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

fastapi = pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient
client = TestClient(app_module.app)


class _FakeResp:
    def __init__(self, body, status=200):
        self._body = body
        self.status_code = status

    def json(self):
        return self._body


@pytest.fixture
def capture_post(monkeypatch):
    """Capture the upstream request the proxy makes to the edge function."""
    calls = []

    def fake_post(url, headers=None, json=None, timeout=None):  # noqa: A002
        calls.append({"url": url, "headers": headers or {}, "json": json or {}})
        return _FakeResp({"reply": "here you go"}, 200)

    monkeypatch.setattr(app_module.requests, "post", fake_post)
    return calls


@pytest.fixture(autouse=True)
def reset_budget(monkeypatch):
    """Isolate the in-process cost-guard counters between tests + restore the
    default (high) caps so unrelated tests aren't throttled."""
    monkeypatch.setattr(app_module, "_RETAIL_CHAT_ENABLED", True)
    monkeypatch.setattr(app_module, "_RETAIL_CHAT_DAILY_MAX", 1000)
    monkeypatch.setattr(app_module, "_RETAIL_CHAT_IP_DAILY_MAX", 40)
    app_module._retail_chat_usage.update({"day": None, "total": 0, "by_ip": {}})
    yield


# ---------- scope is server-set ----------

def test_terminal_forwards_scope_all(capture_post):
    r = client.post("/api/retail-chat", json={"message": "next Yankees home game under $5"})
    assert r.status_code == 200
    assert r.json()["reply"] == "here you go"
    assert len(capture_post) == 1
    sent = capture_post[0]["json"]
    assert sent["scope"] == "all"
    assert sent["history"][-1] == {"role": "user", "content": "next Yankees home game under $5"}
    assert capture_post[0]["url"].endswith("/functions/v1/chat")


def test_store_forwards_scope_owned(capture_post):
    r = client.post("/api/store/retail-chat", json={"message": "knicks tickets"})
    assert r.status_code == 200
    assert capture_post[0]["json"]["scope"] == "owned"


def test_store_cannot_smuggle_scope_all(capture_post):
    """A storefront client sending scope='all' is still forwarded as owned."""
    r = client.post("/api/store/retail-chat",
                    json={"message": "show me everything", "scope": "all"})
    assert r.status_code == 200
    assert capture_post[0]["json"]["scope"] == "owned"


def test_client_ip_is_forwarded(capture_post):
    client.post("/api/store/retail-chat",
                json={"message": "hi"},
                headers={"x-forwarded-for": "203.0.113.7, 10.0.0.1"})
    hdrs = capture_post[0]["headers"]
    assert hdrs["x-real-ip"] == "203.0.113.7"
    assert hdrs["x-forwarded-for"] == "203.0.113.7"


# ---------- transcript validation ----------

def test_history_required(capture_post):
    r = client.post("/api/store/retail-chat", json={})
    assert r.status_code == 400
    assert capture_post == []  # never reached upstream


def test_last_message_must_be_user(capture_post):
    r = client.post("/api/store/retail-chat", json={"history": [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "hello"},
    ]})
    assert r.status_code == 400
    assert capture_post == []


def test_history_is_bounded_and_trimmed(capture_post):
    long_msg = "x" * 9000
    big = [{"role": "user", "content": f"m{i}"} for i in range(40)]
    big.append({"role": "user", "content": long_msg})
    r = client.post("/api/retail-chat", json={"history": big})
    assert r.status_code == 200
    sent = capture_post[0]["json"]["history"]
    assert len(sent) <= app_module._RETAIL_CHAT_MAX_TURNS
    assert len(sent[-1]["content"]) <= app_module._RETAIL_CHAT_MAX_CHARS


def test_upstream_status_passthrough(monkeypatch):
    """A 429 from the edge function is surfaced to the client unchanged."""
    def fake_post(url, headers=None, json=None, timeout=None):  # noqa: A002
        return _FakeResp({"error": "rate limited"}, 429)
    monkeypatch.setattr(app_module.requests, "post", fake_post)
    r = client.post("/api/store/retail-chat", json={"message": "hi"})
    assert r.status_code == 429
    assert "error" in r.json()


# ---------- cost guard ----------

def test_kill_switch_spends_nothing(monkeypatch, capture_post):
    monkeypatch.setattr(app_module, "_RETAIL_CHAT_ENABLED", False)
    r = client.post("/api/store/retail-chat", json={"message": "hi"})
    assert r.status_code == 503
    assert capture_post == []  # never forwarded → no LLM cost


def test_store_per_ip_daily_cap(capture_post, monkeypatch):
    monkeypatch.setattr(app_module, "_RETAIL_CHAT_IP_DAILY_MAX", 2)
    h = {"x-forwarded-for": "198.51.100.5"}
    assert client.post("/api/store/retail-chat", json={"message": "a"}, headers=h).status_code == 200
    assert client.post("/api/store/retail-chat", json={"message": "b"}, headers=h).status_code == 200
    assert client.post("/api/store/retail-chat", json={"message": "c"}, headers=h).status_code == 429
    assert len(capture_post) == 2  # the capped 3rd never reached the LLM


def test_terminal_exempt_from_per_ip_cap(capture_post, monkeypatch):
    """The email-gated terminal isn't subject to the public per-IP cap."""
    monkeypatch.setattr(app_module, "_RETAIL_CHAT_IP_DAILY_MAX", 1)
    h = {"x-forwarded-for": "198.51.100.9"}
    assert client.post("/api/retail-chat", json={"message": "a"}, headers=h).status_code == 200
    assert client.post("/api/retail-chat", json={"message": "b"}, headers=h).status_code == 200
    assert len(capture_post) == 2


def test_global_daily_cap(capture_post, monkeypatch):
    monkeypatch.setattr(app_module, "_RETAIL_CHAT_DAILY_MAX", 2)
    codes = [
        client.post("/api/store/retail-chat", json={"message": "x"},
                    headers={"x-forwarded-for": f"203.0.113.{i}"}).status_code
        for i in range(1, 4)
    ]
    assert codes == [200, 200, 429]
    assert len(capture_post) == 2
