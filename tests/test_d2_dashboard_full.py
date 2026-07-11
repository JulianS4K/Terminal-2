"""Full-coverage tests for d2_dashboard.main.

Companion to tests/test_d2_dashboard.py (smoke tests). This file drives the
remaining uncovered branches to bring d2_dashboard/main.py to 100% line
coverage: the real require_auth path (AUTH_DISABLED off), vault-secret +
env-first helpers, client factories, the SQL-backed fetchers
(_fetch_unified_orders_page / _fetch_filtered_orders / _fetch_unified_orders_fast),
the metrics + health + sales-feed error branches, and the deep-order SQL helpers.

No real network / DB — everything is monkeypatched to in-memory fakes.
"""
from __future__ import annotations

import os
import sys
import pytest

# Force AUTH_DISABLED before import so the module-level constant evaluates true
# (matching the smoke-test file's convention). Individual tests that need the
# real auth gate flip d2_main.AUTH_DISABLED at runtime.
os.environ["AUTH_DISABLED"] = "true"
for key in ("RAILWAY_ENVIRONMENT", "ENVIRONMENT", "NODE_ENV", "PYTHON_ENV", "FLY_APP_NAME", "RENDER"):
    os.environ.pop(key, None)

from fastapi.testclient import TestClient

from d2_dashboard import main as d2_main


@pytest.fixture(autouse=True, scope="module")
def _cleanup_d2_env_after_module():
    yield
    os.environ.pop("AUTH_DISABLED", None)
    d2_main.AUTH_DISABLED = False


@pytest.fixture(autouse=True)
def _auth_disabled_by_default(monkeypatch):
    """Force AUTH_DISABLED=True before each test. The smoke-test module
    (test_d2_dashboard.py) flips d2_main.AUTH_DISABLED to False on its own
    teardown, so when this module runs *after* it the gate would otherwise be
    on and unrelated endpoints would 401. Tests that exercise the real auth
    path use the `auth_on` fixture, whose monkeypatch overrides this one and is
    auto-restored afterwards."""
    monkeypatch.setattr(d2_main, "AUTH_DISABLED", True)


@pytest.fixture
def client():
    return TestClient(d2_main.app)


# --------------------------------------------------------------------------
# require_auth — the real (AUTH_DISABLED=false) path
# --------------------------------------------------------------------------

class _FakeResp:
    def __init__(self, ok=True, payload=None):
        self.ok = ok
        self._payload = payload or {}
    def json(self):
        return self._payload


@pytest.fixture
def auth_on(monkeypatch):
    """Turn the JWT gate back on for the duration of a test."""
    monkeypatch.setattr(d2_main, "AUTH_DISABLED", False)
    monkeypatch.setattr(d2_main, "SUPABASE_URL", "https://example.invalid")
    monkeypatch.setattr(d2_main, "SUPABASE_ANON_KEY", "anon-key")


def test_require_auth_missing_bearer_401(auth_on, client):
    r = client.get("/healthz/detail")
    assert r.status_code == 401
    assert "missing bearer token" in r.json()["detail"]


def test_require_auth_no_supabase_config_500(monkeypatch, client):
    monkeypatch.setattr(d2_main, "AUTH_DISABLED", False)
    monkeypatch.setattr(d2_main, "SUPABASE_URL", None)
    monkeypatch.setattr(d2_main, "SUPABASE_ANON_KEY", None)
    r = client.get("/healthz/detail", headers={"Authorization": "Bearer xyz"})
    assert r.status_code == 500
    assert "Supabase auth not configured" in r.json()["detail"]


def test_require_auth_upstream_unreachable_502(auth_on, monkeypatch, client):
    def boom(*a, **k):
        raise RuntimeError("connection refused to db.internal")
    monkeypatch.setattr(d2_main.requests, "get", boom)
    r = client.get("/healthz/detail", headers={"Authorization": "Bearer xyz"})
    assert r.status_code == 502
    # Internal error detail must not leak.
    assert "connection refused" not in str(r.json())


def test_require_auth_invalid_session_401(auth_on, monkeypatch, client):
    monkeypatch.setattr(d2_main.requests, "get", lambda *a, **k: _FakeResp(ok=False))
    r = client.get("/healthz/detail", headers={"Authorization": "Bearer xyz"})
    assert r.status_code == 401
    assert "invalid session" in r.json()["detail"]


