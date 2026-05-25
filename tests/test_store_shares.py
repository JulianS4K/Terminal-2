"""Security-focused tests for /api/store/share* ownership enforcement.

The share-link CRUD endpoints had two ownership bugs closed in the
2026-05-16 audit (S1 revoke, S2 list): any authenticated user could
revoke OR enumerate ANY share link by id, leaking other creators'
filters / notes / view metrics (multi-tenant data leak). The fix filters
by `created_by = current_user.id`. These tests lock that in.

Key test-harness detail: the other store test modules run with
AUTH_DISABLED=true, which makes require_auth() return None and the
ownership filters SKIP (dev/admin mode). To exercise the *enforced* path
we override the require_auth dependency to inject a concrete user, which
takes precedence over the env-based function.

The Supabase client is a small STATEFUL fake that models the
insert -> select -> update round-trip on share_links plus the events
read, honoring .eq() filters (so a non-owner update matches 0 rows).
No real Supabase.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

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

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------- stateful share_links + events fake ----------

class _Resp:
    def __init__(self, data):
        self.data = data


_NULL = object()  # sentinel for is_(col, "null")


class _Query:
    """Records a select/update/insert + its eq/is_ filters, applies them at
    execute() against the shared row store."""

    def __init__(self, rows: list[dict]):
        self._rows = rows           # shared, mutable backing store
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
            self._rows.append(self._payload)
            return _Resp([self._payload])
        matched = [r for r in self._rows if self._match(r)]
        if self._mode == "update":
            for r in matched:
                r.update(self._payload)
            return _Resp(matched)
        return _Resp(matched)


class _FakeDB:
    def __init__(self, share_rows=None, event_rows=None):
        self.tables = {
            "share_links": share_rows if share_rows is not None else [],
            "events": event_rows if event_rows is not None else [],
        }

    def table(self, name):
        return _Query(self.tables.setdefault(name, []))


@pytest.fixture
def as_user(monkeypatch):
    """Returns a helper that wires a FakeDB + overrides require_auth to a
    given user id, yielding a TestClient. Cleans up the override after."""
    created = {"client": None}

    def _make(user_id, share_rows=None, event_rows=None):
        db = _FakeDB(share_rows=share_rows, event_rows=event_rows)
        monkeypatch.setattr(app_module, "require_sb", lambda: db)
        app_module.app.dependency_overrides[app_module.require_auth] = (
            (lambda: {"id": user_id}) if user_id is not None else (lambda: None)
        )
        c = TestClient(app_module.app)
        c.fakedb = db  # type: ignore[attr-defined]
        created["client"] = c
        return c

    yield _make
    app_module.app.dependency_overrides.pop(app_module.require_auth, None)


# ---------- create ----------

def test_share_create_persists_created_by(as_user):
    """A created share row carries created_by = the authenticated user id —
    the column the revoke/list ownership filters depend on."""
    client = as_user("user-A")
    r = client.post("/api/store/share", json={"event_id": 3346000, "filters": {}})
    assert r.status_code == 200, r.text
    rows = client.fakedb.tables["share_links"]
    assert len(rows) == 1
    assert rows[0]["created_by"] == "user-A"
    assert rows[0]["event_id"] == 3346000


# ---------- revoke ownership ----------

def test_share_revoke_owner_succeeds(as_user):
    client = as_user("user-A", share_rows=[
        {"id": "share1", "event_id": 1, "created_by": "user-A", "revoked_at": None},
    ])
    r = client.delete("/api/store/share/share1")
    assert r.status_code == 200, r.text
    assert client.fakedb.tables["share_links"][0]["revoked_at"] is not None


def test_share_revoke_non_owner_404s_and_does_not_mutate(as_user):
    """user-B may not revoke user-A's link. The created_by eq-filter matches
    0 rows → 404, and the row stays un-revoked. This is the S1 audit fix."""
    client = as_user("user-B", share_rows=[
        {"id": "shareA", "event_id": 1, "created_by": "user-A", "revoked_at": None},
    ])
    r = client.delete("/api/store/share/shareA")
    assert r.status_code == 404, r.text
    # Row must remain un-revoked — the non-owner's update matched nothing.
    assert client.fakedb.tables["share_links"][0]["revoked_at"] is None


def test_share_revoke_unknown_id_404s(as_user):
    client = as_user("user-A", share_rows=[])
    r = client.delete("/api/store/share/does-not-exist")
    assert r.status_code == 404


# ---------- list ownership ----------

def test_share_list_returns_only_own(as_user):
    """user-A's list excludes user-B's links. This is the S2 audit fix
    (was leaking every creator's filters/notes/view metrics)."""
    client = as_user("user-A", share_rows=[
        {"id": "a1", "event_id": 1, "created_by": "user-A", "revoked_at": None,
         "filters": {}, "note": None, "created_at": "2026-05-20T00:00:00+00:00",
         "expires_at": None, "view_count": 0, "last_viewed_at": None},
        {"id": "b1", "event_id": 2, "created_by": "user-B", "revoked_at": None,
         "filters": {}, "note": "secret", "created_at": "2026-05-20T00:00:00+00:00",
         "expires_at": None, "view_count": 9, "last_viewed_at": None},
    ])
    r = client.get("/api/store/shares")
    assert r.status_code == 200, r.text
    ids = [s["id"] for s in r.json()["shares"]]
    assert ids == ["a1"], f"list must only return owner's shares; got {ids}"


def test_share_list_excludes_revoked_by_default(as_user):
    client = as_user("user-A", share_rows=[
        {"id": "live", "event_id": 1, "created_by": "user-A", "revoked_at": None,
         "filters": {}, "note": None, "created_at": "2026-05-20T00:00:00+00:00",
         "expires_at": None, "view_count": 0, "last_viewed_at": None},
        {"id": "dead", "event_id": 1, "created_by": "user-A",
         "revoked_at": "2026-05-20T01:00:00+00:00",
         "filters": {}, "note": None, "created_at": "2026-05-20T00:00:00+00:00",
         "expires_at": None, "view_count": 0, "last_viewed_at": None},
    ])
    r = client.get("/api/store/shares")
    ids = [s["id"] for s in r.json()["shares"]]
    assert ids == ["live"], f"default list must exclude revoked; got {ids}"
