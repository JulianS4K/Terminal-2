"""Smoke tests for d2_dashboard.

Each endpoint is hit through FastAPI's TestClient with the client fetchers
monkey-patched to deterministic stubs. We do NOT exercise real network
calls — the order-client modules are tested elsewhere
(test_readonly_guards.py, etc.).

The contract under test:
  1. /healthz returns 200 unauthenticated.
  2. /api/d2/orders requires Authorization unless AUTH_DISABLED is on
     AND no production indicator is set.
  3. With AUTH_DISABLED + all 4 stubs returning rows, the merged response
     contains rows from each source and a sources summary.
  4. If one source raises, the other three still render and the broken
     source surfaces as ok=False with an error string.
  5. SeatData endpoint returns ok=False gracefully when no creds.
"""
from __future__ import annotations

import os
import pytest

# Force AUTH_DISABLED before import so the module-level constant evaluates true.
os.environ["AUTH_DISABLED"] = "true"
# Make sure no production indicator is set in the test env.
for key in ("RAILWAY_ENVIRONMENT", "ENVIRONMENT", "NODE_ENV", "PYTHON_ENV", "FLY_APP_NAME", "RENDER"):
    os.environ.pop(key, None)

from fastapi.testclient import TestClient

from d2_dashboard import main as d2_main


@pytest.fixture(autouse=True, scope="module")
def _cleanup_d2_env_after_module():
    """Restore env + module state after this test module finishes so a later
    test module importing `d2_dashboard.main` doesn't inherit AUTH_DISABLED=true."""
    yield
    os.environ.pop("AUTH_DISABLED", None)
    # Module is already imported; reset the constant on the loaded module so
    # any test relying on `d2_main.AUTH_DISABLED` sees the default after teardown.
    d2_main.AUTH_DISABLED = False


@pytest.fixture
def client(monkeypatch):
    return TestClient(d2_main.app)


def _stub_evo(per_page, page=1):
    return {
        "source": "evo",
        "ok": True,
        "rows": [{
            "source": "evo", "order_id": "111", "event_name": "Knicks vs Lakers",
            "event_date": "2026-06-01T19:30:00Z", "qty": 2, "status": "completed",
            "amount": 450.0, "currency": "USD", "ordered_at": "2026-05-10T12:00:00Z",
        }],
        "total": 1,
    }


def _stub_sg(per_page, page=1):
    # Post-2026-05-16 rewire: SG source on the orders feed is the broker
    # firehose (seatgeek_sales_snapshots). Rows are terminal/fulfilled
    # observations — the dashboard's Active pill filters them out by
    # construction; the All pill surfaces them.
    return {
        "source": "seatgeek_sales",
        "ok": True,
        "rows": [{
            "source": "seatgeek_sales", "order_id": "SG-SALE-9", "event_name": "Hamilton",
            "event_date": "2026-07-01T20:00:00Z", "qty": 4, "status": "sold",
            "canonical_status": "fulfilled",
            "amount": 1200.5, "currency": "USD", "ordered_at": "2026-05-12T09:00:00Z",
        }],
        "total": 1,
    }


def _stub_tickpick(per_page, page=1):
    return {"source": "tickpick", "ok": True, "rows": [], "total": 0}


def _stub_vivid_err(per_page, page=1):
    return {"source": "vivid", "ok": False, "error": "boom", "rows": []}


def test_healthz_public_minimal(client):
    """Public /healthz exposes only ok + service — no fingerprintable detail."""
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body == {"ok": True, "service": "d2_dashboard"}


class _ReadyzQuery:
    """Minimal chainable stub for sb.table(...).select(...).limit(...).execute()."""
    def __init__(self, raises=False):
        self._raises = raises
    def select(self, *a, **k): return self
    def limit(self, *a, **k): return self
    def execute(self):
        if self._raises:
            raise RuntimeError("connection refused to db.internal:5432")
        return type("R", (), {"data": [{"source": "evo"}]})()


def test_readyz_reachable_when_supabase_responds(monkeypatch, client):
    """/readyz does a real LIMIT-1 read against unified_orders. When Supabase
    answers, it returns 200 + supabase=reachable — the readiness signal that
    /healthz (liveness only) can't give."""
    sb = type("Sb", (), {"table": lambda self, *a, **k: _ReadyzQuery()})()
    monkeypatch.setattr(d2_main, "_sb", lambda: sb)
    r = client.get("/readyz")
    assert r.status_code == 200
    assert r.json() == {"ok": True, "service": "d2_dashboard", "supabase": "reachable"}


def test_readyz_503_when_supabase_not_configured(monkeypatch, client):
    """No Supabase client (unset/missing env) → 503 + supabase=not_configured.
    This is the failure mode /healthz can't see (process is up, DB isn't)."""
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    r = client.get("/readyz")
    assert r.status_code == 503
    assert r.json()["supabase"] == "not_configured"


def test_readyz_503_when_supabase_unreachable_without_leaking_detail(monkeypatch, client):
    """Client present but the probe read raises (wrong URL / DB down) → 503 +
    supabase=unreachable. The exception detail must NOT leak into the client
    body (it goes to stderr); only the reachability enum is exposed."""
    sb = type("Sb", (), {"table": lambda self, *a, **k: _ReadyzQuery(raises=True)})()
    monkeypatch.setattr(d2_main, "_sb", lambda: sb)
    r = client.get("/readyz")
    assert r.status_code == 503
    body = r.json()
    assert body["supabase"] == "unreachable"
    assert "connection refused" not in str(body)  # no internal detail leaks