def test_require_auth_bad_audience_401(auth_on, monkeypatch, client):
    monkeypatch.setattr(d2_main.requests, "get",
                        lambda *a, **k: _FakeResp(payload={"aud": "anon"}))
    r = client.get("/healthz/detail", headers={"Authorization": "Bearer xyz"})
    assert r.status_code == 401
    assert "audience" in r.json()["detail"]


def test_require_auth_email_unconfirmed_403(auth_on, monkeypatch, client):
    monkeypatch.setattr(d2_main.requests, "get",
                        lambda *a, **k: _FakeResp(payload={"aud": "authenticated"}))
    r = client.get("/healthz/detail", headers={"Authorization": "Bearer xyz"})
    assert r.status_code == 403
    assert "email not confirmed" in r.json()["detail"]


def test_require_auth_wrong_domain_403(auth_on, monkeypatch, client):
    monkeypatch.setattr(d2_main.requests, "get", lambda *a, **k: _FakeResp(payload={
        "aud": "authenticated", "email_confirmed_at": "2026-01-01", "email": "x@evil.com",
    }))
    r = client.get("/healthz/detail", headers={"Authorization": "Bearer xyz"})
    assert r.status_code == 403
    assert "access restricted" in r.json()["detail"]


def test_require_auth_happy_path_returns_user(auth_on, monkeypatch, client):
    monkeypatch.setattr(d2_main.requests, "get", lambda *a, **k: _FakeResp(payload={
        "aud": "authenticated", "email_confirmed_at": "2026-01-01",
        "email": "julian@" + d2_main.ALLOWED_EMAIL_DOMAIN,
    }))
    r = client.get("/healthz/detail", headers={"Authorization": "Bearer good"})
    assert r.status_code == 200
    assert r.json()["service"] == "d2_dashboard"


# --------------------------------------------------------------------------
# _vault_secret / _mask_token
# --------------------------------------------------------------------------

class _RpcCall:
    def __init__(self, data): self._data = data
    def execute(self): return type("R", (), {"data": self._data})()


def test_vault_secret_none_when_no_sb(monkeypatch):
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    assert d2_main._vault_secret("ANY") is None


def test_vault_secret_string_payload(monkeypatch):
    sb = type("Sb", (), {"rpc": lambda self, n, a: _RpcCall("the-secret")})()
    monkeypatch.setattr(d2_main, "_sb", lambda: sb)
    assert d2_main._vault_secret("X") == "the-secret"


def test_vault_secret_empty_string_is_none(monkeypatch):
    sb = type("Sb", (), {"rpc": lambda self, n, a: _RpcCall("")})()
    monkeypatch.setattr(d2_main, "_sb", lambda: sb)
    assert d2_main._vault_secret("X") is None


def test_vault_secret_dict_payload(monkeypatch):
    sb = type("Sb", (), {"rpc": lambda self, n, a: _RpcCall({"get_app_secret": "v1"})})()
    monkeypatch.setattr(d2_main, "_sb", lambda: sb)
    assert d2_main._vault_secret("X") == "v1"
    sb2 = type("Sb", (), {"rpc": lambda self, n, a: _RpcCall({"value": "v2"})})()
    monkeypatch.setattr(d2_main, "_sb", lambda: sb2)
    assert d2_main._vault_secret("X") == "v2"


def test_vault_secret_swallows_exception(monkeypatch):
    class Sb:
        def rpc(self, n, a):
            raise RuntimeError("boom")
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    assert d2_main._vault_secret("X") is None



def test_mask_token_variants():
    assert d2_main._mask_token(None) is None
    assert d2_main._mask_token("abcd") == "***"
    assert d2_main._mask_token("abcde") == "...bcde"


# --------------------------------------------------------------------------
# Client factories
# --------------------------------------------------------------------------


def test_gotickets_client_none_without_creds(monkeypatch):
    monkeypatch.delenv("GOTICKETS_ACCESS_ID", raising=False)
    monkeypatch.delenv("GOTICKETS_API_SECRET", raising=False)
    monkeypatch.setattr(d2_main, "_vault_secret", lambda n: None)
    assert d2_main._gotickets_client() is None


def test_gotickets_client_built_with_creds(monkeypatch):
    monkeypatch.setenv("GOTICKETS_ACCESS_ID", "aid")
    monkeypatch.setenv("GOTICKETS_API_SECRET", "sec")
    assert d2_main._gotickets_client() is not None


