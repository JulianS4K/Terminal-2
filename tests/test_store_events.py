"""Tests for /api/store/events TEvo-direct catalog (PR #84 rewrite).

Covers:
  - office_id passthrough to client.list_events()
  - CANCELLED-name filter
  - Pagination math (post-PR #90 fix): offset that's NOT a multiple of
    per_page returns the correct slice
  - performer_metadata fallback when the SQL bulk-fetch raises

These tests never make a real HTTP call. client.list_events and the
SQL bulk-fetch helper are both monkeypatched with synthetic data.

Audit ref: row 96 item 6 (D1 follow-up).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app ----
# app.py at import time runs resolve_tevo_creds() and sys.exit()'s if it
# can't build an EvoClient. Provide fake creds so the import succeeds; we
# replace `app.client` with a stub once we own the test process.
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")  # don't gate routes in tests

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

# Skip the whole module if fastapi/starlette test stack isn't available
# (the readonly-guards-only minimal env). Lets tests/test_readonly_guards.py
# keep running on bare Python.
fastapi = pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------- Helpers ----------

def _ev(eid: int, name: str = None, performer_id: int = 16303,
        performer_name: str = "New York Knicks") -> dict:
    """Synthetic /v9/events item shaped to match TEvo's list response."""
    return {
        "id": eid,
        "name": name or f"Test Event {eid}",
        "occurs_at": "2026-06-01T19:00:00Z",
        "occurs_at_local": "2026-06-01T19:00:00-04:00",
        "available_count": 100,
        "owned_by_office": True,
        "tbd": False,
        "popularity_score": 0.5,
        "venue": {
            "id": 896, "name": "Madison Square Garden",
            "location": "New York, NY", "city": "New York", "state": "NY",
        },
        "performances": [
            {"primary": True,
             "performer": {"id": performer_id, "name": performer_name}},
        ],
    }


@pytest.fixture
def client(monkeypatch):
    """FastAPI TestClient with TEvo + Supabase calls stubbed."""
    # Stub _bulk_performer_assets so we don't actually hit Supabase.
    monkeypatch.setattr(
        app_module, "_bulk_performer_assets",
        lambda db, pids: {16303: {
            "logo_default_url": "https://test/knicks.png",
            "color_primary": "1d428a", "espn_league": "NBA",
        }} if 16303 in pids else {},
    )
    # Stub require_sb so the bulk-fetch helper sees a non-None db param.
    monkeypatch.setattr(app_module, "require_sb", lambda: object())
    return TestClient(app_module.app)


class _FakeEvoClient:
    """Replaces app.client. Records every list_events call kwargs for
    assertions; returns from a programmable page-keyed payload map."""

    def __init__(self, pages: dict[int, list[dict]], total: int | None = None):
        self.pages = pages
        self.total = total if total is not None else sum(len(v) for v in pages.values())
        self.calls: list[dict] = []

    def list_events(self, **kwargs):
        self.calls.append(kwargs)
        page = kwargs.get("page", 1)
        return {"events": self.pages.get(page, []),
                "total_entries": self.total}


# ---------- Tests ----------

def test_office_id_passthrough(client, monkeypatch):
    fake = _FakeEvoClient({1: [_ev(1)]})
    monkeypatch.setattr(app_module, "client", fake)
    r = client.get("/api/store/events?limit=1")
    assert r.status_code == 200
    assert r.json()["count"] == 1
    # The fake should have been called with office_id=TEVO_OFFICE_ID.
    assert fake.calls, "list_events was never invoked"
    assert fake.calls[0].get("office_id") == app_module.TEVO_OFFICE_ID


def test_cancelled_name_filter(client, monkeypatch):
    fake = _FakeEvoClient({1: [
        _ev(1, "Real Event"),
        _ev(2, "CANCELLED — Postponed Show"),
        _ev(3, "Another Real Event"),
        # CANCELLED match is case-insensitive (filter uses .upper())
        _ev(4, "cancelled lower-case marker"),
    ]})
    monkeypatch.setattr(app_module, "client", fake)
    r = client.get("/api/store/events?limit=10")
    out_ids = [e["id"] for e in r.json()["events"]]
    assert out_ids == [1, 3], (
        f"CANCELLED filter should drop ids 2 and 4; got {out_ids}"
    )


