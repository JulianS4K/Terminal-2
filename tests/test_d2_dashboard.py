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


def test_orders_503_when_supabase_unconfigured(monkeypatch, client):
    """Dashboard is SQL-only — when Supabase isn't configured the orders
    endpoint surfaces 503 explicitly instead of silently serving empty."""
    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page", lambda n, p=1: None)
    r = client.get("/api/d2/orders")
    assert r.status_code == 503


def test_orders_serves_unified_orders_with_per_source_chips(monkeypatch, client):
    """SQL-backed sources (evo / seatgeek / seatdata) get origin=sql chips
    with per-source row counts + cron freshness. Tickpick + Vivid hit
    their upstream API and surface origin=api+sql-match — when API has
    no creds, the chip shows the actual broker-side reason."""
    monkeypatch.setattr(
        d2_main, "_fetch_unified_orders_page",
        lambda n, p=1: {
            "rows": [
                {"source": "seatgeek", "order_id": "SG-9", "event_name": "Hamilton",
                 "event_date": "2026-07-01T20:00:00Z", "qty": 4, "status": "open",
                 "canonical_status": "pending", "amount": 1200.5, "currency": None,
                 "ordered_at": "2026-05-12T09:00:00Z"},
                {"source": "evo", "order_id": "111", "event_name": "Knicks vs Lakers",
                 "event_date": "2026-06-01T19:30:00Z", "qty": 2, "status": "accepted",
                 "canonical_status": "accepted", "amount": 450.0, "currency": None,
                 "ordered_at": "2026-05-10T12:00:00Z"},
            ],
            "per_source_count": {"evo": 1, "seatgeek": 1},
            "per_source_as_of": {"evo": "2026-05-13T20:35:00Z", "seatgeek": "2026-05-09T02:57:00Z"},
        },
    )
    # Stub the event-window pull (no v_event_base candidates → tickpick/vivid
    # rows go through without enrichment) + API clients (no creds → chips
    # surface "no creds" not "no sql backing").
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [])
    monkeypatch.setattr(d2_main, "_tickpick_client",   lambda: None)
    monkeypatch.setattr(d2_main, "_vivid_client",      lambda: None)
    body = client.get("/api/d2/orders").json()
    sources = {s["source"]: s for s in body["sources"]}
    assert set(sources) == {"evo", "seatgeek", "seatdata", "tickpick", "vivid"}
    # SQL-backed: ok=True with origin sql + as_of from cron's last_seen_at.
    assert sources["evo"]["ok"] is True
    assert sources["evo"]["origin"] == "sql"
    assert sources["evo"]["as_of"] == "2026-05-13T20:35:00Z"
    assert sources["evo"]["count"] == 1
    assert sources["seatgeek"]["count"] == 1
    assert sources["seatdata"]["count"] == 0   # backed but no rows on this page
    assert sources["seatdata"]["ok"] is True
    # API-backed: chip carries the broker-side reason for failure.
    assert sources["tickpick"]["ok"] is False
    assert sources["tickpick"]["origin"] == "api+sql-match"
    assert sources["tickpick"]["error"] == "no creds"
    assert sources["vivid"]["origin"] == "api+sql-match"
    # SQL rows: 2 returned, sorted newest-first by ordered_at.
    rows = body["rows"]
    assert [r["source"] for r in rows] == ["seatgeek", "evo"]