# --------------------------------------------------------------------------
# _sb singleton init
# --------------------------------------------------------------------------

def test_sb_returns_none_when_unconfigured(monkeypatch):
    monkeypatch.setattr(d2_main, "_SB_INIT_ATTEMPTED", False)
    monkeypatch.setattr(d2_main, "_SB_SINGLETON", None)
    monkeypatch.setattr(d2_main, "SUPABASE_URL", None)
    monkeypatch.setattr(d2_main, "SUPABASE_SERVICE_ROLE_KEY", None)
    assert d2_main._sb() is None


def test_sb_init_failure_returns_none(monkeypatch):
    monkeypatch.setattr(d2_main, "_SB_INIT_ATTEMPTED", False)
    monkeypatch.setattr(d2_main, "_SB_SINGLETON", None)
    monkeypatch.setattr(d2_main, "SUPABASE_URL", "https://x.invalid")
    monkeypatch.setattr(d2_main, "SUPABASE_SERVICE_ROLE_KEY", "key")
    import supabase
    monkeypatch.setattr(supabase, "create_client",
                        lambda *a, **k: (_ for _ in ()).throw(RuntimeError("nope")))
    assert d2_main._sb() is None


def test_sb_init_success_caches_singleton(monkeypatch):
    monkeypatch.setattr(d2_main, "_SB_INIT_ATTEMPTED", False)
    monkeypatch.setattr(d2_main, "_SB_SINGLETON", None)
    monkeypatch.setattr(d2_main, "SUPABASE_URL", "https://x.invalid")
    monkeypatch.setattr(d2_main, "SUPABASE_SERVICE_ROLE_KEY", "key")
    sentinel = object()
    import supabase
    monkeypatch.setattr(supabase, "create_client", lambda *a, **k: sentinel)
    assert d2_main._sb() is sentinel
    # Second call short-circuits on the already-attempted flag.
    assert d2_main._sb() is sentinel


# --------------------------------------------------------------------------
# _fetch_cron_freshness
# --------------------------------------------------------------------------

def test_fetch_cron_freshness_none_when_no_sb(monkeypatch):
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    assert d2_main._fetch_cron_freshness() == {}


def test_fetch_cron_freshness_prefers_queue_phase(monkeypatch):
    rows = [
        {"source": "evo", "phase": "process", "jobname": "evo_proc"},
        {"source": "evo", "phase": "queue", "jobname": "evo_queue"},
        {"source": None, "phase": "queue"},  # skipped (no source)
    ]
    class Sb:
        def rpc(self, name):
            assert name == "d2_cron_freshness"
            return _RpcCall(rows)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_cron_freshness()
    assert out["evo"]["jobname"] == "evo_queue"
    assert None not in out


def test_fetch_cron_freshness_swallows_exception(monkeypatch):
    class Sb:
        def rpc(self, name):
            raise RuntimeError("rpc down")
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    assert d2_main._fetch_cron_freshness() == {}


# --------------------------------------------------------------------------
# _pull_event_window — no-sb + exception branches
# --------------------------------------------------------------------------

def test_pull_event_window_empty_when_no_sb(monkeypatch):
    d2_main._EVENT_WINDOW_CACHE.update({"at": 0.0, "rows": []})
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    assert d2_main._pull_event_window() == []


def test_pull_event_window_swallows_exception(monkeypatch):
    d2_main._EVENT_WINDOW_CACHE.update({"at": 0.0, "rows": []})
    class Q:
        def select(self, *a, **k): return self
        def gte(self, *a, **k): return self
        def lte(self, *a, **k): return self
        def execute(self): raise RuntimeError("view gone")
    class Sb:
        def table(self, n): return Q()
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    assert d2_main._pull_event_window() == []


def test_pull_event_window_queries_and_caches(monkeypatch):
    d2_main._EVENT_WINDOW_CACHE.update({"at": 0.0, "rows": []})
    rows = [{"tevo_event_id": 1, "event_name": "X"}]
    class Q:
        def select(self, *a, **k): return self
        def gte(self, *a, **k): return self
        def lte(self, *a, **k): return self
        def execute(self): return type("R", (), {"data": rows})()
    class Sb:
        def table(self, n): return Q()
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._pull_event_window()
    assert out == rows
    # Reset so other tests aren't affected by the warm cache.
    d2_main._EVENT_WINDOW_CACHE.update({"at": 0.0, "rows": []})