def test_pagination_offset_aligned(client, monkeypatch):
    """offset=0 with limit=5 returns the first 5 events."""
    fake = _FakeEvoClient({1: [_ev(i) for i in range(1, 11)]})
    monkeypatch.setattr(app_module, "client", fake)
    r = client.get("/api/store/events?limit=5&offset=0")
    out_ids = [e["id"] for e in r.json()["events"]]
    assert out_ids == [1, 2, 3, 4, 5]


def test_pagination_offset_non_aligned(client, monkeypatch):
    """offset=25 with limit=60 returns records 26..85 (1-indexed), NOT 1..60.

    Pre-PR-#90 the handler did `start_page = (offset // per_page) + 1`
    which skipped to TEvo page 1 (cap=60, per_page=60, start_page=1) and
    returned records 1-60. The fix is to slice raw_events[offset%per_page:].
    Verify: with limit=60 and offset=25, we get ids [26..85] from a fake
    that emits sequential ids across two TEvo pages.
    """
    # cap=60 → per_page=60. start_page=1 (25//60+1=1). offset_in_first_page=25.
    # pages_needed = ((25+60)+60-1)//60 = 144//60 = 2. So pages 1 and 2.
    fake = _FakeEvoClient({
        1: [_ev(i) for i in range(1, 61)],   # ids 1..60
        2: [_ev(i) for i in range(61, 121)], # ids 61..120
    })
    monkeypatch.setattr(app_module, "client", fake)
    r = client.get("/api/store/events?limit=60&offset=25")
    out_ids = [e["id"] for e in r.json()["events"]]
    assert out_ids == list(range(26, 86)), (
        f"offset=25 limit=60 must return ids 26..85, got first={out_ids[:3]} "
        f"last={out_ids[-3:]} len={len(out_ids)}"
    )


def test_performer_metadata_fallback(client, monkeypatch):
    """If the Supabase bulk-fetch raises, cards still render with null
    logo/color/league — catalog never breaks on enrichment failure."""
    def _raise(*args, **kwargs):
        raise RuntimeError("supabase down")
    monkeypatch.setattr(app_module, "_bulk_performer_assets", _raise)
    fake = _FakeEvoClient({1: [_ev(1)]})
    monkeypatch.setattr(app_module, "client", fake)
    r = client.get("/api/store/events?limit=1")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["count"] == 1
    card = body["events"][0]
    assert card["primary_performer_logo"] is None
    assert card["primary_performer_color"] is None
    assert card["primary_performer_league"] is None
    # Performer name + id still come through (those are TEvo data).
    assert card["primary_performer_name"] == "New York Knicks"
    assert card["primary_performer_id"] == 16303


def test_performer_media_when_available(client, monkeypatch):
    """When Supabase has the performer in performer_metadata, the card
    surfaces logo + color + league."""
    fake = _FakeEvoClient({1: [_ev(1)]})
    monkeypatch.setattr(app_module, "client", fake)
    r = client.get("/api/store/events?limit=1")
    card = r.json()["events"][0]
    assert card["primary_performer_logo"] == "https://test/knicks.png"
    assert card["primary_performer_color"] == "1d428a"
    assert card["primary_performer_league"] == "NBA"


def test_we_own_always_true_with_office_filter(client, monkeypatch):
    """With office_id filter applied at TEvo, every event in the response
    has owned_by_office=true, so we_own surfaces true on every card."""
    fake = _FakeEvoClient({1: [_ev(i) for i in range(1, 4)]})
    monkeypatch.setattr(app_module, "client", fake)
    r = client.get("/api/store/events?limit=3")
    assert all(e["we_own"] is True for e in r.json()["events"])


# ---------- /api/store/reserve cap ----------