def test_orders_enriches_tickpick_via_event_window(monkeypatch, client):
    """When a tickpick row matches a v_event_base candidate (>=2 shared
    tokens + date within 12h), the row gets the canonical event_name +
    tevo_event_id stitched in, so it joins cleanly with SQL rows in the
    table."""
    monkeypatch.setattr(
        d2_main, "_fetch_unified_orders_page",
        lambda n, p=1: {"rows": [], "per_source_count": {}, "per_source_as_of": {}},
    )
    monkeypatch.setattr(d2_main, "_pull_event_window", lambda *a, **kw: [
        {"tevo_event_id": 9001, "event_name": "Knicks vs Lakers — Madison Square Garden",
         "event_at_utc": "2026-12-15T23:30:00", "event_at_local": "2026-12-15T18:30:00-05:00"},
        {"tevo_event_id": 9002, "event_name": "Some Other Concert",
         "event_at_utc": "2026-12-16T23:00:00", "event_at_local": "2026-12-16T18:00:00-05:00"},
    ])

    class FakeTickpick:
        def list_orders(self):
            # Tickpick names are usually less verbose than v_event_base, but
            # the matcher should find "knicks" + "lakers" shared tokens.
            return [{
                "orderId": "T-77", "eventName": "Knicks at Lakers",
                "eventDate": "2026-12-15T23:30:00Z",
                "status": "unfulfilled", "quantity": 2,
            }]

    monkeypatch.setattr(d2_main, "_tickpick_client", lambda: FakeTickpick())
    monkeypatch.setattr(d2_main, "_vivid_client",    lambda: None)

    body = client.get("/api/d2/orders").json()
    tp_rows = [r for r in body["rows"] if r["source"] == "tickpick"]
    assert len(tp_rows) == 1
    row = tp_rows[0]
    # Canonical event info from v_event_base overlaid on the tickpick row.
    assert row["event_name"].startswith("Knicks vs Lakers")
    assert row["tevo_event_id"] == 9001
    assert row.get("event_origin") == "matched"


def test_orders_per_page_bounds_503_passthrough_when_unconfigured(monkeypatch, client):
    """per_page clamping still applies; verifies the clamp fires before the
    SQL call so a malformed query string can't blow up downstream."""
    seen = {}

    def fake_page(per_page, page=1):
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


def test_samples_no_creds_all_sources(monkeypatch, client):
    """When every client factory returns None (no creds), /api/d2/samples
    still returns 200 with one entry per source, each ok=False."""
    monkeypatch.setattr(d2_main, "_evo_client",       lambda: None)
    monkeypatch.setattr(d2_main, "_sg_client",        lambda: None)
    monkeypatch.setattr(d2_main, "_tickpick_client",  lambda: None)
    monkeypatch.setattr(d2_main, "_vivid_client",     lambda: None)
    monkeypatch.setattr(d2_main, "_seatdata_client",  lambda: None)
    monkeypatch.setattr(d2_main, "_gotickets_client", lambda: None)
    r = client.get("/api/d2/samples")
    assert r.status_code == 200
    body = r.json()
    sources = {s["source"]: s for s in body["samples"]}
    assert set(sources) == {"evo", "seatgeek", "tickpick", "vivid", "seatdata", "gotickets"}
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


def test_norm_evo_pulls_event_from_nested_ticket_group():
    """list_orders puts the event inside items[0].ticket_group.event — not at
    the top level. Earlier reads of o.get('event') silently returned None and
    left the dashboard's Event / Event Date columns blank."""
    row = d2_main._norm_evo({
        "id": 99, "state": "accepted",
        "items": [{
            "quantity": 2,
            "ticket_group": {
                "event": {"name": "Knicks vs Lakers", "occurs_at": "2026-12-15T19:30:00Z"},
            },
        }],
    })
    assert row["event_name"] == "Knicks vs Lakers"
    assert row["event_date"] == "2026-12-15T19:30:00Z"
    assert row["qty"] == 2


def test_norm_vivid_xml_flat_dict():
    """Vivid clients return dicts with all string values (XML-flattened).
    The XML uses lowercase <event> as the event-name tag; camelCase
    'eventName' is accepted as a fallback for legacy data."""
    row = d2_main._norm_vivid({
        "orderId": "V-100", "event": "Show", "eventDate": "2026-09-01",
        "quantity": "3", "status": "PENDING_SHIPMENT", "total": "275.00",
    })
    assert row["source"] == "vivid"
    assert row["order_id"] == "V-100"
    assert row["event_name"] == "Show"
    assert row["qty"] == 3
    assert row["amount"] == 275.0


def test_norm_vivid_legacy_eventname_fallback():
    """Records persisted with the older 'eventName' key still resolve."""
    row = d2_main._norm_vivid({"orderId": "V-1", "eventName": "Legacy Show"})
    assert row["event_name"] == "Legacy Show"


def test_fetch_orders_from_sql_returns_none_when_unconfigured(monkeypatch):
    """When Supabase isn't configured (_sb returns None), the SQL fetcher
    short-circuits with None so the caller falls back to the upstream API."""
    monkeypatch.setattr(d2_main, "_sb", lambda: None)
    assert d2_main._fetch_orders_from_sql("evo", 25) is None