# --------------------------------------------------------------------------
# _fetch_unified_orders_page
# --------------------------------------------------------------------------

class _UOQuery:
    """Chainable PostgREST stub for unified_orders / v_event_base."""
    def __init__(self, rows, capture=None, raise_on_execute=False):
        self._rows = rows
        self._capture = capture if capture is not None else {}
        self._raise = raise_on_execute
    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def or_(self, expr): self._capture.setdefault("or_", []).append(expr); return self
    def ilike(self, *a, **k): self._capture["ilike"] = a; return self
    def gte(self, *a, **k): self._capture.setdefault("gte", []).append(a); return self
    def lt(self, *a, **k): self._capture.setdefault("lt", []).append(a); return self
    def lte(self, *a, **k): return self
    def in_(self, col, vals): self._capture["in"] = (col, list(vals)); return self
    def order(self, *a, **k): return self
    def range(self, *a, **k): self._capture.setdefault("range", []).append(a); return self
    def limit(self, *a, **k): return self
    def execute(self):
        if self._raise:
            raise RuntimeError("sql boom")
        return type("R", (), {"data": self._rows})()


def test_fetch_unified_orders_page_none_when_no_sb(monkeypatch):
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    assert d2_main._fetch_unified_orders_page(25) is None


def test_fetch_unified_orders_page_happy_with_event_backfill(monkeypatch):
    uo_rows = {
        "evo": [{"source": "evo", "source_order_id": "1", "tevo_event_id": 42,
                 "source_status": "accepted", "canonical_status": "accepted",
                 "quantity": 2, "gross_value": "100.0",
                 "created_at": "2026-05-13T19:00:00Z", "last_seen_at": "2026-05-13T20:00:00Z",
                 "event_name": None, "event_date": None}],
    }
    cap = {}
    class Sb:
        def table(self, name):
            if name == "unified_orders":
                # ex.map passes the source via .eq; we just return evo rows for
                # the first source and empty for others. Use a closure on a
                # mutable so each .table() returns a fresh query but we can't
                # know src here — instead key on call order via a counter.
                return _UOQuery(self._next_uo(), cap)
            if name == "v_event_base":
                return _UOQuery([{"tevo_event_id": 42, "event_name": "Knicks",
                                  "event_at_local": "2026-06-01T19:30:00-04:00",
                                  "event_at_utc": "2026-06-01T23:30:00Z"}], cap)
            raise AssertionError(name)
        _calls = {"n": 0}
        def _next_uo(self):
            # 5 sources pulled; give evo rows once, rest empty.
            self._calls["n"] += 1
            return uo_rows["evo"] if self._calls["n"] == 1 else []
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_unified_orders_page(25)
    assert out is not None
    # event backfill populated from v_event_base
    rows = [r for r in out["rows"] if r["order_id"] == "1"]
    assert rows and rows[0]["event_name"] == "Knicks"
    assert rows[0]["event_date"] == "2026-06-01T19:30:00-04:00"
    assert out["per_source_count"]["evo"] == 1
    assert out["per_source_as_of"]["evo"] == "2026-05-13T20:00:00Z"


def test_fetch_unified_orders_page_per_source_query_error(monkeypatch):
    """A per-source query that raises is caught inside _pull_one → any_error
    set, result still returned (line 847-848, 903-904)."""
    class Sb:
        def table(self, name):
            if name == "unified_orders":
                return _UOQuery([], raise_on_execute=True)
            return _UOQuery([])
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_unified_orders_page(25)
    assert out["rows"] == []
    assert "error" in out