def test_cors_storefront_origin_allowed(client):
    """D0's /undelivered scaffold on vibepass-storefront-test.onrender.com
    must be able to fetch /api/d2/* cross-origin per the unified architecture
    (bot_chat 194 Option C + row 216 CORS gap flag).

    Preflight request from the storefront origin should be allowed with
    credentialed methods + Authorization header echo.
    """
    r = client.options(
        "/api/d2/orders",
        headers={
            "Origin": "https://vibepass-storefront-test.onrender.com",
            "Access-Control-Request-Method": "GET",
            "Access-Control-Request-Headers": "authorization",
        },
    )
    assert r.status_code in (200, 204)
    assert r.headers.get("access-control-allow-origin") == "https://vibepass-storefront-test.onrender.com"
    assert "GET" in r.headers.get("access-control-allow-methods", "")
    assert r.headers.get("access-control-allow-credentials") == "true"


def test_cors_unknown_origin_not_echoed(client):
    """Random origin not in the whitelist should NOT be echoed back —
    prevents accidental opening of the API to arbitrary sites if the
    operator forgets to update the allowlist."""
    r = client.options(
        "/api/d2/orders",
        headers={
            "Origin": "https://evil.example.com",
            "Access-Control-Request-Method": "GET",
        },
    )
    # FastAPI/Starlette CORSMiddleware returns 400 OR omits the allow-origin
    # header on a non-whitelisted origin — either is acceptable. Key is the
    # browser will block the request.
    assert r.headers.get("access-control-allow-origin") != "https://evil.example.com"


def test_cors_localhost_dev_allowed(client):
    """Local dev (uvicorn at any port) must work — operator runs the dashboard
    on localhost:8000 typically; D0 may run their shell on a different port."""
    r = client.options(
        "/api/d2/orders",
        headers={
            "Origin": "http://localhost:8000",
            "Access-Control-Request-Method": "GET",
        },
    )
    assert r.status_code in (200, 204)
    assert r.headers.get("access-control-allow-origin") == "http://localhost:8000"


def test_healthz_detail_under_auth_disabled(client):
    """Full diagnostic moved to /healthz/detail behind require_auth. With
    AUTH_DISABLED=true (test env), the route returns the rich shape."""
    r = client.get("/healthz/detail")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["service"] == "d2_dashboard"
    assert body["auth_disabled"] is True
    assert "python" in body
    assert set(body["brokers"]) == {"evo", "seatgeek", "tickpick", "vivid", "seatdata", "gotickets"}
    # Per-broker diag carries the env-var name actually read + a masked tail
    # so the operator can verify a token rotation took effect (e.g. when a
    # 401 fires on TickPick and they need to confirm the right key is loaded).
    assert "token_set" in body["brokers"]["tickpick"]
    assert "token_env_var" in body["brokers"]["tickpick"]
    assert "token_masked" in body["brokers"]["tickpick"]
    assert body["templates"]["dashboard_html_exists"] is True
    # Lane-status fields default to data-collection / rebuild-pending.
    assert body["phase"] == "data-collection"
    assert body["ui"] == "rebuild-pending"


def test_root_serves_html(client):
    """Root serves the Undelivered shell (rebranded from prior "D2 Orders
    Dashboard" per D0 architecture decision 2026-05-15, bot_chat 194 Option C).
    Same FastAPI app, customer-service framing."""
    r = client.get("/")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/html")
    assert "Undelivered" in r.text


def test_root_injects_config_blob(client):
    """The shell substitutes a JSON config blob in place of the placeholder
    so the front-end module can read window.__D2_CONFIG__ synchronously
    without a /api/d2/config-public round trip on boot."""
    r = client.get("/")
    assert r.status_code == 200
    body = r.text
    # Placeholder must be fully replaced.
    assert "__D2_CONFIG_JSON__" not in body
    # The config script tag is present and contains valid JSON with expected keys.
    assert '<script id="d2-config" type="application/json">' in body
    # Expected fields land in the inline blob.
    assert '"allowed_email_domain":' in body
    assert '"auth_disabled":' in body
    assert '"canonical_origin":' in body


def test_root_returns_503_when_prod_missing_supabase_with_auth_on(monkeypatch, client):
    """`/` returns 503 when the boot guard fires — operator set
    AUTH_DISABLED=false on a prod platform without Supabase env vars. Catches
    the misconfiguration before users see a 'Server misconfigured' panel.
    With AUTH_DISABLED=true (the default), Supabase env vars are unused and
    the guard never trips."""
    monkeypatch.setattr(d2_main, "PROD_MISSING_SUPABASE", True)
    r = client.get("/")
    assert r.status_code == 503
    # Healthz stays public + minimal regardless.
    r = client.get("/healthz")
    assert r.status_code == 200


def test_static_css_and_js_mounted(client):
    """The split assets must be reachable under /static/d2/ so the shell's
    <link> and <script src=> resolve. 404 here means StaticFiles didn't mount."""
    r = client.get("/static/d2/dashboard.css")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/css")
    assert "--bg:" in r.text  # CSS variables block

    r = client.get("/static/d2/dashboard.js")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("application/javascript") or \
           r.headers["content-type"].startswith("text/javascript")
    assert "window.__D2_CONFIG__" in r.text


def test_orders_503_when_supabase_unconfigured(monkeypatch, client):
    """Dashboard is SQL-only — when Supabase isn't configured the orders
    endpoint surfaces 503 explicitly instead of silently serving empty."""
    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", lambda n, p=1, include_terminal=False: None)
    r = client.get("/api/d2/orders")
    assert r.status_code == 503


