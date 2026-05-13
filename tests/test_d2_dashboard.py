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


def _stub_evo(per_page):
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


def _stub_sg(per_page):
    return {
        "source": "seatgeek",
        "ok": True,
        "rows": [{
            "source": "seatgeek", "order_id": "SG-9", "event_name": "Hamilton",
            "event_date": "2026-07-01T20:00:00Z", "qty": 4, "status": "open",
            "amount": 1200.5, "currency": "USD", "ordered_at": "2026-05-12T09:00:00Z",
        }],
        "total": 1,
    }


def _stub_tickpick(per_page):
    return {"source": "tickpick", "ok": True, "rows": [], "total": 0}


def _stub_vivid_err(per_page):
    return {"source": "vivid", "ok": False, "error": "boom", "rows": []}


def test_healthz_public_minimal(client):
    """Public /healthz exposes only ok + service — no fingerprintable detail."""
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body == {"ok": True, "service": "d2_dashboard"}


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
    assert set(body["brokers"]) == {"evo", "seatgeek", "tickpick", "vivid", "seatdata"}
    assert body["templates"]["dashboard_html_exists"] is True
    # Lane-status fields default to data-collection / rebuild-pending.
    assert body["phase"] == "data-collection"
    assert body["ui"] == "rebuild-pending"


def test_root_serves_html(client):
    r = client.get("/")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/html")
    assert "D2 Orders Dashboard" in r.text


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


def test_config_public_includes_canonical_origin(client, monkeypatch):
    """Pre-auth bootstrap endpoint mirrors the shell-injected blob so API
    consumers and any front-end fallback path get the same shape."""
    monkeypatch.setattr(d2_main, "D2_CANONICAL_ORIGIN", "https://d2.example.com")
    r = client.get("/api/d2/config-public")
    assert r.status_code == 200
    body = r.json()
    assert body["canonical_origin"] == "https://d2.example.com"
    assert body["allowed_email_domain"] == d2_main.ALLOWED_EMAIL_DOMAIN
    assert "supabase_url" in body
    assert "supabase_anon_key" in body
    assert "auth_disabled" in body


def test_orders_merges_all_sources(monkeypatch, client):
    monkeypatch.setattr(d2_main, "_fetch_evo", _stub_evo)
    monkeypatch.setattr(d2_main, "_fetch_sg", _stub_sg)
    monkeypatch.setattr(d2_main, "_fetch_tickpick", _stub_tickpick)
    monkeypatch.setattr(d2_main, "_fetch_vivid", _stub_vivid_err)

    r = client.get("/api/d2/orders")
    assert r.status_code == 200
    body = r.json()

    # Summary chip per source.
    sources_by_name = {s["source"]: s for s in body["sources"]}
    assert set(sources_by_name) == {"evo", "seatgeek", "tickpick", "vivid"}
    assert sources_by_name["evo"]["ok"] is True
    assert sources_by_name["seatgeek"]["ok"] is True
    assert sources_by_name["tickpick"]["ok"] is True
    assert sources_by_name["vivid"]["ok"] is False
    assert sources_by_name["vivid"]["error"] == "boom"

    # Merged rows: evo + seatgeek, sorted newest first (by ordered_at).
    rows = body["rows"]
    assert len(rows) == 2
    assert rows[0]["source"] == "seatgeek"   # 2026-05-12 > 2026-05-10
    assert rows[1]["source"] == "evo"


def test_orders_per_page_bounds(monkeypatch, client):
    """per_page is clamped to [1, 100]."""
    seen = {}

    def stub(per_page):
        seen["per_page"] = per_page
        return {"source": "evo", "ok": True, "rows": [], "total": 0}

    monkeypatch.setattr(d2_main, "_fetch_evo", stub)
    monkeypatch.setattr(d2_main, "_fetch_sg", lambda n: {"source": "seatgeek", "ok": True, "rows": [], "total": 0})
    monkeypatch.setattr(d2_main, "_fetch_tickpick", lambda n: {"source": "tickpick", "ok": True, "rows": [], "total": 0})
    monkeypatch.setattr(d2_main, "_fetch_vivid", lambda n: {"source": "vivid", "ok": True, "rows": [], "total": 0})

    r = client.get("/api/d2/orders?per_page=999")
    assert r.status_code == 200
    assert seen["per_page"] == 100

    r = client.get("/api/d2/orders?per_page=0")
    assert r.status_code == 200
    assert seen["per_page"] == 1


def test_samples_no_creds_all_sources(monkeypatch, client):
    """When every client factory returns None (no creds), /api/d2/samples
    still returns 200 with one entry per source, each ok=False."""
    monkeypatch.setattr(d2_main, "_evo_client",      lambda: None)
    monkeypatch.setattr(d2_main, "_sg_client",       lambda: None)
    monkeypatch.setattr(d2_main, "_tickpick_client", lambda: None)
    monkeypatch.setattr(d2_main, "_vivid_client",    lambda: None)
    monkeypatch.setattr(d2_main, "_seatdata_client", lambda: None)
    r = client.get("/api/d2/samples")
    assert r.status_code == 200
    body = r.json()
    sources = {s["source"]: s for s in body["samples"]}
    assert set(sources) == {"evo", "seatgeek", "tickpick", "vivid", "seatdata"}
    for s in sources.values():
        assert s["ok"] is False
        assert s["error"] == "no creds"
        assert s["sample"] is None