def test_fetch_orders_from_sql_joins_unified_orders_and_v_event_base(monkeypatch):
    """The SQL path pulls unified_orders, then v_event_base for the referenced
    tevo_event_ids, and merges them into the normalized row shape with
    event_name + event_date populated."""
    captured: dict = {}

    class FakeQuery:
        def __init__(self, table_name, rows):
            self.table_name = table_name
            self._rows = rows
            captured.setdefault("tables", []).append(table_name)
        def select(self, *_a, **_kw):  return self
        def eq(self, key, val):        captured.setdefault("eq",  []).append((key, val)); return self
        def in_(self, key, vals):      captured.setdefault("in",  []).append((key, list(vals))); return self
        def order(self, *_a, **_kw):   return self
        def limit(self, *_a, **_kw):   return self
        def range(self, *a, **_kw):    captured.setdefault("range", []).append(tuple(a)); return self
        def execute(self):
            return type("Res", (), {"data": self._rows})()

    class FakeSb:
        def table(self, name):
            if name == "unified_orders":
                return FakeQuery(name, [
                    {"source": "evo", "source_order_id": "111", "tevo_event_id": 42,
                     "source_status": "accepted", "quantity": 2, "gross_value": "180.50",
                     "created_at": "2026-05-13T19:00:00Z", "last_seen_at": "2026-05-13T20:35:00Z"},
                ])
            if name == "v_event_base":
                return FakeQuery(name, [
                    {"tevo_event_id": 42, "event_name": "Knicks vs Lakers",
                     "event_at_local": "2026-06-01T19:30:00-04:00",
                     "event_at_utc":   "2026-06-01T23:30:00"},
                ])
            raise AssertionError(f"unexpected table: {name}")

    monkeypatch.setattr(d2_main, "_sb", lambda: FakeSb())
    out = d2_main._fetch_orders_from_sql("evo", 25)
    assert out["ok"] is True
    assert out["origin"] == "sql"
    assert out["as_of"] == "2026-05-13T20:35:00Z"
    row = out["rows"][0]
    assert row["source"] == "evo"
    assert row["order_id"] == "111"
    assert row["event_name"] == "Knicks vs Lakers"
    assert row["event_date"] == "2026-06-01T19:30:00-04:00"  # prefers _local over _utc
    assert row["qty"] == 2
    assert row["amount"] == 180.5
    # Both tables queried; second query filtered by the discovered tevo_event_id.
    assert captured["tables"] == ["unified_orders", "v_event_base"]
    assert ("tevo_event_id", [42]) in captured["in"]


def test_fetch_evo_uses_sql_when_rows_present(monkeypatch):
    """_fetch_evo prefers the SQL row when it's ok and non-empty; the
    upstream API client is never called."""
    monkeypatch.setattr(
        d2_main, "_fetch_orders_from_sql",
        lambda src, n, p=1: {"source": "evo", "ok": True, "rows": [{"source": "evo", "order_id": "X"}], "origin": "sql"},
    )
    called = {}
    def fail_evo_client():
        called["api"] = True
        raise AssertionError("API should not be called when SQL has rows")
    monkeypatch.setattr(d2_main, "_evo_client", fail_evo_client)

    out = d2_main._fetch_evo(per_page=10)
    assert out["origin"] == "sql"
    assert "api" not in called


def test_fetch_evo_falls_back_to_api_when_sql_empty(monkeypatch):
    """When the SQL row is ok but rows is empty, the API path runs."""
    monkeypatch.setattr(d2_main, "_fetch_orders_from_sql", lambda src, n, p=1: {"source": "evo", "ok": True, "rows": [], "origin": "sql"})

    class FakeEvo:
        def list_orders(self, **kw):
            return {"orders": [{"id": 99, "items": [{"quantity": 1, "ticket_group": {"event": {"name": "API event"}}}]}], "total_entries": 1}

    monkeypatch.setattr(d2_main, "_evo_client", lambda: FakeEvo())
    out = d2_main._fetch_evo(per_page=10)
    assert out["origin"] == "api"
    assert out["rows"][0]["event_name"] == "API event"