def test_orders_serves_unified_orders_with_per_source_chips(monkeypatch, client):
    """All 5 sources (evo / seatgeek_sales / seatdata / tickpick / vivid)
    get origin=sql chips with per-source row counts and `as_of` freshness
    from `unified_orders.last_seen_at`. No upstream-API leg — the dashboard
    is SQL-only as of the 2026-05-14 cutover. Post-2026-05-16 the SG source
    is the broker firehose (seatgeek_sales_snapshots), not the dormant
    seatgeek_orders seller table."""
    monkeypatch.setattr(
        d2_main, "_fetch_unified_orders_page",
        lambda n, p=1, include_terminal=False: {
            "rows": [
                {"source": "seatgeek_sales", "order_id": "SG-SALE-9", "event_name": "Hamilton",
                 "event_date": "2026-07-01T20:00:00Z", "qty": 4, "status": "sold",
                 "canonical_status": "fulfilled", "amount": 1200.5, "currency": None,
                 "ordered_at": "2026-05-12T09:00:00Z"},
                {"source": "evo", "order_id": "111", "event_name": "Knicks vs Lakers",
                 "event_date": "2026-06-01T19:30:00Z", "qty": 2, "status": "accepted",
                 "canonical_status": "accepted", "amount": 450.0, "currency": None,
                 "ordered_at": "2026-05-10T12:00:00Z"},
            ],
            "per_source_count": {"evo": 1, "seatgeek_sales": 1},
            "per_source_as_of": {"evo": "2026-05-13T20:35:00Z", "seatgeek_sales": "2026-05-16T16:16:00Z"},
        },
    )
    # Stub the event-window pull (no v_event_base candidates → rows
    # go through without enrichment) and the cron freshness call.
    monkeypatch.setattr(d2_main, "_pull_event_window",   lambda *a, **kw: [])
    monkeypatch.setattr(d2_main, "_fetch_cron_freshness", lambda: {})
    body = client.get("/api/d2/orders").json()
    sources = {s["source"]: s for s in body["sources"]}
    assert set(sources) == {"evo", "seatgeek_sales", "seatdata", "tickpick", "vivid"}
    # Every source is SQL-backed now (vivid joined the unified_orders view
    # 2026-05-13; the dashboard was updated 2026-05-14 to stop using the
    # legacy API+match path for it).
    for src in ("evo", "seatgeek_sales", "seatdata", "tickpick", "vivid"):
        assert sources[src]["origin"] == "sql"
    assert sources["evo"]["ok"] is True
    assert sources["evo"]["as_of"] == "2026-05-13T20:35:00Z"
    assert sources["evo"]["count"] == 1
    assert sources["seatgeek_sales"]["count"] == 1
    assert sources["seatdata"]["count"] == 0
    assert sources["seatdata"]["ok"] is True
    assert sources["tickpick"]["count"] == 0
    assert sources["vivid"]["count"] == 0
    # SQL rows: 2 returned, sorted newest-first by ordered_at.
    rows = body["rows"]
    assert [r["source"] for r in rows] == ["seatgeek_sales", "evo"]


def test_orders_no_longer_carries_cron_blob(monkeypatch, client):
    """As of the perf split (cron moved to /api/d2/cron-freshness), the
    orders endpoint no longer carries per-source cron data. This keeps
    the orders feed paced by unified_orders (3ms) instead of the cron
    RPC (66ms+)."""
    monkeypatch.setattr(
        d2_main, "_fetch_unified_orders_page",
        lambda n, p=1, include_terminal=False: {"rows": [], "per_source_count": {}, "per_source_as_of": {}},
    )
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [])
    sources = {s["source"]: s for s in client.get("/api/d2/orders").json()["sources"]}
    for s in sources.values():
        assert "cron" not in s


def test_orders_fast_phase_skips_event_window(monkeypatch, client):
    """?fast=1 returns phase=fast with only the SQL-side rows; the
    event_window query is NOT fired. Lets the client paint the soonest
    events in <200ms while the full call loads in the background."""
    called = {"fast": False, "event_window": False, "full_page": False}

    def fake_fast(per_page, include_terminal=False):
        called["fast"] = True
        return {
            "rows": [{"source": "evo", "order_id": "111", "event_name": "Knicks vs Lakers",
                      "event_date": "2026-06-01T19:30:00", "qty": 2, "status": "accepted",
                      "canonical_status": "accepted", "amount": 450.0, "currency": None,
                      "ordered_at": "2026-05-10T12:00:00Z"}],
            "per_source_count": {"evo": 1},
            "per_source_as_of": {"evo": "2026-05-13T20:35:00Z"},
        }

    def fail_event(*a, **kw):
        called["event_window"] = True
        return []

    def fail_full(*a, **kw):
        called["full_page"] = True
        return None

    monkeypatch.setattr(d2_main, "_fetch_unified_orders_fast", fake_fast)
    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", fail_full)
    monkeypatch.setattr(d2_main, "_pull_event_window",         fail_event)

    body = client.get("/api/d2/orders?fast=1").json()
    assert body["phase"] == "fast"
    assert called["fast"] is True
    assert called["event_window"] is False
    assert called["full_page"] is False
    assert len(body["rows"]) == 1
    assert body["rows"][0]["source"] == "evo"