def test_fetch_unified_orders_page_outer_exception(monkeypatch):
    """An exception outside _pull_one (e.g. sorted/len fails) hits the outer
    except → 907."""
    class Sb:
        def table(self, name):
            raise RuntimeError("table broke")
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    # Force the outer try to blow up: ThreadPoolExecutor.map will surface the
    # per-source exception inside _pull_one, so instead break len(_SQL...) path.
    # Simplest: monkeypatch _SQL_BACKED_SOURCES to a non-iterable-len object is
    # hard; instead break sb.table at v_event_base by giving a row with a bad
    # tevo_event_id so the second query path runs and raises.
    rows = [{"source": "evo", "source_order_id": "1", "tevo_event_id": 5,
             "event_name": None, "quantity": 1, "gross_value": "1",
             "created_at": "x", "last_seen_at": "y",
             "source_status": "accepted", "canonical_status": "accepted"}]
    class Sb2:
        _n = {"i": 0}
        def table(self, name):
            if name == "unified_orders":
                self._n["i"] += 1
                return _UOQuery(rows if self._n["i"] == 1 else [])
            if name == "v_event_base":
                return _UOQuery([], raise_on_execute=True)
            raise AssertionError(name)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb2())
    out = d2_main._fetch_unified_orders_page(25)
    assert out["rows"] == []
    assert "error" in out


# --------------------------------------------------------------------------
# _build_order_rows
# --------------------------------------------------------------------------

def test_build_order_rows_backfills_event():
    class Sb:
        def table(self, name):
            assert name == "v_event_base"
            return _UOQuery([{"tevo_event_id": 7, "event_name": "Backfilled",
                              "event_at_utc": "2026-06-01T23:30:00Z"}])
    rows = d2_main._build_order_rows(Sb(), [
        {"source": "evo", "source_order_id": "1", "tevo_event_id": 7,
         "event_name": None, "quantity": 3, "gross_value": "9.5",
         "source_status": "accepted", "canonical_status": "accepted",
         "created_at": "2026-05-13T19:00:00Z"},
    ])
    assert rows[0]["event_name"] == "Backfilled"
    assert rows[0]["event_date"] == "2026-06-01T23:30:00Z"
    assert rows[0]["qty"] == 3
    assert rows[0]["amount"] == 9.5


def test_build_order_rows_no_missing_ids_skips_event_query():
    class Sb:
        def table(self, name):
            raise AssertionError("should not query v_event_base")
    rows = d2_main._build_order_rows(Sb(), [
        {"source": "evo", "source_order_id": "1", "event_name": "Native",
         "event_date": "2026-06-01", "quantity": 1, "gross_value": "5",
         "source_status": "accepted", "canonical_status": "accepted",
         "created_at": "2026-05-13T19:00:00Z"},
    ])
    assert rows[0]["event_name"] == "Native"


# --------------------------------------------------------------------------
# _fetch_filtered_orders
# --------------------------------------------------------------------------

def test_fetch_filtered_orders_none_when_no_sb(monkeypatch):
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    assert d2_main._fetch_filtered_orders("evo", 25) is None


def test_fetch_filtered_single_source_full_window(monkeypatch):
    cap = {}
    rows = [{"source": "evo", "source_order_id": "1", "tevo_event_id": None,
             "event_name": "Native Show", "event_date": "2026-06-01",
             "quantity": 2, "gross_value": "100", "source_status": "accepted",
             "canonical_status": "accepted", "created_at": "2026-05-13T19:00:00Z",
             "last_seen_at": "2026-05-13T20:00:00Z"}]
    class Sb:
        def table(self, name):
            return _UOQuery(rows, cap)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_filtered_orders("evo", 10, page=1, include_terminal=False,
                                         q="Show", when="upcoming")
    assert out["per_source_count"]["evo"] == 1
    assert out["has_more"] is False  # 1 row < per_source(10)
    # q → ilike pushed down; when=upcoming → gte cutoff
    assert cap["ilike"][0] == "event_name"
    assert "gte" in cap


def test_fetch_filtered_when_past_uses_lt(monkeypatch):
    cap = {}
    class Sb:
        def table(self, name):
            return _UOQuery([], cap)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_filtered_orders("evo", 10, when="past", include_terminal=True)
    assert "lt" in cap
    assert out["has_more"] is False


def test_fetch_filtered_all_sources_has_more(monkeypatch):
    # per_page // 5 = 1 per source; returning 1 row each → filled → has_more.
    class Sb:
        def table(self, name):
            if name == "v_event_base":
                return _UOQuery([])
            return _UOQuery([{"source": "evo", "source_order_id": "1",
                              "tevo_event_id": None, "event_name": "N",
                              "event_date": "2026-06-01", "quantity": 1,
                              "gross_value": "1", "source_status": "accepted",
                              "canonical_status": "accepted",
                              "created_at": "2026-05-13T19:00:00Z",
                              "last_seen_at": "2026-05-13T20:00:00Z"}])
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_filtered_orders("all", 5)
    assert out["has_more"] is True


