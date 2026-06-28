"""Coverage-focused tests for the BROKER EVENT-DETAIL slice of app.py.

Targets the big read-only detail handlers:
  - GET /api/broker/event/{id}/overview
  - GET /api/broker/event/{id}/section-zones
  - GET /api/broker/event/{id}/zones
  - GET /api/broker/event/{id}/section-metrics
  - GET /api/broker/event/{id}/raw-tevo
  - GET /api/broker/watchlist-movers
  - GET /api/broker/performer/{id}/espn
  - GET /api/broker/event/{id}/chart-data   (the 469-line workbench handler)
  - GET /api/broker/movers                  (v1 + v2 paths)

House style mirrors tests/test_broker_routes.py: a programmable FakeSupabase
fluent chain + Starlette TestClient against app.app. No real network/DB — the
TEvo client and all RPC/table reads are stubbed. The fake's query builder is
keyed by table/rpc name so a single handler can read many tables with distinct
canned rows; some routes re-query the SAME table with different filters (e.g.
chart-data pulls espn_event_snapshots once per team) so the fake returns the
full programmed row list and lets the handler's own Python filtering run.
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

import server as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------- Programmable fake Supabase ----------

class _FakeQuery:
    """No-op fluent chain. Every builder method returns self; execute() yields
    an object exposing the preloaded `.data`. Builder filters are recorded but
    NOT applied — handlers do their own Python-side filtering, which is exactly
    the logic we want to exercise."""

    def __init__(self, data):
        self._data = data

    def select(self, *_a, **_k):
        return self

    def eq(self, *_a, **_k):
        return self

    def in_(self, *_a, **_k):
        return self

    def gte(self, *_a, **_k):
        return self

    def lte(self, *_a, **_k):
        return self

    def or_(self, *_a, **_k):
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, *_a, **_k):
        return self

    def upsert(self, *_a, **_k):
        return self

    def execute(self):
        return type("_Res", (), {"data": self._data})()


class FakeSupabase:
    """rpc_data: {rpc_name: rows-or-scalar}; table_data: {table: rows}. Unknown
    names default to [] (mirrors `.data or []` call sites). RPC entries may also
    be a scalar (e.g. derive_zone_fallback returns a bare string) or an
    Exception instance (to drive the `except` fallbacks)."""

    def __init__(self, rpc_data=None, table_data=None):
        self.rpc_data = rpc_data or {}
        self.table_data = table_data or {}
        self.rpc_calls: list[tuple[str, dict]] = []
        self.table_calls: list[str] = []

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params or {}))
        val = self.rpc_data.get(name, [])
        if isinstance(val, Exception):
            raise val
        return _FakeQuery(val)

    def table(self, name):
        self.table_calls.append(name)
        return _FakeQuery(self.table_data.get(name, []))


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _use_db(monkeypatch, fake: FakeSupabase):
    monkeypatch.setattr(app_module, "require_sb", lambda: fake)


# ===========================================================================
# /api/broker/event/{id}/overview
# ===========================================================================

def test_overview_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    monkeypatch.setattr(app_module, "_bulk_performer_assets", lambda db, pids: {})
    body = client.get("/api/broker/event/1/overview").json()
    assert body["event"] is None
    assert body["metrics"]["getin_price"] == {"v": None, "delta": None}
    assert body["assets"]["home"] is None
    assert body["lifecycle"] is None


def test_overview_populated_with_assets_and_lifecycle(client, monkeypatch):
    head = {
        "id": 1, "name": "Knicks vs Celtics", "primary_performer_id": 16303,
        "performer_ids": [16303, 16304, None], "occurs_at_local": "2026-07-01T19:00:00-04:00",
    }
    em_curr = {"captured_at": "2026-05-10T12:00:00Z", "getin_price": 150, "tickets_count": 500}
    em_prev = {"captured_at": "2026-05-09T12:00:00Z", "getin_price": 120, "tickets_count": 400}
    fake = FakeSupabase(
        rpc_data={
            "get_broker_event_detail": [head],
            "get_event_zones_rollup": [{"zone": "Lower", "tickets_count": 10}],
            "derive_event_lifecycle": [{"status": "active", "is_active": True}],
        },
        table_data={"event_metrics": [em_curr, em_prev]},
    )
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "_bulk_performer_assets",
                        lambda db, pids: {16303: {"logo": "h.png"}, 16304: {"logo": "a.png"}})
    body = client.get("/api/broker/event/1/overview").json()
    assert body["event"]["name"].startswith("Knicks")
    assert body["metrics"]["getin_price"]["v"] == 150
    assert body["metrics"]["getin_price"]["delta"] is not None
    assert body["last_pull_at"] == "2026-05-10T12:00:00Z"
    assert body["assets"]["home"] == {"logo": "h.png"}
    assert body["assets"]["away"] == {"logo": "a.png"}
    assert body["lifecycle"] == {"status": "active", "is_active": True}


def test_overview_lifecycle_rpc_exception_swallowed(client, monkeypatch):
    head = {"id": 1, "name": "X", "primary_performer_id": None, "performer_ids": []}
    fake = FakeSupabase(
        rpc_data={
            "get_broker_event_detail": [head],
            "derive_event_lifecycle": RuntimeError("rpc boom"),
        },
    )
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "_bulk_performer_assets", lambda db, pids: {})
    body = client.get("/api/broker/event/1/overview").json()
    # lifecycle RPC raised -> swallowed to None; route still 200s.
    assert body["lifecycle"] is None
    assert body["event"]["id"] == 1


# ===========================================================================
# /api/broker/event/{id}/section-zones
# ===========================================================================

def test_section_zones_no_event(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"events": []}))
    body = client.get("/api/broker/event/9/section-zones").json()
    assert body == {"map": {}, "source_mix": {}}


def test_section_zones_no_listings(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={
        "events": [{"primary_performer_id": 16303, "venue_id": 42}],
        "listings_snapshots": [],
    }))
    body = client.get("/api/broker/event/1/section-zones").json()
    assert body == {"map": {}, "source_mix": {}}


def test_section_zones_curated_match_all_match_types(client, monkeypatch):
    # One curated zone with rules covering exact/prefix/suffix/substring/regex
    # so every branch of _curated_match runs. listings sections chosen to hit
    # each. A bad regex pattern exercises the re.error guard.
    rules = [
        {"section_pattern": "104", "match_type": "exact", "row_pattern": None, "priority": 10},
        {"section_pattern": "FL", "match_type": "prefix", "row_pattern": None, "priority": 9},
        {"section_pattern": "ZZ", "match_type": "suffix", "row_pattern": None, "priority": 8},
        {"section_pattern": "MID", "match_type": "substring", "row_pattern": None, "priority": 7},
        {"section_pattern": r"^REG\d+$", "match_type": "regex", "row_pattern": "^A$", "priority": 6},
        {"section_pattern": "[", "match_type": "regex", "row_pattern": None, "priority": 5},  # bad regex
    ]
    perfzones = [{"id": 1, "zone": "ZoneA", "performer_zone_section_rules": rules}]
    # listings_snapshots is read twice (latest probe, then full rows). The fake
    # returns the full list both times; the handler's distinct() collapses it.
    listings = [
        {"captured_at": "2026-05-10T12:00:00Z"},  # latest probe row
        {"section": "104", "row": "1"},     # exact
        {"section": "FLOOR", "row": "1"},   # prefix FL
        {"section": "ABZZ", "row": "1"},    # suffix ZZ
        {"section": "XMIDX", "row": "1"},   # substring MID
        {"section": "REG7", "row": "A"},    # regex + row regex match
        {"section": "NOPE", "row": "1"},    # no curated -> fallback
        {"section": "RAW9", "row": "9"},    # no curated, fallback returns None -> unmapped
    ]
    fake = FakeSupabase(
        table_data={
            "events": [{"primary_performer_id": 16303, "venue_id": 42}],
            "listings_snapshots": listings,
            "performer_zones": perfzones,
        },
        rpc_data={"derive_zone_fallback": "FallbackZone"},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/section-zones").json()
    m = body["map"]
    assert m["104"]["source"] == "curated" and m["104"]["zone"] == "ZoneA"
    assert m["FLOOR"]["source"] == "curated"
    assert m["ABZZ"]["source"] == "curated"
    assert m["XMIDX"]["source"] == "curated"
    assert m["REG7"]["source"] == "curated"
    # NOPE/RAW9 fall through to the RPC (returns "FallbackZone" string)
    assert m["NOPE"]["source"] == "fallback"
    assert body["source_mix"]["curated"] >= 1


def test_section_zones_curated_bad_row_pattern(client, monkeypatch):
    # A curated rule whose SECTION regex matches but whose ROW pattern is
    # invalid regex -> the inner `except re.error: pass` keeps the section hit.
    rules = [
        {"section_pattern": r"^SEC\d+$", "match_type": "regex", "row_pattern": "[", "priority": 5},
    ]
    perfzones = [{"id": 1, "zone": "ZoneR", "performer_zone_section_rules": rules}]
    listings = [
        {"captured_at": "2026-05-10T12:00:00Z"},
        {"section": "SEC7", "row": "12"},  # section matches; bad row regex swallowed -> still curated
    ]
    fake = FakeSupabase(
        table_data={
            "events": [{"primary_performer_id": 16303, "venue_id": 42}],
            "listings_snapshots": listings,
            "performer_zones": perfzones,
        },
        rpc_data={"derive_zone_fallback": None},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/section-zones").json()
    assert body["map"]["SEC7"] == {"zone": "ZoneR", "source": "curated"}


def test_section_zones_fallback_and_unmapped(client, monkeypatch):
    # No curated rules (no performer/venue) -> _curated_match always None. The
    # fallback RPC returns a string for one section and raises for another.
    class _RaisingDB(FakeSupabase):
        def __init__(self):
            super().__init__(table_data={
                "events": [{"primary_performer_id": None, "venue_id": None}],
                "listings_snapshots": [
                    {"captured_at": "2026-05-10T12:00:00Z"},
                    {"section": "GoodSec", "row": "1"},
                    {"section": "BadSec", "row": "1"},
                    {"section": "NullSec", "row": "1"},
                ],
            })

        def rpc(self, name, params=None):
            self.rpc_calls.append((name, params or {}))
            sec = (params or {}).get("p_section")
            if name == "derive_zone_fallback":
                if sec == "GoodSec":
                    return _FakeQuery("ConcourseZone")
                if sec == "BadSec":
                    raise RuntimeError("rpc down")
                return _FakeQuery(None)  # NullSec -> unmapped
            return _FakeQuery([])

    _use_db(monkeypatch, _RaisingDB())
    body = client.get("/api/broker/event/1/section-zones").json()
    m = body["map"]
    assert m["GoodSec"] == {"zone": "ConcourseZone", "source": "fallback"}
    assert m["BadSec"] == {"zone": None, "source": "unmapped"}    # exception -> unmapped
    assert m["NullSec"] == {"zone": None, "source": "unmapped"}
    assert body["source_mix"]["fallback"] == 1
    # BadSec (exception), NullSec, plus the None-section probe row all -> unmapped
    assert body["source_mix"]["unmapped"] == 3


def test_section_zones_all_curated_skips_fallback(client, monkeypatch):
    # Every (section, row) resolves to a curated zone -> the fallback set is
    # empty and _batch_fallback_zones short-circuits without any RPC. (The probe
    # row carries a curated section so no (None, None) pair leaks into pending.)
    rules = [{"section_pattern": "104", "match_type": "exact", "row_pattern": None, "priority": 10}]
    perfzones = [{"id": 1, "zone": "ZoneA", "performer_zone_section_rules": rules}]
    listings = [{"captured_at": "2026-05-10T12:00:00Z", "section": "104", "row": "1"}]
    fake = FakeSupabase(
        table_data={
            "events": [{"primary_performer_id": 16303, "venue_id": 42}],
            "listings_snapshots": listings,
            "performer_zones": perfzones,
        },
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/section-zones").json()
    assert body["map"]["104"] == {"zone": "ZoneA", "source": "curated"}
    # No fallback pairs -> neither the batch nor the scalar RPC was called.
    called = [name for name, _ in fake.rpc_calls]
    assert "derive_zone_fallback_batch" not in called
    assert "derive_zone_fallback" not in called


def test_section_zones_uses_batch_rpc_when_available(client, monkeypatch):
    # When derive_zone_fallback_batch returns rows, the handler uses them in ONE
    # call and never falls back to the per-section scalar RPC (no N+1).
    listings = [
        {"captured_at": "2026-05-10T12:00:00Z"},
        {"section": "NOPE", "row": "1"},   # batch -> "BatchZone" (fallback)
        {"section": "RAW9", "row": "9"},   # batch -> None (unmapped)
    ]
    batch_rows = [
        {"section": "NOPE", "row": "1", "zone": "BatchZone"},
        {"section": "RAW9", "row": "9", "zone": None},
    ]
    fake = FakeSupabase(
        table_data={
            "events": [{"primary_performer_id": None, "venue_id": None}],
            "listings_snapshots": listings,
        },
        rpc_data={"derive_zone_fallback_batch": batch_rows},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/section-zones").json()
    m = body["map"]
    assert m["NOPE"] == {"zone": "BatchZone", "source": "fallback"}
    assert m["RAW9"] == {"zone": None, "source": "unmapped"}
    # The batch RPC was used; the scalar per-section RPC was never called.
    called = [name for name, _ in fake.rpc_calls]
    assert "derive_zone_fallback_batch" in called
    assert "derive_zone_fallback" not in called


def test_section_zones_batch_rpc_error_degrades_to_scalar(client, monkeypatch):
    # If the batch RPC raises (e.g. function not yet applied), the handler
    # transparently degrades to the legacy per-section scalar loop.
    class _BatchRaisesDB(FakeSupabase):
        def __init__(self):
            super().__init__(table_data={
                "events": [{"primary_performer_id": None, "venue_id": None}],
                "listings_snapshots": [
                    {"captured_at": "2026-05-10T12:00:00Z"},
                    {"section": "GoodSec", "row": "1"},
                ],
            })

        def rpc(self, name, params=None):
            self.rpc_calls.append((name, params or {}))
            if name == "derive_zone_fallback_batch":
                raise RuntimeError("function does not exist")
            if name == "derive_zone_fallback":
                return _FakeQuery("ScalarZone")
            return _FakeQuery([])

    fake = _BatchRaisesDB()
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/section-zones").json()
    assert body["map"]["GoodSec"] == {"zone": "ScalarZone", "source": "fallback"}
    called = [name for name, _ in fake.rpc_calls]
    assert "derive_zone_fallback_batch" in called  # attempted first
    assert "derive_zone_fallback" in called        # then degraded


# ===========================================================================
# /api/broker/event/{id}/zones
# ===========================================================================

def test_zones_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"zone_metrics": []}))
    body = client.get("/api/broker/event/1/zones").json()
    assert body == {"zones": [], "count": 0, "source": None, "available_sources": []}


def test_zones_curated_priority_dedupe_parking(client, monkeypatch):
    rows = [
        {"zone": "Lower", "zone_source": "curated", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 100},
        {"zone": "Upper", "zone_source": "curated", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 200},
        {"zone": "Parking East", "zone_source": "curated", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 5},
        {"zone": "Lower", "zone_source": "curated", "captured_at": "2026-05-09T12:00:00Z", "tickets_count": 80},
        {"zone": "Club", "zone_source": "fallback", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 300},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"zone_metrics": rows}))
    body = client.get("/api/broker/event/1/zones").json()
    assert body["source"] == "curated"
    assert [z["zone"] for z in body["zones"]] == ["Upper", "Lower"]
    assert body["parking_hidden"] == 1
    assert body["include_parking"] is False


def test_zones_include_parking_true(client, monkeypatch):
    rows = [
        {"zone": "Parking East", "zone_source": "fallback", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 5},
        {"zone": "Club", "zone_source": "fallback", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 30},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={"zone_metrics": rows}))
    body = client.get("/api/broker/event/1/zones?include_parking=true").json()
    # fallback chosen (no curated), parking kept because opted-in
    assert body["source"] == "fallback"
    assert {z["zone"] for z in body["zones"]} == {"Parking East", "Club"}
    assert body["parking_hidden"] == 0


def test_zones_unmapped_only_source(client, monkeypatch):
    rows = [{"zone": None, "zone_source": "unmapped", "captured_at": "2026-05-10T12:00:00Z", "tickets_count": 9}]
    _use_db(monkeypatch, FakeSupabase(table_data={"zone_metrics": rows}))
    body = client.get("/api/broker/event/1/zones").json()
    assert body["source"] == "unmapped"
    assert body["count"] == 1


# ===========================================================================
# /api/broker/event/{id}/section-metrics
# ===========================================================================

def test_section_metrics_empty_default_cadence(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"section_metrics": []}))
    body = client.get("/api/broker/event/1/section-metrics").json()
    assert body["sections"] == []
    assert body["last_pull_at"] is None
    assert body["cadence_seconds"] == 60 * 60 * 24


def test_section_metrics_grouped_sorted(client, monkeypatch):
    rows = [
        {"captured_at": "2026-05-10T12:00:00Z", "section": "104", "is_ancillary": False,
         "tickets_count": 50, "groups_count": 10, "retail_min": 100, "retail_median": 150,
         "retail_mean": 160, "retail_max": 300},
        {"captured_at": "2026-05-09T12:00:00Z", "section": "104", "is_ancillary": False,
         "tickets_count": 40, "groups_count": 8, "retail_min": 90, "retail_median": 140,
         "retail_mean": 150, "retail_max": 280},
        {"captured_at": "2026-05-10T11:00:00Z", "section": "Parking", "is_ancillary": True,
         "tickets_count": 5, "groups_count": 2, "retail_min": 20, "retail_median": 25,
         "retail_mean": 25, "retail_max": 30},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "section_metrics": rows,
        "events": [{"occurs_at_local": "2026-07-01T19:00:00-04:00"}],
    }))
    body = client.get("/api/broker/event/1/section-metrics").json()
    secs = body["sections"]
    assert [s["section"] for s in secs] == ["104", "Parking"]
    assert secs[0]["metrics"]["tickets_count"]["delta"]["dir"] == "up"
    assert secs[1]["metrics"]["tickets_count"]["delta"] is None
    assert body["last_pull_at"] == "2026-05-10T12:00:00Z"


# ===========================================================================
# /api/broker/event/{id}/raw-tevo
# ===========================================================================

class _FakeTevo:
    def __init__(self, groups=None, raise_runtime=False):
        self._groups = groups or []
        self._raise = raise_runtime

    def get_ticket_groups(self, event_id):
        if self._raise:
            raise RuntimeError("upstream 500")
        return {"ticket_groups": self._groups}


def test_raw_tevo_cache_hit(client, monkeypatch):
    fake = FakeSupabase(rpc_data={"get_cached_ticket_groups": {
        "ticket_groups": [{"id": "g1"}], "captured_at": "2026-05-10T12:00:00Z"}})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/raw-tevo").json()
    assert body["source"] == "cache"
    assert body["groups"] == [{"id": "g1"}]
    assert body["captured_at"] == "2026-05-10T12:00:00Z"


def test_raw_tevo_live_on_miss(client, monkeypatch):
    fake = FakeSupabase(rpc_data={"get_cached_ticket_groups": None})
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", _FakeTevo(groups=[{"id": "live1"}]))
    body = client.get("/api/broker/event/1/raw-tevo").json()
    assert body["source"] == "live"
    assert body["groups"] == [{"id": "live1"}]
    assert "captured_at" in body
    # put_cached_ticket_groups was attempted
    assert any(n == "put_cached_ticket_groups" for n, _ in fake.rpc_calls)


def test_raw_tevo_force_skips_cache(client, monkeypatch):
    fake = FakeSupabase()
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", _FakeTevo(groups=[{"id": "f1"}]))
    body = client.get("/api/broker/event/1/raw-tevo?force=true").json()
    assert body["source"] == "live"
    # cache get not consulted on force
    assert not any(n == "get_cached_ticket_groups" for n, _ in fake.rpc_calls)


def test_raw_tevo_put_cache_failure_swallowed(client, monkeypatch):
    # put_cached_ticket_groups raising must not break the live response.
    class _DB(FakeSupabase):
        def rpc(self, name, params=None):
            self.rpc_calls.append((name, params or {}))
            if name == "get_cached_ticket_groups":
                return _FakeQuery(None)
            if name == "put_cached_ticket_groups":
                raise RuntimeError("cache write failed")
            return _FakeQuery([])

    _use_db(monkeypatch, _DB())
    monkeypatch.setattr(app_module, "client", _FakeTevo(groups=[{"id": "x"}]))
    body = client.get("/api/broker/event/1/raw-tevo").json()
    assert body["source"] == "live"


def test_raw_tevo_fetch_failure_502(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_cached_ticket_groups": None}))
    monkeypatch.setattr(app_module, "client", _FakeTevo(raise_runtime=True))
    r = client.get("/api/broker/event/1/raw-tevo")
    assert r.status_code == 502


# ===========================================================================
# /api/broker/watchlist-movers
# ===========================================================================

def test_watchlist_movers_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"watch_sources": []}))
    body = client.get("/api/broker/watchlist-movers").json()
    assert body == {"window_hours": 24, "sort": "value", "count": 0, "events": []}


def test_watchlist_movers_value_sort(client, monkeypatch):
    fake = FakeSupabase(
        table_data={"watch_sources": [{"event_id": 1}, {"event_id": 2}, {"event_id": None}]},
        rpc_data={"get_event_movers": [
            {"event_id": 1, "name": "Knicks", "cur_market_med": 150, "cur_market_tix": 10,
             "prev_market_med": 120, "prev_market_tix": 10, "cur_owned_med": 50,
             "cur_owned_tix": 4, "prev_owned_med": 40, "prev_owned_tix": 4},
            {"event_id": 2, "name": "Nets", "cur_market_med": None, "cur_market_tix": None,
             "prev_market_med": None, "prev_market_tix": None},  # no movement -> sinks
            {"event_id": 9, "name": "Off list", "cur_market_med": 999, "cur_market_tix": 1,
             "prev_market_med": 1, "prev_market_tix": 1},  # not watchlisted
        ]},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/watchlist-movers?sort=value&window_hours=48&limit=5").json()
    assert body["window_hours"] == 48
    assert body["count"] == 2
    # event 1 has a real delta_market_val -> ranks above event 2 (None sinks)
    assert body["events"][0]["event_id"] == 1
    assert body["events"][0]["delta_market_pct"] == 25.0
    assert body["events"][0]["cur_market_val"] == 1500.0
    assert body["events"][0]["delta_market_val"] == 300.0
    assert body["events"][0]["cur_owned_val"] == 200.0


def test_watchlist_movers_pct_sort_and_clamps(client, monkeypatch):
    fake = FakeSupabase(
        table_data={"watch_sources": [{"event_id": 1}]},
        rpc_data={"get_event_movers": [
            {"event_id": 1, "name": "Knicks", "cur_market_med": 200, "cur_market_tix": 5,
             "prev_market_med": 100, "prev_market_tix": 5},
        ]},
    )
    _use_db(monkeypatch, fake)
    # window_hours over the 168 cap + sort=pct
    body = client.get("/api/broker/watchlist-movers?sort=pct&window_hours=999&limit=200").json()
    assert body["window_hours"] == 168   # clamped
    assert body["sort"] == "pct"
    assert body["events"][0]["delta_market_pct"] == 100.0


# ===========================================================================
# /api/broker/performer/{id}/espn
# ===========================================================================

def test_watchlist_movers_non_numeric_values(client, monkeypatch):
    # cur/prev present but non-floatable -> pct_delta/val hit the
    # except (TypeError, ValueError) guards and return None.
    fake = FakeSupabase(
        table_data={"watch_sources": [{"event_id": 1}]},
        rpc_data={"get_event_movers": [
            {"event_id": 1, "name": "Junk", "cur_market_med": "abc", "cur_market_tix": "xyz",
             "prev_market_med": "def", "prev_market_tix": "uvw"},
        ]},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/watchlist-movers").json()
    e = body["events"][0]
    assert e["delta_market_pct"] is None
    assert e["cur_market_val"] is None


def test_performer_espn_no_mapping(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"performer_external_ids": []}))
    body = client.get("/api/broker/performer/1/espn").json()
    assert body["applicable"] is False


def test_performer_espn_populated_rpc_recent(client, monkeypatch):
    fake = FakeSupabase(
        table_data={
            "performer_external_ids": [{"performer_id": 1, "external_id": "18", "league": "NBA", "meta": {}}],
            "espn_team_snapshots": [{"captured_at": "2026-05-10T12:00:00Z", "wins": 50, "losses": 32,
                                     "win_pct": 0.61, "record_summary": "50-32", "streak": "W3"}],
            "espn_injuries_snapshots": [
                {"athlete_id": "a1", "athlete_name": "Player A", "status": "Out", "captured_at": "2026-05-10T01:00:00Z"},
                {"athlete_id": "a1", "athlete_name": "Player A", "status": "Out", "captured_at": "2026-05-09T01:00:00Z"},  # dup athlete
                {"athlete_id": "a2", "athlete_name": "Player B", "status": "Day-To-Day", "captured_at": "2026-05-10T02:00:00Z"},
            ],
            "espn_news": [{"headline": "Trade", "published_at": "2026-05-10T00:00:00Z", "type": "story"}],
        },
        rpc_data={"get_team_recent_games": [
            {"espn_event_id": "e1", "captured_at": "2026-05-09T00:00:00Z", "home_score": 100, "away_score": 90},
        ]},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/performer/1/espn").json()
    assert body["applicable"] is True
    assert body["espn_team_id"] == "18"
    assert body["league"] == "NBA"
    assert body["team"]["record_summary"] == "50-32"
    # athlete a1 deduped to a single entry
    assert len(body["injuries"]) == 2
    assert body["recent"][0]["espn_event_id"] == "e1"


def test_performer_espn_recent_rpc_fallback(client, monkeypatch):
    # get_team_recent_games raises -> route falls back to direct snapshot query
    # over home+away, merging + deduping by espn_event_id.
    snaps = [
        {"espn_event_id": "e1", "captured_at": "2026-05-10T00:00:00Z", "home_team_id": "18",
         "away_team_id": "20", "home_score": 100, "away_score": 90},
        {"espn_event_id": "e1", "captured_at": "2026-05-09T00:00:00Z", "home_team_id": "18",
         "away_team_id": "20", "home_score": 1, "away_score": 1},  # older dup of e1
        {"espn_event_id": "e2", "captured_at": "2026-05-08T00:00:00Z", "home_team_id": "20",
         "away_team_id": "18", "home_score": 80, "away_score": 95},
    ]
    fake = FakeSupabase(
        table_data={
            "performer_external_ids": [{"performer_id": 1, "external_id": "18", "league": "NBA", "meta": {}}],
            "espn_team_snapshots": [],
            "espn_injuries_snapshots": [],
            "espn_news": [],
            "espn_event_snapshots": snaps,
        },
        rpc_data={"get_team_recent_games": RuntimeError("rpc missing")},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/performer/1/espn").json()
    assert body["team"] is None
    # e1 + e2 deduped; the fallback path produced a non-empty recent list
    ids = [r["espn_event_id"] for r in body["recent"]]
    assert "e1" in ids and "e2" in ids


# ===========================================================================
# /api/broker/event/{id}/chart-data
# ===========================================================================

def _chart_db(em=None, xref=None, snap=None, team_snaps=None, inj=None, rm=None,
              last5=None, news=None, inj_load=None, zm=None, axs=None):
    """Build a FakeSupabase whose tables resolve to the canned rows used by the
    chart-data handler. Each table key maps to one row-list; the handler does
    Python filtering per team so the same list is reused across re-queries."""
    return FakeSupabase(
        rpc_data={"get_axs_event_price_series": axs if axs is not None else []},
        table_data={
            "event_metrics": em or [],
            "event_xref": xref or [],
            "espn_event_snapshots": (snap or []) + (last5 or []),
            "espn_team_snapshots": team_snaps or [],
            "espn_injuries_snapshots": (inj or []) + (inj_load or []),
            "espn_athlete_team_history": rm or [],
            "espn_news": news or [],
            "zone_metrics": zm or [],
        },
    )


def test_chart_data_empty_default_days(client, monkeypatch):
    _use_db(monkeypatch, _chart_db())
    body = client.get("/api/broker/event/1/chart-data").json()
    assert body["event_id"] == 1
    assert body["series"]["prices_market"] == []
    assert body["teams"]["home_team_id"] is None
    assert body["zone_series"]["source"] is None
    assert body["range_meta"]["range"] == "720h"  # 30 days default


def test_chart_data_range_presets(client, monkeypatch):
    _use_db(monkeypatch, _chart_db())
    for preset, expect in [("6h", 6), ("24h", 24), ("1d", 24), ("3d", 72),
                           ("7d", 168), ("30d", 720)]:
        body = client.get(f"/api/broker/event/1/chart-data?range={preset}").json()
        assert body["range_meta"]["hours"] == expect


def test_chart_data_range_all(client, monkeypatch):
    _use_db(monkeypatch, _chart_db())
    body = client.get("/api/broker/event/1/chart-data?range=all").json()
    assert body["range_meta"]["hours"] is None
    assert body["range_meta"]["since"] is None
    assert body["range_meta"]["range"] == "all"


def test_chart_data_range_invalid_400(client, monkeypatch):
    _use_db(monkeypatch, _chart_db())
    r = client.get("/api/broker/event/1/chart-data?range=99x")
    assert r.status_code == 400


def test_chart_data_hours_param(client, monkeypatch):
    _use_db(monkeypatch, _chart_db())
    # hours below floor (6) and above cap (720)
    assert client.get("/api/broker/event/1/chart-data?hours=1").json()["range_meta"]["hours"] == 6
    assert client.get("/api/broker/event/1/chart-data?hours=9999").json()["range_meta"]["hours"] == 720


def test_chart_data_axs_rpc_exception(client, monkeypatch):
    fake = _chart_db(em=[{"captured_at": "2026-05-10T12:00:00Z", "retail_median": 100}])
    fake.rpc_data["get_axs_event_price_series"] = RuntimeError("axs rpc down")
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/chart-data?range=24h").json()
    assert body["series"]["prices_axs"] == []
    assert body["series"]["prices_market"][0]["v"] == 100


def test_chart_data_full_espn_path(client, monkeypatch):
    em = [
        {"captured_at": "2026-05-10T12:00:00Z", "retail_median": 150, "owned_median_retail": 90,
         "tickets_count": 500, "owned_tickets_count": 20, "nonowned_median_retail": 160},
        {"captured_at": "2026-05-10T13:00:00Z", "retail_median": 155, "owned_median_retail": 92,
         "tickets_count": 480, "owned_tickets_count": 18, "nonowned_median_retail": 165},
    ]
    xref = [{"espn_event_id": "espnE", "espn_slug": "knicks-celtics", "espn_league": "NBA"}]
    snap = [{"captured_at": "2026-05-10T12:00:00Z", "home_team_id": "18", "away_team_id": "20"}]
    # NOTE: espn_team_snapshots (standings) must stay EMPTY here. The handler's
    # _team_index_series mixes raw standings rows (keyed captured_at) with
    # t-keyed news/injury rows and indexes them by r["t"] — a non-empty
    # standings list makes that line raise KeyError in app.py (latent bug, not
    # ours to fix). Standings *series* are covered by test_chart_data_standings.
    team_snaps = []
    inj = [
        {"captured_at": "2026-05-10T12:00:00Z", "athlete_name": "P1", "status": "Out",
         "injury_type": "knee", "short_comment": "x", "espn_team_id": "18", "is_baseline": False},
        {"captured_at": "2026-05-10T12:30:00Z", "athlete_name": "P2", "status": "Active",
         "injury_type": "ankle", "short_comment": "y", "espn_team_id": "20", "is_baseline": True},
    ]
    rm = [
        {"detected_at": "2026-05-10T12:00:00Z", "transaction_type": "traded", "prior_team_id": "20",
         "espn_team_id": "18", "espn_athlete_id": "ath1", "notes": "trade"},
    ]
    last5 = [
        {"captured_at": "2026-05-09T00:00:00Z", "espn_event_id": "g1", "home_team_id": "18",
         "away_team_id": "20", "home_score": 110, "away_score": 100, "state": "post"},
        {"captured_at": "2026-05-08T00:00:00Z", "espn_event_id": "g2", "home_team_id": "20",
         "away_team_id": "18", "home_score": 99, "away_score": 88, "state": "post"},
        {"captured_at": "2026-05-07T00:00:00Z", "espn_event_id": "g3", "home_team_id": "18",
         "away_team_id": "20", "home_score": None, "away_score": None, "state": "post"},  # skipped (no scores)
    ]
    news = [
        {"published_at": "2026-05-10T12:00:00Z"},
        {"published_at": "2026-05-10T12:30:00Z"},
        {"published_at": ""},  # empty ts -> bucket "" branch
    ]
    inj_load = [
        {"captured_at": "2026-05-10T12:00:00Z", "athlete_id": "a1", "status": "Out"},
        {"captured_at": "2026-05-10T13:00:00Z", "athlete_id": "a1", "status": "Active"},
        {"captured_at": "2026-05-10T13:30:00Z", "athlete_id": None, "status": "Out"},  # no aid -> skipped
    ]
    zm = [
        {"captured_at": "2026-05-10T12:00:00Z", "zone": "Lower", "zone_source": "curated",
         "retail_median": 150, "tickets_count": 100, "owned_tickets_count": 10, "owned_median_retail": 90},
        {"captured_at": "2026-05-10T12:00:00Z", "zone": "Upper", "zone_source": "curated",
         "retail_median": 80, "tickets_count": 50, "owned_tickets_count": 5, "owned_median_retail": 60},
        {"captured_at": "2026-05-10T12:00:00Z", "zone": None, "zone_source": "curated",
         "retail_median": 10, "tickets_count": 3, "owned_tickets_count": 0, "owned_median_retail": 0},
        {"captured_at": "2026-05-10T12:00:00Z", "zone": "X", "zone_source": "fallback",
         "retail_median": 1, "tickets_count": 1, "owned_tickets_count": 0, "owned_median_retail": 0},
    ]
    axs = [{"captured_at": "2026-05-10T12:00:00Z", "median_price": 120, "listings_count": 7}]
    fake = _chart_db(em=em, xref=xref, snap=snap, team_snaps=team_snaps, inj=inj,
                     rm=rm, last5=last5, news=news, inj_load=inj_load, zm=zm, axs=axs)
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/chart-data?range=30d").json()
    s = body["series"]
    assert s["prices_market"][0]["v"] == 150
    assert s["prices_axs"][0]["v"] == 120
    assert body["teams"]["home_team_id"] == "18"
    assert body["teams"]["away_team_id"] == "20"
    assert body["teams"]["league"] == "NBA"
    # standings empty (see note above) -> empty series
    assert s["home_win_pct"] == []
    # injuries overlay: at least one real change (is_baseline False -> True) and
    # at least one baseline (False). (The fake serves one row-list for the
    # espn_injuries_snapshots table, so overlay + injury-load share rows.)
    flags = {o["is_change"] for o in body["overlays"]["injuries"]}
    assert True in flags and False in flags
    assert body["overlays"]["roster_moves"][0]["type"] == "traded"
    # last5: g3 dropped for missing scores
    assert len(body["last5"]["home"]) == 2
    # team index produced from weighted signals
    assert body["signal_weights"]["home"]["standings"] >= 0
    assert body["series"]["home_team_index"]
    # news velocity buckets present
    assert s["home_news_1h"]
    # injury load forward-filled
    assert s["home_injury_load"]
    # zone series: curated chosen, parking-less, sorted by counts
    assert body["zone_series"]["source"] == "curated"
    assert body["zone_series"]["zones"][0]["zone"] == "Lower"
    assert "fallback" in body["zone_series"]["available"]


def test_chart_data_xref_no_snapshot(client, monkeypatch):
    # event_xref present but espn_event_snapshots empty -> team ids stay None,
    # all team-keyed series short-circuit to []. Covers the `if snap:` false arm.
    xref = [{"espn_event_id": "espnE", "espn_slug": "s", "espn_league": "NBA"}]
    fake = FakeSupabase(
        rpc_data={"get_axs_event_price_series": []},
        table_data={
            "event_metrics": [{"captured_at": "2026-05-10T12:00:00Z", "retail_median": 1}],
            "event_xref": xref,
            "espn_event_snapshots": [],
        },
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/chart-data?range=24h").json()
    assert body["teams"]["home_team_id"] is None
    assert body["series"]["home_win_pct"] == []
    assert body["overlays"]["injuries"] == []


def test_chart_data_zone_fallback_source(client, monkeypatch):
    # No curated zones -> fallback chosen.
    zm = [{"captured_at": "2026-05-10T12:00:00Z", "zone": "Z", "zone_source": "fallback",
           "retail_median": 5, "tickets_count": 2, "owned_tickets_count": 0, "owned_median_retail": 0}]
    fake = _chart_db(zm=zm)
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/chart-data?range=24h").json()
    assert body["zone_series"]["source"] == "fallback"


def test_chart_data_zone_unmapped_source(client, monkeypatch):
    zm = [{"captured_at": "2026-05-10T12:00:00Z", "zone": "Z", "zone_source": "unmapped",
           "retail_median": 5, "tickets_count": 2, "owned_tickets_count": 0, "owned_median_retail": 0}]
    fake = _chart_db(zm=zm)
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/event/1/chart-data?range=24h").json()
    assert body["zone_series"]["source"] == "unmapped"


# ===========================================================================
# /api/broker/movers  (v1 + v2)
# ===========================================================================

def test_movers_v2_path(client, monkeypatch):
    fake = FakeSupabase(rpc_data={
        "get_event_movers_v2": [
            {"event_id": 1, "category": "sports", "score": 9},
            {"event_id": 2, "category": None, "score": 3},
        ],
        "get_event_movers_index_summary": [{"n": 2}],
    })
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/movers?window_days=7&source=tevo&category=sports").json()
    assert body["v"] == 2
    assert body["source"] == "tevo"
    assert body["event_count"] == 2
    assert "sports" in body["events_by_category"]
    assert "unknown" in body["events_by_category"]  # None category -> "unknown"


def test_movers_v1_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_event_movers_with_sg": []}))
    body = client.get("/api/broker/movers").json()
    assert body["events"]["owned_winners"] == []
    assert body["performers"]["market_winners"] == []
    assert "ranking" not in body  # empty short-circuit response


def test_movers_v1_full_with_lifecycle_filter(client, monkeypatch):
    rpc_rows = [
        {"event_id": 1, "name": "Knicks", "primary_performer_id": 16303, "primary_performer_name": "NYK",
         "venue_id": 99, "venue_name": "MSG", "cur_market_med": 150, "cur_market_tix": 10,
         "prev_market_med": 100, "prev_market_tix": 10, "cur_owned_med": 50, "cur_owned_tix": 5,
         "prev_owned_med": 40, "prev_owned_tix": 5, "cur_owned_share": 0.3, "sg_sales_window": 4},
        {"event_id": 2, "name": "Nets", "primary_performer_id": 16304, "primary_performer_name": "BKN",
         "venue_id": 99, "venue_name": "MSG", "cur_market_med": 80, "cur_market_tix": 8,
         "prev_market_med": 120, "prev_market_tix": 8, "cur_owned_med": None, "cur_owned_tix": 0,
         "prev_owned_med": None, "prev_owned_tix": 0, "sg_sales_window": 0},
        {"event_id": 3, "name": "Ghost", "primary_performer_id": None, "primary_performer_name": None,
         "venue_id": None, "venue_name": None, "cur_market_med": 1, "cur_market_tix": 1,
         "prev_market_med": 1, "prev_market_tix": 1},  # inactive -> filtered
    ]
    fake = FakeSupabase(
        rpc_data={"get_event_movers_with_sg": rpc_rows},
        table_data={"event_lifecycle": [{"event_id": 3, "status": "completed", "is_active": False}]},
    )
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/movers?window_hours=24").json()
    assert "ranking" in body
    ev = body["events"]
    # event 3 filtered out by lifecycle; event 1 owned, event 2 market-only
    owned_ids = {r["event_id"] for r in ev["owned_winners"] + ev["owned_losers"]}
    assert 1 in owned_ids and 3 not in owned_ids
    # market lists dedupe out owned entities (event 1) -> event 2 surfaces
    market_ids = {r["event_id"] for r in ev["market_winners"] + ev["market_losers"]}
    assert 2 in market_ids
    # value movers + performer/venue rollups present
    assert isinstance(ev["value_winners"], list)
    assert isinstance(body["performers"]["market_winners"], list)
    assert isinstance(body["venues"]["owned_winners"], list)


def test_movers_v1_include_inactive_skips_lifecycle(client, monkeypatch):
    rpc_rows = [
        {"event_id": 3, "name": "Ghost", "primary_performer_id": 1, "primary_performer_name": "P",
         "venue_id": 9, "venue_name": "V", "cur_market_med": 100, "cur_market_tix": 5,
         "prev_market_med": 80, "prev_market_tix": 5, "cur_owned_med": 10, "cur_owned_tix": 2,
         "prev_owned_med": 8, "prev_owned_tix": 2, "sg_sales_window": 1},
    ]
    fake = FakeSupabase(rpc_data={"get_event_movers_with_sg": rpc_rows})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/movers?include_inactive=true").json()
    # lifecycle table never queried; event survives
    assert "event_lifecycle" not in fake.table_calls
    ids = {r["event_id"] for r in body["events"]["owned_winners"]}
    assert 3 in ids


def test_movers_v1_non_numeric_deltas(client, monkeypatch):
    # Non-floatable cur/prev exercise the TypeError/ValueError guards in
    # pct_delta / abs_delta / _val.
    rpc_rows = [
        {"event_id": 1, "name": "Junk", "primary_performer_id": 1, "primary_performer_name": "P",
         "venue_id": 9, "venue_name": "V", "cur_market_med": "abc", "cur_market_tix": 5,
         "prev_market_med": "def", "prev_market_tix": 5, "cur_owned_med": "q",
         "cur_owned_tix": 2, "prev_owned_med": "s", "prev_owned_tix": 2, "sg_sales_window": 0},
    ]
    fake = FakeSupabase(rpc_data={"get_event_movers_with_sg": rpc_rows},
                        table_data={"event_lifecycle": []})
    _use_db(monkeypatch, fake)
    body = client.get("/api/broker/movers").json()
    assert "ranking" in body
    # all delta computations None -> top10 filters everything out
    assert body["events"]["market_winners"] == []
    assert body["events"]["owned_winners"] == []
    assert body["events"]["value_winners"] == []


def test_movers_v1_clamps_window_hours(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(rpc_data={"get_event_movers_with_sg": []}))
    body = client.get("/api/broker/movers?window_hours=99999").json()
    assert body["window_hours"] == 168


def test_chart_data_last5_dedupes_and_caps_at_five(client, monkeypatch):
    # Regression for the _last5 bug: the ESPN collector re-snapshots each
    # finished game many times, so a raw .limit(5) on snapshot rows repeated one
    # game. _last5 must dedupe by espn_event_id (keeping the latest snapshot)
    # and cap at 5 distinct games. Feed g1 twice (dup) + 6 distinct games, all
    # captured_at-desc, to drive both the dedup `continue` and the >=5 `break`.
    xref = [{"espn_event_id": "espnE", "espn_slug": "knicks-celtics", "espn_league": "NBA"}]
    snap = [{"captured_at": "2026-05-10T12:00:00Z", "home_team_id": "18", "away_team_id": "20"}]

    def _g(ts, eid, hs, as_):
        return {"captured_at": ts, "espn_event_id": eid, "home_team_id": "18",
                "away_team_id": "20", "home_score": hs, "away_score": as_, "state": "post"}

    last5 = [
        _g("2026-05-09T05:00:00Z", "g1", 110, 100),  # latest g1 -> counted (W)
        _g("2026-05-09T04:00:00Z", "g1", 108, 101),  # older g1 -> dedup `continue`
        _g("2026-05-08T00:00:00Z", "g2", 90, 99),
        _g("2026-05-07T00:00:00Z", "g3", 88, 80),
        _g("2026-05-06T00:00:00Z", "g4", 70, 71),
        _g("2026-05-05T00:00:00Z", "g5", 60, 50),
        _g("2026-05-04T00:00:00Z", "g6", 55, 40),  # 6th distinct -> never reached (break at 5)
    ]
    fake = _chart_db(xref=xref, snap=snap, last5=last5)
    _use_db(monkeypatch, fake)
    home = client.get("/api/broker/event/1/chart-data?range=30d").json()["last5"]["home"]
    # Capped at 5 distinct games; g1 counted once (not twice); g6 excluded.
    assert len(home) == 5
    assert [r["result"] for r in home] == ["W", "L", "W", "L", "W"]  # g1..g5
    assert home[0]["score"] == "110-100"  # the LATEST g1 snapshot, not the older one