def test_orders_response_carries_per_leg_timings(monkeypatch, client):
    """The orders response surfaces per-leg timings_ms + Server-Timing header
    so the operator can see exactly which fan-out leg is slow."""
    monkeypatch.setattr(
        d2_main, "_fetch_unified_orders_page",
        lambda n, p=1, include_terminal=False: {"rows": [], "per_source_count": {}, "per_source_as_of": {}},
    )
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [])
    r = client.get("/api/d2/orders")
    body = r.json()
    assert "timings_ms" in body
    assert "sql.unified"      in body["timings_ms"]
    assert "sql.event_window" in body["timings_ms"]
    assert "total"            in body["timings_ms"]
    # The "api.vivid" leg was removed when vivid moved to SQL backing.
    assert "api.vivid" not in body["timings_ms"]
    server_timing = r.headers.get("Server-Timing", "")
    assert "sql_unified;dur=" in server_timing
    assert "total;dur="       in server_timing


def test_orders_source_filter_routes_to_filtered_fetch(monkeypatch, client):
    """?source=evo routes to the single-source filtered fetch (full per_page
    window, not the balanced ~20/source cap) and echoes source + has_more so
    the client can page through ALL of that source's book."""
    captured = {}

    def fake_filtered(source, per_page, page=1, include_terminal=False, q=None, when="all"):
        captured.update(source=source, per_page=per_page, page=page,
                        include_terminal=include_terminal, q=q, when=when)
        return {
            "rows": [{"source": "evo", "order_id": "111", "event_name": "Knicks vs Lakers",
                      "event_date": "2026-06-01T19:30:00Z", "qty": 2, "status": "accepted",
                      "canonical_status": "accepted", "amount": 450.0, "currency": None,
                      "ordered_at": "2026-05-10T12:00:00Z"}],
            "per_source_count": {"evo": 1},
            "per_source_as_of": {"evo": "2026-05-13T20:35:00Z"},
            "has_more": True,
        }

    # The balanced path must NOT be used when a source filter is set.
    def fail_balanced(*a, **kw):
        raise AssertionError("balanced fan-out should not run for a source filter")

    monkeypatch.setattr(d2_main, "_fetch_filtered_orders", fake_filtered)
    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", fail_balanced)
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [])

    body = client.get("/api/d2/orders?source=evo&per_page=100&page=2").json()
    assert body["phase"] == "filtered"
    assert body["source"] == "evo"
    assert body["has_more"] is True
    assert body["page"] == 2
    assert captured["source"] == "evo"
    assert captured["per_page"] == 100
    assert captured["page"] == 2
    assert [r["source"] for r in body["rows"]] == ["evo"]


def test_orders_search_and_when_route_to_filtered_fetch(monkeypatch, client):
    """?q= and ?when= (even with source=all) route to the filtered fetch and
    forward the normalized filter args."""
    captured = {}

    def fake_filtered(source, per_page, page=1, include_terminal=False, q=None, when="all"):
        captured.update(source=source, q=q, when=when)
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}, "has_more": False}

    monkeypatch.setattr(d2_main, "_fetch_filtered_orders", fake_filtered)
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [])

    body = client.get("/api/d2/orders?q=Knicks&when=upcoming").json()
    assert body["phase"] == "filtered"
    assert captured["source"] == "all"
    assert captured["q"] == "Knicks"
    assert captured["when"] == "upcoming"
    assert body["when"] == "upcoming"


def test_orders_default_all_stays_on_balanced_path(monkeypatch, client):
    """No source/q/when → the original balanced fan-out (phase=full) runs,
    and the filtered fetch is NOT called. Guards the back-compat default."""
    def fail_filtered(*a, **kw):
        raise AssertionError("filtered fetch should not run for the default view")

    monkeypatch.setattr(
        d2_main, "_fetch_unified_orders_page",
        lambda n, p=1, include_terminal=False: {
            "rows": [], "per_source_count": {"evo": 20}, "per_source_as_of": {},
        },
    )
    monkeypatch.setattr(d2_main, "_fetch_filtered_orders", fail_filtered)
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [])

    body = client.get("/api/d2/orders?per_page=100").json()
    assert body["phase"] == "full"
    assert body["source"] == "all"
    # per_source slice = 100//5 = 20; evo filled it → more pages exist.
    assert body["has_more"] is True


def test_cron_freshness_endpoint_returns_per_source(monkeypatch, client):
    """/api/d2/cron-freshness returns the same per-source blob the orders
    endpoint used to carry inline. Front-end polls this on a 60s timer."""
    monkeypatch.setattr(d2_main, "_fetch_cron_freshness", lambda: {
        "evo": {
            "jobname": "evo_orders_queue_30min",
            "schedule": "*/30 * * * *",
            "active": True,
            "last_run": "2026-05-13T22:30:00Z",
            "last_status": "succeeded",
        },
    })
    body = client.get("/api/d2/cron-freshness").json()
    assert body["sources"]["evo"]["jobname"] == "evo_orders_queue_30min"


def test_event_window_cache_short_circuits_repeat_calls(monkeypatch):
    """The 60s in-process cache lets repeated /api/d2/orders refreshes
    skip the v_event_base round-trip on every poll tick."""
    # Reset the cache so this test is deterministic regardless of order.
    d2_main._EVENT_WINDOW_CACHE.update({"at": 0.0, "rows": []})
    hits = {"n": 0}

    class FakeQuery:
        def __init__(self, rows):
            self._rows = rows
        def select(self, *_a, **_kw): return self
        def gte(self, *_a, **_kw):    return self
        def lte(self, *_a, **_kw):    return self
        def execute(self):
            hits["n"] += 1
            return type("Res", (), {"data": self._rows})()

    class FakeSb:
        def table(self, name):
            return FakeQuery([{"tevo_event_id": 1, "event_name": "X",
                               "event_at_utc": "2026-12-01T00:00:00", "event_at_local": None}])

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    # First call: miss → query → cache
    d2_main._pull_event_window()
    assert hits["n"] == 1
    # Second call (within TTL): cache hit, no extra query
    d2_main._pull_event_window()
    assert hits["n"] == 1