def test_fetch_filtered_per_source_error(monkeypatch):
    class Sb:
        def table(self, name):
            return _UOQuery([], raise_on_execute=True)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_filtered_orders("evo", 10)
    assert "error" in out


def test_fetch_filtered_outer_exception(monkeypatch):
    class Sb:
        _n = {"i": 0}
        def table(self, name):
            if name == "v_event_base":
                return _UOQuery([], raise_on_execute=True)
            self._n["i"] += 1
            return _UOQuery([{"source": "evo", "source_order_id": "1",
                              "tevo_event_id": 5, "event_name": None,
                              "event_date": None, "quantity": 1, "gross_value": "1",
                              "source_status": "accepted", "canonical_status": "accepted",
                              "created_at": "2026-05-13T19:00:00Z",
                              "last_seen_at": "2026-05-13T20:00:00Z"}])
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_filtered_orders("evo", 10)
    assert out["has_more"] is False
    assert "error" in out


# --------------------------------------------------------------------------
# _fetch_unified_orders_fast
# --------------------------------------------------------------------------

def test_fetch_unified_orders_fast_none_when_no_sb(monkeypatch):
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    assert d2_main._fetch_unified_orders_fast(25) is None


def test_fetch_unified_orders_fast_happy(monkeypatch):
    rows = [{"source": "evo", "source_order_id": "1", "tevo_event_id": None,
             "source_status": "accepted", "canonical_status": "accepted",
             "quantity": 2, "gross_value": "100.0",
             "created_at": "2026-05-13T19:00:00Z", "last_seen_at": "2026-05-13T20:00:00Z",
             "event_name": "Show", "event_date": "2026-06-01"}]
    cap = {}
    class Sb:
        def table(self, name):
            return _UOQuery(rows, cap)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_unified_orders_fast(25)
    assert out["per_source_count"]["evo"] == 1
    assert out["rows"][0]["event_name"] == "Show"
    assert out["per_source_as_of"]["evo"] == "2026-05-13T20:00:00Z"
    # active-only default applies the or_ filter
    assert "or_" in cap


def test_fetch_unified_orders_fast_include_terminal_skips_filter(monkeypatch):
    cap = {}
    class Sb:
        def table(self, name):
            return _UOQuery([], cap)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    d2_main._fetch_unified_orders_fast(25, include_terminal=True)
    assert "or_" not in cap


def test_fetch_unified_orders_fast_exception(monkeypatch):
    class Sb:
        def table(self, name):
            return _UOQuery([], raise_on_execute=True)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_unified_orders_fast(25)
    assert out["rows"] == []
    assert "error" in out


# --------------------------------------------------------------------------
# orders endpoint — when clamp + filtered 503 + fast 503
# --------------------------------------------------------------------------

def test_root_500_when_shell_missing(monkeypatch, client):
    """When the dashboard.html shell didn't load at import time, `/` raises a
    500 rather than serving an empty page."""
    monkeypatch.setattr(d2_main, "PROD_MISSING_SUPABASE", False)
    monkeypatch.setattr(d2_main, "_DASHBOARD_SHELL", None)
    r = client.get("/")
    assert r.status_code == 500
    assert "dashboard.html missing" in r.json()["detail"]


def test_orders_bad_when_clamps_to_all(monkeypatch, client):
    captured = {}
    def fake_filtered(source, per_page, page=1, include_terminal=False, q=None, when="all"):
        captured["when"] = when
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}, "has_more": False}
    monkeypatch.setattr(d2_main, "_fetch_filtered_orders", fake_filtered)
    # bad when + a q to force the filtered path
    body = client.get("/api/d2/orders?when=garbage&q=X").json()
    assert captured["when"] == "all"
    assert body["when"] == "all"


def test_orders_filtered_503_when_unconfigured(monkeypatch, client):
    monkeypatch.setattr(d2_main, "_fetch_filtered_orders",
                        lambda *a, **k: None)
    r = client.get("/api/d2/orders?source=evo")
    assert r.status_code == 503


def test_orders_fast_503_when_unconfigured(monkeypatch, client):
    monkeypatch.setattr(d2_main, "_fetch_unified_orders_fast", lambda *a, **k: None)
    r = client.get("/api/d2/orders?fast=1")
    assert r.status_code == 503