def test_fetch_evo_dedupes_accepted_and_pending(monkeypatch):
    monkeypatch.setattr(d2_main, "_fetch_orders_from_sql", lambda src, n, p=1: None)
    """_fetch_evo fans out across state=accepted + state=pending and dedupes
    by order_id. Mirrors the operator's reference Tkinter app's pattern."""
    calls: list[str] = []

    class FakeEvo:
        def list_orders(self, *, state=None, **kw):
            calls.append(state)
            if state == "accepted":
                return {
                    "orders": [
                        {"id": 1, "state": "accepted", "items": [{"quantity": 2, "ticket_group": {"event": {"name": "A"}}}]},
                        {"id": 2, "state": "accepted", "items": [{"quantity": 1, "ticket_group": {"event": {"name": "B"}}}]},
                    ],
                    "total_entries": 50,
                }
            if state == "pending":
                # Order 2 appears in both lists — must dedupe.
                return {
                    "orders": [
                        {"id": 2, "state": "pending",  "items": [{"quantity": 1, "ticket_group": {"event": {"name": "B"}}}]},
                        {"id": 3, "state": "pending",  "items": [{"quantity": 4, "ticket_group": {"event": {"name": "C"}}}]},
                    ],
                    "total_entries": 50,
                }
            return {"orders": []}

    monkeypatch.setattr(d2_main, "_evo_client", lambda: FakeEvo())
    result = d2_main._fetch_evo(per_page=10)
    assert calls == ["accepted", "pending"]
    assert result["ok"] is True
    ids = sorted(r["order_id"] for r in result["rows"])
    assert ids == ["1", "2", "3"]


def test_canonical_status_maps_per_source():
    """Every source's raw status enum maps to a canonical bucket from
    order_status_xref. Unknown values return None (caller can surface raw)."""
    assert d2_main._canonical_status("evo", "completed") == "fulfilled"
    assert d2_main._canonical_status("evo", "rejected") == "rejected"
    assert d2_main._canonical_status("seatgeek", "open") == "pending"
    assert d2_main._canonical_status("seatgeek", "delivered") == "fulfilled"
    # TickPick — list_orders defaults to status=unfulfilled, which maps
    # to canonical "accepted" (broker holds, awaiting delivery).
    assert d2_main._canonical_status("tickpick", "unfulfilled") == "accepted"
    # Vivid is case-sensitive uppercase in the XML feed.
    assert d2_main._canonical_status("vivid", "PENDING_SHIPMENT") == "accepted"
    # Case-insensitive fallback.
    assert d2_main._canonical_status("vivid", "pending_shipment") == "accepted"
    # Unknown values + nones.
    assert d2_main._canonical_status("evo", "wat") is None
    assert d2_main._canonical_status("evo", None) is None


def test_norm_tickpick_includes_canonical_status():
    row = d2_main._norm_tickpick({"orderId": "T-1", "status": "unfulfilled", "quantity": 2})
    assert row["status"] == "unfulfilled"
    assert row["canonical_status"] == "accepted"


def test_norm_vivid_includes_canonical_status():
    row = d2_main._norm_vivid({"orderId": "V-1", "status": "PENDING_SHIPMENT", "event": "Show"})
    assert row["canonical_status"] == "accepted"


def test_norm_gotickets_derives_status_from_fulfilled_and_cancel():
    fulfilled = d2_main._norm_gotickets({"id": 1, "fulfilled": True, "fulfillmentTime": "2026-05-13T20:00:00Z"})
    assert fulfilled["canonical_status"] == "fulfilled"
    assert fulfilled["fulfillment_time"] == "2026-05-13T20:00:00Z"

    cancelled = d2_main._norm_gotickets({"id": 2, "cancelReason": "REJECTED", "fulfilled": False})
    assert cancelled["canonical_status"] == "cancelled"
    assert "REJECTED" in cancelled["status"]

    pending = d2_main._norm_gotickets({"id": 3, "fulfilled": False, "sellerStatus": "NONE"})
    assert pending["canonical_status"] == "pending"


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


