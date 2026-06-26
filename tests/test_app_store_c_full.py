"""Line-coverage tests for the STORE-C slice of app.py.

Routes owned by this slice:
  - POST /api/store/verify-human
  - POST /api/store/reserve            (mock checkout — inventory cap logic)
  - POST /api/retail-chat, POST /api/store/retail-chat
  - POST/GET/DELETE /api/store/share, /api/store/share/{id}
  - GET  /api/store/shares
  - GET  /store/test, /store/test/{search,performer,venue,event,share,
          media_test,trip,tour}

No real network or DB: TEvo client, Supabase (app.sb / require_sb), the
retail-chat upstream proxy (requests.post / _proxy_retail_chat), and the
share-resolve event fetch are all monkeypatched. Mirrors the env-before-import
+ TestClient pattern used by tests/test_store_events.py and
tests/test_store_shares.py.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app (mirrors sibling store test modules) ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


@pytest.fixture(autouse=True)
def _reset_rate_limiter():
    """The per-IP rate-limit middleware buckets all TestClient calls under one
    IP; clear its hit log before each test so back-to-back POSTs to the same
    bucket (share create cap = 10/60s) don't trip a 429."""
    app_module._ip_limiter._hits.clear()
    yield
    app_module._ip_limiter._hits.clear()


# ============================================================
# Stateful share_links + events Supabase fake (modeled on
# tests/test_store_shares.py, extended with .rpc()).
# ============================================================

class _Resp:
    def __init__(self, data):
        self.data = data


_NULL = object()  # sentinel for is_(col, "null")


class _Query:
    def __init__(self, rows, fail_inserts=0):
        self._rows = rows
        self._fail_inserts = fail_inserts
        self._mode = "select"
        self._payload = None
        self._filters: list[tuple] = []

    def select(self, *_a, **_k):
        self._mode = "select"
        return self

    def insert(self, row):
        self._mode = "insert"
        self._payload = dict(row)
        return self

    def update(self, vals):
        self._mode = "update"
        self._payload = dict(vals)
        return self

    def eq(self, col, val):
        self._filters.append((col, val))
        return self

    def is_(self, col, val):
        self._filters.append((col, _NULL if val == "null" else val))
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def _match(self, r) -> bool:
        for col, val in self._filters:
            if val is _NULL:
                if r.get(col) is not None:
                    return False
            elif r.get(col) != val:
                return False
        return True

    def execute(self):
        if self._mode == "insert":
            if self._fail_inserts and self._fail_inserts[0] > 0:
                self._fail_inserts[0] -= 1
                raise RuntimeError("duplicate key value violates unique constraint")
            self._rows.append(self._payload)
            return _Resp([self._payload])
        matched = [r for r in self._rows if self._match(r)]
        if self._mode == "update":
            for r in matched:
                r.update(self._payload)
            return _Resp(matched)
        return _Resp(matched)


class _FakeDB:
    def __init__(self, share_rows=None, event_rows=None, fail_inserts=0):
        self.tables = {
            "share_links": share_rows if share_rows is not None else [],
            "events": event_rows if event_rows is not None else [],
        }
        # mutable counter shared with each _Query so the collision-retry path
        # (fail first N inserts then succeed) can be exercised deterministically.
        self._fail_inserts = [fail_inserts]
        self.rpc_calls: list = []

    def table(self, name):
        return _Query(self.tables.setdefault(name, []), fail_inserts=self._fail_inserts)

    def rpc(self, name, params):
        self.rpc_calls.append((name, params))

        class _RpcQ:
            def execute(_self):
                return _Resp(None)

        return _RpcQ()


@pytest.fixture
def as_user(monkeypatch):
    """Wire a FakeDB + override require_auth to a given user id. Yields a
    helper that returns a TestClient. Cleans up the dependency override."""
    def _make(user_id, share_rows=None, event_rows=None, fail_inserts=0):
        db = _FakeDB(share_rows=share_rows, event_rows=event_rows,
                     fail_inserts=fail_inserts)
        monkeypatch.setattr(app_module, "require_sb", lambda: db)
        app_module.app.dependency_overrides[app_module.require_auth] = (
            (lambda: {"id": user_id}) if user_id is not None else (lambda: None)
        )
        c = TestClient(app_module.app)
        c.fakedb = db  # type: ignore[attr-defined]
        return c

    yield _make
    app_module.app.dependency_overrides.pop(app_module.require_auth, None)


