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
    # The storefront concierge is gated OFF by default (cost kill-switch). These
    # tests exercise the live forwarding/validation path, so enable it here.
    monkeypatch.setattr(app_module, "STOREFRONT_CONCIERGE_ENABLED", True)
    return calls


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
    # X-Forwarded-For is "client-supplied…, edge-appended-real-ip". The RIGHTMOST
    # hop is the one our own edge proxy appends and the only one a client can't
    # forge; keying on the leftmost let a client rotate fake IPs to bypass the
    # edge function's per-IP rate limit (audit 2026-06-22, aligning _client_ip
    # with the in-process limiter + recaptcha-ip fix from 2026-06-10).
    client.post("/api/store/retail-chat",
                json={"message": "hi"},
                headers={"x-forwarded-for": "203.0.113.7, 10.0.0.1"})
    hdrs = capture_post[0]["headers"]
    assert hdrs["x-real-ip"] == "10.0.0.1"
    assert hdrs["x-forwarded-for"] == "10.0.0.1"


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
    monkeypatch.setattr(app_module, "STOREFRONT_CONCIERGE_ENABLED", True)
    r = client.post("/api/store/retail-chat", json={"message": "hi"})
    assert r.status_code == 429
    assert "error" in r.json()


# ---------- kill-switch: storefront concierge disabled by default ----------

def test_store_concierge_disabled_returns_canned_reply_without_upstream(monkeypatch):
    """With STOREFRONT_CONCIERGE_ENABLED off (the default), the storefront route
    returns a friendly canned reply and never calls the chat edge function — so
    no paid Anthropic spend. Re-enabling is an env flip, no code change."""
    calls = []

    def fake_post(url, headers=None, json=None, timeout=None):  # noqa: A002
        calls.append(url)
        return _FakeResp({"reply": "should not happen"}, 200)

    monkeypatch.setattr(app_module.requests, "post", fake_post)
    monkeypatch.setattr(app_module, "STOREFRONT_CONCIERGE_ENABLED", False)
    r = client.post("/api/store/retail-chat", json={"message": "knicks tickets"})
    assert r.status_code == 200
    assert r.json()["reply"] == app_module._CONCIERGE_OFFLINE_REPLY
    assert calls == []  # edge function never called