def test_orders_per_page_bounds_503_passthrough_when_unconfigured(monkeypatch, client):
    """per_page clamping still applies; verifies the clamp fires before the
    SQL call so a malformed query string can't blow up downstream."""
    seen = {}

    def fake_page(per_page, page=1, include_terminal=False):
        seen["per_page"] = per_page
        seen["page"] = page
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}}

    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", fake_page)
    r = client.get("/api/d2/orders?per_page=999")
    assert r.status_code == 200
    assert seen["per_page"] == 100
    r = client.get("/api/d2/orders?per_page=0")
    assert r.status_code == 200
    assert seen["per_page"] == 1


def test_orders_default_filters_to_active_only(monkeypatch, client):
    """Without `?include_terminal=`, the orders endpoint requests the SQL
    fan-out with include_terminal=False so only non-terminal canonical_status
    rows come back. Primary-tab default per operator 2026-05-15 directive."""
    seen = {}

    def fake_page(per_page, page=1, include_terminal=False):
        seen["include_terminal"] = include_terminal
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}}

    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", fake_page)
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [])
    r = client.get("/api/d2/orders")
    assert r.status_code == 200
    assert seen["include_terminal"] is False
    assert r.json()["include_terminal"] is False


def test_orders_include_terminal_param_threads_to_sql(monkeypatch, client):
    """`?include_terminal=1` flips the filter to show every row regardless
    of canonical_status. The 'All' view-mode pill on the frontend toggles
    this query param."""
    seen = {}

    def fake_page(per_page, page=1, include_terminal=False):
        seen["include_terminal"] = include_terminal
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}}

    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", fake_page)
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [])
    r = client.get("/api/d2/orders?include_terminal=1")
    assert r.status_code == 200
    assert seen["include_terminal"] is True
    assert r.json()["include_terminal"] is True


def test_orders_fast_include_terminal_param_threads_to_fast_sql(monkeypatch, client):
    """The include_terminal param also propagates to the fast path."""
    seen = {}

    def fake_fast(per_page, include_terminal=False):
        seen["include_terminal"] = include_terminal
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}}

    monkeypatch.setattr(d2_main, "_fetch_unified_orders_fast", fake_fast)
    r = client.get("/api/d2/orders?fast=1&include_terminal=1")
    assert r.status_code == 200
    assert seen["include_terminal"] is True
    body = r.json()
    assert body["phase"] == "fast"
    assert body["include_terminal"] is True


# ---------- Metrics tab endpoints (CEO view) ----------

def test_metrics_503_when_supabase_unconfigured(monkeypatch, client):
    """The metrics bundle endpoint is SQL-only — surfaces 503 when
    Supabase isn't wired, same shape as /api/d2/orders + /api/d2/health."""
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    r = client.get("/api/d2/metrics")
    assert r.status_code == 503


def test_metrics_today_start_anchors_on_et():
    """The "today" window for the Metrics tab anchors on America/New_York
    so the Today card matches the operator's clock. Without this, the
    Today card would reset at 8 PM ET (= midnight UTC) and read as a bug.

    Asserts the returned datetime is at an hour boundary in UTC AND falls
    within the expected ET-midnight band (00:00 ET = 04:00 UTC EDT / 05:00
    UTC EST). Tolerant of DST."""
    from datetime import datetime, timezone
    ts = d2_main._today_start_utc()
    assert ts.tzinfo is not None
    assert ts.minute == 0 and ts.second == 0 and ts.microsecond == 0
    # ET midnight maps to either 04:00 UTC (EDT) or 05:00 UTC (EST).
    assert ts.hour in (4, 5), f"Expected UTC hour 4 (EDT) or 5 (EST), got {ts.hour}"
    # The returned ts should never be in the future relative to now_utc.
    assert ts <= datetime.now(timezone.utc)