@pytest.fixture
def client(monkeypatch):
    """Plain TestClient with reserve-auth flag forced off (so the mock-checkout
    body runs without a Supabase session) and require_sb stubbed."""
    monkeypatch.setattr(app_module, "STOREFRONT_RESERVE_REQUIRES_AUTH", False)
    monkeypatch.setattr(app_module, "require_sb", lambda: object())
    return TestClient(app_module.app)


# ============================================================
# POST /api/store/verify-human
# ============================================================

def test_verify_human_dormant_noop(client):
    """Gate dormant (RECAPTCHA_ENABLED false) → no-op success, enabled:false."""
    r = client.post("/api/store/verify-human", json={})
    assert r.status_code == 200
    assert r.json() == {"ok": True, "enabled": False}


def test_verify_human_enabled_sets_cookie(client, monkeypatch):
    monkeypatch.setattr(app_module, "RECAPTCHA_ENABLED", True)
    monkeypatch.setattr(app_module, "_verify_recaptcha", lambda *a, **k: True)
    r = client.post(
        "/api/store/verify-human",
        json={"recaptcha_token": "tok"},
        headers={"x-forwarded-for": "203.0.113.5, 10.0.0.9"},
    )
    assert r.status_code == 200
    assert r.json() == {"ok": True, "enabled": True}
    assert app_module._HUMAN_COOKIE_NAME in r.cookies


def test_verify_human_bad_token_403(client, monkeypatch):
    """Enabled gate + failing reCAPTCHA → 403 verification failed (line 6024)."""
    monkeypatch.setattr(app_module, "RECAPTCHA_ENABLED", True)
    monkeypatch.setattr(app_module, "_verify_recaptcha", lambda *a, **k: False)
    r = client.post("/api/store/verify-human", json={"token": "bad"})
    assert r.status_code == 403


# ============================================================
# POST /api/store/reserve
# ============================================================

class _MatchTGFake:
    """TEvo client returning one ticket group keyed by id."""
    def __init__(self, group):
        self._group = group

    def get_ticket_groups(self, *_a, **_k):
        return {"ticket_groups": [self._group]}


_GROUP = {
    "id": 12345, "available_quantity": 4, "splits": [2, 4],
    "retail_price": 100.0, "section": "100", "row": "A",
    "format": "Eticket", "in_hand": True,
}


def test_reserve_non_integer_inputs_400(client):
    """event_id that can't int-convert → 400 (lines 6056-6057)."""
    r = client.post("/api/store/reserve", json={
        "event_id": "not-a-number", "ticket_group_id": 1, "quantity": 1,
    })
    assert r.status_code == 400
    assert "integers" in r.json()["detail"]


def test_reserve_missing_required_400(client):
    """quantity == 0 fails the (event_id and tg and qty>0) gate (line 6059)."""
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 1, "quantity": 0,
    })
    assert r.status_code == 400
    assert "required" in r.json()["detail"]


def test_reserve_over_cap_400(client):
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 1, "quantity": 999999,
    })
    assert r.status_code == 400
    assert "maximum" in r.json()["detail"].lower()


def test_reserve_success(client, monkeypatch):
    """Happy path: qty within avail + in splits → mock confirmation
    (lines 6095-6103 success body)."""
    monkeypatch.setattr(app_module, "client", _MatchTGFake(_GROUP))
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 12345, "quantity": 4,
    })
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["ok"] is True
    assert body["purchase_enabled"] is False
    res = body["reservation"]
    assert res["quantity"] == 4
    assert res["unit_price"] == 100.0
    assert res["subtotal"] == 400.0
    assert res["section"] == "100"