def test_reserve_rejects_quantity_over_cap(client):
    """quantity > 50 is rejected at the input-validation gate before any
    inventory lookup. A malformed/malicious client requesting 999999 must
    short-circuit with 400; we never want to hit TEvo or the snapshot
    table with that shape."""
    r = client.post("/api/store/reserve", json={
        "event_id": 3346000,
        "ticket_group_id": 12345,
        "quantity": 999999,
    })
    assert r.status_code == 400, r.text
    assert "maximum" in r.json()["detail"].lower()


def test_reserve_rejects_quantity_just_over_cap(client):
    """Boundary: quantity == 51 (one over the cap of 50) is rejected."""
    r = client.post("/api/store/reserve", json={
        "event_id": 3346000,
        "ticket_group_id": 12345,
        "quantity": 51,
    })
    assert r.status_code == 400


def test_reserve_accepts_quantity_at_cap(client, monkeypatch):
    """quantity == 50 passes the cap check (and continues to inventory
    lookup, where our fake returns no match → 404 is expected).
    Asserting NOT 400-with-cap-message proves the cap check let it
    through."""
    class _EmptyTGFake:
        def get_ticket_groups(self, *_, **__):
            return {"ticket_groups": []}
    monkeypatch.setattr(app_module, "client", _EmptyTGFake())
    r = client.post("/api/store/reserve", json={
        "event_id": 3346000,
        "ticket_group_id": 12345,
        "quantity": 50,
    })
    # quantity=50 passes the cap; downstream fails for "no such group" → 404
    assert r.status_code == 404, r.text


def test_503_when_client_unconfigured(client, monkeypatch):
    """When `client` is None at request time, we return 503 — not 500."""
    monkeypatch.setattr(app_module, "client", None)
    r = client.get("/api/store/events?limit=5")
    assert r.status_code == 503
    assert "TEvo client not configured" in r.json().get("detail", "")


# ---------- error-message scrubbing (no upstream details leak to public) ----------

def test_reserve_upstream_error_does_not_leak_tevo(client, monkeypatch):
    """When the upstream ticket_groups fetch raises, the public 502 must NOT
    echo 'TEvo' or the raw exception text (which can carry tokens / URLs /
    stack fragments). The full error is logged server-side only."""
    class _BoomFake:
        def get_ticket_groups(self, *_, **__):
            raise RuntimeError("TEvo API 500 https://api.tevo/x?token=SECRET")
    monkeypatch.setattr(app_module, "client", _BoomFake())
    r = client.post("/api/store/reserve", json={
        "event_id": 3346000, "ticket_group_id": 12345, "quantity": 2,
    })
    assert r.status_code == 502, r.text
    detail = r.json().get("detail", "")
    assert "TEvo" not in detail
    assert "SECRET" not in detail
    assert "token" not in detail.lower()
    # The same scrub pattern (log {e!r} server-side, return generic public
    # message) is applied at all 3 storefront TEvo-error sites: this reserve
    # path (app.py:7345), the cached ticket_groups helper (6812), and
    # /api/store/events/near (6384). reserve is the representative public
    # case; the other two are identical scrubs.


# ---------- seat-map "null"-string coercion (broken-image bug) ----------

def test_clean_opt_url_coerces_null_sentinels():
    """v_event_seating_chart / TEvo carry the literal string 'null' for an
    absent seat-map URL. _clean_opt_url must coerce 'null'/'none'/'' (any
    case, with whitespace) to real None so the frontend takes the no-chart
    placeholder path instead of rendering <img src="null"> (a broken image
    resolving to /store/event/null). Found live on event 3091432
    (Tigers @ Yankees): configuration.seating_chart_medium == 'null'."""
    f = app_module._clean_opt_url
    # sentinels → None
    assert f("null") is None
    assert f("NULL") is None
    assert f("  null  ") is None
    assert f("none") is None
    assert f("") is None
    assert f("   ") is None
    assert f(None) is None
    # real URLs pass through untouched
    assert f("https://s3.amazonaws.com/chart/medium.jpg") == "https://s3.amazonaws.com/chart/medium.jpg"
    # a string that merely contains "null" is NOT a sentinel
    assert f("https://x/nullsville.jpg") == "https://x/nullsville.jpg"