# --------------------------------------------------------------------------
# Deep-order SQL helpers (direct calls)
# --------------------------------------------------------------------------

class _DeepQuery:
    def __init__(self, data): self._data = data
    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def limit(self, *a, **k): return self
    def execute(self): return type("R", (), {"data": self._data})()


def test_deep_order_helpers_return_first_row():
    sb_evo = type("S", (), {"table": lambda self, n: _DeepQuery([{"evo_order_id": "1"}])})()
    assert d2_main._deep_order_evo_sql(sb_evo, "1")["evo_order_id"] == "1"

    sb_sg = type("S", (), {"table": lambda self, n: _DeepQuery([{"sg_sale_id": "S-1"}])})()
    assert d2_main._deep_order_seatgeek_sales_sql(sb_sg, "S-1")["sg_sale_id"] == "S-1"

    sb_tp = type("S", (), {"table": lambda self, n: _DeepQuery([{"tp_order_id": "T-1"}])})()
    assert d2_main._deep_order_tickpick_sql(sb_tp, "T-1")["tp_order_id"] == "T-1"

    sb_vv = type("S", (), {"table": lambda self, n: _DeepQuery([{"vivid_order_id": "V-1"}])})()
    assert d2_main._deep_order_vivid_sql(sb_vv, "V-1")["vivid_order_id"] == "V-1"


def test_deep_order_helpers_empty_returns_dict():
    sb = type("S", (), {"table": lambda self, n: _DeepQuery([])})()
    assert d2_main._deep_order_evo_sql(sb, "x") == {}


def test_deep_order_gotickets_calls_get_sale():
    class C:
        def get_sale(self, oid):
            return {"id": oid}
    assert d2_main._deep_order_gotickets(C(), "S-9")["id"] == "S-9"


def test_order_detail_seatgeek_sales_route(monkeypatch, client):
    class Q:
        def select(self, *a, **k): return self
        def eq(self, col, val):
            assert col == "sg_sale_id"
            return self
        def limit(self, *a, **k): return self
        def execute(self): return type("R", (), {"data": [{"sg_sale_id": "S-1"}]})()
    class Sb:
        def table(self, name):
            assert name == "seatgeek_sales_snapshots"
            return Q()
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    r = client.get("/api/d2/order/seatgeek_sales/S-1")
    assert r.status_code == 200
    assert r.json()["data"]["sg_sale_id"] == "S-1"


def test_order_detail_exception_returns_ok_false(monkeypatch, client):
    class Q:
        def select(self, *a, **k): return self
        def eq(self, *a, **k): return self
        def limit(self, *a, **k): return self
        def execute(self): raise RuntimeError("db boom")
    class Sb:
        def table(self, name): return Q()
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    r = client.get("/api/d2/order/evo/42")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert body["error"]  # scrubbed message


# --------------------------------------------------------------------------
# /api/d2/health — error branches
# --------------------------------------------------------------------------

def test_health_swallows_cron_and_counts_errors(monkeypatch, client):
    class FailingRpc:
        def execute(self): raise RuntimeError("rpc down")
    class FailingTable:
        def select(self, *a, **k): return self
        def eq(self, *a, **k): return self
        def is_(self, *a, **k): return self
        def order(self, *a, **k): return self
        def limit(self, *a, **k): return self
        def execute(self): raise RuntimeError("counts down")
    class Sb:
        def rpc(self, name):
            return FailingRpc()
        def table(self, name):
            return FailingTable()
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    r = client.get("/api/d2/health")
    assert r.status_code == 200
    body = r.json()
    # cron rpc failed → empty list; queue/count loop failed → queues empty.
    assert body["crons"] == []
    assert "fulfillby_fields" in body