def test_reserve_exceeds_available_409(client, monkeypatch):
    """qty > available_quantity → 409 (line 6097-6098)."""
    monkeypatch.setattr(app_module, "client", _MatchTGFake(_GROUP))
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 12345, "quantity": 6,
    })
    assert r.status_code == 409
    assert "only 4 available" in r.json()["detail"]


def test_reserve_sold_out_group_409(client, monkeypatch):
    """Regression (money path): a sold-out group reports available_quantity=0
    while `quantity` (original block size) stays non-zero. The old
    `available_quantity or quantity` fallback treated 0 as falsy and admitted
    the reservation; it must now 409 with 0 available."""
    sold_out = {**_GROUP, "id": 777, "available_quantity": 0, "quantity": 4}
    monkeypatch.setattr(app_module, "client", _MatchTGFake(sold_out))
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 777, "quantity": 4,
    })
    assert r.status_code == 409
    assert "only 0 available" in r.json()["detail"]


def test_reserve_falls_back_to_quantity_when_available_absent(client, monkeypatch):
    """When available_quantity is genuinely absent (None), `quantity` is the
    intended fallback — this path must still succeed."""
    no_aq = {"id": 778, "quantity": 4, "splits": [2, 4], "retail_price": 100.0,
             "section": "100", "row": "A", "format": "Eticket", "in_hand": True}
    monkeypatch.setattr(app_module, "client", _MatchTGFake(no_aq))
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 778, "quantity": 4,
    })
    assert r.status_code == 200, r.text
    assert r.json()["reservation"]["quantity"] == 4


def test_reserve_wrong_split_409(client, monkeypatch):
    """qty not in splits → 409 (line 6099-6100). avail high enough that the
    earlier avail gate passes."""
    group = dict(_GROUP, available_quantity=10, splits=[2, 4])
    monkeypatch.setattr(app_module, "client", _MatchTGFake(group))
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 12345, "quantity": 3,
    })
    assert r.status_code == 409
    assert "only sells in quantities" in r.json()["detail"]


def test_reserve_group_not_found_404(client, monkeypatch):
    """Live mode: no matching ticket_group id → 404 (line 6093)."""
    class _Empty:
        def get_ticket_groups(self, *_a, **_k):
            return {"ticket_groups": []}
    monkeypatch.setattr(app_module, "client", _Empty())
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 99999, "quantity": 2,
    })
    assert r.status_code == 404
    assert "no longer available" in r.json()["detail"]


def test_reserve_upstream_error_502_scrubbed(client, monkeypatch):
    """Upstream RuntimeError → generic 502, no TEvo/secret leak (6085-6087)."""
    class _Boom:
        def get_ticket_groups(self, *_a, **_k):
            raise RuntimeError("TEvo 500 https://api.tevo/x?token=SECRET")
    monkeypatch.setattr(app_module, "client", _Boom())
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 12345, "quantity": 2,
    })
    assert r.status_code == 502
    detail = r.json()["detail"]
    assert "TEvo" not in detail and "SECRET" not in detail


def test_reserve_sql_only_match(client, monkeypatch):
    """SQL-only mode validates against the DB snapshot helper (6072-6077)."""
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", True)
    monkeypatch.setattr(
        app_module, "_fetch_owned_ticket_groups_from_db",
        lambda eid: ([_GROUP], "snapshot", "2026-06-25T00:00:00Z"),
    )
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 12345, "quantity": 4,
    })
    assert r.status_code == 200, r.text
    assert r.json()["reservation"]["quantity"] == 4


def test_reserve_sql_only_not_found_404(client, monkeypatch):
    """SQL-only mode, no snapshot match → snapshot-based 404 (6077-6081)."""
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", True)
    monkeypatch.setattr(
        app_module, "_fetch_owned_ticket_groups_from_db",
        lambda eid: ([], "snapshot", None),
    )
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 12345, "quantity": 2,
    })
    assert r.status_code == 404
    assert "snapshot-based" in r.json()["detail"]


def test_reserve_honeypot_rejects_bot(client):
    """Always-on honeypot: a filled 'hp' field → 400 before inventory."""
    r = client.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 1, "quantity": 1, "hp": "iam-a-bot",
    })
    assert r.status_code == 400


