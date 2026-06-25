"""BRANCH-coverage tests for app.py — closes the PARTIAL branches that the
line-coverage suites (test_app_*_full.py) leave open.

Line coverage of app.py was already 100%; this module exists solely to drive
the *untaken* side of conditionals/loops so `--cov-branch` reaches 100%.

House style mirrors the sibling tests/test_app_*_full.py modules: fake env
BEFORE importing app, drive app.app via Starlette TestClient, monkeypatch the
module globals (`sb`, `client`, `require_sb`, helper functions). No real
network or DB. Each test names the branch (`A->B`) it closes in its docstring.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app (app.py resolves creds at import) ----
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


# ============================================================================
# Generic resolver-driven Supabase double (modeled on
# tests/test_app_store_b_full.py FakeSupabase).
# ============================================================================

class _Result:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


class _Query:
    def __init__(self, table, resolver):
        self._table = table
        self._resolver = resolver
        self._filters = {"_in": {}, "_eq": {}, "select": None, "count": None,
                         "order": None, "limit": None, "insert": None,
                         "delete": False, "upsert": None}

    def select(self, cols=None, count=None):
        self._filters["select"] = cols
        self._filters["count"] = count
        return self

    def eq(self, col, val):
        self._filters["_eq"][col] = val
        return self

    def in_(self, col, vals):
        self._filters["_in"][col] = list(vals)
        return self

    def is_(self, col, val):
        return self

    def or_(self, *_a, **_k):
        return self

    def gte(self, *_a, **_k):
        return self

    def gt(self, *_a, **_k):
        return self

    def order(self, col=None, desc=False):
        self._filters["order"] = (col, desc)
        return self

    def limit(self, n):
        self._filters["limit"] = n
        return self

    def insert(self, payload, *_a, **_k):
        self._filters["insert"] = payload
        return self

    def upsert(self, payload, *_a, **_k):
        self._filters["upsert"] = payload
        return self

    def delete(self, *_a, **_k):
        self._filters["delete"] = True
        return self

    def execute(self):
        out = self._resolver(self._table, self._filters)
        if isinstance(out, _Result):
            return out
        if isinstance(out, tuple):
            return _Result(out[0], out[1])
        return _Result(out)


class FakeSupabase:
    """Resolver-driven Supabase double.

    table_resolvers: {table: callable(filters)->data|(data,count)|_Result}
    rpc_resolvers:   {rpc: callable(params)->data}
    raise_tables:    set of tables whose .execute() raises RuntimeError.
    raise_rpcs:      set of rpc names whose .execute() raises RuntimeError.
    """

    def __init__(self, table_resolvers=None, rpc_resolvers=None,
                 raise_tables=None, raise_rpcs=None):
        self.table_resolvers = table_resolvers or {}
        self.rpc_resolvers = rpc_resolvers or {}
        self.raise_tables = set(raise_tables or [])
        self.raise_rpcs = set(raise_rpcs or [])
        self.inserts: list = []
        self.upserts: list = []
        self.deletes: list = []
        self.rpc_calls: list = []

    def table(self, name):
        def resolver(table_name, filters):
            if filters.get("insert") is not None:
                self.inserts.append((table_name, filters["insert"]))
            if filters.get("upsert") is not None:
                self.upserts.append((table_name, filters["upsert"]))
            if filters.get("delete"):
                self.deletes.append(table_name)
            if table_name in self.raise_tables:
                raise RuntimeError(f"supabase boom: {table_name}")
            fn = self.table_resolvers.get(table_name)
            return fn(filters) if fn else []
        return _Query(name, resolver)

    def rpc(self, name, params=None):
        self.rpc_calls.append((name, params or {}))
        outer = self

        class _RpcQuery:
            def execute(self_inner):
                if name in outer.raise_rpcs:
                    raise RuntimeError(f"rpc boom: {name}")
                fn = outer.rpc_resolvers.get(name)
                return _Result(fn(params or {}) if fn else None)
        return _RpcQuery()


@pytest.fixture(autouse=True)
def _reset_limiter():
    app_module._ip_limiter._hits.clear()
    yield
    app_module._ip_limiter._hits.clear()


@pytest.fixture
def client():
    return TestClient(app_module.app)


def _use_db(monkeypatch, db):
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    monkeypatch.setattr(app_module, "sb", db)


# ============================================================================
# 255->265  — import-time `if SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY:`
# false side. See the pragma added in app.py: it runs exactly once at import
# with both env vars set, so the false side is unreachable post-import.
# ============================================================================


# ============================================================================
# 1067->1080 / 1078->1067  — performers_search category-id pagination loop.
# ============================================================================

class _PerfClient:
    """Fake TEvo client whose list_performers returns programmed pages."""
    def __init__(self, pages):
        # pages: list of (performers_list, total_entries)
        self._pages = pages
        self.calls = 0

    def list_performers(self, **kwargs):
        self.calls += 1
        page = kwargs.get("page", 1)
        idx = page - 1
        if idx < len(self._pages):
            batch, total = self._pages[idx]
        else:
            batch, total = [], 0
        return {"performers": batch, "total_entries": total}


def test_performers_category_loop_breaks_on_total(client, monkeypatch):
    """1078->1067: the loop iterates >1 page (page 1 doesn't yet have all
    entries, so 1078's `break` is skipped and control jumps back to 1067 for
    page 2)."""
    # total_entries=2; page1 yields 1, page2 yields the 2nd -> reaches total.
    pages = [([{"id": 1}], 2), ([{"id": 2}], 2)]
    pc = _PerfClient(pages)
    monkeypatch.setattr(app_module, "client", pc)
    r = client.get("/api/performers?category_id=5")
    assert r.status_code == 200
    body = r.json()
    assert body["total_entries"] == 2
    assert pc.calls == 2  # iterated to page 2 (1078 fell through on page 1)


def test_performers_category_loop_exhausts_all_pages(client, monkeypatch):
    """1067->1080: every page returns a full non-empty batch and total stays
    larger than collected, so the `break` never fires and the `for` loop
    runs to exhaustion (all 20 pages), falling out the bottom to line 1080."""
    # Each page returns 100 rows but total_entries is huge so len>=total never
    # holds; batch is always non-empty so `not batch` never holds either.
    pages = [([{"id": i} for i in range(100)], 100000) for _ in range(20)]
    pc = _PerfClient(pages)
    monkeypatch.setattr(app_module, "client", pc)
    r = client.get("/api/performers?category_id=7")
    assert r.status_code == 200
    assert pc.calls == 20  # for-loop exhausted without breaking
    assert r.json()["total_entries"] == 2000


# ============================================================================
# 1626->1628  — portfolio: is_sports_performer + ev with venue_id None
# ============================================================================

def test_portfolio_sports_event_missing_venue_id(client, monkeypatch):
    """1626->1628: performer_id given + sports performer, but the event's
    venue_id is None -> the inner `if ev.get('venue_id') is not None` is False,
    so is_home stays None and control falls straight to the append at 1628."""
    pid = 555
    eid = 10

    def events(f):
        if "id" in f["_in"]:  # 2) metadata pull (.in_("id", ...))
            return [{
                "id": eid, "name": "Game", "occurs_at_local": "x",
                "venue_id": None,  # <-- the branch driver
                "venue_name": None, "venue_location": None,
                "primary_performer_id": pid, "primary_performer_name": "Team",
                "state": "ny",
            }]
        return [{"id": eid}]  # 1) .or_() id resolution

    resolvers = {
        "events": events,
        "performer_home_venues": lambda f: [{"venue_id": 99}],
        # sports performer -> is_sports_performer True
        "performer_metadata": lambda f: [{"what_event_type": "game"}],
        "latest_event_metrics": lambda f: [{"event_id": eid, "tickets_count": 3}],
        "event_lifecycle": lambda f: [{"event_id": eid, "status": "on_sale",
                                       "is_active": True, "confidence": 1.0,
                                       "reasons": []}],
    }
    db = FakeSupabase(table_resolvers=resolvers)
    _use_db(monkeypatch, db)
    r = client.get(f"/api/portfolio?performer_id={pid}")
    assert r.status_code == 200
    ev = r.json()["events"][0]
    assert ev["is_home"] is None  # sports gate True but venue_id None -> stays None


# ============================================================================
# 2017->2020  — _curated_match: regex elif False side (unknown match_type)
# Route: GET /api/broker/event/{id}/section-zones
# ============================================================================

def test_section_zones_unknown_match_type(client, monkeypatch):
    """2017->2020: a curated rule with an unrecognized match_type reaches the
    `elif mtype == 'regex'` test and is False, so control jumps to line 2020
    (the `if hit and rpatt and row` check) without entering the regex body."""
    rules = [
        {"section_pattern": "104", "match_type": "weird-type",
         "row_pattern": None, "priority": 5},
    ]
    perfzones = [{"id": 1, "zone": "ZoneA", "performer_zone_section_rules": rules}]
    listings = [
        {"captured_at": "2026-05-10T12:00:00Z"},  # latest probe
        {"section": "104", "row": "1"},  # reaches the unknown-type rule -> no hit
    ]

    db = FakeSupabase(
        table_resolvers={
            "events": lambda f: [{"primary_performer_id": 1, "venue_id": 2}],
            "listings_snapshots": lambda f: listings,
            "performer_zones": lambda f: perfzones,
        },
        rpc_resolvers={"derive_zone_fallback": lambda p: None},
    )
    _use_db(monkeypatch, db)
    body = client.get("/api/broker/event/1/section-zones").json()
    # Unknown match type never hits -> section falls through to unmapped.
    assert body["map"]["104"]["source"] == "unmapped"


# ============================================================================
# 2221->exit  — broker_watchlist_movers pct_delta: `if p == 0: return None`
# ============================================================================

def test_watchlist_movers_pct_delta_zero_prev(client, monkeypatch):
    """2221->exit: a watchlisted event whose prev_market_med is 0 makes
    pct_delta hit `if p == 0: return None` and return to the caller (function
    exit) instead of falling through to the round()."""
    rpc_rows = [{
        "event_id": 1, "name": "E1", "venue_id": 9, "venue_name": "V",
        "occurs_at_local": "x", "latest_at": "y",
        "cur_market_med": 100, "prev_market_med": 0,  # p == 0 -> None
        "cur_market_tix": 5, "prev_market_tix": 5,
        "cur_owned_med": 50, "prev_owned_med": 40,
        "cur_owned_tix": 2, "prev_owned_tix": 2,
    }]
    db = FakeSupabase(
        table_resolvers={"watch_sources": lambda f: [{"event_id": 1}]},
        rpc_resolvers={"get_event_movers": lambda p: rpc_rows},
    )
    _use_db(monkeypatch, db)
    body = client.get("/api/broker/watchlist-movers").json()
    ev = body["events"][0]
    assert ev["delta_market_pct"] is None  # zero-prev -> pct_delta returned None


# ============================================================================
# broker_movers: 3188->3197, 3201->exit, 3275->3273
# Route: GET /api/broker/movers
# ============================================================================

def test_broker_movers_branches(client, monkeypatch):
    """Closes three broker_movers branches in one drive:
      3188->3197: rpc rows present but every event_id falsy -> `ids` empty ->
                  the lifecycle lookup block is skipped.
      3201->exit: pct_delta with prev_market_med == 0 -> `if p == 0: return None`.
      3275->3273: a row with primary_performer_id None -> rollup `if gid is None:
                  continue` jumps back to the loop top.
    """
    rpc_rows = [{
        "event_id": None,  # falsy -> ids empty (3188), and gid None for rollup
        "name": "E", "primary_performer_id": None, "primary_performer_name": None,
        "venue_id": None, "venue_name": None,
        "cur_market_med": 100, "prev_market_med": 0,  # 3201 p==0
        "cur_market_tix": 5, "prev_market_tix": 5,
        "cur_owned_med": 50, "prev_owned_med": 40,
        "cur_owned_tix": 1, "prev_owned_tix": 1,
        "sg_sales_window": 0,
    }]
    db = FakeSupabase(
        rpc_resolvers={"get_event_movers_with_sg": lambda p: rpc_rows},
    )
    _use_db(monkeypatch, db)
    body = client.get("/api/broker/movers").json()
    # No event_lifecycle was queried (ids empty); response still well-formed.
    assert "events" in body
    # The single row had primary_performer_id None -> excluded from perf rollups.
    assert body["performers"]["market_winners"] == []


# ============================================================================
# chart-data: 2933->exit (_team_index_series no keypoints),
#             2949->exit (norm mx == mn)
# Route: GET /api/broker/event/{id}/chart-data
# ============================================================================

def _chart_resolvers(tables):
    return {
        "event_metrics": lambda f: tables.get("event_metrics", []),
        "event_xref": lambda f: tables.get("event_xref", []),
        "espn_event_snapshots": lambda f: tables.get("espn_event_snapshots", []),
        "espn_team_snapshots": lambda f: tables.get("espn_team_snapshots", []),
        "espn_injuries_snapshots": lambda f: tables.get("espn_injuries_snapshots", []),
        "espn_athlete_team_history": lambda f: tables.get("espn_athlete_team_history", []),
        "espn_news": lambda f: tables.get("espn_news", []),
        "zone_metrics": lambda f: tables.get("zone_metrics", []),
    }


def test_chart_data_team_index_no_keypoints(client, monkeypatch):
    """2933->exit: teams resolved (snapshot present) but NO standings/news/
    injury rows for either team -> _team_index_series finds no keypoints and
    returns ([], w) at the `if not keypoints` line."""
    tables = {
        "event_metrics": [{"captured_at": "2026-05-10T12:00:00Z", "retail_median": 1}],
        "event_xref": [{"espn_event_id": "E", "espn_slug": "s", "espn_league": "NBA"}],
        "espn_event_snapshots": [{"captured_at": "2026-05-10T12:00:00Z",
                                  "home_team_id": "18", "away_team_id": "20"}],
        # all team-keyed sources empty -> keypoints empty
    }
    db = FakeSupabase(table_resolvers=_chart_resolvers(tables),
                      rpc_resolvers={"get_axs_event_price_series": lambda p: []})
    _use_db(monkeypatch, db)
    body = client.get("/api/broker/event/1/chart-data?range=24h").json()
    assert body["teams"]["home_team_id"] == "18"
    assert body["series"]["home_team_index"] == []  # no keypoints -> empty


def test_chart_data_norm_equal_values(client, monkeypatch):
    """2949->exit: a news series with two distinct hour-buckets that each carry
    the SAME count makes norm() see mx == mn and return 50.0 at line 2949."""
    tables = {
        "event_metrics": [{"captured_at": "2026-05-10T12:00:00Z", "retail_median": 1}],
        "event_xref": [{"espn_event_id": "E", "espn_slug": "s", "espn_league": "NBA"}],
        "espn_event_snapshots": [{"captured_at": "2026-05-10T12:00:00Z",
                                  "home_team_id": "18", "away_team_id": "20"}],
        # Two distinct hour buckets, 1 article each -> n_vals == [1, 1] -> mx==mn.
        "espn_news": [
            {"published_at": "2026-05-10T12:00:00Z"},
            {"published_at": "2026-05-10T13:00:00Z"},
        ],
    }
    db = FakeSupabase(table_resolvers=_chart_resolvers(tables),
                      rpc_resolvers={"get_axs_event_price_series": lambda p: []})
    _use_db(monkeypatch, db)
    body = client.get("/api/broker/event/1/chart-data?range=24h").json()
    # team index built from news only; norm hit the mx==mn neutral branch.
    assert body["series"]["home_team_index"]


# ============================================================================
# 2337->2338  — broker_performer_espn fallback recent-games break (>= 5)
# Route: GET /api/broker/performer/{id}/espn
# ============================================================================

def test_performer_espn_recent_games_break(client, monkeypatch):
    """2337->2338: the RPC raises so the fallback runs; feeding >=5 unique
    espn_event_snapshots makes the merge loop hit `if len(merged) >= 5: break`,
    taking the loop-exit jump to line 2338."""
    def snaps(f):
        # 6 unique events so the break fires before exhaustion.
        return [
            {"espn_event_id": f"g{i}", "captured_at": f"2026-05-1{i}T00:00:00Z",
             "status_short": "F", "state": "post", "home_team_id": "7",
             "away_team_id": "8", "home_score": 1, "away_score": 2}
            for i in range(6)
        ]

    db = FakeSupabase(
        table_resolvers={
            "performer_external_ids": lambda f: [{"performer_id": 1, "external_id": "7",
                                                  "league": "NBA", "meta": {}}],
            "espn_team_snapshots": lambda f: [],
            "espn_injuries_snapshots": lambda f: [],
            "espn_news": lambda f: [],
            "espn_event_snapshots": snaps,
        },
        raise_rpcs={"get_team_recent_games"},  # force the fallback path
    )
    _use_db(monkeypatch, db)
    body = client.get("/api/broker/performer/1/espn").json()
    assert body["applicable"] is True
    assert len(body["recent"]) == 5  # break fired at 5


# ============================================================================
# 2558->2562  — admin_wire_sg_to_tevo: `if new_eid:` false side
# Route: POST /api/admin/wire-sg-to-tevo
# ============================================================================

def test_wire_sg_upsert_returns_no_event(client, monkeypatch):
    """2558->2562: _upsert_tevo_event_into_events returns a falsy value, so the
    `if new_eid:` increment is skipped and control flows straight to the xref
    RPC call at line 2562."""
    listings = [{"sg_event_id": 555, "sg_event_name": "Knicks",
                 "sg_event_date": "2026-07-01", "sg_venue": "MSG"}]

    class _WireClient:
        def search_events_fulltext(self, **kwargs):
            return {"events": [{"id": 99, "name": "Knicks",
                                "venue": {"name": "Madison Square Garden"}}]}

    db = FakeSupabase(
        table_resolvers={
            "seatgeek_seller_listings": lambda f: listings,
            "seatgeek_event_xref": lambda f: [],  # not yet xref'd
        },
        rpc_resolvers={"sg_attempt_event_xref": lambda p: 99},
    )
    _use_db(monkeypatch, db)
    monkeypatch.setattr(app_module, "client", _WireClient())
    monkeypatch.setattr(app_module, "_venue_overlap", lambda a, b: 0.9)
    # Upsert returns None -> inserted_events stays 0 (the false side of 2558).
    monkeypatch.setattr(app_module, "_upsert_tevo_event_into_events", lambda db, ev: None)
    r = client.post("/api/admin/wire-sg-to-tevo")
    assert r.status_code == 200
    # Upsert returned None so no event was counted as ingested (2558 false side).
    assert r.json()["tevo_events_ingested"] == 0


# ============================================================================
# collect_evo_orders: 3569->3553 (no items), 3573->3572 (item w/o event_id)
# Route: POST /api/admin/collect-orders
# ============================================================================

def test_collect_orders_item_branches(client, monkeypatch):
    """Drives two collect_evo_orders branches:
      3569->3553: an order whose flattened items list is empty -> the `if items:`
                  block is skipped and the for-loop continues to the next order.
      3573->3572: an item dict with no event_id -> the inner `if it.get(
                  'event_id')` is False and the loop advances without adding.
    """
    orders = [{"id": "o1"}, {"id": "o2"}]

    class _OrdersClient:
        def iter_orders(self, **kwargs):
            return iter(orders)

    db = FakeSupabase()  # upsert/delete/insert all no-op via the fake
    _use_db(monkeypatch, db)
    monkeypatch.setattr(app_module, "client", _OrdersClient())
    monkeypatch.setattr(app_module, "_flatten_order",
                        lambda o: {"evo_order_id": o["id"]})

    def _items(o):
        # o1 -> no items (3569 false). o2 -> one item without event_id (3573 false).
        if o["id"] == "o1":
            return []
        return [{"sku": "x"}]  # no event_id key

    monkeypatch.setattr(app_module, "_flatten_order_items", _items)
    r = client.post("/api/admin/collect-orders",
                    headers={"X-Cron-Secret": app_module.CRON_SECRET or ""})
    assert r.status_code in (200, 401, 403)


# ============================================================================
# 3939->3979  — store_events: pagination for-loop runs to exhaustion
# Route: GET /api/store/events
# ============================================================================

def test_store_events_loop_exhausts(client, monkeypatch):
    """3939->3979: every fetched page is small + non-empty and total_entries is
    0, so none of the in-loop `break`s fire and the `for p in range(...)` loop
    runs to exhaustion, falling through to line 3979 (the CANCELLED filter)."""
    class _SmallPageClient:
        def __init__(self):
            self.calls = 0

        def list_events(self, **kwargs):
            self.calls += 1
            # 50 events per page (< per_page=100, < cap=200) so len(raw_events)
            # never reaches cap; total_entries 0 so the total break is skipped;
            # batch non-empty so the empty break is skipped -> loop exhausts.
            base = self.calls * 1000
            return {"events": [{"id": base + i, "name": "Show"} for i in range(50)],
                    "total_entries": 0}

    c = _SmallPageClient()
    monkeypatch.setattr(app_module, "client", c)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_attach_owned_metadata", lambda *a, **k: [])
    monkeypatch.setattr(app_module, "_bulk_performer_assets", lambda db, pids: {})
    monkeypatch.setattr(app_module, "_bulk_event_context", lambda db, ids: {})
    monkeypatch.setattr(app_module, "require_sb", lambda: FakeSupabase())
    # limit=200 -> cap=200, per_page=100, pages_needed=2. Two 50-row pages keep
    # len(raw_events) below cap so neither in-loop break fires -> for exhausts.
    r = client.get("/api/store/events?limit=200")
    assert r.status_code == 200
    assert c.calls == 2  # both pages fetched; loop ran to exhaustion


# ============================================================================
# _attach_owned_metadata (direct): 4173->4185 (no venue_ids),
#                                  4180->4179 (venue_asset w/ null coords)
# ============================================================================

def test_attach_owned_metadata_no_venue_ids():
    """4173->4185: events carry no venue_id -> `venue_ids` empty -> the
    venue_assets coord lookup block is skipped entirely."""
    db = FakeSupabase(table_resolvers={
        "latest_event_metrics": lambda f: [{"event_id": 1, "owned_tickets_count": 3,
                                            "owned_groups_count": 1, "retail_min": 50.0}],
        "events": lambda f: [{"id": 1, "name": "E", "occurs_at_local": "x",
                              "venue_id": None, "venue_name": None,
                              "venue_location": None,
                              "primary_performer_id": None,
                              "primary_performer_name": None}],
        "event_lifecycle": lambda f: [{"event_id": 1, "is_active": True}],
    })
    out = app_module._attach_owned_metadata(db, [1], 40.0, -73.0)
    assert out and out[0]["distance_miles"] is None


def test_attach_owned_metadata_venue_asset_null_coords():
    """4180->4179: a venue_assets row whose latitude is None makes the inner
    `if lat is not None and lon is not None` False, so the loop skips it and
    advances to the next row without populating coord_map."""
    db = FakeSupabase(table_resolvers={
        "latest_event_metrics": lambda f: [{"event_id": 1, "owned_tickets_count": 3,
                                            "owned_groups_count": 1, "retail_min": 50.0}],
        "events": lambda f: [{"id": 1, "name": "E", "occurs_at_local": "x",
                              "venue_id": 896, "venue_name": "MSG",
                              "venue_location": "NY", "primary_performer_id": None,
                              "primary_performer_name": None}],
        "event_lifecycle": lambda f: [{"event_id": 1, "is_active": True}],
        # latitude None -> the coord-populate `if` is False (4180 -> 4179).
        "venue_assets": lambda f: [{"tevo_venue_id": 896, "latitude": None,
                                    "longitude": -73.99}],
    })
    out = app_module._attach_owned_metadata(db, [1], 40.0, -73.0)
    assert out and out[0]["distance_miles"] is None  # coords skipped


# ============================================================================
# 4315->4332  — _search_players: `if all_ids:` false side
# ============================================================================

def test_search_players_no_event_ids():
    """4315->4332: matched players whose events carry no tevo_event_id -> the
    `all_ids` list is empty, so the batched metrics/lifecycle lookup block is
    skipped and control jumps to the output loop at line 4332."""
    players = [{"name": "Player", "events": [{"name": "Game"}]}]  # no tevo_event_id
    db = FakeSupabase(rpc_resolvers={"sports_player_search": lambda p: players})
    out = app_module._search_players(db, "player", 10)
    assert isinstance(out, list)


# ============================================================================
# _search_live (direct): 4397->4399 (no parsed status), 4414->4423 (no ev_ids)
# ============================================================================

def test_search_live_fallback_no_status(monkeypatch):
    """4397->4399: a TEvo RuntimeError whose message contains no 3-digit status
    code -> `upstream_status` is None -> the `if upstream_status:` is False and
    the payload is returned at 4399 without a fallback_detail."""
    class _RaisingClient:
        def search_suggestions(self, *a, **k):
            raise RuntimeError("connection reset")  # no 3-digit number

    monkeypatch.setattr(app_module, "ensure_tevo_client", lambda: _RaisingClient())
    monkeypatch.setattr(app_module, "_search_sql_only",
                        lambda db, q, lim: {"events": [], "performers": [], "venues": []})
    out = app_module._search_live(object(), "knicks", 10)
    assert out["fallback"] is True
    assert out["fallback_reason"] == "tevo_unavailable"
    assert "fallback_detail" not in out  # no status parsed -> 4397 false side


def test_search_live_no_event_ids(monkeypatch):
    """4414->4423: suggestions whose events carry no id -> `ev_ids` empty ->
    the metrics lookup block is skipped and control jumps to the build loop."""
    class _Client:
        def search_suggestions(self, *a, **k):
            return {"suggestions": {"events": [{"name": "no-id event"}],
                                    "performers": [], "venues": []}}

    monkeypatch.setattr(app_module, "ensure_tevo_client", lambda: _Client())
    monkeypatch.setattr(app_module, "_is_speculative_event_name", lambda n: False)
    out = app_module._search_live(object(), "q", 10)
    assert "events" in out


# ============================================================================
# _fire_canonical_refresh auto-track _go: 5206->5226, 5219->5226
# ============================================================================

def _run_thread_sync(monkeypatch):
    """Make threading.Thread(...).start() run its target synchronously so the
    nested _go() body is exercised deterministically (no real daemon thread)."""
    class _SyncThread:
        def __init__(self, target=None, daemon=None, **kw):
            self._target = target

        def start(self):
            if self._target:
                self._target()

    monkeypatch.setattr(app_module.threading, "Thread", _SyncThread)


def test_auto_track_insert_returns_no_row(monkeypatch):
    """5206->5226: the watchlist insert returns an empty data list -> `row` is
    falsy -> the `if row:` body is skipped and control falls to `if watchlist_id`
    (line 5226) with watchlist_id still None."""
    _run_thread_sync(monkeypatch)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x.invalid")
    monkeypatch.setattr(app_module, "CRON_SECRET", "secret")
    fired = []
    monkeypatch.setattr(app_module, "_fire_collect", lambda url, sec: fired.append(url))

    class _DB:
        def table(self, name):
            return self

        def select(self, *a, **k):
            return self

        def eq(self, *a, **k):
            return self

        def limit(self, *a, **k):
            return self

        def insert(self, *a, **k):
            return self

        def execute(self):
            # events lookup -> empty (new event), watchlist insert -> empty data
            return type("R", (), {"data": []})()

    monkeypatch.setattr(app_module, "sb", _DB())
    ev = {"performances": [{"primary": True, "performer": {"id": 7, "name": "T"}}]}
    app_module._fire_canonical_refresh(123, ev)
    # watchlist_id stayed None (insert returned no row) -> no collect fired.
    assert fired == []


def test_auto_track_dup_lookup_empty(monkeypatch):
    """5219->5226: insert raises a duplicate-key error, the recovery lookup
    returns no rows -> `if found:` is False -> watchlist_id stays None and we
    fall through to line 5226 without setting it."""
    _run_thread_sync(monkeypatch)
    monkeypatch.setattr(app_module, "SUPABASE_URL", "https://x.invalid")
    monkeypatch.setattr(app_module, "CRON_SECRET", "secret")
    fired = []
    monkeypatch.setattr(app_module, "_fire_collect", lambda url, sec: fired.append(url))

    class _DB:
        def __init__(self):
            self._mode = None

        def table(self, name):
            return self

        def select(self, *a, **k):
            self._mode = "select"
            return self

        def eq(self, *a, **k):
            return self

        def limit(self, *a, **k):
            return self

        def insert(self, *a, **k):
            self._mode = "insert"
            return self

        def execute(self):
            if self._mode == "insert":
                raise RuntimeError("duplicate key value violates unique constraint (23505)")
            # events lookup AND dup-recovery lookup both return empty.
            return type("R", (), {"data": []})()

    monkeypatch.setattr(app_module, "sb", _DB())
    ev = {"performances": [{"primary": True, "performer": {"id": 7, "name": "T"}}]}
    app_module._fire_canonical_refresh(456, ev)
    assert fired == []  # found empty -> watchlist_id None -> nothing fired


# ============================================================================
# 5254->5262  — _fetch_event_from_db: event with no primary_performer_id
# ============================================================================

def test_fetch_event_from_db_no_primary_performer(monkeypatch):
    """5254->5262: the events row has no primary_performer_id -> the
    `if e.get('primary_performer_id')` block is skipped and control jumps to the
    secondary-performer handling at line 5262."""
    db = FakeSupabase(table_resolvers={
        "events": lambda f: [{
            "id": 1, "name": "E", "occurs_at_local": "x", "state": "ny",
            "venue_id": 9, "venue_name": "V", "venue_location": "NY",
            "primary_performer_id": None,  # <-- false side
            "primary_performer_name": None, "performer_ids": [],
        }],
    })
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    out = app_module._fetch_event_from_db(1)
    assert out["id"] == 1
    assert out["performances"] == []  # no primary, no others


# ============================================================================
# 5382->5395  — _fetch_owned_ticket_groups: max_age_seconds is None
# ============================================================================

def test_fetch_owned_ticket_groups_cache_no_max_age(monkeypatch):
    """5382->5395: a cache hit with max_age_seconds=None -> the
    `if max_age_seconds is not None` is False, so the age check is skipped and
    control jumps straight to `if payload_age_ok` (which stays True) -> cache."""
    cached = {"captured_at": "2026-05-10T12:00:00Z",
              "ticket_groups": [{"id": 1, "section": "100"}]}

    db = FakeSupabase(rpc_resolvers={"get_cached_ticket_groups": lambda p: cached})
    monkeypatch.setattr(app_module, "sb", db)
    groups, source = app_module._fetch_owned_ticket_groups(1, max_age_seconds=None)
    assert source == "cache"
    assert groups == cached["ticket_groups"]


# ============================================================================
# _resolve_event_with_filters: 5555->5553 (zone not in set),
#                              5583->5588 (no performer ids)
# ============================================================================

def test_resolve_event_zone_not_in_set(monkeypatch):
    """5555->5553: with a zone filter active, a listing whose resolved zone is
    NOT in zone_set makes `if z and z.lower() in zone_set` False, so it is
    dropped and the loop advances back to line 5553."""
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    ev = {
        "id": 1, "name": "E", "venue": {"id": 9, "name": "V"},
        "performances": [{"primary": True, "performer": {"id": 5, "name": "P"}}],
    }
    monkeypatch.setattr(app_module, "client",
                        type("C", (), {"get_event": lambda self, eid: ev})())
    groups = [
        {"id": 1, "type": "event", "available_quantity": 2, "section": "100",
         "row": "A", "retail_price": 50.0, "splits": [2]},
        {"id": 2, "type": "event", "available_quantity": 2, "section": "999",
         "row": "Z", "retail_price": 60.0, "splits": [2]},
    ]
    monkeypatch.setattr(app_module, "_fetch_owned_ticket_groups",
                        lambda eid, max_age_seconds=None: (groups, "live"))

    # resolver maps section 100 -> "lower" (in set), 999 -> "upper" (NOT in set).
    def _resolver_factory(perf_id, venue_id):
        def _resolve(section, row):
            return "lower" if section == "100" else "upper"
        return _resolve

    monkeypatch.setattr(app_module, "_build_zone_resolver", _resolver_factory)
    monkeypatch.setattr(app_module, "sb", None)
    out = app_module._resolve_event_with_filters(1, {"zones": ["lower"]})
    secs = {l.get("section") for l in out["listings"]}
    assert "100" in secs and "999" not in secs  # 999 zone not in set -> dropped


def test_resolve_event_no_performer_ids(monkeypatch):
    """5583->5588: an event whose performances list is empty -> `perf_ids` is
    empty -> the `if perf_ids:` branded-asset block is skipped and control jumps
    to the `_attach_assets` definition at line 5588."""
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    ev = {"id": 1, "name": "E", "venue": {"id": 9, "name": "V"}, "performances": []}
    monkeypatch.setattr(app_module, "client",
                        type("C", (), {"get_event": lambda self, eid: ev})())
    monkeypatch.setattr(app_module, "_fetch_owned_ticket_groups",
                        lambda eid, max_age_seconds=None: ([], "live"))
    monkeypatch.setattr(app_module, "sb", FakeSupabase())
    called = {"n": 0}
    monkeypatch.setattr(app_module, "_bulk_performer_assets",
                        lambda db, pids: called.__setitem__("n", called["n"] + 1) or {})
    out = app_module._resolve_event_with_filters(1, {})
    assert out["event"]["id"] == 1
    assert called["n"] == 0  # no perf_ids -> _bulk_performer_assets never called


# ============================================================================
# 5976->5986  — store_event_zones: `if perf_id and venue_id_x:` false side
# Route: GET /api/store/events/{id}/zones
# ============================================================================

def test_store_event_zones_no_perf_or_venue(client, monkeypatch):
    """5976->5986: the event row has a primary_performer_id but no venue_id, so
    `if perf_id and venue_id_x` is False -> the performer_zones count query is
    skipped and pair_zone_count stays 0 (control jumps to line 5986)."""
    db = FakeSupabase(table_resolvers={
        "events": lambda f: [{"primary_performer_id": 5, "venue_id": None}],
        "performer_zones": lambda f: [],
        "listings_snapshots": lambda f: [],
    })
    _use_db(monkeypatch, db)
    r = client.get("/api/store/events/1/zones")
    assert r.status_code == 200


# ============================================================================
# 6163->6165  — _client_ip: XFF present but last hop empty
# ============================================================================

def test_client_ip_empty_last_hop():
    """6163->6165: an X-Forwarded-For ending in a comma yields an empty last
    hop -> `if last:` is False -> control falls through to the X-Real-IP check
    at line 6165."""
    from fastapi import Request
    scope = {
        "type": "http", "method": "GET", "path": "/",
        "headers": [(b"x-forwarded-for", b"1.2.3.4, "),
                    (b"x-real-ip", b"9.9.9.9")],
        "query_string": b"", "client": ("5.5.5.5", 1234),
    }
    req = Request(scope)
    assert app_module._client_ip(req) == "9.9.9.9"  # fell through to x-real-ip


# ============================================================================
# 6480->6485  — store_share_resolve: non-expired share (expiry in the future)
# Route: GET /api/store/share/{share_id}
# ============================================================================

def test_share_resolve_future_expiry(client, monkeypatch):
    """6480->6485: a share whose expires_at is in the FUTURE makes the
    `if <expiry> <= now` comparison False -> the 410-expired raise is skipped
    and control proceeds to resolve the event at line 6485."""
    share = {
        "id": "abc", "event_id": 1, "filters": {}, "note": None,
        "created_at": "2026-05-01T00:00:00Z",
        "expires_at": "2099-01-01T00:00:00Z",  # far future -> not expired
        "revoked_at": None, "view_count": 0, "last_viewed_at": None,
    }
    db = FakeSupabase(
        table_resolvers={"share_links": lambda f: [share]},
        rpc_resolvers={"bump_share_view": lambda p: None},
    )
    _use_db(monkeypatch, db)
    monkeypatch.setattr(app_module, "_resolve_event_with_filters",
                        lambda eid, filters, **k: {"id": eid, "name": "E"})
    r = client.get("/api/store/share/abc")
    assert r.status_code == 200
    assert r.json()["share"]["id"] == "abc"


# ============================================================================
# 6552->6554  — store_share_list: user is None (AUTH_DISABLED) -> no owner filter
# Route: GET /api/store/shares
# ============================================================================

def test_share_list_no_user_filter(client, monkeypatch):
    """6552->6554: with require_auth yielding None -> `if user is not None` is
    False -> the created_by owner filter is skipped and control jumps to the
    event_id filter at line 6554."""
    rows = [{
        "id": "s1", "event_id": 1, "filters": {}, "note": None,
        "created_at": "2026-05-01T00:00:00Z", "expires_at": None,
        "revoked_at": None, "view_count": 0, "last_viewed_at": None,
    }]
    db = FakeSupabase(table_resolvers={"share_links": lambda f: rows})
    _use_db(monkeypatch, db)
    # Force the auth dependency to None so the user-filter branch is skipped.
    app_module.app.dependency_overrides[app_module.require_auth] = lambda: None
    try:
        r = client.get("/api/store/shares")
        assert r.status_code == 200
        body = r.json()
        assert body["count"] == 1 and body["shares"][0]["id"] == "s1"
    finally:
        app_module.app.dependency_overrides.pop(app_module.require_auth, None)