def test_samples_includes_gotickets_when_sample_id_set(monkeypatch, client):
    class FakeGoTickets:
        def get_sale(self, order_id):
            assert order_id == "S-99"
            return {"id": "S-99", "fulfilled": True}

    monkeypatch.setenv("GOTICKETS_SAMPLE_ORDER_ID", "S-99")
    monkeypatch.setattr(d2_main, "_evo_client",       lambda: None)
    monkeypatch.setattr(d2_main, "_sg_client",        lambda: None)
    monkeypatch.setattr(d2_main, "_tickpick_client",  lambda: None)
    monkeypatch.setattr(d2_main, "_vivid_client",     lambda: None)
    monkeypatch.setattr(d2_main, "_seatdata_client",  lambda: None)
    monkeypatch.setattr(d2_main, "_gotickets_client", lambda: FakeGoTickets())
    r = client.get("/api/d2/samples")
    assert r.status_code == 200
    sources = {s["source"]: s for s in r.json()["samples"]}
    gt = sources["gotickets"]
    assert gt["ok"] is True
    assert gt["method"] == "get_sale(S-99)"
    assert gt["sample"]["id"] == "S-99"


def test_samples_gotickets_without_sample_id_surfaces_clear_error(monkeypatch, client):
    """Without GOTICKETS_SAMPLE_ORDER_ID set, the chip shows 'upstream error'
    (generic — RuntimeError isn't in the typed-error allowlist). Operator
    sees the underlying reason in Render logs."""
    monkeypatch.delenv("GOTICKETS_SAMPLE_ORDER_ID", raising=False)
    # Stub every other client to None so the gotickets-specific sampler is
    # the only one that runs into the env check.
    monkeypatch.setattr(d2_main, "_evo_client",       lambda: None)
    monkeypatch.setattr(d2_main, "_sg_client",        lambda: None)
    monkeypatch.setattr(d2_main, "_tickpick_client",  lambda: None)
    monkeypatch.setattr(d2_main, "_vivid_client",     lambda: None)
    monkeypatch.setattr(d2_main, "_seatdata_client",  lambda: None)
    monkeypatch.setattr(d2_main, "_gotickets_client", lambda: object())  # truthy stub
    r = client.get("/api/d2/samples")
    sources = {s["source"]: s for s in r.json()["samples"]}
    assert sources["gotickets"]["ok"] is False
    assert sources["gotickets"]["sample"] is None


def test_diag_tickpick_no_token(monkeypatch, client):
    """No token configured → ok=False, error 'no token configured'.
    base_diag fields still present so the operator can see WHY (env_var=None)."""
    monkeypatch.delenv("TICKPICK_API_TOKEN", raising=False)
    monkeypatch.delenv("TICKPICK_TOKEN",     raising=False)
    r = client.get("/api/d2/diag/tickpick")
    body = r.json()
    assert body["ok"] is False
    assert body["error"] == "no token configured"
    assert body["token_env_var"] is None
    assert body["token_masked"] is None


def test_diag_tickpick_surfaces_upstream_status_and_body(monkeypatch, client):
    """The probe captures the upstream HTTP status + response body so the
    operator can see exactly why a 401 is firing (invalid_token vs
    expired_token vs whatever the upstream returns)."""
    captured = {}

    class FakeResp:
        def __init__(self):
            self.status_code = 401
            self.ok = False
            self.text = '{"error":"invalid_token","error_description":"The access token expired"}'
            self.headers = {
                "Content-Type": "application/json",
                "WWW-Authenticate": 'Bearer error="invalid_token"',
                "X-RateLimit-Remaining": "499",
            }

    def fake_get(url, **kw):
        captured["url"] = url
        captured["headers"] = kw.get("headers", {})
        captured["params"] = kw.get("params", {})
        captured["allow_redirects"] = kw.get("allow_redirects")
        return FakeResp()

    monkeypatch.setenv("TICKPICK_API_TOKEN", "tok-secret-WXYZ")
    monkeypatch.delenv("TICKPICK_TOKEN", raising=False)
    monkeypatch.setattr(d2_main.requests, "get", fake_get)
    r = client.get("/api/d2/diag/tickpick")
    body = r.json()
    assert body["ok"] is False
    assert body["status_code"] == 401
    assert "invalid_token" in body["response_body"]
    assert body["response_headers"]["WWW-Authenticate"] == 'Bearer error="invalid_token"'
    assert body["response_headers"]["X-RateLimit-Remaining"] == "499"
    assert body["token_env_var"] == "TICKPICK_API_TOKEN"
    assert body["token_masked"] == "...WXYZ"
    # We sent the actual token in the Authorization header, but never echoed
    # it back in the response body or in any returned header.
    assert "tok-secret-WXYZ" not in r.text
    # Probe must not follow redirects (could leak token to a 3xx Location host).
    assert captured["allow_redirects"] is False