def test_reserve_requires_auth_flag(monkeypatch):
    """STOREFRONT_RESERVE_REQUIRES_AUTH on → the route calls require_auth(...)
    directly (not via Depends), so a rejecting require_auth short-circuits the
    request before any inventory lookup (line 6048-6049)."""
    monkeypatch.setattr(app_module, "STOREFRONT_RESERVE_REQUIRES_AUTH", True)

    from fastapi import HTTPException

    def _deny(authorization=None):
        raise HTTPException(401, "missing bearer token")

    monkeypatch.setattr(app_module, "require_auth", _deny)
    c = TestClient(app_module.app)
    r = c.post("/api/store/reserve", json={
        "event_id": 5, "ticket_group_id": 12345, "quantity": 2,
    })
    assert r.status_code == 401


# ============================================================
# Retail chat — _client_ip / _sanitize_chat_history / _proxy_retail_chat
# ============================================================

class _FakeResp:
    def __init__(self, body, status=200, raise_json=False):
        self._body = body
        self.status_code = status
        self._raise_json = raise_json

    def json(self):
        if self._raise_json:
            raise ValueError("not json")
        return self._body


@pytest.fixture
def capture_post(monkeypatch):
    calls = []

    def fake_post(url, headers=None, json=None, timeout=None):  # noqa: A002
        calls.append({"url": url, "headers": headers or {}, "json": json or {}})
        return _FakeResp({"reply": "ok"}, 200)

    monkeypatch.setattr(app_module.requests, "post", fake_post)
    monkeypatch.setattr(app_module, "STOREFRONT_CONCIERGE_ENABLED", True)
    return calls


def test_retail_terminal_scope_all(capture_post):
    c = TestClient(app_module.app)
    r = c.post("/api/retail-chat", json={"message": "hi there"})
    assert r.status_code == 200
    assert capture_post[0]["json"]["scope"] == "all"


def test_retail_store_scope_owned(capture_post):
    c = TestClient(app_module.app)
    r = c.post("/api/store/retail-chat", json={"message": "knicks"})
    assert r.status_code == 200
    assert capture_post[0]["json"]["scope"] == "owned"


def test_retail_store_disabled_canned_reply(monkeypatch):
    """Concierge OFF → canned reply, no upstream call (line 6233-6234)."""
    calls = []
    monkeypatch.setattr(app_module.requests, "post",
                        lambda *a, **k: calls.append(1))
    monkeypatch.setattr(app_module, "STOREFRONT_CONCIERGE_ENABLED", False)
    c = TestClient(app_module.app)
    r = c.post("/api/store/retail-chat", json={"message": "hi"})
    assert r.status_code == 200
    assert r.json()["reply"] == app_module._CONCIERGE_OFFLINE_REPLY
    assert calls == []


def test_retail_client_ip_xff_rightmost(capture_post):
    """X-Forwarded-For present → rightmost (proxy-appended) hop is forwarded
    (lines 6149-6153)."""
    c = TestClient(app_module.app)
    c.post("/api/store/retail-chat", json={"message": "hi"},
           headers={"x-forwarded-for": "1.2.3.4, 10.0.0.1"})
    assert capture_post[0]["headers"]["x-real-ip"] == "10.0.0.1"


def test_sanitize_chat_history_non_dict_payload():
    """Direct call: a non-dict payload → 400 (line 6163-6164). Unreachable via
    HTTP because the route param is typed `dict` (FastAPI 422s first), so we
    exercise the guard at the function level."""
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as ei:
        app_module._sanitize_chat_history(["not", "a", "dict"])
    assert ei.value.status_code == 400


def test_retail_client_ip_x_real_ip(capture_post):
    """No X-Forwarded-For but X-Real-IP present → that IP forwarded (6154-6156)."""
    c = TestClient(app_module.app)
    c.post("/api/store/retail-chat", json={"message": "hi"},
           headers={"x-real-ip": "198.51.100.7"})
    assert capture_post[0]["headers"]["x-real-ip"] == "198.51.100.7"