def test_metrics_bundles_all_windows_buckets_and_top(monkeypatch, client):
    """Happy path: the metrics endpoint fans out to d2_metrics_window for
    each of the 4 windows × {current, prior}, plus d2_metrics_hourly_buckets
    and d2_metrics_top_events. Response carries each result keyed by window
    name + sub-bundle keys."""
    calls = {"window": [], "hourly": 0, "top": 0}

    class FakeRpcCall:
        def __init__(self, fn, args): self._fn = fn; self._args = args
        def execute(self):
            data = self._fn(self._args)
            return type("Res", (), {"data": data})()

    def _window_data(args):
        calls["window"].append(args)
        return [
            {"source": "evo",      "orders_count": 3, "fulfilled_count": 2,
             "gross_total": 450.0, "fulfilled_gross": 300.0,
             "qty_total": 6, "fulfilled_qty": 4},
            {"source": "seatgeek_sales", "orders_count": 1, "fulfilled_count": 1,
             "gross_total": 1200.0, "fulfilled_gross": 1200.0,
             "qty_total": 4, "fulfilled_qty": 4},
        ]

    def _hourly_data(args):
        calls["hourly"] += 1
        return [{"hour_bucket": "2026-05-15T03:00:00Z", "source": "evo",
                 "orders_count": 1, "gross": 150.0, "fulfilled_gross": 150.0}]

    def _top_data(args):
        calls["top"] += 1
        return [{"tevo_event_id": 9001, "event_name": "Knicks vs Lakers",
                 "event_date": "2026-06-01T19:30:00Z",
                 "total_gross": 4500.0, "total_count": 12, "fulfilled_count": 10}]

    def _hot_data(args):
        return [{"tevo_event_id": 9001, "event_name": "Hot show",
                 "event_date": "2026-06-01T00:00:00Z",
                 "recent_count": 4, "recent_gross": 800.0,
                 "fulfilled_count": 3, "last_order_at": "2026-05-15T14:55:00Z"}]
    def _biggest_data(args):
        return [{"source": "evo", "source_order_id": "B-1", "tevo_event_id": 9001,
                 "event_name": "Hot show", "event_date": "2026-06-01T00:00:00Z",
                 "gross_value": 5000.0, "quantity": 10, "canonical_status": "fulfilled",
                 "created_at": "2026-05-15T14:58:00Z"}]
    def _gaps_data(args):
        return [{"source": "vivid", "gap_start": "2026-05-15T10:00:00Z",
                 "gap_end": "2026-05-15T12:30:00Z", "gap_minutes": 150.0}]

    class FakeSb:
        def rpc(self, name, args):
            if name == "d2_metrics_window":         return FakeRpcCall(_window_data,  args)
            if name == "d2_metrics_hourly_buckets": return FakeRpcCall(_hourly_data,  args)
            if name == "d2_metrics_top_events":     return FakeRpcCall(_top_data,     args)
            if name == "d2_metrics_hot_events":     return FakeRpcCall(_hot_data,     args)
            if name == "d2_metrics_biggest_sales":  return FakeRpcCall(_biggest_data, args)
            if name == "d2_metrics_sales_gaps":     return FakeRpcCall(_gaps_data,    args)
            raise AssertionError(f"unexpected RPC: {name}")

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    r = client.get("/api/d2/metrics")
    assert r.status_code == 200
    body = r.json()
    # 4 windows × {current, prior}
    assert set(body["windows"].keys()) == {"hour", "today", "24h", "7d"}
    for name, twin in body["windows"].items():
        assert set(twin.keys()) == {"current", "prior"}
        # Each twin has the per-source rollup rows from our fake RPC.
        assert len(twin["current"]) == 2
        assert len(twin["prior"]) == 2
    assert len(calls["window"]) == 8  # 4 windows × 2 (current + prior)
    assert calls["hourly"] == 1
    assert calls["top"] == 1
    assert len(body["hourly_buckets"]) == 1
    assert len(body["top_events"]) == 1
    assert body["top_events"][0]["tevo_event_id"] == 9001
    # New legs from operator 2026-05-15 directive.
    assert len(body["hot_events"]) == 1
    assert body["hot_events"][0]["recent_count"] == 4
    assert len(body["biggest_sales"]) == 1
    assert body["biggest_sales"][0]["gross_value"] == 5000.0
    assert len(body["sales_gaps"]) == 1
    assert body["sales_gaps"][0]["gap_minutes"] == 150.0
    assert "timings_ms" in body
    assert "checked_at" in body


def test_metrics_partial_failure_surfaces_in_errors_array(monkeypatch, client):
    """If one of the 10 parallel SQL calls fails, the bundle still returns
    200 with the other 9 legs' data + the failing leg recorded in errors[].
    Single-leg failures should not cascade to 503."""
    class FakeFailingCall:
        def execute(self): raise RuntimeError("simulated SQL hiccup")
    class FakeOkCall:
        def __init__(self, payload): self._payload = payload
        def execute(self): return type("Res", (), {"data": self._payload})()

    class FakeSb:
        def rpc(self, name, args):
            # Break only the top_events leg.
            if name == "d2_metrics_top_events":
                return FakeFailingCall()
            return FakeOkCall([])

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    r = client.get("/api/d2/metrics")
    assert r.status_code == 200
    body = r.json()
    assert body["top_events"] == []
    assert any(e["leg"] == "top_events" for e in body["errors"])


def test_sales_feed_503_when_supabase_unconfigured(monkeypatch, client):
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    r = client.get("/api/d2/sales-feed")
    assert r.status_code == 503


def test_sales_feed_returns_newest_first(monkeypatch, client):
    """The sales feed sources newest-first from unified_orders. Mock the
    PostgREST chain and assert the response shape + ordering call."""
    captured = {}

    class FakeQuery:
        def select(self, *_a, **_kw):  return self
        def in_(self, col, vals):
            captured["in"] = (col, list(vals))
            return self
        def order(self, col, desc=False, nullsfirst=False):
            captured["order"] = (col, desc); return self
        def limit(self, n):
            captured["limit"] = n; return self
        def execute(self):
            return type("Res", (), {"data": [
                {"source": "evo",      "source_order_id": "1", "gross_value": 100.0,
                 "quantity": 2, "event_name": "A", "event_date": "2026-06-01T00:00:00Z",
                 "created_at": "2026-05-15T12:00:00Z", "canonical_status": "accepted",
                 "is_sale_succeeded": False},
                {"source": "tickpick", "source_order_id": "T-9", "gross_value": 200.0,
                 "quantity": 1, "event_name": "B", "event_date": "2026-06-02T00:00:00Z",
                 "created_at": "2026-05-15T11:00:00Z", "canonical_status": "fulfilled",
                 "is_sale_succeeded": True},
            ]})()

    class FakeSb:
        def table(self, name):
            captured["table"] = name
            return FakeQuery()

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    r = client.get("/api/d2/sales-feed?limit=5")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert captured["table"] == "unified_orders"
    assert captured["order"] == ("created_at", True)  # desc=True
    assert captured["limit"] == 5
    assert captured["in"][0] == "source"
    assert set(captured["in"][1]) == set(d2_main._ALL_SOURCES)
    assert len(body["rows"]) == 2
    assert body["rows"][0]["source"] == "evo"   # mock returns newest-first
    assert body["limit"] == 5