def test_health_queue_query_failure_sets_sentinel(monkeypatch, client):
    """The pending-queue per-source try/except sets -1 when that single query
    fails, while the unified_orders counts still succeed."""
    class PendingFail:
        def select(self, *a, **k): return self
        def is_(self, *a, **k): raise RuntimeError("pending broke")
    class CountQuery:
        def select(self, *a, **k): return self
        def eq(self, *a, **k): return self
        def order(self, *a, **k): return self
        def limit(self, *a, **k): return self
        def execute(self):
            return type("R", (), {"count": 3, "data": [{"last_seen_at": "2026-05-13T20:00:00Z"}]})()
    class Sb:
        def rpc(self, name):
            return type("Rpc", (), {"execute": lambda s: type("R", (), {"data": []})()})()
        def table(self, name):
            if name.endswith("_pending"):
                return PendingFail()
            return CountQuery()
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    body = client.get("/api/d2/health").json()
    assert body["queues"]["tickpick"] == -1
    assert body["queues"]["vivid"] == -1
    assert body["sql_counts"]["evo"]["rows"] == 3
    assert body["sql_counts"]["evo"]["newest_seen"] == "2026-05-13T20:00:00Z"


# --------------------------------------------------------------------------
# _today_start_utc fallback when zoneinfo unavailable
# --------------------------------------------------------------------------

def test_today_start_utc_falls_back_without_zoneinfo(monkeypatch):
    import builtins
    real_import = builtins.__import__
    def fake_import(name, *a, **k):
        if name == "zoneinfo":
            raise ImportError("no tzdata")
        return real_import(name, *a, **k)
    monkeypatch.setattr(builtins, "__import__", fake_import)
    ts = d2_main._today_start_utc()
    assert ts.tzinfo is not None
    # UTC-midnight fallback → hour 0.
    assert ts.hour == 0


# --------------------------------------------------------------------------
# Metrics RPC helper wrappers + error branches
# --------------------------------------------------------------------------

def test_metrics_rpc_helpers_pass_args():
    from datetime import datetime, timezone
    captured = {}
    class Sb:
        def rpc(self, name, args):
            captured[name] = args
            return _RpcCall([{"ok": True}])
    sb = Sb()
    s = datetime(2026, 5, 1, tzinfo=timezone.utc)
    e = datetime(2026, 5, 2, tzinfo=timezone.utc)
    assert d2_main._metrics_window_rows(sb, s, e) == [{"ok": True}]
    assert d2_main._metrics_hourly_buckets(sb, s, e) == [{"ok": True}]
    assert d2_main._metrics_top_events(sb, s, e) == [{"ok": True}]
    assert d2_main._metrics_hot_events(sb, s, e) == [{"ok": True}]
    assert d2_main._metrics_biggest_sales(sb, s) == [{"ok": True}]
    assert d2_main._metrics_sales_gaps(sb) == [{"ok": True}]
    assert "p_since" in captured["d2_metrics_biggest_sales"]


def test_metrics_biggest_sales_none_since_omits_arg():
    captured = {}
    class Sb:
        def rpc(self, name, args):
            captured["args"] = args
            return _RpcCall([])
    d2_main._metrics_biggest_sales(Sb(), None)
    assert "p_since" not in captured["args"]


def test_metrics_biggest_sales_string_since():
    captured = {}
    class Sb:
        def rpc(self, name, args):
            captured["args"] = args
            return _RpcCall([])
    d2_main._metrics_biggest_sales(Sb(), "2026-05-01T00:00:00Z")
    assert captured["args"]["p_since"] == "2026-05-01T00:00:00Z"


def test_metrics_all_legs_fail_recorded_in_errors(monkeypatch, client):
    """Every RPC raises → bundle still 200 with all legs in errors[],
    covering the error branch of each _safe_* closure."""
    class FailRpc:
        def execute(self): raise RuntimeError("leg down")
    class Sb:
        def rpc(self, name, args=None):
            return FailRpc()
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    r = client.get("/api/d2/metrics")
    assert r.status_code == 200
    body = r.json()
    legs = {e["leg"] for e in body["errors"]}
    # the 5 named legs + at least one window leg
    assert {"hourly_buckets", "top_events", "hot_events", "biggest_sales", "sales_gaps"} <= legs
    assert any(l.startswith("window.") for l in legs)


# --------------------------------------------------------------------------
# /api/d2/sales-feed — query exception branch
# --------------------------------------------------------------------------

def test_sales_feed_exception_returns_ok_false(monkeypatch, client):
    class Q:
        def select(self, *a, **k): return self
        def in_(self, *a, **k): return self
        def order(self, *a, **k): return self
        def limit(self, *a, **k): return self
        def execute(self): raise RuntimeError("feed down")
    class Sb:
        def table(self, name): return Q()
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    r = client.get("/api/d2/sales-feed")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert body["rows"] == []