def test_retail_history_not_a_list_400(capture_post):
    """history present but not a list → 400 (line 6168-6169)."""
    c = TestClient(app_module.app)
    r = c.post("/api/retail-chat", json={"history": "nope"})
    assert r.status_code == 400
    assert capture_post == []


def test_retail_history_skips_invalid_items(capture_post):
    """Non-dict / wrong-role / empty-content items are dropped; a trailing
    valid user message survives (lines 6172-6181)."""
    c = TestClient(app_module.app)
    r = c.post("/api/retail-chat", json={"history": [
        "not-a-dict",
        {"role": "system", "content": "ignored-bad-role"},
        {"role": "user", "content": 123},        # non-str content dropped
        {"role": "assistant", "content": "   "},  # empty after strip dropped
        {"role": "user", "content": "  real question  "},
    ]})
    assert r.status_code == 200
    sent = capture_post[0]["json"]["history"]
    assert sent == [{"role": "user", "content": "real question"}]


def test_retail_no_valid_messages_400(capture_post):
    """All items invalid → 'no valid messages' 400 (line 6182-6183)."""
    c = TestClient(app_module.app)
    r = c.post("/api/retail-chat", json={"history": [
        {"role": "system", "content": "x"},
        {"role": "assistant", "content": 5},
    ]})
    assert r.status_code == 400
    assert capture_post == []


def test_retail_last_message_must_be_user(capture_post):
    c = TestClient(app_module.app)
    r = c.post("/api/retail-chat", json={"history": [
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "hello"},
    ]})
    assert r.status_code == 400


def test_retail_proxy_not_configured_503(monkeypatch):
    """SUPABASE_URL empty → 503 chat not configured (line 6190-6191)."""
    monkeypatch.setattr(app_module, "STOREFRONT_CONCIERGE_ENABLED", True)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "")
    c = TestClient(app_module.app)
    r = c.post("/api/store/retail-chat", json={"message": "hi"})
    assert r.status_code == 503


def test_retail_proxy_upstream_unreachable_502(monkeypatch):
    """requests.post raises → 502 unreachable (lines 6207-6209)."""
    monkeypatch.setattr(app_module, "STOREFRONT_CONCIERGE_ENABLED", True)

    def boom(*a, **k):
        raise ConnectionError("down")

    monkeypatch.setattr(app_module.requests, "post", boom)
    c = TestClient(app_module.app)
    r = c.post("/api/store/retail-chat", json={"message": "hi"})
    assert r.status_code == 502


def test_retail_proxy_malformed_json_passthrough(monkeypatch):
    """Upstream returns non-JSON body → error dict surfaced (lines 6212-6213)."""
    monkeypatch.setattr(app_module, "STOREFRONT_CONCIERGE_ENABLED", True)
    monkeypatch.setattr(
        app_module.requests, "post",
        lambda *a, **k: _FakeResp(None, status=200, raise_json=True),
    )
    c = TestClient(app_module.app)
    r = c.post("/api/store/retail-chat", json={"message": "hi"})
    assert r.status_code == 200
    assert "malformed" in r.json()["error"]


# ============================================================
# Share links — create / resolve / revoke / list
# ============================================================

def test_share_create_bad_event_id_400(as_user):
    c = as_user("user-A")
    r = c.post("/api/store/share", json={"event_id": "abc"})
    assert r.status_code == 400
    assert "integer" in r.json()["detail"]


def test_share_create_missing_event_id_400(as_user):
    c = as_user("user-A")
    r = c.post("/api/store/share", json={"event_id": 0})
    assert r.status_code == 400
    assert "required" in r.json()["detail"]


def test_share_create_note_too_long_400(as_user):
    c = as_user("user-A")
    r = c.post("/api/store/share", json={"event_id": 5, "note": "x" * 501})
    assert r.status_code == 400
    assert "too long" in r.json()["detail"]