def test_sales_feed_limit_clamped(monkeypatch, client):
    """`?limit=999` clamps to 100; `?limit=0` clamps to 1. Prevents the
    operator from accidentally fetching the whole table."""
    captured_limits = []

    class FakeQuery:
        def select(self, *_a, **_kw):  return self
        def in_(self, *_a, **_kw):     return self
        def order(self, *_a, **_kw):   return self
        def limit(self, n):
            captured_limits.append(n); return self
        def execute(self):
            return type("Res", (), {"data": []})()
    class FakeSb:
        def table(self, _name): return FakeQuery()

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    client.get("/api/d2/sales-feed?limit=999")
    client.get("/api/d2/sales-feed?limit=0")
    client.get("/api/d2/sales-feed")  # default = 20
    assert captured_limits == [100, 1, 20]



def test_order_detail_routes_gotickets_to_get_sale(monkeypatch, client):
    class FakeGoTickets:
        def get_sale(self, order_id):
            assert order_id == "S-42"
            return {"id": "S-42", "fulfilled": True, "fulfillmentTime": "2026-05-13T20:00:00Z"}

    monkeypatch.setattr(d2_main, "_gotickets_client", lambda: FakeGoTickets())
    r = client.get("/api/d2/order/gotickets/S-42")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["data"]["fulfilled"] is True


def test_health_503_when_supabase_unconfigured(monkeypatch, client):
    """/api/d2/health is SQL-only — surfaces 503 when Supabase isn't wired."""
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    r = client.get("/api/d2/health")
    assert r.status_code == 503


def test_health_returns_cron_queue_and_sql_blob(monkeypatch, client):
    """Happy path: /api/d2/health returns the four sections the Health tab
    renders — crons, queues, sql_counts, fulfillby_fields."""
    class FakeQuery:
        def __init__(self, table, rows, count=None):
            self.table_name = table
            self._rows = rows
            self._count = count if count is not None else len(rows)
        def select(self, *_a, **_kw):  return self
        def eq(self, *_a, **_kw):      return self
        def is_(self, *_a, **_kw):     return self
        def order(self, *_a, **_kw):   return self
        def limit(self, *_a, **_kw):   return self
        def execute(self):
            return type("Res", (), {"data": self._rows, "count": self._count})()

    class FakeRpcResult:
        data = [
            {"source": "evo", "jobname": "evo_orders_queue_30min", "phase": "queue",
             "schedule": "*/30 * * * *", "active": True,
             "last_run": "2026-05-13T22:30:00Z", "last_status": "succeeded"},
            {"source": "tickpick", "jobname": "tickpick_orders_queue_30min", "phase": "queue",
             "schedule": "*/30 * * * *", "active": True,
             "last_run": None, "last_status": None},
        ]

    class FakeSb:
        def rpc(self, name):
            assert name == "d2_cron_freshness"
            return type("RpcCall", (), {"execute": lambda self2: FakeRpcResult()})()
        def table(self, name):
            if name.endswith("_pending"):
                return FakeQuery(name, [], count=0)
            # unified_orders per-source: return 0 rows with a count
            return FakeQuery(name, [], count=0)

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    body = client.get("/api/d2/health").json()
    assert {c["jobname"] for c in body["crons"]} == {"evo_orders_queue_30min", "tickpick_orders_queue_30min"}
    assert set(body["queues"]) == {"tickpick", "vivid"}
    assert set(body["sql_counts"]) == {"evo", "seatgeek_sales", "seatdata", "tickpick", "vivid"}
    # fulfillby_fields: post-2026-05-16 rewire, seatgeek_sales (broker firehose)
    # exposes in_hand_date from the listing snapshot. The other four sources
    # still surface no explicit in-hand / fulfill-by timestamp.
    fb = body["fulfillby_fields"]
    assert set(fb) == {"evo", "seatgeek_sales", "tickpick", "vivid", "seatdata"}
    assert fb["seatgeek_sales"]["in_hand"] == "in_hand_date"
    assert fb["seatgeek_sales"]["fulfill_by"] is None
    for src in ("evo", "tickpick", "vivid", "seatdata"):
        assert fb[src]["in_hand"] is None
        assert fb[src]["fulfill_by"] is None


def test_orders_returns_pagination_metadata(monkeypatch, client):
    """`/api/d2/orders` echoes the requested page + per_page so the front-end
    can size the Prev/Next buttons without a separate count query."""
    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page",
                        lambda n, p=1, include_terminal=False: {"rows": [], "per_source_count": {}, "per_source_as_of": {}})
    body = client.get("/api/d2/orders?per_page=25&page=3").json()
    assert body["page"] == 3
    assert body["per_page"] == 25


def test_orders_page_param_threads_to_sql(monkeypatch, client):
    """The page param reaches the unified-orders SQL fetcher so PostgREST
    .range() lines up with the operator's Next/Prev clicks."""
    seen = {}

    def fake_page(per_page, page=1, include_terminal=False):
        seen["per_page"] = per_page
        seen["page"] = page
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}}

    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", fake_page)
    assert client.get("/api/d2/orders?page=4").status_code == 200
    assert seen == {"per_page": 25, "page": 4}


def test_orders_page_clamped_to_minimum_one(monkeypatch, client):
    """Negative or zero page values clamp to 1 so a malformed query string
    doesn't blow up the SQL fetcher (PostgREST .range() would 416)."""
    seen = {}

    def fake_page(per_page, page=1, include_terminal=False):
        seen["page"] = page
        return {"rows": [], "per_source_count": {}, "per_source_as_of": {}}

    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", fake_page)
    assert client.get("/api/d2/orders?page=-5").status_code == 200
    assert seen["page"] == 1