def test_diag_tickpick_warns_on_duplicate_env_vars(monkeypatch, client):
    """Both vault-canonical AND legacy keys set with different values is a
    common cause of 401 — surface it explicitly in the probe response."""
    monkeypatch.setenv("TICKPICK_API_TOKEN", "new-AAAA")
    monkeypatch.setenv("TICKPICK_TOKEN",     "old-BBBB")

    class FakeResp:
        status_code = 200
        ok = True
        text = "[]"
        headers = {"Content-Type": "application/json"}

    monkeypatch.setattr(d2_main.requests, "get", lambda *a, **kw: FakeResp())
    body = client.get("/api/d2/diag/tickpick").json()
    assert body["token_env_var"] == "TICKPICK_API_TOKEN"
    assert body["token_warning"] is not None
    assert "TICKPICK_API_TOKEN" in body["token_warning"]
    assert "TICKPICK_TOKEN" in body["token_warning"]


def test_diag_tickpick_scrubs_token_if_echoed_in_body(monkeypatch, client):
    """Belt-and-suspenders: if the upstream somehow echoes the token back in
    the response body, mask it before returning to the client."""
    monkeypatch.setenv("TICKPICK_API_TOKEN", "echo-me-XYZW")
    monkeypatch.delenv("TICKPICK_TOKEN", raising=False)

    class FakeResp:
        status_code = 200
        ok = True
        text = '{"orders":[],"debug_token":"echo-me-XYZW"}'
        headers = {"Content-Type": "application/json"}

    monkeypatch.setattr(d2_main.requests, "get", lambda *a, **kw: FakeResp())
    body = client.get("/api/d2/diag/tickpick").json()
    assert "echo-me-XYZW" not in body["response_body"]
    assert "...XYZW" in body["response_body"]


def test_orders_returns_pagination_metadata(monkeypatch, client):
    """`/api/d2/orders` echoes the requested page + per_page so the front-end
    can size the Prev/Next buttons without a separate count query."""
    monkeypatch.setattr(d2_main, "_fetch_unified_orders_page",
                        lambda n, p=1: {"rows": [], "per_source_count": {}, "per_source_as_of": {}})
    body = client.get("/api/d2/orders?per_page=25&page=3").json()
    assert body["page"] == 3
    assert body["per_page"] == 25


def test_orders_page_param_threads_to_sql(monkeypatch, client):
    """The page param reaches the unified-orders SQL fetcher so PostgREST
    .range() lines up with the operator's Next/Prev clicks."""
    seen = {}

    def fake_page(per_page, page=1):
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

    def fake_page(per_page, page=1):
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


def test_order_detail_no_creds(monkeypatch, client):
    """When the client factory returns None, the endpoint returns 200 with
    ok=False instead of 500 — front-end can render a clear error card."""
    monkeypatch.setattr(d2_main, "_tickpick_client", lambda: None)
    r = client.get("/api/d2/order/tickpick/42")
    assert r.status_code == 200
    body = r.json()
    assert body == {"ok": False, "error": "no creds"}


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


def test_order_detail_dispatches_to_client(monkeypatch, client):
    """Happy path: the endpoint dispatches to the source's by-id fetcher and
    wraps the response. The /v9/orders/:id call hits get_order on evo_client."""
    class FakeEvo:
        def get_order(self, order_id):
            assert order_id == 42
            return {"id": 42, "state": "accepted", "items": []}

    monkeypatch.setattr(d2_main, "_evo_client", lambda: FakeEvo())
    r = client.get("/api/d2/order/evo/42")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["source"] == "evo"
    assert body["order_id"] == "42"
    assert body["data"]["id"] == 42


def test_to_int_to_float_handle_garbage():
    assert d2_main._to_int(None) is None
    assert d2_main._to_int("") is None
    assert d2_main._to_int("not a number") is None
    assert d2_main._to_int("7") == 7
    assert d2_main._to_float(None) is None
    assert d2_main._to_float("not a number") is None
    assert d2_main._to_float("3.14") == 3.14