def test_share_create_with_filters_and_note(as_user):
    """Exercises the persisted-filter branches + note set (6347-6353)."""
    c = as_user("user-A")
    r = c.post("/api/store/share", json={
        "event_id": 5,
        "filters": {
            "section": "100", "zones": ["lower"],
            "min_price": 10, "max_price": 200, "min_qty": 2,
        },
        "note": "great seats",
    })
    assert r.status_code == 200, r.text
    row = c.fakedb.tables["share_links"][0]
    assert row["note"] == "great seats"
    # _normalize_filters coerces section to a list form
    assert row["filters"]["section"] == ["100"]
    assert row["filters"]["min_price"] == 10


def test_share_create_expiry_user_pick_only(as_user):
    """expires_in_days set, no event ceiling → user pick chosen (6390-6407)."""
    c = as_user("user-A")
    r = c.post("/api/store/share", json={"event_id": 5, "expires_in_days": 7})
    assert r.status_code == 200, r.text
    assert c.fakedb.tables["share_links"][0]["expires_at"] is not None


def test_share_create_expiry_capped_by_event(as_user):
    """Both user pick + event ceiling → tighter (event ceiling) chosen
    (lines 6377-6383, 6402-6403)."""
    c = as_user("user-A", event_rows=[
        {"id": 5, "occurs_at_local": "2026-06-26T19:00:00-04:00"},
    ])
    r = c.post("/api/store/share", json={"event_id": 5, "expires_in_days": 365})
    assert r.status_code == 200, r.text
    # event ceiling (event_start +1h) is much tighter than 365 days out.
    # 2026-06-26T19:00-04:00 + 1h = 2026-06-27T00:00:00+00:00 (UTC).
    assert c.fakedb.tables["share_links"][0]["expires_at"].startswith("2026-06-27")


def test_share_create_expiry_days_not_integer_400(as_user):
    c = as_user("user-A")
    r = c.post("/api/store/share", json={"event_id": 5, "expires_in_days": "lots"})
    assert r.status_code == 400
    assert "must be an integer" in r.json()["detail"]


def test_share_create_expiry_days_out_of_range_400(as_user):
    c = as_user("user-A")
    r = c.post("/api/store/share", json={"event_id": 5, "expires_in_days": 9999})
    assert r.status_code == 400
    assert "between 1 and 365" in r.json()["detail"]


def test_share_create_event_lookup_exception_swallowed(as_user, monkeypatch):
    """A raising events read falls back to user-only expiry (lines 6384-6385).
    Force the events select to raise."""
    c = as_user("user-A")

    real_table = c.fakedb.table

    def boom_table(name):
        if name == "events":
            class _Boom:
                def select(self, *_a, **_k):
                    raise RuntimeError("events read failed")
            return _Boom()
        return real_table(name)

    monkeypatch.setattr(c.fakedb, "table", boom_table)
    r = c.post("/api/store/share", json={"event_id": 5, "expires_in_days": 3})
    assert r.status_code == 200, r.text


def test_share_create_collision_retry_succeeds(as_user):
    """First insert raises (PK collision) → one retry succeeds (6429-6434)."""
    c = as_user("user-A", fail_inserts=1)
    r = c.post("/api/store/share", json={"event_id": 5})
    assert r.status_code == 200, r.text
    assert len(c.fakedb.tables["share_links"]) == 1


def test_share_create_collision_twice_500(as_user):
    """Both inserts raise → sanitized 500 (lines 6435-6441)."""
    c = as_user("user-A", fail_inserts=2)
    r = c.post("/api/store/share", json={"event_id": 5})
    assert r.status_code == 500
    assert r.json()["detail"] == "could not create share link"


def test_share_create_auth_disabled_null_created_by():
    """user None (AUTH_DISABLED path) → created_by stored as NULL (line 6414)."""
    # Use a fresh fake + override require_auth to None.
    db = _FakeDB()
    app_module.app.dependency_overrides[app_module.require_auth] = lambda: None
    import server as _a
    _a.require_sb = lambda: db  # type: ignore
    try:
        c = TestClient(app_module.app)
        r = c.post("/api/store/share", json={"event_id": 5})
        assert r.status_code == 200, r.text
        assert db.tables["share_links"][0]["created_by"] is None
    finally:
        app_module.app.dependency_overrides.pop(app_module.require_auth, None)


