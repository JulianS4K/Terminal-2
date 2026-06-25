"""Tests for the ADMIN + INTEGRATION-SYNC slice of app.py.

Covers the admin orchestrators that fire upstream READ pulls (TEvo / SeatGeek /
SeatData clients) and persist results to Supabase:

  POST /api/admin/seed-home-venues
  POST /api/admin/wire-sg-to-tevo
  POST /api/admin/wire-sd-to-tevo
  POST /api/seatdata/event/{id}/link
  POST /api/seatdata/event/{id}/auto-search
  POST /api/admin/collect-orders
  GET  /api/broker/event/{id}/orders
  POST /api/seatgeek/event/{id}/link
  POST /api/seatgeek/event/{id}/sync-listings
  POST /api/seatgeek/event/{id}/sync-sales
  POST /api/admin/collect-sg-seller
  POST /api/seatdata/event/{id}/sync-sales

House-style mirrors tests/test_broker_routes.py + test_seatgeek_routes.py:
fake env BEFORE importing app, drive app.app via Starlette TestClient,
monkeypatch app.require_sb (FakeSupabase) + the upstream client objects
(app.client / app._get_seatgeek_client / app._get_seatdata_client) so NO
real upstream/DB call ever fires. AUTH_DISABLED=true bypasses the gate.
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
os.environ.setdefault("CRON_SECRET", "test-cron-secret")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------------------------------------------------------------------------
# Fake Supabase — programmable fluent chain. Records writes (upsert / insert /
# delete / update / rpc) so tests can assert what the handler persisted.
# ---------------------------------------------------------------------------

class _Res:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


class _Query:
    """Fluent query/mutation chain. Builder methods return self; execute()
    returns the preloaded rows (for reads) or whatever a mutation recorded."""

    def __init__(self, sb, name):
        self._sb = sb
        self._name = name
        self._result = sb.table_data.get(name, [])

    # ----- read builders -----
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

    # ----- mutation builders (record + keep chainable) -----
    def upsert(self, row, **_k):
        self._sb.writes.append(("upsert", self._name, row))
        self._result = []
        return self

    def insert(self, rows, **_k):
        self._sb.writes.append(("insert", self._name, rows))
        self._result = []
        return self

    def delete(self, *_a, **_k):
        self._sb.writes.append(("delete", self._name, None))
        self._result = []
        return self

    def update(self, row, **_k):
        self._sb.writes.append(("update", self._name, row))
        self._result = []
        return self

    def execute(self):
        return _Res(self._result, self._sb.counts.get(self._name))


class _RpcQuery:
    def __init__(self, sb, name, params):
        self._sb = sb
        self._name = name
        self._params = params
        self._data = sb.rpc_data.get(name)

    def execute(self):
        self._sb.rpc_calls.append((self._name, self._params or {}))
        return _Res(self._data)


class FakeSupabase:
    def __init__(self, table_data=None, rpc_data=None, counts=None):
        self.table_data = table_data or {}
        self.rpc_data = rpc_data or {}
        self.counts = counts or {}
        self.writes: list[tuple] = []
        self.rpc_calls: list[tuple] = []

    def table(self, name):
        return _Query(self, name)

    def rpc(self, name, params=None):
        return _RpcQuery(self, name, params)


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _use_db(monkeypatch, fake: FakeSupabase):
    monkeypatch.setattr(app_module, "require_sb", lambda: fake)


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    """The /api/admin/ bucket caps at 5 req/60s per IP. These tests fire many
    admin POSTs from one TestClient IP, so disable the limiter for the slice."""
    monkeypatch.setattr(app_module._ip_limiter, "check", lambda *a, **k: True)


# ---------------------------------------------------------------------------
# Fake upstream clients
# ---------------------------------------------------------------------------

class FakeTevo:
    """Stand-in for the module-level EvoClient (app.client)."""

    def __init__(self, *, performer=None, search=None, orders=None,
                 raise_on=None):
        self._performer = performer or {}
        self._search = search or {}
        self._orders = orders or []
        self._raise_on = raise_on or set()

    def get_performer(self, pid, include_opponents=False):
        if "get_performer" in self._raise_on:
            raise RuntimeError("tevo performer boom")
        return self._performer

    def search_events_fulltext(self, q=None, per_page=20, **kw):
        if "search" in self._raise_on:
            raise RuntimeError("tevo search boom")
        return self._search

    def iter_orders(self, max_pages=50, per_page=10, state=None):
        if "iter_orders" in self._raise_on:
            raise RuntimeError("iter_orders boom")
        for o in self._orders:
            yield o


class FakeSG:
    def __init__(self, *, listings_body=None, sales_body=None,
                 seller_listings=None, seller_orders=None,
                 store_listings_n=0, store_sales_n=0,
                 raise_on=None):
        self._listings_body = listings_body or {}
        self._sales_body = sales_body or {}
        self._seller_listings = seller_listings or []
        self._seller_orders = seller_orders or []
        self._store_listings_n = store_listings_n
        self._store_sales_n = store_sales_n
        self._raise_on = raise_on or {}
        self.calls: list[str] = []

    def _maybe_raise(self, key):
        if key in self._raise_on:
            raise RuntimeError(self._raise_on[key])

    def listings(self, sg_event_id, v2=False, tevo_event_id=None):
        self._maybe_raise("listings")
        return self._listings_body

    def sales(self, sg_event_id, tevo_event_id=None):
        self._maybe_raise("sales")
        return self._sales_body

    def link_event(self, *a, **k):
        self.calls.append("link_event")

    def store_listings(self, *a, **k):
        return self._store_listings_n

    def store_sales(self, *a, **k):
        return self._store_sales_n

    def iter_seller_listings(self, max_pages=5, per_page=200):
        self._maybe_raise("iter_seller_listings")
        for x in self._seller_listings:
            yield x

    def store_seller_listings(self, collected):
        return {"received": len(collected), "inserted": len(collected)}

    def iter_seller_orders(self, status_filter, max_pages=100):
        self._maybe_raise("iter_seller_orders")
        for x in self._seller_orders:
            yield x

    def store_seller_orders(self, collected, status_filter):
        return {"received": len(collected), "status": status_filter}


class FakeSD:
    def __init__(self, *, search=None, salesdata=None, store_sales_n=0,
                 raise_on=None):
        self._search = search or {"data": []}
        self._salesdata = salesdata or []
        self._store_sales_n = store_sales_n
        self._raise_on = raise_on or {}
        self.linked = []

    def search_events(self, event_name=None, event_date=None, venue_name=None, limit=20):
        if "search" in self._raise_on:
            raise RuntimeError("sd search boom")
        return self._search

    def link_event(self, tevo_event_id, sd_event_id, match_method=None,
                   confidence=None, meta=None):
        self.linked.append((tevo_event_id, sd_event_id))

    def salesdata(self, sd_event_id, tevo_event_id=None):
        if "salesdata" in self._raise_on:
            raise RuntimeError(self._raise_on["salesdata"])
        return self._salesdata

    def store_sales(self, *a, **k):
        return self._store_sales_n


# ===========================================================================
# POST /api/admin/seed-home-venues
# ===========================================================================

def test_seed_home_venues_adds_skips_and_errors(client, monkeypatch):
    pei = [
        {"performer_id": 1, "external_name": "Team One", "league": "MLS"},
        {"performer_id": 2, "external_name": "Team Two", "league": "MLS"},  # no venue id
        {"performer_id": 3, "external_name": "Team Three", "league": "MLS"},  # already have
        {"performer_id": 4, "external_name": "Team Four", "league": "MLS"},  # raises
    ]
    fake = FakeSupabase(table_data={
        "performer_external_ids": pei,
        "performer_home_venues": [{"performer_id": 3}],
    })
    _use_db(monkeypatch, fake)

    def _get_performer(pid, include_opponents=False):
        if pid == 4:
            raise RuntimeError("kaboom")
        if pid == 2:
            return {"name": "Team Two", "venue": {}}  # no id -> skipped
        return {"name": f"Team {pid}",
                "venue": {"id": 900 + pid, "name": "Stadium",
                          "address": {"locality": "City", "region": "ST"}}}

    monkeypatch.setattr(app_module, "client", FakeTevo())
    monkeypatch.setattr(app_module.client, "get_performer", _get_performer)

    body = client.post("/api/admin/seed-home-venues?league=MLS").json()
    assert body["league"] == "MLS"
    assert body["scanned"] == 3          # performer 3 already had a venue
    assert body["added"] == 1            # only performer 1 succeeds
    assert body["skipped_no_venue"] == 1  # performer 2
    assert len(body["errors"]) == 1 and "performer_id=4" in body["errors"][0]
    # the successful add upserted a home-venue row with the joined location
    upserts = [w for w in fake.writes if w[0] == "upsert" and w[1] == "performer_home_venues"]
    assert upserts and upserts[0][2]["venue_location"] == "City, ST"


def test_seed_home_venues_location_fallback(client, monkeypatch):
    # No address dict -> falls back to v.get("location").
    fake = FakeSupabase(table_data={
        "performer_external_ids": [{"performer_id": 7, "external_name": "X", "league": "NBA"}],
        "performer_home_venues": [],
    })
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", FakeTevo(performer={
        "name": "X", "home_venue": {"id": 50, "name": "Arena", "location": "Somewhere"}}))
    body = client.post("/api/admin/seed-home-venues?league=NBA").json()
    assert body["added"] == 1
    up = [w for w in fake.writes if w[1] == "performer_home_venues"][0]
    assert up[2]["venue_location"] == "Somewhere"
    assert up[2]["venue_id"] == 50


# ===========================================================================
# POST /api/admin/wire-sg-to-tevo
# ===========================================================================

def _sg_seller_rows():
    return [
        {"sg_event_id": 100, "sg_event_name": "Knicks", "sg_event_date": "2026-06-01", "sg_venue": "Madison Square Garden"},
        {"sg_event_id": 100, "sg_event_name": "Knicks", "sg_event_date": "2026-06-01", "sg_venue": "Madison Square Garden"},  # dup -> skipped
        {"sg_event_id": 200, "sg_event_name": "NoDate", "sg_event_date": None, "sg_venue": "X"},  # no date
        {"sg_event_id": 300, "sg_event_name": "BadDate", "sg_event_date": "not-a-date", "sg_venue": "X"},  # bad date
        {"sg_event_id": 400, "sg_event_name": "Already", "sg_event_date": "2026-06-02", "sg_venue": "X"},  # already xref'd
        {"sg_event_id": None},  # no key -> skipped
    ]


def test_wire_sg_to_tevo_dry_run(client, monkeypatch):
    # event 400 already xref'd; the FakeSupabase returns the xref for the eq probe.
    # Use a table stub that yields the xref row only for seatgeek_event_xref.
    rows = _sg_seller_rows()
    fake = FakeSupabase(table_data={
        "seatgeek_seller_listings": rows,
        "seatgeek_event_xref": [{"tevo_event_id": 999}],  # makes EVERY probe "existing"
    })
    # We need only event 100 to be a candidate; but xref stub returns existing for all.
    # Override: make xref empty so all unlinked, and test the matching logic instead.
    fake.table_data["seatgeek_event_xref"] = []
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", FakeTevo(search={
        "events": [
            {"id": 555, "name": "Knicks vs Celtics", "venue": {"name": "Madison Square Garden"}},
            {"id": 556, "name": "Other", "venue": {"name": "Random Arena"}},
        ]}))
    body = client.post("/api/admin/wire-sg-to-tevo?dry_run=true").json()
    assert body["dry_run"] is True
    # candidates: 100, 200(no date), 300(bad date), 400 -> 4 distinct keys
    assert body["candidates"] == 4
    # 100 matches MSG; 200 + 300 + 400 don't match (no/bad date, or 0-overlap venue)
    assert body["newly_linked"] == 1
    assert body["no_match"] == 3
    matched = [a for a in body["audit"] if a.get("matched")]
    assert matched and matched[0]["tevo_event_id"] == 555
    assert any(a.get("reason") == "no sg_event_date" for a in body["audit"])
    assert any("bad date" in (a.get("reason") or "") for a in body["audit"])


def test_wire_sg_to_tevo_skips_already_xrefd(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "seatgeek_seller_listings": [
            {"sg_event_id": 100, "sg_event_name": "K", "sg_event_date": "2026-06-01", "sg_venue": "MSG"},
        ],
        "seatgeek_event_xref": [{"tevo_event_id": 999}],  # existing -> skip
    })
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", FakeTevo())
    body = client.post("/api/admin/wire-sg-to-tevo?dry_run=true").json()
    assert body["candidates"] == 0  # the only event is already linked
    assert body["audit"] == []


def test_wire_sg_to_tevo_search_error_and_no_hits(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "seatgeek_seller_listings": [
            {"sg_event_id": 1, "sg_event_name": "A", "sg_event_date": "2026-06-01", "sg_venue": "V1"},
        ],
        "seatgeek_event_xref": [],
    })
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", FakeTevo(raise_on={"search"}))
    body = client.post("/api/admin/wire-sg-to-tevo?dry_run=true").json()
    assert body["errors"] and "TEvo search failed" in body["errors"][0]
    assert body["newly_linked"] == 0


def test_wire_sg_to_tevo_no_hits_path(client, monkeypatch):
    fake = FakeSupabase(table_data={
        "seatgeek_seller_listings": [
            {"sg_event_id": 1, "sg_event_name": "A", "sg_event_date": "2026-06-01", "sg_venue": "V1"},
        ],
        "seatgeek_event_xref": [],
    })
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", FakeTevo(search={"events": []}))
    body = client.post("/api/admin/wire-sg-to-tevo?dry_run=true").json()
    assert body["no_match"] == 1
    assert any("0 hits" in (a.get("reason") or "") for a in body["audit"])


def test_wire_sg_to_tevo_write_path_links_and_ingests(client, monkeypatch):
    fake = FakeSupabase(
        table_data={
            "seatgeek_seller_listings": [
                {"sg_event_id": 100, "sg_event_name": "Knicks", "sg_event_date": "2026-06-01",
                 "sg_venue": "Madison Square Garden"},
            ],
            "seatgeek_event_xref": [],
            "events": [],
        },
        rpc_data={"sg_attempt_event_xref": 555},
    )
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", FakeTevo(search={
        "events": [
            {"id": 555, "name": "Knicks vs Celtics",
             "venue": {"name": "Madison Square Garden", "id": 7},
             "performances": [{"primary": True, "performer": {"id": 1, "name": "Knicks"}}]},
        ]}))
    body = client.post("/api/admin/wire-sg-to-tevo").json()
    assert body["dry_run"] is False
    assert body["newly_linked"] == 1
    assert body["tevo_events_ingested"] == 1
    # the events upsert + xref rpc both fired
    assert any(w[1] == "events" for w in fake.writes)
    assert any(c[0] == "sg_attempt_event_xref" for c in fake.rpc_calls)
    matched = [a for a in body["audit"] if a.get("matched")]
    assert matched[0]["tevo_event_id"] == 555


def test_wire_sg_to_tevo_xref_rpc_null_and_error(client, monkeypatch):
    # Two events: one whose xref RPC returns NULL (matcher rejected), one whose
    # xref RPC raises.
    fake = FakeSupabase(
        table_data={
            "seatgeek_seller_listings": [
                {"sg_event_id": 100, "sg_event_name": "K", "sg_event_date": "2026-06-01", "sg_venue": "MSG"},
                {"sg_event_id": 200, "sg_event_name": "K2", "sg_event_date": "2026-06-02", "sg_venue": "MSG"},
            ],
            "seatgeek_event_xref": [],
            "events": [],
        },
        rpc_data={"sg_attempt_event_xref": None},  # NULL return -> matcher rejected
    )
    _use_db(monkeypatch, fake)

    sg_event_hit = {"id": 555, "name": "T", "venue": {"name": "MSG"},
                    "performances": []}

    class _TevoRpcErr(FakeTevo):
        def search_events_fulltext(self, q=None, per_page=20, **kw):
            return {"events": [sg_event_hit]}

    monkeypatch.setattr(app_module, "client", _TevoRpcErr())

    # First call: rpc returns None -> rejected branch. Make rpc raise on 2nd event.
    orig_rpc = fake.rpc
    state = {"n": 0}

    def _rpc(name, params=None):
        if name == "sg_attempt_event_xref":
            state["n"] += 1
            if state["n"] == 2:
                raise RuntimeError("xref boom")
        return orig_rpc(name, params)

    monkeypatch.setattr(fake, "rpc", _rpc)
    body = client.post("/api/admin/wire-sg-to-tevo").json()
    # event 100: rpc None -> matched False with rejection reason
    assert any("matcher rejected" in (a.get("reason") or "") for a in body["audit"])
    # event 200: rpc raised -> error captured
    assert any("xref RPC failed" in e for e in body["errors"])


# ---- _upsert_tevo_event_into_events helper (used by wire-sg-to-tevo) ----

def test_upsert_tevo_event_no_id_returns_none():
    assert app_module._upsert_tevo_event_into_events(FakeSupabase(), {"name": "x"}) is None


def test_upsert_tevo_event_success_returns_id():
    fake = FakeSupabase()
    ev = {"id": 42, "name": "Game", "venue": {"id": 5, "name": "Arena"},
          "performances": [{"primary": True, "performer": {"id": 1, "name": "A"}},
                           {"performer": {"id": 2, "name": "B"}}],
          "category": {"slug": "basketball"}, "configuration": {"id": 9, "name": "cfg"}}
    assert app_module._upsert_tevo_event_into_events(fake, ev) == 42
    row = [w for w in fake.writes if w[1] == "events"][0][2]
    assert row["id"] == 42 and row["event_type"] == "basketball"
    assert row["performer_ids"] == [1, 2]


def test_upsert_tevo_event_first_perf_fallback_and_category_str():
    # No primary -> first performance's performer; category is a plain string.
    fake = FakeSupabase()
    ev = {"id": 43, "name": "G",
          "performances": [{"performer": {"id": 3, "name": "C"}}],
          "category": "concert"}
    assert app_module._upsert_tevo_event_into_events(fake, ev) == 43
    row = [w for w in fake.writes if w[1] == "events"][0][2]
    assert row["primary_performer_id"] == 3
    assert row["event_type"] == "concert"


def test_upsert_tevo_event_upsert_raises_returns_none(monkeypatch):
    class _RaiseSb(FakeSupabase):
        def table(self, name):
            q = super().table(name)
            if name == "events":
                def _boom(*a, **k):
                    raise RuntimeError("db down")
                q.upsert = _boom
            return q
    assert app_module._upsert_tevo_event_into_events(_RaiseSb(), {"id": 99}) is None


# ===========================================================================
# POST /api/admin/wire-sd-to-tevo
# ===========================================================================

def test_wire_sd_to_tevo_no_candidates(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"seatdata_sales_snapshots": []}))
    body = client.post("/api/admin/wire-sd-to-tevo").json()
    assert body == {"candidates": 0, "newly_linked": 0, "audit": []}


def test_wire_sd_to_tevo_linked_and_unlinked(client, monkeypatch):
    # One sd event already xref'd, one with no metadata.
    fake = FakeSupabase(table_data={
        "seatdata_sales_snapshots": [{"sd_event_id": "AAA"}, {"sd_event_id": "BBB"}],
    })
    # xref probe: return existing only when we can't distinguish — use a custom
    # table that returns the existing row for sd_event_id AAA and [] for BBB.
    calls = {"n": 0}
    orig_table = fake.table

    def _table(name):
        q = orig_table(name)
        if name == "seatdata_event_xref":
            calls["n"] += 1
            # First xref probe -> linked; second -> unlinked.
            q._result = [{"tevo_event_id": 42}] if calls["n"] == 1 else []
        return q

    monkeypatch.setattr(fake, "table", _table)
    _use_db(monkeypatch, fake)
    body = client.post("/api/admin/wire-sd-to-tevo").json()
    assert body["candidates"] == 2
    assert body["already_linked"] == 1
    assert any(a["matched"] for a in body["audit"])
    assert any(not a["matched"] for a in body["audit"])


# ===========================================================================
# Client-factory helpers (_get_seatdata_client / _get_seatgeek_client)
# ===========================================================================

def test_get_seatdata_client_ok_and_unconfigured(monkeypatch):
    import seatdata_client as sdc
    monkeypatch.setattr(app_module, "require_sb", lambda: FakeSupabase())
    sentinel = object()
    monkeypatch.setattr(sdc, "SeatDataClient", lambda db=None: sentinel)
    assert app_module._get_seatdata_client() is sentinel

    def _raise(db=None):
        raise sdc.SeatDataError("SEATDATA_API_KEY missing")
    monkeypatch.setattr(sdc, "SeatDataClient", _raise)
    assert app_module._get_seatdata_client() is None


def test_get_seatgeek_client_ok_missing_and_other_error(monkeypatch):
    import seatgeek_client as sgc
    monkeypatch.setattr(app_module, "require_sb", lambda: FakeSupabase())
    sentinel = object()
    monkeypatch.setattr(sgc, "SeatGeekClient", lambda db=None: sentinel)
    assert app_module._get_seatgeek_client() is sentinel

    def _missing(db=None):
        raise RuntimeError("SEATGEEK_API_TOKEN not found in env or vault")
    monkeypatch.setattr(sgc, "SeatGeekClient", _missing)
    assert app_module._get_seatgeek_client() is None

    def _other(db=None):
        raise RuntimeError("network exploded")
    monkeypatch.setattr(sgc, "SeatGeekClient", _other)
    with pytest.raises(RuntimeError, match="network exploded"):
        app_module._get_seatgeek_client()


# ===========================================================================
# POST /api/seatdata/event/{id}/link
# ===========================================================================

def test_seatdata_link(client, monkeypatch):
    fake = FakeSupabase()
    _use_db(monkeypatch, fake)
    body = client.post("/api/seatdata/event/55/link?sd_event_id=900").json()
    assert body == {"linked": True, "tevo_event_id": 55, "sd_event_id": 900}
    assert fake.writes[0] == ("upsert", "seatdata_event_xref", {
        "tevo_event_id": 55, "sd_event_id": 900,
        "match_method": "manual", "match_confidence": 1.0})


# ===========================================================================
# POST /api/seatdata/event/{id}/auto-search
# ===========================================================================

def test_seatdata_auto_search_503_when_unconfigured(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: None)
    r = client.post("/api/seatdata/event/55/auto-search")
    assert r.status_code == 503


def test_seatdata_auto_search_404_event_missing(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: FakeSD())
    _use_db(monkeypatch, FakeSupabase(table_data={"events": []}))
    r = client.post("/api/seatdata/event/55/auto-search")
    assert r.status_code == 404


def test_seatdata_auto_search_no_match(client, monkeypatch):
    sd = FakeSD(search={"data": [
        {"event_id": "X", "event_date": "2026-06-01", "venue_name": "Wrong Venue"},
    ]})
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: sd)
    _use_db(monkeypatch, FakeSupabase(table_data={"events": [{
        "id": 55, "name": "Knicks", "occurs_at_local": "2026-06-02T19:00:00",
        "venue_name": "MSG", "primary_performer_name": "New York Knicks"}]}))
    body = client.post("/api/seatdata/event/55/auto-search").json()
    assert body["matched"] is False
    assert "candidates" in body


def test_seatdata_auto_search_match_links(client, monkeypatch):
    sd = FakeSD(search={"data": [
        {"event_id": "SD9", "event_date": "2026-06-02", "venue_name": "msg",
         "event_name": "Knicks G5"},
    ]})
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: sd)
    _use_db(monkeypatch, FakeSupabase(table_data={"events": [{
        "id": 55, "name": "Knicks", "occurs_at_local": "2026-06-02T19:00:00",
        "venue_name": "MSG", "primary_performer_name": "New York Knicks"}]}))
    body = client.post("/api/seatdata/event/55/auto-search").json()
    assert body["matched"] is True
    assert body["sd_event_id"] == "SD9"
    assert sd.linked == [(55, "SD9")]


def test_seatdata_auto_search_no_performer_name(client, monkeypatch):
    # primary_performer_name absent -> perf None branch; venue empty too.
    sd = FakeSD(search={"data": []})
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: sd)
    _use_db(monkeypatch, FakeSupabase(table_data={"events": [{
        "id": 55, "name": "X", "occurs_at_local": None,
        "venue_name": None, "primary_performer_name": None}]}))
    body = client.post("/api/seatdata/event/55/auto-search").json()
    assert body["matched"] is False


# ===========================================================================
# POST /api/admin/collect-orders
# ===========================================================================

def test_collect_orders_success(client, monkeypatch):
    fake = FakeSupabase()
    _use_db(monkeypatch, fake)
    orders = [
        {"id": 10, "state": "accepted"},
        {"id": 11, "state": "pending"},
        {"id": None},  # no id -> skipped via flatten
    ]
    monkeypatch.setattr(app_module, "client", FakeTevo(orders=orders))
    monkeypatch.setattr(app_module, "_flatten_order_items",
                        lambda o: [{"evo_item_id": 1, "event_id": 700, "quantity": 2}]
                        if o.get("id") else [])
    body = client.post("/api/admin/collect-orders").json()
    assert body["ok"] is True
    assert body["orders_seen"] == 3
    assert body["orders_upserted"] == 2
    assert body["items_inserted"] == 2  # 2 orders * 1 item
    assert body["events_touched"] == 1
    assert body["events_touched_ids"] == [700]


def test_collect_orders_per_order_error(client, monkeypatch):
    fake = FakeSupabase()
    _use_db(monkeypatch, fake)
    monkeypatch.setattr(app_module, "client", FakeTevo(orders=[{"id": 10, "state": "x"}]))

    def _boom(o):
        raise RuntimeError("item explode")

    monkeypatch.setattr(app_module, "_flatten_order_items", _boom)
    body = client.post("/api/admin/collect-orders").json()
    # the per-order try/except captures it; order was upserted before the boom
    assert body["ok"] is False
    assert body["errors"] and "order 10" in body["errors"][0]


def test_collect_orders_iter_failure(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase())
    monkeypatch.setattr(app_module, "client", FakeTevo(raise_on={"iter_orders"}))
    body = client.post("/api/admin/collect-orders").json()
    assert body["ok"] is False
    assert any("iter_orders failed" in e for e in body["errors"])
    assert body["orders_seen"] == 0


# ===========================================================================
# GET /api/broker/event/{id}/orders
# ===========================================================================

def test_broker_event_orders_empty(client, monkeypatch):
    _use_db(monkeypatch, FakeSupabase(table_data={"evo_order_items": []}))
    body = client.get("/api/broker/event/1/orders").json()
    assert body == {"event_id": 1, "items": [], "orders": [], "summary": None}


def test_broker_event_orders_rollup(client, monkeypatch):
    items = [
        {"evo_order_id": 10, "evo_item_id": 1, "quantity": 2, "price": 100},
        {"evo_order_id": 11, "evo_item_id": 2, "quantity": 1, "price": 50},
        {"evo_order_id": None, "evo_item_id": 3, "quantity": 1, "price": 10},  # no order id -> unknown state
    ]
    orders = [
        {"evo_order_id": 10, "state": "accepted", "evo_updated_at": "2026-05-10T12:00:00Z"},
        {"evo_order_id": 11, "state": "pending", "evo_updated_at": "2026-05-09T12:00:00Z"},
    ]
    _use_db(monkeypatch, FakeSupabase(table_data={
        "evo_order_items": items, "evo_orders": orders}))
    body = client.get("/api/broker/event/1/orders").json()
    s = body["summary"]
    assert s["total_items"] == 3
    assert s["by_state"]["accepted"] == 1 and s["by_state"]["pending"] == 1
    assert s["by_state"]["unknown"] == 1
    assert s["tickets_sold"] == 2          # only accepted item counts
    assert s["gross_sold"] == 200.0
    assert s["last_update_at"] == "2026-05-10T12:00:00Z"


# ===========================================================================
# POST /api/seatgeek/event/{id}/link
# ===========================================================================

def test_seatgeek_link(client, monkeypatch):
    fake = FakeSupabase()
    _use_db(monkeypatch, fake)
    body = client.post("/api/seatgeek/event/55/link?sg_event_id=900").json()
    assert body == {"linked": True, "tevo_event_id": 55, "sg_event_id": 900}
    assert fake.writes[0][1] == "seatgeek_event_xref"


# ===========================================================================
# POST /api/seatgeek/event/{id}/sync-listings
# ===========================================================================

def test_sg_sync_listings_503(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: None)
    r = client.post("/api/seatgeek/event/55/sync-listings")
    assert r.status_code == 503


def test_sg_sync_listings_404_unlinked(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: FakeSG())
    _use_db(monkeypatch, FakeSupabase(table_data={"seatgeek_event_xref": []}))
    r = client.post("/api/seatgeek/event/55/sync-listings")
    assert r.status_code == 404


def test_sg_sync_listings_success(client, monkeypatch):
    sg = FakeSG(listings_body={
        "listings": [{"a": 1}, {"a": 2}], "event": {"id": 900},
        "cache_hit": False, "refreshed_at_utc": "t"}, store_listings_n=2)
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatgeek_event_xref": [{"sg_event_id": 900}]}))
    body = client.post("/api/seatgeek/event/55/sync-listings").json()
    assert body["event_id"] == 55 and body["sg_event_id"] == 900
    assert body["rows_received"] == 2 and body["rows_inserted"] == 2
    assert body["endpoint"] == "/listings"
    assert "link_event" in sg.calls


def test_sg_sync_listings_v2(client, monkeypatch):
    sg = FakeSG(listings_body={"listings": [], "event": None}, store_listings_n=0)
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatgeek_event_xref": [{"sg_event_id": 900}]}))
    body = client.post("/api/seatgeek/event/55/sync-listings?v2=true").json()
    assert body["endpoint"] == "/v2/listings"


def test_sg_sync_listings_scope_denied_403(client, monkeypatch):
    sg = FakeSG(raise_on={"listings": "scope denied for this token"})
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatgeek_event_xref": [{"sg_event_id": 900}]}))
    r = client.post("/api/seatgeek/event/55/sync-listings")
    assert r.status_code == 403


def test_sg_sync_listings_upstream_502(client, monkeypatch):
    sg = FakeSG(raise_on={"listings": "connection reset"})
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatgeek_event_xref": [{"sg_event_id": 900}]}))
    r = client.post("/api/seatgeek/event/55/sync-listings")
    assert r.status_code == 502
    assert "SeatGeek call failed" in r.json()["detail"]


# ===========================================================================
# POST /api/seatgeek/event/{id}/sync-sales
# ===========================================================================

def test_sg_sync_sales_503(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: None)
    assert client.post("/api/seatgeek/event/55/sync-sales").status_code == 503


def test_sg_sync_sales_404_unlinked(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: FakeSG())
    _use_db(monkeypatch, FakeSupabase(table_data={"seatgeek_event_xref": []}))
    assert client.post("/api/seatgeek/event/55/sync-sales").status_code == 404


def test_sg_sync_sales_success(client, monkeypatch):
    sg = FakeSG(sales_body={"sales": [{"s": 1}], "event": {"id": 900},
                            "cache_hit": True, "refreshed_at_utc": "t"},
                store_sales_n=1)
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatgeek_event_xref": [{"sg_event_id": 900}]}))
    body = client.post("/api/seatgeek/event/55/sync-sales").json()
    assert body["rows_received"] == 1 and body["rows_inserted"] == 1
    assert body["cache_hit"] is True


def test_sg_sync_sales_scope_denied_403(client, monkeypatch):
    sg = FakeSG(raise_on={"sales": "scope denied"})
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatgeek_event_xref": [{"sg_event_id": 900}]}))
    assert client.post("/api/seatgeek/event/55/sync-sales").status_code == 403


def test_sg_sync_sales_upstream_502(client, monkeypatch):
    sg = FakeSG(raise_on={"sales": "boom"})
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatgeek_event_xref": [{"sg_event_id": 900}]}))
    assert client.post("/api/seatgeek/event/55/sync-sales").status_code == 502


# ===========================================================================
# POST /api/admin/collect-sg-seller
# ===========================================================================

def test_collect_sg_seller_503(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: None)
    assert client.post("/api/admin/collect-sg-seller").status_code == 503


def test_collect_sg_seller_success(client, monkeypatch):
    sg = FakeSG(seller_listings=[{"l": 1}, {"l": 2}],
                seller_orders=[{"o": 1}])
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    body = client.post("/api/admin/collect-sg-seller?statuses=open,pending").json()
    assert body["listings"]["received"] == 2
    assert set(body["orders_by_status"].keys()) == {"open", "pending"}
    assert body["errors"] == []
    assert "finished_at" in body


def test_collect_sg_seller_no_listings_pull(client, monkeypatch):
    sg = FakeSG(seller_orders=[])
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    body = client.post("/api/admin/collect-sg-seller?pull_listings=false&statuses=open").json()
    assert body["listings"] is None
    assert "open" in body["orders_by_status"]


def test_collect_sg_seller_listings_and_orders_errors(client, monkeypatch):
    sg = FakeSG(raise_on={
        "iter_seller_listings": "listings blew up",
        "iter_seller_orders": "orders blew up"})
    monkeypatch.setattr(app_module, "_get_seatgeek_client", lambda: sg)
    body = client.post("/api/admin/collect-sg-seller?statuses=open").json()
    assert any("listings:" in e for e in body["errors"])
    assert any("orders[open]" in e for e in body["errors"])


# ===========================================================================
# POST /api/seatdata/event/{id}/sync-sales
# ===========================================================================

def test_sd_sync_sales_503(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: None)
    assert client.post("/api/seatdata/event/55/sync-sales").status_code == 503


def test_sd_sync_sales_404_unlinked(client, monkeypatch):
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: FakeSD())
    _use_db(monkeypatch, FakeSupabase(table_data={"seatdata_event_xref": []}))
    assert client.post("/api/seatdata/event/55/sync-sales").status_code == 404


def test_sd_sync_sales_success(client, monkeypatch):
    sd = FakeSD(salesdata=[{"s": 1}, {"s": 2}], store_sales_n=2)
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: sd)
    fake = FakeSupabase(table_data={"seatdata_event_xref": [{"sd_event_id": 900}]})
    _use_db(monkeypatch, fake)
    body = client.post("/api/seatdata/event/55/sync-sales").json()
    assert body["event_id"] == 55 and body["sd_event_id"] == 900
    assert body["rows_received"] == 2 and body["rows_inserted"] == 2
    # last_paid_pull_at update fired
    assert any(w[0] == "update" and w[1] == "seatdata_event_xref" for w in fake.writes)


def test_sd_sync_sales_budget_exhausted_402(client, monkeypatch):
    sd = FakeSD(raise_on={"salesdata": "budget exhausted for this month"})
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: sd)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatdata_event_xref": [{"sd_event_id": 900}]}))
    assert client.post("/api/seatdata/event/55/sync-sales").status_code == 402


def test_sd_sync_sales_upstream_502(client, monkeypatch):
    sd = FakeSD(raise_on={"salesdata": "connection refused"})
    monkeypatch.setattr(app_module, "_get_seatdata_client", lambda: sd)
    _use_db(monkeypatch, FakeSupabase(table_data={
        "seatdata_event_xref": [{"sd_event_id": 900}]}))
    r = client.post("/api/seatdata/event/55/sync-sales")
    assert r.status_code == 502
    assert "SeatData call failed" in r.json()["detail"]
