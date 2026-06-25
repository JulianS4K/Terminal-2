"""Branch-coverage closers for routers/axs.py + routers/broker.py.

Line coverage of both routers is already 100%; this file drives the few
remaining PARTIAL branches to reach 100% BRANCH coverage. Each test targets a
specific `A->B` jump that the existing suites never exercise:

routers/axs.py
  33->35  axs_events with active=false (skip the `.eq("active", True)` filter)
  39->53  axs_events where NO event carries a last_snapshot_id (skip snap fetch)
  55->63  axs_events where NO event carries a tevo_event_id (skip owned peg)

routers/broker.py
  174->172  seller-book dedupe: a newer row already stored, an older dup arrives
            -> the `if` is False, loop continues without overwriting
  206->202  section-quality build: a row that is non-ancillary yet still skipped
            (duplicate section / null retail_median) -> body not entered
  263->272  order-lookup with source pinned past vivid (skip the vivid block)
  272->292  order-lookup with source pinned that never reaches the evo block
  281->292  order-lookup evo: valid int order id but no matching evo header

House style mirrors tests/test_axs_routes.py + tests/test_broker_routes.py:
fake env BEFORE importing app, no real network/DB, app.require_sb monkeypatched
to a fluent fake.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app ----
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


# ---------- Reusable fluent fake (same shape as the sibling suites) ----------

class _FakeQuery:
    def __init__(self, data):
        self._data = data

    def select(self, *_a, **_k):
        return self

    def eq(self, *_a, **_k):
        return self

    def in_(self, *_a, **_k):
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def execute(self):
        return type("_Res", (), {"data": self._data})()


class FakeSupabase:
    def __init__(self, rpc_data=None, table_data=None):
        self.rpc_data = rpc_data or {}
        self.table_data = table_data or {}
        self.rpc_calls: list[tuple[str, dict]] = []
        self.table_calls: list[str] = []

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params or {}))
        return _FakeQuery(self.rpc_data.get(name, []))

    def table(self, name):
        self.table_calls.append(name)
        return _FakeQuery(self.table_data.get(name, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _use_db(monkeypatch, fake: FakeSupabase):
    monkeypatch.setattr(app_module, "require_sb", lambda: fake)


# ======================================================================
# routers/axs.py
# ======================================================================

def test_axs_events_active_false_skips_active_filter(client, monkeypatch):
    """33->35: active=false means the `if active` guard is False, so the
    `.eq("active", True)` filter is skipped and retired rows are included."""
    evs = [
        {"axs_event_id": "ev-a", "event_url": "https://axs.com/a", "tevo_event_id": 42,
         "tevo_venue_id": 7, "active": True, "last_pulled_at": "2026-06-19T00:00:00Z",
         "last_snapshot_id": 100},
        {"axs_event_id": "ev-x", "event_url": "https://axs.com/x", "tevo_event_id": 99,
         "tevo_venue_id": 8, "active": False, "last_pulled_at": "2026-06-18T00:00:00Z",
         "last_snapshot_id": None},
    ]
    snaps = [{"id": 100, "captured_at": "2026-06-19T00:00:00Z", "event_name": "Show A",
              "venue_name": "Arena", "occurs_at_local": None, "currency": "USD",
              "getin": 55, "price_min": 55, "price_max": 250, "listings_count": 1,
              "sections_count": 1, "offers_count": 0, "seats_primary": 1,
              "seats_resale": 0, "onsale_now": True}]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "axs_events": evs, "axs_event_snapshots": snaps, "latest_event_metrics": []}))
    body = client.get("/api/axs/events?active=false").json()
    # Both rows (including the inactive one) come back since the filter was skipped.
    assert body["count"] == 2
    retired = next(e for e in body["events"] if e["axs_event_id"] == "ev-x")
    assert retired["active"] is False


def test_axs_events_no_snapshot_ids_skips_snap_fetch(client, monkeypatch):
    """39->53: every event lacks last_snapshot_id, so snap_ids is empty and the
    snapshot-fetch block is skipped (snaps stays {})."""
    evs = [
        {"axs_event_id": "ev-a", "event_url": "https://axs.com/a", "tevo_event_id": 42,
         "tevo_venue_id": 7, "active": True, "last_pulled_at": "2026-06-19T00:00:00Z",
         "last_snapshot_id": None},
    ]
    metrics = [{"event_id": 42, "owned_tickets_count": 3, "owned_groups_count": 1,
                "owned_share": 0.1}]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "axs_events": evs, "axs_event_snapshots": [], "latest_event_metrics": metrics}))
    body = client.get("/api/axs/events").json()
    assert body["count"] == 1
    assert body["pulled"] == 0  # no captured_at without a snapshot
    a = body["events"][0]
    assert a["event_name"] is None and a["captured_at"] is None
    # owned peg still applied (tevo_event_id present), proving snap-skip is isolated.
    assert a["we_own"] is True and a["owned_tickets"] == 3


def test_axs_events_no_tevo_ids_skips_owned_peg(client, monkeypatch):
    """55->63: no event carries a tevo_event_id, so tevo_ids is empty and the
    owned-inventory peg block is skipped (owned stays {})."""
    evs = [
        {"axs_event_id": "ev-b", "event_url": "https://axs.com/b", "tevo_event_id": None,
         "tevo_venue_id": None, "active": True, "last_pulled_at": "2026-06-19T00:00:00Z",
         "last_snapshot_id": 200},
    ]
    snaps = [{"id": 200, "captured_at": "2026-06-19T00:00:00Z", "event_name": "Show B",
              "venue_name": "Hall", "occurs_at_local": None, "currency": "USD",
              "getin": 30, "price_min": 30, "price_max": 80, "listings_count": 2,
              "sections_count": 2, "offers_count": 0, "seats_primary": 2,
              "seats_resale": 0, "onsale_now": False}]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "axs_events": evs, "axs_event_snapshots": snaps, "latest_event_metrics": []}))
    body = client.get("/api/axs/events").json()
    assert body["count"] == 1
    a = body["events"][0]
    # Snapshot joined (proves snap path ran) but owned peg empty (tevo id absent).
    assert a["event_name"] == "Show B"
    assert a["linked"] is False
    assert a["we_own"] is False and a["owned_tickets"] is None
    assert body["owned"] == 0


# ======================================================================
# routers/broker.py
# ======================================================================

def test_substitutions_seller_dedupe_keeps_newer_when_older_arrives_later(client, monkeypatch):
    """174->172: the NEWER seller row is iterated first and stored; the OLDER
    duplicate arrives next, so `if k not in latest_seller or (newer)` is False
    and the loop continues without overwriting (the older row is dropped)."""
    ls: list[dict] = []  # no TEvo owned pool; seller book only
    seller = [
        # newest first -> stored on the first iteration
        {"seller_listing_id": "SLR1", "section": "310", "row": "14", "quantity": 4,
         "cost": 17.95, "pulled_at": "2026-05-10T00:00:00Z", "tevo_event_id": 3100123},
        # older dup -> condition False, NOT stored (drives 174->172)
        {"seller_listing_id": "SLR1", "section": "310", "row": "14", "quantity": 4,
         "cost": 99.0, "pulled_at": "2026-05-09T00:00:00Z", "tevo_event_id": 3100123},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": ls, "seatgeek_seller_listings": seller}))
    body = client.get("/api/broker/event/3100123/substitutions"
                      "?section=310&row=14&quantity=4&revenue=67.12").json()
    # The kept lot is the newer one ($17.95), proving the older dup was dropped.
    assert body["best"]["ticket_group_id"] == "SLR1"
    assert body["best"]["unit_cost"] == 17.95
    assert body["best"]["inv_source"] == "sg_seller"
    # exactly one seller lot survived dedupe
    assert [s["ticket_group_id"] for s in body["subs"]] == ["SLR1"]


def test_substitutions_section_quality_skips_dup_and_null_median(client, monkeypatch):
    """206->202: non-ancillary section_metrics rows that still fail the build
    guard (duplicate section already seen, or null retail_median) take the
    `if`-False jump back to the loop without populating section_quality."""
    ls = [
        {"tevo_ticket_group_id": "lower", "captured_at": "2026-05-10T12:00:00Z",
         "section": "108", "row": "20", "quantity": 4, "retail_price": 180, "is_owned": True},
    ]
    section_metrics = [
        # sold section, latest wins
        {"section": "310", "retail_median": 50, "is_ancillary": False, "captured_at": "2026-05-10T12:00:00Z"},
        # DUPLICATE of 310 (already in section_quality) -> sec in section_quality -> skip
        {"section": "310", "retail_median": 40, "is_ancillary": False, "captured_at": "2026-05-09T12:00:00Z"},
        # non-ancillary but NULL retail_median -> retail_median-is-None -> skip
        {"section": "200", "retail_median": None, "is_ancillary": False, "captured_at": "2026-05-10T12:00:00Z"},
        # the real upgrade target
        {"section": "108", "retail_median": 200, "is_ancillary": False, "captured_at": "2026-05-10T12:00:00Z"},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "listings_snapshots": ls, "section_metrics": section_metrics}))
    body = client.get("/api/broker/event/1/substitutions"
                      "?section=310&row=14&quantity=4&revenue=400").json()
    ss = body["section_subs"]
    assert ss["best"]["to_section"] == "108"
    # sold-section quality is the FIRST (latest) 310 row = 50, not the dropped dup 40.
    assert ss["sold_quality"] == 50
    assert ss["best"]["section_delta"] == 150  # 200 - 50


def test_order_lookup_source_pinned_skips_vivid_block(client, monkeypatch):
    """263->272: source='evo' means `src in (None, 'vivid')` is False, so the
    vivid block is skipped and control jumps to the evo block."""
    _use_db(monkeypatch, FakeSupabase(table_data={
        "evo_orders": [{"evo_order_id": 77, "tevo_event_id": 9, "total": 300, "subtotal": 280}],
        "evo_order_items": [
            {"ticket_group_section": "Sec", "ticket_group_row": "R", "quantity": 2,
             "event_name": "Z", "event_id": 9},
        ],
    }))
    body = client.get("/api/broker/order-lookup?order_id=77&source=evo").json()
    assert body["found"] is True and body["source"] == "evo"
    assert body["section"] == "Sec" and body["revenue"] == 280


def test_order_lookup_source_pinned_never_reaches_evo_block(client, monkeypatch):
    """272->292: source='tickpick' with no matching tickpick order means
    `src in (None, 'evo')` is False, so the evo block is skipped entirely and
    control falls through to the not-found return."""
    _use_db(monkeypatch, FakeSupabase(table_data={"tickpick_orders": []}))
    body = client.get("/api/broker/order-lookup?order_id=99&source=tickpick").json()
    assert body["found"] is False
    assert body["source"] == "tickpick"
    assert "note" in body


def test_order_lookup_evo_valid_int_but_no_header(client, monkeypatch):
    """281->292: an all-digit order id passes the int() parse so eoid is set,
    but no evo header matches -> `if hdr` is False and we fall through to the
    not-found return."""
    _use_db(monkeypatch, FakeSupabase(table_data={"evo_orders": []}))
    body = client.get("/api/broker/order-lookup?order_id=123456").json()
    assert body["found"] is False
    assert body["order_id"] == "123456"
    assert "note" in body