# ---------- resolve ----------

@pytest.fixture
def stub_resolve(monkeypatch):
    """Stub _resolve_event_with_filters so the share-resolve route doesn't hit
    TEvo/DB for event detail."""
    monkeypatch.setattr(
        app_module, "_resolve_event_with_filters",
        lambda eid, filters, **k: {"event": {"id": eid}, "zones": []},
    )


def test_share_resolve_found_bumps_view(as_user, stub_resolve):
    c = as_user("user-A", share_rows=[{
        "id": "sh1", "event_id": 5, "filters": {}, "note": None,
        "created_at": "2026-06-20T00:00:00+00:00", "expires_at": None,
        "revoked_at": None, "view_count": 0, "last_viewed_at": None,
    }])
    r = c.get("/api/store/share/sh1")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["share"]["id"] == "sh1"
    assert body["event"]["id"] == 5
    assert c.fakedb.rpc_calls == [("bump_share_view", {"p_id": "sh1"})]


def test_share_resolve_not_found_404(as_user, stub_resolve):
    c = as_user("user-A", share_rows=[])
    r = c.get("/api/store/share/nope")
    assert r.status_code == 404


def test_share_resolve_revoked_410(as_user, stub_resolve):
    c = as_user("user-A", share_rows=[{
        "id": "sh1", "event_id": 5, "filters": {}, "note": None,
        "created_at": "2026-06-20T00:00:00+00:00", "expires_at": None,
        "revoked_at": "2026-06-21T00:00:00+00:00",
        "view_count": 0, "last_viewed_at": None,
    }])
    r = c.get("/api/store/share/sh1")
    assert r.status_code == 410
    assert "revoked" in r.json()["detail"]


def test_share_resolve_expired_410(as_user, stub_resolve):
    c = as_user("user-A", share_rows=[{
        "id": "sh1", "event_id": 5, "filters": {}, "note": None,
        "created_at": "2026-06-20T00:00:00+00:00",
        "expires_at": "2020-01-01T00:00:00+00:00",  # in the past
        "revoked_at": None, "view_count": 0, "last_viewed_at": None,
    }])
    r = c.get("/api/store/share/sh1")
    assert r.status_code == 410
    assert "expired" in r.json()["detail"]


def test_share_resolve_bad_expiry_does_not_500(as_user, stub_resolve):
    """A malformed expires_at is ignored (ValueError caught) (lines 6471-6472)."""
    c = as_user("user-A", share_rows=[{
        "id": "sh1", "event_id": 5, "filters": {}, "note": None,
        "created_at": "2026-06-20T00:00:00+00:00",
        "expires_at": "not-a-timestamp",
        "revoked_at": None, "view_count": 0, "last_viewed_at": None,
    }])
    r = c.get("/api/store/share/sh1")
    assert r.status_code == 200, r.text


def test_share_resolve_view_bump_failure_swallowed(as_user, monkeypatch, stub_resolve):
    """An RPC failure on bump_share_view is best-effort (lines 6478-6480)."""
    c = as_user("user-A", share_rows=[{
        "id": "sh1", "event_id": 5, "filters": {}, "note": None,
        "created_at": "2026-06-20T00:00:00+00:00", "expires_at": None,
        "revoked_at": None, "view_count": 0, "last_viewed_at": None,
    }])

    def boom_rpc(*_a, **_k):
        raise RuntimeError("rpc down")

    monkeypatch.setattr(c.fakedb, "rpc", boom_rpc)
    r = c.get("/api/store/share/sh1")
    assert r.status_code == 200, r.text


# ---------- revoke ----------

def test_share_revoke_owner(as_user):
    c = as_user("user-A", share_rows=[
        {"id": "s1", "event_id": 1, "created_by": "user-A", "revoked_at": None},
    ])
    r = c.delete("/api/store/share/s1")
    assert r.status_code == 200
    assert c.fakedb.tables["share_links"][0]["revoked_at"] is not None


