"""Tests for the group-chat concierge webhook (/api/store/group-chat/inbound).

The endpoint is a Twilio Conversations onMessageAdded webhook: the VibePass
number sits in a group MMS thread and replies only when @-mentioned. On a
mention it re-reads the thread from Twilio, forwards a speaker-labelled
transcript to the `chat` edge function with scope='owned' (server-set, like
the web storefront), and posts the reply back into the conversation.

Security-critical properties covered here:
  - default-off kill switch (no Twilio/LLM call while disabled)
  - X-Twilio-Signature validation (bad/absent signature → 403, no spend)
  - mention gating + own-message loop guard (no LLM call without an @handle)
  - scope is always 'owned' — the group cannot widen it
  - shared retail-chat budget guard applies (silent when over budget)

Most tests drive `_handle_inbound` directly — the async route wrapper isn't
attributable by coverage.py via TestClient (same as server.py's
render_deploy_webhook), so the decision path lives in that sync helper and two
end-to-end tests exercise the wrapper's real wiring (form parse, headers, URL
reconstruction). No real HTTP call is made — requests.get/post are stubbed.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app (mirrors tests/test_retail_chat.py) ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

fastapi = pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")
from starlette.requests import Request as StarletteRequest  # noqa: E402

import server as app_module  # noqa: E402
import routers.retail_chat as retail_chat_mod  # noqa: E402
import routers.store_group_chat as gc_mod  # noqa: E402

TestClient = starlette_testclient.TestClient
client = TestClient(app_module.app)

WEBHOOK_PATH = "/api/store/group-chat/inbound"
WEBHOOK_URL = f"http://testserver{WEBHOOK_PATH}"
CONVO = "CH0123456789abcdef"


def _sign(url: str, params: dict) -> str:
    payload = url + "".join(k + str(params[k]) for k in sorted(params))
    digest = hmac.new(b"twilio-test-token", payload.encode(), hashlib.sha1).digest()
    return base64.b64encode(digest).decode()


class _Result:
    def __init__(self, status_code, body):
        self.status_code = status_code
        self._body = body

    def json(self):
        return self._body


def _post_webhook(params: dict, sign: bool = True, signature: str | None = None, enabled: bool = True):
    """Drive the sync decision path directly (coverage-attributable),
    presenting the same (status, body) surface a TestClient response has."""
    sig = signature if signature is not None else (_sign(WEBHOOK_URL, params) if sign else "")
    try:
        resp = gc_mod._handle_inbound(lambda: enabled, WEBHOOK_URL, dict(params), sig)
    except fastapi.HTTPException as e:
        return _Result(e.status_code, {"detail": e.detail})
    return _Result(resp.status_code, json.loads(resp.body))


def _mention_params(body: str = "@vibe find us something Saturday", author: str = "Sam"):
    return {
        "EventType": "onMessageAdded",
        "ConversationSid": CONVO,
        "Author": author,
        "Body": body,
    }


class _FakeResp:
    def __init__(self, body, status=200):
        self._body = body
        self.status_code = status

    def json(self):
        return self._body


@pytest.fixture(autouse=True)
def reset_budget(monkeypatch):
    """Isolate the shared retail-chat cost-guard counters between tests, and
    pin the Twilio config on the MODULE GLOBALS (another suite may have
    imported server first, freezing whatever env existed at that moment —
    patching the globals makes these tests order-independent)."""
    monkeypatch.setattr(retail_chat_mod, "_RETAIL_CHAT_ENABLED", True)
    monkeypatch.setattr(retail_chat_mod, "_RETAIL_CHAT_DAILY_MAX", 1000)
    monkeypatch.setattr(retail_chat_mod, "_RETAIL_CHAT_IP_DAILY_MAX", 40)
    retail_chat_mod._retail_chat_usage.update({"day": None, "total": 0, "by_ip": {}})
    monkeypatch.setattr(gc_mod, "TWILIO_ACCOUNT_SID", "ACtest")
    monkeypatch.setattr(gc_mod, "TWILIO_AUTH_TOKEN", "twilio-test-token")
    monkeypatch.setattr(gc_mod, "STORE_GROUP_CONCIERGE_IDENTITY", "vibepass")
    monkeypatch.setattr(gc_mod, "_WEBHOOK_URL_OVERRIDE", "")
    monkeypatch.setattr(app_module, "STORE_GROUP_CONCIERGE_PHONE", "+1 (555) 222-0222")
    # Owned-EVO gate defaults to UNWIRED here → fails closed (no links). Link
    # tests that want links opt in via _owned_event_ids/_get_require_sb stubs.
    monkeypatch.setattr(gc_mod, "_get_require_sb", None)
    yield


class _FakeOwnedDb:
    """Stub of the supabase query chain _owned_event_ids uses:
    table('listings_snapshots').select().eq('event_id', id).eq('is_owned',
    True).limit(1).execute().data — returns a row only for ids in `owned`."""

    def __init__(self, owned_ids, raise_on_query=False):
        self.owned = {int(i) for i in owned_ids}
        self.raise_on_query = raise_on_query
        self.tables = []
        self.queried_ids = []
        self.filters = []

    def table(self, name):
        self.tables.append(name)
        if self.raise_on_query:
            raise RuntimeError("db down")
        return self

    def select(self, *cols):
        return self

    def eq(self, col, val):
        self.filters.append((col, val))
        if col == "event_id":
            self._eid = val
        return self

    def limit(self, n):
        return self

    def execute(self):
        self.queried_ids.append(self._eid)
        return type("R", (), {"data": [{"event_id": self._eid}] if self._eid in self.owned else []})()


@pytest.fixture
def capture_http(monkeypatch):
    """Stub the three upstream calls: Twilio thread read (GET), the chat edge
    fn (POST to /functions/v1/chat), and the Twilio reply (POST to
    conversations.twilio.com). Routes by URL; captures everything."""
    calls = {"gets": [], "edge_posts": [], "twilio_posts": []}
    # Twilio returns Order=desc — NEWEST FIRST (the router reverses it).
    thread = {
        "messages": [
            {"author": "Riley", "body": "@vibe find us something Saturday"},
            {"author": "Sam", "body": "somewhere fun saturday"},
            {"author": "vibepass", "body": "hey! what are you all thinking?"},
        ]
    }

    def fake_get(url, params=None, auth=None, timeout=None):
        calls["gets"].append({"url": url, "params": params or {}, "auth": auth})
        return _FakeResp(thread, 200)

    def fake_post(url, headers=None, json=None, data=None, auth=None, timeout=None):  # noqa: A002
        rec = {"url": url, "headers": headers or {}, "json": json or {}, "data": data or {}, "auth": auth}
        if "/functions/v1/chat" in url:
            calls["edge_posts"].append(rec)
            return _FakeResp({"reply": "How about Yankees Saturday 7pm? I hold sec 214."}, 200)
        calls["twilio_posts"].append(rec)
        return _FakeResp({"sid": "IM123"}, 201)

    monkeypatch.setattr(gc_mod.requests, "get", fake_get)
    monkeypatch.setattr(gc_mod.requests, "post", fake_post)
    calls["thread"] = thread
    return calls


# ---------- Kill switch + configuration ----------

def test_disabled_by_default_short_circuits(monkeypatch):
    """No signature check, no Twilio, no LLM while the flag is off (default)."""
    def boom(*a, **k):
        raise AssertionError("no upstream call while disabled")

    monkeypatch.setattr(gc_mod.requests, "get", boom)
    monkeypatch.setattr(gc_mod.requests, "post", boom)
    r = _post_webhook(_mention_params(), enabled=False)
    assert r.status_code == 200
    assert r.json()["status"] == "disabled"


def test_missing_twilio_creds_503(monkeypatch):
    monkeypatch.setattr(gc_mod, "TWILIO_ACCOUNT_SID", "")
    r = _post_webhook(_mention_params())
    assert r.status_code == 503


# ---------- Signature validation ----------

def test_bad_signature_403(capture_http):
    r = _post_webhook(_mention_params(), signature="bogus")
    assert r.status_code == 403
    assert not capture_http["edge_posts"] and not capture_http["twilio_posts"]


def test_absent_signature_403(capture_http):
    r = _post_webhook(_mention_params(), sign=False)
    assert r.status_code == 403


def test_signature_check_fails_closed_without_token(monkeypatch):
    """Defense-in-depth: with no auth token even a 'matching' signature is
    rejected (the route 503s earlier, but the validator must not pass-open)."""
    monkeypatch.setattr(gc_mod, "TWILIO_AUTH_TOKEN", "")
    assert gc_mod._twilio_signature_ok(WEBHOOK_URL, {}, "anything") is False


# ---------- Public-URL reconstruction (what Twilio signed) ----------

def _fake_request(headers: dict, path: str = WEBHOOK_PATH, query: bytes = b""):
    return StarletteRequest({
        "type": "http",
        "method": "POST",
        "scheme": "http",
        "server": ("testserver", 80),
        "path": path,
        "query_string": query,
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
    })


def test_webhook_url_prefers_env_override(monkeypatch):
    public = "https://vibepass.example/api/store/group-chat/inbound"
    monkeypatch.setattr(gc_mod, "_WEBHOOK_URL_OVERRIDE", public)
    assert gc_mod._webhook_url(_fake_request({"host": "internal:8000"})) == public


def test_webhook_url_reconstructs_from_forwarded_headers():
    req = _fake_request({"x-forwarded-proto": "https", "x-forwarded-host": "vibepass.example"})
    assert gc_mod._webhook_url(req) == f"https://vibepass.example{WEBHOOK_PATH}"


def test_webhook_url_keeps_query_string():
    req = _fake_request({"host": "testserver"}, query=b"probe=1")
    assert gc_mod._webhook_url(req) == f"{WEBHOOK_URL}?probe=1"


# ---------- Gating: mention, own message, event type ----------

def test_no_mention_is_ignored(capture_http):
    r = _post_webhook(_mention_params(body="anyone free saturday?"))
    assert r.status_code == 200
    assert r.json()["status"] == "no-mention"
    assert not capture_http["edge_posts"] and not capture_http["twilio_posts"]


def test_own_message_is_ignored(capture_http):
    r = _post_webhook(_mention_params(author="vibepass"))
    assert r.json()["status"] == "own-message"
    assert not capture_http["edge_posts"]


def test_other_event_types_ignored(capture_http):
    params = _mention_params()
    params["EventType"] = "onConversationAdded"
    r = _post_webhook(params)
    assert r.json()["status"] == "ignored"
    assert not capture_http["edge_posts"]


def test_handle_must_be_word_bounded(capture_http):
    """'@vibecheck' must not trigger '@vibe'."""
    r = _post_webhook(_mention_params(body="total @vibecheck moment"))
    assert r.json()["status"] == "no-mention"
    assert not capture_http["edge_posts"]


# ---------- The reply path ----------

def test_mention_replies_into_the_conversation(capture_http):
    r = _post_webhook(_mention_params(body="@vibe find us something Saturday", author="Riley"))
    assert r.status_code == 200
    assert r.json()["status"] == "replied"
    # Thread was re-read from the right conversation.
    assert capture_http["gets"][0]["url"].endswith(f"/Conversations/{CONVO}/Messages")
    assert capture_http["gets"][0]["auth"] == ("ACtest", "twilio-test-token")
    # Reply posted back into the same conversation, as our identity.
    tp = capture_http["twilio_posts"][0]
    assert tp["url"].endswith(f"/Conversations/{CONVO}/Messages")
    assert tp["data"]["Author"] == "vibepass"
    assert "Yankees" in tp["data"]["Body"]


def test_scope_is_owned_and_client_cannot_widen(capture_http):
    params = _mention_params()
    params["scope"] = "all"  # smuggled field is just ignored form data
    r = _post_webhook(params)
    assert r.status_code == 200
    assert capture_http["edge_posts"][0]["json"]["scope"] == "owned"


def test_history_is_speaker_labelled_and_alternating(capture_http):
    _post_webhook(_mention_params())
    history = capture_http["edge_posts"][0]["json"]["history"]
    # Leading assistant turn dropped (LLM requires user-first), then merged
    # user turns: "Sam: ..." + "Riley: ..." collapse into one user turn.
    assert [h["role"] for h in history] == ["user"]
    assert "Sam: somewhere fun saturday" in history[0]["content"]
    assert "Riley: @vibe find us something Saturday" in history[0]["content"]
    # The group-context + [event:<id>] tagging instruction rides the first turn.
    assert history[0]["content"].startswith(gc_mod._GROUP_CONTEXT_NOTE)


def test_history_appends_trigger_when_thread_ends_with_us(capture_http):
    """Webhook can outrun the Messages read — the triggering mention must
    still close the transcript as a user turn."""
    capture_http["thread"]["messages"] = [
        {"author": "vibepass", "body": "how about a comedy night?"},
        {"author": "Sam", "body": "what's good next weekend"},
    ]
    _post_webhook(_mention_params(author="Riley", body="@vibe yes do it"))
    history = capture_http["edge_posts"][0]["json"]["history"]
    assert [h["role"] for h in history] == ["user", "assistant", "user"]
    assert history[-1] == {"role": "user", "content": "Riley: @vibe yes do it"}


def test_history_skips_media_only_and_survives_all_ours(capture_http):
    """Media-only (empty body) messages are skipped; a thread that is nothing
    but our own messages still yields the triggering turn."""
    capture_http["thread"]["messages"] = [
        {"author": "Sam", "body": ""},  # media-only
        {"author": "vibepass", "body": "welcome to the thread!"},
    ]
    _post_webhook(_mention_params(author="Sam", body="@vibe hi"))
    history = capture_http["edge_posts"][0]["json"]["history"]
    assert [h["role"] for h in history] == ["user"]
    assert history[0]["content"].endswith("Sam: @vibe hi")


def test_thread_fetch_failure_falls_back_to_single_turn(monkeypatch, capture_http):
    def broken_get(*a, **k):
        raise RuntimeError("twilio down")

    monkeypatch.setattr(gc_mod.requests, "get", broken_get)
    r = _post_webhook(_mention_params(author="Sam", body="@vibe help"))
    assert r.json()["status"] == "replied"
    history = capture_http["edge_posts"][0]["json"]["history"]
    assert [h["role"] for h in history] == ["user"]
    assert history[0]["content"].endswith("Sam: @vibe help")


def test_edge_failure_posts_offline_reply(monkeypatch, capture_http):
    def fake_post(url, headers=None, json=None, data=None, auth=None, timeout=None):  # noqa: A002
        if "/functions/v1/chat" in url:
            raise RuntimeError("edge fn down")
        capture_http["twilio_posts"].append({"url": url, "data": data or {}})
        return _FakeResp({"sid": "IM124"}, 201)

    monkeypatch.setattr(gc_mod.requests, "post", fake_post)
    r = _post_webhook(_mention_params())
    assert r.json()["status"] == "replied"
    assert capture_http["twilio_posts"][0]["data"]["Body"] == retail_chat_mod._CONCIERGE_OFFLINE_REPLY


def test_reply_is_truncated_for_mms(monkeypatch, capture_http):
    def fake_post(url, headers=None, json=None, data=None, auth=None, timeout=None):  # noqa: A002
        if "/functions/v1/chat" in url:
            return _FakeResp({"reply": "x" * 5000}, 200)
        capture_http["twilio_posts"].append({"url": url, "data": data or {}})
        return _FakeResp({"sid": "IM125"}, 201)

    monkeypatch.setattr(gc_mod.requests, "post", fake_post)
    _post_webhook(_mention_params())
    assert len(capture_http["twilio_posts"][0]["data"]["Body"]) == gc_mod._REPLY_MAX_CHARS


def test_reply_post_failure_is_logged_not_raised(monkeypatch, capture_http, caplog):
    def fake_post(url, headers=None, json=None, data=None, auth=None, timeout=None):  # noqa: A002
        if "/functions/v1/chat" in url:
            return _FakeResp({"reply": "ok!"}, 200)
        return _FakeResp({"error": "nope"}, 400)

    monkeypatch.setattr(gc_mod.requests, "post", fake_post)
    with caplog.at_level("ERROR"):
        r = _post_webhook(_mention_params())
    assert r.json()["status"] == "replied"
    assert any("reply post failed" in m for m in caplog.messages)


# ---------- Direct store-event links in replies (owned-EVO gated) ----------

def _tagged_reply_post(capture_http, reply_text):
    def fake_post(url, headers=None, json=None, data=None, auth=None, timeout=None):  # noqa: A002
        if "/functions/v1/chat" in url:
            return _FakeResp({"reply": reply_text}, 200)
        capture_http["twilio_posts"].append({"url": url, "data": data or {}})
        return _FakeResp({"sid": "IM126"}, 201)
    return fake_post


def test_event_tags_become_store_links(monkeypatch, capture_http):
    """The model tags recommendations with [event:<id>]; ids that VERIFY as
    owned EVO become direct /store/event/{id} links in the group reply."""
    monkeypatch.setattr(gc_mod, "_STORE_BASE", "https://vibepass.example")
    db = _FakeOwnedDb({3091462, 3091999})
    monkeypatch.setattr(gc_mod, "_get_require_sb", lambda: (lambda: db))
    monkeypatch.setattr(gc_mod.requests, "post", _tagged_reply_post(
        capture_http,
        "1. Yankees vs Red Sox Sat 7:05pm [event:3091462]\n2. Mets Sun 1:10pm [event:3091999]\nWant me to hold either?",
    ))
    _post_webhook(_mention_params())
    body = capture_http["twilio_posts"][0]["data"]["Body"]
    assert "https://vibepass.example/store/event/3091462" in body
    assert "https://vibepass.example/store/event/3091999" in body
    assert "[event:" not in body
    # The verification really hit the owned-EVO table with the right filters.
    assert db.tables == ["listings_snapshots", "listings_snapshots"]
    assert ("is_owned", True) in db.filters
    assert sorted(db.queried_ids) == [3091462, 3091999]


def test_non_owned_event_tags_never_link(monkeypatch, capture_http):
    """HARD RULE: an id without owned-EVO rows gets its tag stripped — a link
    to a non-owned event can never reach the group."""
    monkeypatch.setattr(gc_mod, "_STORE_BASE", "https://vibepass.example")
    db = _FakeOwnedDb({3091462})  # 3091999 is NOT owned
    monkeypatch.setattr(gc_mod, "_get_require_sb", lambda: (lambda: db))
    monkeypatch.setattr(gc_mod.requests, "post", _tagged_reply_post(
        capture_http, "1. Yankees Sat [event:3091462]\n2. Mets Sun [event:3091999]",
    ))
    _post_webhook(_mention_params())
    body = capture_http["twilio_posts"][0]["data"]["Body"]
    assert "https://vibepass.example/store/event/3091462" in body
    assert "3091999" not in body
    assert "[event:" not in body


def test_owned_check_fails_closed_on_db_error(monkeypatch, capture_http):
    """DB down → NO links at all (fail closed), reply text still goes out."""
    monkeypatch.setattr(gc_mod, "_STORE_BASE", "https://vibepass.example")
    db = _FakeOwnedDb({3091462}, raise_on_query=True)
    monkeypatch.setattr(gc_mod, "_get_require_sb", lambda: (lambda: db))
    monkeypatch.setattr(gc_mod.requests, "post", _tagged_reply_post(
        capture_http, "Yankees Sat [event:3091462]",
    ))
    _post_webhook(_mention_params())
    body = capture_http["twilio_posts"][0]["data"]["Body"]
    assert body == "Yankees Sat"


def test_owned_check_fails_closed_when_unwired(monkeypatch, capture_http):
    """_get_require_sb unwired (isolation/misconfig) → fail closed, no links."""
    monkeypatch.setattr(gc_mod, "_STORE_BASE", "https://vibepass.example")
    # autouse fixture already set _get_require_sb = None
    monkeypatch.setattr(gc_mod.requests, "post", _tagged_reply_post(
        capture_http, "Yankees Sat [event:3091462]",
    ))
    _post_webhook(_mention_params())
    assert capture_http["twilio_posts"][0]["data"]["Body"] == "Yankees Sat"


def test_owned_check_is_capped(monkeypatch):
    """The DB loop is bounded (_OWNED_CHECK_MAX_IDS) no matter how many tags
    the model emits."""
    db = _FakeOwnedDb(set())
    monkeypatch.setattr(gc_mod, "_get_require_sb", lambda: (lambda: db))
    ids = {str(3000000 + i) for i in range(10)}
    assert gc_mod._owned_event_ids(ids) == set()
    assert len(db.queried_ids) == gc_mod._OWNED_CHECK_MAX_IDS


def test_scope_cannot_be_widened_from_group_chat_code():
    """HARD RULE layer 1: the only edge-fn entry point for this surface
    hard-codes scope='owned' — there is no scope parameter to widen."""
    import inspect
    sig = inspect.signature(gc_mod._owned_chat_edge_post)
    assert "scope" not in sig.parameters


def test_malformed_event_tags_are_stripped(monkeypatch, capture_http):
    monkeypatch.setattr(gc_mod, "_STORE_BASE", "https://vibepass.example")

    def fake_post(url, headers=None, json=None, data=None, auth=None, timeout=None):  # noqa: A002
        if "/functions/v1/chat" in url:
            return _FakeResp({"reply": "Try the Garden show [event:abc] or [event:12] tonight."}, 200)
        capture_http["twilio_posts"].append({"url": url, "data": data or {}})
        return _FakeResp({"sid": "IM127"}, 201)

    monkeypatch.setattr(gc_mod.requests, "post", fake_post)
    _post_webhook(_mention_params())
    body = capture_http["twilio_posts"][0]["data"]["Body"]
    assert "[event:" not in body
    assert "Try the Garden show or tonight." == body


def test_event_tags_stripped_when_no_base_url(monkeypatch, capture_http):
    monkeypatch.setattr(gc_mod, "_STORE_BASE", "")

    def fake_post(url, headers=None, json=None, data=None, auth=None, timeout=None):  # noqa: A002
        if "/functions/v1/chat" in url:
            return _FakeResp({"reply": "Yankees Sat [event:3091462]"}, 200)
        capture_http["twilio_posts"].append({"url": url, "data": data or {}})
        return _FakeResp({"sid": "IM128"}, 201)

    monkeypatch.setattr(gc_mod.requests, "post", fake_post)
    _post_webhook(_mention_params())
    assert capture_http["twilio_posts"][0]["data"]["Body"] == "Yankees Sat"


# ---------- Budget guard ----------

def test_over_budget_stays_silent(monkeypatch, capture_http):
    monkeypatch.setattr(retail_chat_mod, "_RETAIL_CHAT_IP_DAILY_MAX", 1)
    assert _post_webhook(_mention_params()).json()["status"] == "replied"
    r = _post_webhook(_mention_params())
    assert r.status_code == 200
    assert r.json()["status"] == "over-budget"
    # Only the first mention reached the LLM / posted a reply.
    assert len(capture_http["edge_posts"]) == 1
    assert len(capture_http["twilio_posts"]) == 1


# ---------- End-to-end route wiring (through the async wrapper) ----------

def test_route_wiring_end_to_end(monkeypatch, capture_http):
    """The real webhook path: urlencoded form parse, X-Twilio-Signature header
    extraction, and public-URL reconstruction all feed _handle_inbound."""
    monkeypatch.setattr(app_module, "STORE_GROUP_CONCIERGE_ENABLED", True)
    params = _mention_params()
    r = client.post(
        WEBHOOK_PATH, data=params,
        headers={"X-Twilio-Signature": _sign(WEBHOOK_URL, params)},
    )
    assert r.status_code == 200
    assert r.json()["status"] == "replied"
    assert capture_http["edge_posts"][0]["json"]["scope"] == "owned"


def test_route_disabled_by_default_end_to_end():
    r = client.post(WEBHOOK_PATH, data=_mention_params())
    assert r.status_code == 200
    assert r.json()["status"] == "disabled"


# ---------- /simulate — Twilio-free test harness ----------

def test_simulate_404_in_production(monkeypatch, capture_http):
    monkeypatch.setattr(app_module, "_is_production", lambda: True)
    r = client.post("/api/store/group-chat/simulate", json={"messages": [{"author": "Sam", "body": "@vibe hi"}]})
    assert r.status_code == 404
    assert not capture_http["edge_posts"]


def test_simulate_validates_payload(capture_http):
    assert client.post("/api/store/group-chat/simulate", json={}).status_code == 400
    assert client.post("/api/store/group-chat/simulate", json={"messages": []}).status_code == 400
    r = client.post("/api/store/group-chat/simulate", json={"messages": ["junk", {"author": "Sam", "body": "  "}]})
    assert r.status_code == 400
    assert not capture_http["edge_posts"]


def test_simulate_no_mention_stays_out(capture_http):
    r = client.post("/api/store/group-chat/simulate", json={"messages": [
        {"author": "Sam", "body": "anyone free saturday?"},
    ]})
    assert r.status_code == 200
    assert r.json() == {"status": "no-mention", "reply": None}
    assert not capture_http["edge_posts"]


def test_simulate_replies_with_owned_scope_and_history(capture_http):
    r = client.post("/api/store/group-chat/simulate", json={"messages": [
        {"author": "vibepass", "body": "hey! what are you all thinking?"},
        {"author": "Sam", "body": "somewhere fun saturday"},
        {"author": "Riley", "body": "@vibe find us something Saturday"},
    ]})
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "replied"
    assert "Yankees" in body["reply"]
    # Same transcript rules as the webhook: leading assistant dropped, user
    # turns merged + speaker-labelled — and echoed back for the harness debug.
    assert [h["role"] for h in body["history"]] == ["user"]
    assert "Sam: somewhere fun saturday" in body["history"][0]["content"]
    # scope is server-set 'owned'; no Twilio call happens on this path.
    assert capture_http["edge_posts"][0]["json"]["scope"] == "owned"
    assert not capture_http["twilio_posts"] and not capture_http["gets"]


def test_simulate_surfaces_budget_429(monkeypatch, capture_http):
    """Unlike the webhook (silent — Twilio would redeliver), the harness shows
    the tester the budget refusal."""
    monkeypatch.setattr(retail_chat_mod, "_RETAIL_CHAT_IP_DAILY_MAX", 1)
    msgs = {"messages": [{"author": "Sam", "body": "@vibe hi"}]}
    assert client.post("/api/store/group-chat/simulate", json=msgs).status_code == 200
    r = client.post("/api/store/group-chat/simulate", json=msgs)
    assert r.status_code == 429
    assert len(capture_http["edge_posts"]) == 1


def test_simulate_edge_failure_returns_offline_reply(monkeypatch, capture_http):
    def fake_post(url, headers=None, json=None, data=None, auth=None, timeout=None):  # noqa: A002
        raise RuntimeError("edge fn down")

    monkeypatch.setattr(gc_mod.requests, "post", fake_post)
    r = client.post("/api/store/group-chat/simulate", json={"messages": [{"author": "Sam", "body": "@vibe hi"}]})
    assert r.status_code == 200
    assert r.json()["reply"] == retail_chat_mod._CONCIERGE_OFFLINE_REPLY


def test_groupchat_test_page_served_in_non_prod():
    r = client.get("/store/test/groupchat")
    assert r.status_code == 200
    assert "Group-chat concierge" in r.text


# ---------- Public config card wiring ----------

def test_public_config_exposes_group_concierge(monkeypatch):
    monkeypatch.setattr(app_module, "STORE_GROUP_CONCIERGE_ENABLED", True)
    cfg = client.get("/api/public/config").json()
    assert cfg["group_concierge_enabled"] is True
    assert cfg["group_concierge_phone"] == "+1 (555) 222-0222"
    assert cfg["group_concierge_handle"] == "@vibe"


def test_public_config_hides_group_concierge_when_disabled():
    cfg = client.get("/api/public/config").json()
    assert cfg["group_concierge_enabled"] is False
    assert cfg["group_concierge_phone"] is None