def test_broker_diag_masks_token_and_reports_env_var(monkeypatch):
    """The /healthz/detail diag exposes which env var resolved + a masked
    tail (last 4 chars) so the operator can verify a token rotation took
    effect without exposing the secret."""
    monkeypatch.setenv("TICKPICK_API_TOKEN", "supersecret-abcd")
    monkeypatch.delenv("TICKPICK_TOKEN", raising=False)
    diag = d2_main._broker_diag("TICKPICK_API_TOKEN", "TICKPICK_TOKEN")
    assert diag["token_set"] is True
    assert diag["token_env_var"] == "TICKPICK_API_TOKEN"
    assert diag["token_masked"] == "...abcd"
    assert "token_warning" not in diag


def test_broker_diag_warns_when_multiple_env_vars_set(monkeypatch):
    """Both vault-canonical AND legacy env vars set is a common cause of
    auth failures (operator rotates one but not the other). Surface it."""
    monkeypatch.setenv("TICKPICK_API_TOKEN", "new-XXXX")
    monkeypatch.setenv("TICKPICK_TOKEN",     "old-YYYY")
    diag = d2_main._broker_diag("TICKPICK_API_TOKEN", "TICKPICK_TOKEN")
    assert diag["token_env_var"] == "TICKPICK_API_TOKEN"
    assert "token_warning" in diag
    assert "TICKPICK_API_TOKEN" in diag["token_warning"]
    assert "TICKPICK_TOKEN" in diag["token_warning"]


def test_order_detail_unknown_source(client):
    """/api/d2/order/<bad>/<id> returns 404 for unrecognized sources."""
    r = client.get("/api/d2/order/bogus/123")
    assert r.status_code == 404


def test_order_detail_no_supabase(monkeypatch, client):
    """When Supabase isn't configured, the SQL deep-detail path returns 200
    with ok=False so the front-end can render a clear error card."""
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    r = client.get("/api/d2/order/tickpick/42")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert "Supabase not configured" in body["error"]


def test_order_detail_no_creds_gotickets(monkeypatch, client):
    """Gotickets keeps the API-by-id flow until SQL backing exists; missing
    creds surface as 200 ok=False (same UX as the SQL sources' 503-soft)."""
    monkeypatch.setattr(d2_main, "_gotickets_client", lambda: None)
    r = client.get("/api/d2/order/gotickets/S-42")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert body["error"] == "no creds"


def test_scrub_err_passes_typed_client_errors(monkeypatch):
    """Typed client errors (TickPickError, EvoError, etc.) only carry an HTTP
    status code — no URL / token / body. Surface them verbatim so the operator
    can tell 401 from 404 from 502. Generic exceptions still get scrubbed."""
    # Typed error → pass-through.
    from tickpick_client import TickPickError
    out = d2_main._scrub_err("tickpick", TickPickError("HTTP 401"))
    assert out == "HTTP 401"

    # Generic exception → scrubbed.
    out = d2_main._scrub_err("evo", RuntimeError("traceback with /v9/orders?token=secret"))
    assert out == "upstream error"

    # Typed error containing a URL → defensive scrub (shouldn't happen in
    # practice but the guard exists in case a client adds a URL to its
    # error message in the future).
    out = d2_main._scrub_err("tickpick", TickPickError("HTTP 500 https://api.tickpick.com/orders"))
    assert out == "upstream error"


def test_order_detail_dispatches_to_sql(monkeypatch, client):
    """Happy path: the endpoint queries the source's raw `*_orders` table by
    its primary key and wraps the row. Replaces the prior live-API call —
    the dashboard is SQL-only as of the 2026-05-14 cutover."""
    captured = {}

    class FakeQuery:
        def select(self, *_a, **_kw):  return self
        def eq(self, col, val):
            captured["col"] = col
            captured["val"] = val
            return self
        def limit(self, *_a, **_kw):   return self
        def execute(self):
            return type("Res", (), {"data": [{"evo_order_id": "42", "state": "accepted", "buyer_name": "Acme"}]})()

    class FakeSb:
        def table(self, name):
            captured["table"] = name
            return FakeQuery()

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    r = client.get("/api/d2/order/evo/42")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["source"] == "evo"
    assert body["order_id"] == "42"
    assert body["data"]["evo_order_id"] == "42"
    assert body["data"]["buyer_name"] == "Acme"
    # Verify the dispatch routes to the right table + column for evo.
    assert captured["table"] == "evo_orders"
    assert captured["col"] == "evo_order_id"
    assert captured["val"] == "42"


def test_order_detail_not_found_returns_ok_false(monkeypatch, client):
    """When the SQL query finds no row for the given order_id, the endpoint
    returns 200 ok=False with error='not found' so the front-end can render
    a "no such order" card rather than an opaque 404."""
    class EmptyQuery:
        def select(self, *_a, **_kw):  return self
        def eq(self, *_a, **_kw):      return self
        def limit(self, *_a, **_kw):   return self
        def execute(self):
            return type("Res", (), {"data": []})()

    class FakeSb:
        def table(self, _name):
            return EmptyQuery()

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    r = client.get("/api/d2/order/tickpick/no-such-id")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is False
    assert body["error"] == "not found"


def test_to_int_to_float_handle_garbage():
    assert d2_main._to_int(None) is None
    assert d2_main._to_int("") is None
    assert d2_main._to_int("not a number") is None
    assert d2_main._to_int("7") == 7
    assert d2_main._to_float(None) is None
    assert d2_main._to_float("not a number") is None
    assert d2_main._to_float("3.14") == 3.14