def test_samples_mixed_ok_and_error(monkeypatch, client):
    """One broken sampler doesn't blank the others — the broken one surfaces
    ok=False with a scrubbed error, the rest carry their records."""
    class FakeEvo:
        def list_events(self, **kw):     return {"events":     [{"id": 1, "name": "Concert"}],   "total_entries": 42}
        def list_performers(self, **kw): return {"performers": [{"id": 2, "name": "Performer"}], "total_entries": 7}
        def list_venues(self, **kw):     return {"venues":     [{"id": 3, "name": "Arena"}],     "total_entries": 9}
        def list_orders(self, **kw):     return {"orders":     [{"id": 4, "state": "open"}],     "total_entries": 5620}

    class FakeVivid:
        def list_active_orders(self):             return [{"orderId": "V-1", "eventName": "Show"}]
        def list_pending_retransfer_orders(self): return []

    class BrokenTickpick:
        def list_orders(self): raise RuntimeError("upstream 500")

    monkeypatch.setattr(d2_main, "_evo_client",      lambda: FakeEvo())
    monkeypatch.setattr(d2_main, "_sg_client",       lambda: None)
    monkeypatch.setattr(d2_main, "_tickpick_client", lambda: BrokenTickpick())
    monkeypatch.setattr(d2_main, "_vivid_client",    lambda: FakeVivid())
    monkeypatch.setattr(d2_main, "_seatdata_client", lambda: None)

    r = client.get("/api/d2/samples")
    assert r.status_code == 200
    sources = {s["source"]: s for s in r.json()["samples"]}

    # Evo + Vivid have records → ok=True, sample present, method labeled.
    assert sources["evo"]["ok"] is True
    assert sources["evo"]["sample"] is not None
    assert sources["evo"]["method"] in {"list_events", "list_performers", "list_venues", "list_orders"}
    assert sources["vivid"]["ok"] is True
    assert sources["vivid"]["method"] in {"list_active_orders", "list_pending_retransfer_orders"}

    # SG + SeatData lack creds → ok=False, "no creds".
    assert sources["seatgeek"]["ok"] is False
    assert sources["seatgeek"]["error"] == "no creds"
    assert sources["seatdata"]["error"] == "no creds"

    # TickPick raised → ok=False, scrubbed error (no stack trace on wire).
    assert sources["tickpick"]["ok"] is False
    assert sources["tickpick"]["error"] == "upstream error"
    assert "500" not in sources["tickpick"]["error"]


def test_seatdata_no_creds(monkeypatch, client):
    """When SEATDATA_API_KEY is missing, endpoint returns ok=False gracefully."""
    monkeypatch.setattr(d2_main, "_seatdata_client", lambda: None)
    r = client.get("/api/d2/seatdata")
    assert r.status_code == 200
    body = r.json()
    assert body == {"ok": False, "error": "no creds"}


def test_seatdata_with_stub(monkeypatch, client):
    class StubSD:
        def account(self):
            return {"balance": 100, "plan": "test"}

        def usage(self):
            return {"calls_today": 7, "limit": 1000}

    monkeypatch.setattr(d2_main, "_seatdata_client", lambda: StubSD())
    r = client.get("/api/d2/seatdata")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["account"] == {"balance": 100, "plan": "test"}
    assert body["usage"] == {"calls_today": 7, "limit": 1000}


# ---------- Normalizer unit tests ----------

def test_norm_evo_handles_missing_event():
    row = d2_main._norm_evo({"id": 42, "state": "open", "total": "100.50", "currency": "USD"})
    assert row["source"] == "evo"
    assert row["order_id"] == "42"
    assert row["event_name"] is None
    assert row["amount"] == 100.5
    assert row["status"] == "open"


def test_norm_evo_sums_item_quantities():
    row = d2_main._norm_evo({
        "id": 1, "items": [{"quantity": 2}, {"quantity": 3}, {"quantity": 1}],
    })
    assert row["qty"] == 6


def test_norm_vivid_xml_flat_dict():
    """Vivid clients return dicts with all string values (XML-flattened)."""
    row = d2_main._norm_vivid({
        "orderId": "V-100", "eventName": "Show", "eventDate": "2026-09-01",
        "quantity": "3", "status": "PENDING_SHIPMENT", "total": "275.00",
    })
    assert row["source"] == "vivid"
    assert row["order_id"] == "V-100"
    assert row["qty"] == 3
    assert row["amount"] == 275.0


def test_to_int_to_float_handle_garbage():
    assert d2_main._to_int(None) is None
    assert d2_main._to_int("") is None
    assert d2_main._to_int("not a number") is None
    assert d2_main._to_int("7") == 7
    assert d2_main._to_float(None) is None
    assert d2_main._to_float("not a number") is None
    assert d2_main._to_float("3.14") == 3.14