def test_share_revoke_non_owner_404(as_user):
    c = as_user("user-B", share_rows=[
        {"id": "s1", "event_id": 1, "created_by": "user-A", "revoked_at": None},
    ])
    r = c.delete("/api/store/share/s1")
    assert r.status_code == 404
    assert c.fakedb.tables["share_links"][0]["revoked_at"] is None


def test_share_revoke_auth_disabled_skips_owner_filter():
    """user None → ownership eq-filter skipped, any row revokable (line 6508)."""
    db = _FakeDB(share_rows=[
        {"id": "s1", "event_id": 1, "created_by": "someone", "revoked_at": None},
    ])
    app_module.app.dependency_overrides[app_module.require_auth] = lambda: None
    import server as _a
    _a.require_sb = lambda: db  # type: ignore
    try:
        c = TestClient(app_module.app)
        r = c.delete("/api/store/share/s1")
        assert r.status_code == 200
        assert db.tables["share_links"][0]["revoked_at"] is not None
    finally:
        app_module.app.dependency_overrides.pop(app_module.require_auth, None)


# ---------- list ----------

def _live_row(rid, created_by="user-A", **over):
    base = {
        "id": rid, "event_id": 1, "created_by": created_by, "revoked_at": None,
        "filters": {}, "note": None, "created_at": "2026-06-20T00:00:00+00:00",
        "expires_at": None, "view_count": 0, "last_viewed_at": None,
    }
    base.update(over)
    return base


def test_share_list_owner_only(as_user):
    c = as_user("user-A", share_rows=[
        _live_row("a1", "user-A"), _live_row("b1", "user-B"),
    ])
    r = c.get("/api/store/shares")
    assert [s["id"] for s in r.json()["shares"]] == ["a1"]


def test_share_list_event_filter(as_user):
    """event_id query param adds the eq filter (line 6544)."""
    c = as_user("user-A", share_rows=[
        _live_row("a1", "user-A", event_id=1),
        _live_row("a2", "user-A", event_id=2),
    ])
    r = c.get("/api/store/shares?event_id=2")
    ids = [s["id"] for s in r.json()["shares"]]
    assert ids == ["a2"]


def test_share_list_include_inactive(as_user):
    """include_inactive=true keeps revoked rows + skips the active post-filter."""
    c = as_user("user-A", share_rows=[
        _live_row("live", "user-A"),
        _live_row("dead", "user-A", revoked_at="2026-06-21T00:00:00+00:00"),
    ])
    r = c.get("/api/store/shares?include_inactive=true")
    ids = sorted(s["id"] for s in r.json()["shares"])
    assert ids == ["dead", "live"]


def test_share_list_excludes_expired_when_active(as_user):
    """Default list post-filters out expired rows via _share_to_dict active
    flag (lines 6549-6553)."""
    c = as_user("user-A", share_rows=[
        _live_row("live", "user-A"),
        _live_row("expired", "user-A", expires_at="2020-01-01T00:00:00+00:00"),
    ])
    r = c.get("/api/store/shares")
    ids = [s["id"] for s in r.json()["shares"]]
    assert ids == ["live"]


# ============================================================
# Test-harness HTML pages (non-prod gate)
# ============================================================

@pytest.mark.parametrize("path", [
    "/store/test",
    "/store/test/search",
    "/store/test/performer",
    "/store/test/venue",
    "/store/test/event",
    "/store/test/share",
    "/store/test/media_test",
    "/store/test/trip",
    "/store/test/tour",
])
def test_store_test_pages_served_in_non_prod(path):
    c = TestClient(app_module.app)
    r = c.get(path)
    assert r.status_code == 200, path
    assert "html" in r.headers["content-type"].lower()


def test_store_test_pages_404_in_production(monkeypatch):
    """_is_production() true → 404 from the _require_non_prod gate (6576-6577)."""
    monkeypatch.setattr(app_module, "_is_production", lambda: True)
    c = TestClient(app_module.app)
    r = c.get("/store/test")
    assert r.status_code == 404
