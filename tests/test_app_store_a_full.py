"""Coverage-maximizing tests for the STORE-A slice of app.py.

Owned routes:
  - GET /api/store/events    (TEvo-direct catalog, large handler ~3881-4105)
  - GET /api/store/search    (~4444-4501, + _search_live/_search_players helpers)
  - GET /api/store/concierge (~4504-4529)
  - GET /api/store/movers    (~4532-4598)
  - GET /api/store/home      (SQL-only first-paint, large handler ~4619-4857)

Everything is stubbed — no real TEvo/Supabase/network. The TEvo client is a
fake recording `list_events` calls and returning canned pages; Supabase is a
FakeDB whose tables are programmable per-test. We flip STOREFRONT_SQL_ONLY /
STOREFRONT_SEARCH_SQL_ONLY via monkeypatch to drive both routing branches.

House style mirrors tests/test_store_home.py + tests/test_store_events.py
(FakeDB fluent chain, app.client / require_sb monkeypatch).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# ---- Env setup BEFORE importing app (app.py exits at import without creds) ----
os.environ.setdefault("STOREFRONT_SQL_ONLY", "false")
os.environ.setdefault("TEVO_API_TOKEN", "test-token")
os.environ.setdefault("TEVO_API_SECRET", "test-secret")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-key")
os.environ.setdefault("AUTH_DISABLED", "true")

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

fastapi = pytest.importorskip("fastapi")
starlette_testclient = pytest.importorskip("fastapi.testclient")

import server as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# --------------------------------------------------------------------------- #
# Fake Supabase — fluent-chain stub returning programmable rows per table.
# --------------------------------------------------------------------------- #

class _Response:
    def __init__(self, data):
        self.data = data


class _FakeTable:
    def __init__(self, rows: list[dict]):
        self._rows = list(rows)
        self._filters: list[tuple] = []
        self._limit: int | None = None

    def select(self, *_a, **_k):
        return self

    def gt(self, col, val):
        self._filters.append(("gt", col, val))
        return self

    def gte(self, col, val):
        self._filters.append(("gte", col, val))
        return self

    def lte(self, col, val):
        self._filters.append(("lte", col, val))
        return self

    def eq(self, col, val):
        self._filters.append(("eq", col, val))
        return self

    def in_(self, col, vals):
        self._filters.append(("in_", col, list(vals)))
        return self

    def ilike(self, col, pat):
        self._filters.append(("ilike", col, pat))
        return self

    def or_(self, _clauses):
        return self

    def order(self, *_a, **_k):
        return self

    def limit(self, n):
        self._limit = n
        return self

    def _match(self, row, op, col, val):
        v = row.get(col)
        if op == "gt":
            try:
                return v is not None and float(v) > float(val)
            except (TypeError, ValueError):
                return False
        if op == "gte":
            return v is not None and str(v) >= str(val)
        if op == "lte":
            return v is not None and str(v) <= str(val)
        if op == "eq":
            return v == val
        if op == "in_":
            return v in val
        if op == "ilike":
            return (val or "").strip("%").lower() in (v or "").lower()
        return True

    def execute(self):
        out = [r for r in self._rows
               if all(self._match(r, *f) for f in self._filters)]
        if self._limit is not None:
            out = out[: self._limit]
        return _Response(out)


class _FakeDB:
    def __init__(self, tables: dict[str, list[dict]] | None = None):
        self.tables = tables or {}
        self.rpc_returns: dict[str, list] = {}
        self.rpc_raises: set[str] = set()

    def table(self, name):
        return _FakeTable(self.tables.get(name, []))

    def rpc(self, name, _params):
        if name in self.rpc_raises:
            raise RuntimeError("rpc boom")
        return _FakeTable(self.rpc_returns.get(name, []))


# --------------------------------------------------------------------------- #
# Fake TEvo client — records list_events kwargs, returns canned pages.
# --------------------------------------------------------------------------- #

class _FakeEvo:
    def __init__(self, pages: dict[int, list[dict]], total: int | None = None):
        self.pages = pages
        self.total = total if total is not None else sum(len(v) for v in pages.values())
        self.calls: list[dict] = []
        self.suggest_resp: dict | None = None
        self.suggest_raises = False

    def list_events(self, **kwargs):
        self.calls.append(kwargs)
        return {"events": self.pages.get(kwargs.get("page", 1), []),
                "total_entries": self.total}

    def search_suggestions(self, *_a, **_k):
        if self.suggest_raises:
            raise RuntimeError("TEvo API 503 upstream")
        return self.suggest_resp or {"suggestions": {}}


# --------------------------------------------------------------------------- #
# Row factories
# --------------------------------------------------------------------------- #

def _tevo_ev(eid, name=None, performances=None, venue=None, **over):
    base = {
        "id": eid,
        "name": name if name is not None else f"Event {eid}",
        "occurs_at": "2026-07-01T19:00:00Z",
        "occurs_at_local": "2026-07-01T19:00:00-04:00",
        "available_count": 50,
        "owned_by_office": True,
        "tbd": False,
        "popularity_score": 0.4,
        "venue": venue if venue is not None else {
            "id": 896, "name": "MSG", "location": "New York, NY",
            "city": "New York", "state": "NY",
        },
        "performances": performances if performances is not None else [
            {"primary": True, "performer": {"id": 16303, "name": "Knicks"}},
        ],
    }
    base.update(over)
    return base


def _lem(eid, owned=100, retail_min=50.0):
    return {
        "event_id": eid,
        "owned_tickets_count": owned,
        "owned_groups_count": max(1, owned // 5),
        "retail_min": retail_min,
        "retail_median": retail_min * 2,
        "captured_at": "2026-06-01T00:00:00+00",
        "tickets_count": owned * 3,
    }


def _fut_date_str():
    from datetime import date, timedelta
    return f"{(date.today() + timedelta(days=30)).isoformat()}T19:00:00-04:00"


def _event(eid, name=None, venue_location="New York, NY",
           performer_id=16303, performer_ids=None, occurs=None):
    return {
        "id": eid,
        "name": name or f"Event {eid}",
        "occurs_at_local": occurs or _fut_date_str(),
        "venue_id": 896,
        "venue_name": "MSG",
        "venue_location": venue_location,
        "primary_performer_id": performer_id,
        "primary_performer_name": "Knicks",
        "performer_ids": performer_ids if performer_ids is not None else [],
    }


def _lc(eid, active=True):
    return {"event_id": eid, "is_active": active}


_ASSETS = {
    16303: {"logo_default_url": "https://t/knicks.png", "color_primary": "1d428a",
            "espn_league": "NBA", "name": "Knicks"},
    55578: {"logo_default_url": "https://t/cavs.png", "color_primary": "860038",
            "espn_league": "NBA", "name": "Cavaliers"},
}


@pytest.fixture(autouse=True)
def _reset_ip_limiter():
    """The per-IP rate-limit middleware keeps a process-global sliding window
    (_ip_limiter._hits). This file issues many /api/store/* requests; without
    a reset the shared budget would spill 429s into other test modules that
    run after us. Clear it before AND after every test so the limiter starts
    empty and leaves no residue. (No source change — only the in-memory
    counter is cleared.)"""
    from collections import defaultdict, deque
    try:
        app_module._ip_limiter._hits = defaultdict(deque)
    except Exception:
        pass
    yield
    try:
        app_module._ip_limiter._hits = defaultdict(deque)
    except Exception:
        pass


@pytest.fixture
def patched(monkeypatch):
    """Stub Supabase + performer assets; return a handle the test populates."""
    db = _FakeDB()
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    monkeypatch.setattr(app_module, "_bulk_performer_assets",
                        lambda d, pids: {k: v for k, v in _ASSETS.items() if k in pids})

    class _H:
        pass
    h = _H()
    h.db = db
    h.monkeypatch = monkeypatch
    h.client = TestClient(app_module.app)
    return h


def _set_evo(h, fake):
    h.monkeypatch.setattr(app_module, "client", fake)


# ========================================================================== #
# /api/store/events
# ========================================================================== #

def test_events_client_none_503(patched):
    _set_evo(patched, None)
    r = patched.client.get("/api/store/events?limit=5")
    assert r.status_code == 503
    assert "TEvo client not configured" in r.json()["detail"]


def test_events_basic_with_assets(patched):
    _set_evo(patched, _FakeEvo({1: [_tevo_ev(1)]}))
    r = patched.client.get("/api/store/events?limit=1&q=knicks&performer_id=16303&venue_id=896")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] == 1
    card = body["events"][0]
    assert card["primary_performer_logo"] == "https://t/knicks.png"
    assert card["primary_performer_league"] == "NBA"
    assert card["we_own"] is True


def test_events_cancelled_filtered(patched):
    _set_evo(patched, _FakeEvo({1: [
        _tevo_ev(1, "Real"), _tevo_ev(2, "CANCELLED game"),
        _tevo_ev(3, "Other"),
    ]}))
    r = patched.client.get("/api/store/events?limit=10")
    assert [e["id"] for e in r.json()["events"]] == [1, 3]


def test_events_runtime_error_502(patched):
    class _Boom(_FakeEvo):
        def list_events(self, **k):
            raise RuntimeError("TEvo down https://x?token=SECRET")
    _set_evo(patched, _Boom({}))
    r = patched.client.get("/api/store/events?limit=5")
    assert r.status_code == 502
    assert r.json()["detail"] == "events fetch failed"
    assert "SECRET" not in r.text


def test_events_empty_batch_breaks(patched):
    # page 1 empty -> break immediately, count 0 (covers `if not batch: break`)
    _set_evo(patched, _FakeEvo({}))
    r = patched.client.get("/api/store/events?limit=5")
    assert r.json()["count"] == 0


def test_events_stops_at_total_entries(patched):
    # total_entries small so the `len(raw_events) >= total` branch fires.
    fake = _FakeEvo({1: [_tevo_ev(i) for i in range(1, 4)],
                     2: [_tevo_ev(i) for i in range(4, 7)]}, total=3)
    _set_evo(patched, fake)
    r = patched.client.get("/api/store/events?limit=100")
    # Only page 1 fetched because total reached.
    assert r.json()["count"] == 3


def test_events_venue_location_fallback_from_city_state(patched):
    ev = _tevo_ev(1, venue={"id": 5, "name": "V", "city": "Boston", "state": "MA"})
    _set_evo(patched, _FakeEvo({1: [ev]}))
    r = patched.client.get("/api/store/events?limit=1")
    assert r.json()["events"][0]["venue_location"] == "Boston, MA"


def test_events_venue_location_blank_city_state_none(patched):
    ev = _tevo_ev(1, venue={"id": 5, "name": "V"})  # no location/city/state
    _set_evo(patched, _FakeEvo({1: [ev]}))
    r = patched.client.get("/api/store/events?limit=1")
    assert r.json()["events"][0]["venue_location"] is None


def test_events_away_performer_populated(patched):
    perfs = [
        {"primary": True, "performer": {"id": 16303, "name": "Knicks"}},
        {"primary": False, "performer": {"id": 55578, "name": "Cavaliers"}},
    ]
    _set_evo(patched, _FakeEvo({1: [_tevo_ev(1, performances=perfs)]}))
    r = patched.client.get("/api/store/events?limit=1")
    card = r.json()["events"][0]
    assert card["away_performer_id"] == 55578
    assert card["away_performer_name"] == "Cavaliers"
    assert card["away_performer_logo"] == "https://t/cavs.png"


def test_events_no_primary_uses_first_performance(patched):
    # No `primary` flag on any performance -> falls back to performances[0].
    perfs = [
        {"performer": {"id": 16303, "name": "Knicks"}},
        {"performer": {"id": 55578, "name": "Cavaliers"}},
    ]
    _set_evo(patched, _FakeEvo({1: [_tevo_ev(1, performances=perfs)]}))
    r = patched.client.get("/api/store/events?limit=1")
    card = r.json()["events"][0]
    assert card["primary_performer_id"] == 16303
    assert card["away_performer_id"] == 55578


def test_events_performer_missing_id(patched):
    # Performer with no id -> not added to perf_ids; primary id is None.
    perfs = [{"primary": True, "performer": {"name": "No ID Performer"}}]
    _set_evo(patched, _FakeEvo({1: [_tevo_ev(1, performances=perfs)]}))
    r = patched.client.get("/api/store/events?limit=1")
    card = r.json()["events"][0]
    assert card["primary_performer_id"] is None
    assert card["primary_performer_logo"] is None


def test_events_assets_bulk_fetch_failure_falls_back(patched):
    def _raise(d, pids):
        raise RuntimeError("supabase down")
    patched.monkeypatch.setattr(app_module, "_bulk_performer_assets", _raise)
    _set_evo(patched, _FakeEvo({1: [_tevo_ev(1)]}))
    r = patched.client.get("/api/store/events?limit=1")
    assert r.status_code == 200
    assert r.json()["events"][0]["primary_performer_logo"] is None


def test_events_no_performers_no_perf_ids(patched):
    # Event with empty performances -> perf_ids stays empty, skips bulk fetch.
    _set_evo(patched, _FakeEvo({1: [_tevo_ev(1, performances=[])]}))
    r = patched.client.get("/api/store/events?limit=1")
    card = r.json()["events"][0]
    assert card["primary_performer_id"] is None


def test_events_offset_clamped(patched):
    _set_evo(patched, _FakeEvo({}))
    r = patched.client.get("/api/store/events?offset=999999&limit=5")
    # offset clamped to 5000 in the echoed response.
    assert r.json()["offset"] == 5000


# ========================================================================== #
# /api/store/search
# ========================================================================== #

def test_search_empty_query(patched):
    r = patched.client.get("/api/store/search?q=%20%20")
    body = r.json()
    assert body["source"] == "empty"
    assert body["events"] == [] and body["players"] == []


def test_search_sql_only_path(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", True)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_sql_only",
                        lambda db, q, lim: {"events": [{"id": 1}], "performers": [],
                                            "venues": [], "source": "sql"})
    monkeypatch.setattr(app_module, "_search_players", lambda db, q, lim: [])
    r = patched.client.get("/api/store/search?q=knicks")
    body = r.json()
    assert body["source"] == "sql"
    assert body["q"] == "knicks"
    assert "latency_ms" in body


def test_search_db_failure_returns_502(patched, monkeypatch):
    """Production-readiness P1 #4: search is an ACTIVE query, so a Supabase blip
    surfaces an explicit 502 (not a misleading empty result) while still running
    through the shared DB breaker for load-shedding. Contrast the passive
    homepage strips, which degrade silently to empty."""
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", True)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})

    def _boom(db, q, lim):
        raise RuntimeError("supabase down")
    monkeypatch.setattr(app_module, "_search_sql_only", _boom)
    monkeypatch.setattr(app_module, "_search_players", lambda *a: [])
    r = patched.client.get("/api/store/search?q=knicks")
    assert r.status_code == 502
    assert r.json()["detail"] == "search temporarily unavailable"


def test_search_cache_hit(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", True)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    calls = {"n": 0}

    def _sql(db, q, lim):
        calls["n"] += 1
        return {"events": [], "performers": [], "venues": [], "source": "sql"}
    monkeypatch.setattr(app_module, "_search_sql_only", _sql)
    monkeypatch.setattr(app_module, "_search_players", lambda *a: [])
    r1 = patched.client.get("/api/store/search?q=knicks&limit=5")
    r2 = patched.client.get("/api/store/search?q=KNICKS&limit=5")
    assert calls["n"] == 1, "second normalized query should hit cache"
    assert r2.json()["source"] == "cache"


def test_search_live_path(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_players", lambda *a: [])
    fake = _FakeEvo({})
    fake.suggest_resp = {"suggestions": {
        "events": [
            {"id": 1, "name": "Knicks vs Cavs", "venue_name": "MSG",
             "location": "New York, NY", "occurs_at": "2026-07-01"},
            {"id": 2, "name": "Playoff (If Necessary)"},  # speculative, dropped
        ],
        "performers": [{"id": 10, "name": "Knicks", "location": "NY",
                        "venue_name": "MSG"}],
        "venues": [{"id": 20, "name": "MSG", "location": "NY"}],
    }}
    monkeypatch.setattr(app_module, "ensure_tevo_client", lambda: fake)
    patched.db.tables["latest_event_metrics"] = [
        {"event_id": 1, "owned_tickets_count": 5, "owned_groups_count": 1,
         "retail_min": 99.0},
    ]
    r = patched.client.get("/api/store/search?q=knicks")
    body = r.json()
    assert body["source"] == "live"
    ids = [e["id"] for e in body["events"]]
    assert 1 in ids and 2 not in ids
    assert body["events"][0]["we_own"] is True
    assert body["performers"][0]["id"] == 10
    assert body["venues"][0]["id"] == 20


def test_search_live_tevo_unconfigured_fallback(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_players", lambda *a: [])
    monkeypatch.setattr(app_module, "ensure_tevo_client", lambda: None)
    monkeypatch.setattr(app_module, "_search_sql_only",
                        lambda db, q, lim: {"events": [], "performers": [],
                                            "venues": [], "source": "sql"})
    r = patched.client.get("/api/store/search?q=knicks")
    body = r.json()
    assert body["fallback"] is True
    assert body["fallback_reason"] == "tevo_unconfigured"


def test_search_live_tevo_error_fallback_with_status(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_players", lambda *a: [])
    fake = _FakeEvo({})
    fake.suggest_raises = True  # raises "TEvo API 503 upstream"
    monkeypatch.setattr(app_module, "ensure_tevo_client", lambda: fake)
    monkeypatch.setattr(app_module, "_search_sql_only",
                        lambda db, q, lim: {"events": [], "performers": [],
                                            "venues": [], "source": "sql"})
    r = patched.client.get("/api/store/search?q=knicks")
    body = r.json()
    assert body["fallback"] is True
    assert body["fallback_reason"] == "tevo_unavailable"
    assert body["fallback_detail"]["tevo_status"] == 503


def test_search_live_metrics_failure_swallowed(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_players", lambda *a: [])
    fake = _FakeEvo({})
    fake.suggest_resp = {"suggestions": {
        "events": [{"id": 1, "name": "Real Game"}],
        "performers": [], "venues": [],
    }}
    monkeypatch.setattr(app_module, "ensure_tevo_client", lambda: fake)

    class _RaiseDB(_FakeDB):
        def table(self, name):
            raise RuntimeError("metrics down")
    monkeypatch.setattr(app_module, "require_sb", lambda: _RaiseDB())
    r = patched.client.get("/api/store/search?q=knicks")
    # metrics dict stays empty -> we_own False, but route still 200s.
    assert r.json()["events"][0]["we_own"] is False


# ----- _search_players helper exercised directly via the live path ----- #

def test_search_players_full(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", True)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_sql_only",
                        lambda db, q, lim: {"events": [], "performers": [],
                                            "venues": [], "source": "sql"})
    db = _FakeDB()
    db.rpc_returns["sports_player_search"] = [{
        "tevo_performer_id": 99, "full_name": "Le Bron", "team_name": "Lakers",
        "espn_league": "NBA", "position_abbr": "SF", "jersey": "23",
        "status": "active", "headshot_url": "h.png",
        "events": [
            {"tevo_event_id": 1, "name": "Real Game", "venue_name": "MSG",
             "venue_location": "NY", "occurs_at_local": "2026-07-01"},
            {"tevo_event_id": 2, "name": "Game (If Necessary)"},  # speculative
            {"tevo_event_id": 3, "name": "Inactive Game"},
            {"tevo_event_id": 0, "name": "No id"},
        ],
    }]
    db.tables["latest_event_metrics"] = [
        {"event_id": 1, "owned_tickets_count": 4, "retail_min": 80.0},
    ]
    db.tables["event_lifecycle"] = [{"event_id": 3, "is_active": False}]
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    r = patched.client.get("/api/store/search?q=lebron")
    players = r.json()["players"]
    assert len(players) == 1
    p = players[0]
    assert p["performer_id"] == 99 and p["name"] == "Le Bron"
    # event 1 kept; 2 (speculative), 3 (inactive), 0 (no id) dropped.
    assert [e["id"] for e in p["events"]] == [1]
    assert p["events"][0]["we_own"] is True


def test_search_players_rpc_failure_returns_empty(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", True)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_sql_only",
                        lambda db, q, lim: {"events": [], "performers": [],
                                            "venues": [], "source": "sql"})
    db = _FakeDB()
    db.rpc_raises.add("sports_player_search")
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    r = patched.client.get("/api/store/search?q=lebron")
    assert r.json()["players"] == []


def test_search_players_no_results(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", True)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_sql_only",
                        lambda db, q, lim: {"events": [], "performers": [],
                                            "venues": [], "source": "sql"})
    db = _FakeDB()
    db.rpc_returns["sports_player_search"] = []  # empty -> early return []
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    r = patched.client.get("/api/store/search?q=nobody")
    assert r.json()["players"] == []


def test_search_players_metrics_and_lifecycle_failures(patched, monkeypatch):
    monkeypatch.setattr(app_module, "STOREFRONT_SEARCH_SQL_ONLY", True)
    monkeypatch.setattr(app_module, "STOREFRONT_SQL_ONLY", False)
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_search_sql_only",
                        lambda db, q, lim: {"events": [], "performers": [],
                                            "venues": [], "source": "sql"})

    class _DB(_FakeDB):
        def table(self, name):
            raise RuntimeError(f"{name} down")
    db = _DB()
    db.rpc_returns["sports_player_search"] = [{
        "tevo_performer_id": 7, "full_name": "Player", "team_name": "T",
        "events": [{"tevo_event_id": 5, "name": "Game",
                    "occurs_at_local": "2026-07-01"}],
    }]
    monkeypatch.setattr(app_module, "require_sb", lambda: db)
    r = patched.client.get("/api/store/search?q=player")
    # Both metrics + lifecycle table reads raise -> swallowed; event still kept.
    players = r.json()["players"]
    assert players[0]["events"][0]["id"] == 5
    assert players[0]["events"][0]["we_own"] is False


# ----- search-cache helper unit tests ----- #

def test_search_cache_get_expired_pops(monkeypatch):
    monkeypatch.setattr(app_module, "_search_cache", {})
    monkeypatch.setattr(app_module, "_SEARCH_CACHE_TTL", 0.0)  # everything stale
    app_module._search_cache["k"] = (0.0, {"x": 1})
    assert app_module._search_cache_get("k") is None  # expiry pop branch
    assert "k" not in app_module._search_cache
    # miss path
    assert app_module._search_cache_get("absent") is None


def test_search_cache_put_evicts_oldest_over_200(monkeypatch):
    monkeypatch.setattr(app_module, "_search_cache", {})
    # Seed 200 entries with ascending timestamps; the oldest is "k0".
    for i in range(200):
        app_module._search_cache[f"k{i}"] = (float(i), {"i": i})
    app_module._search_cache_put("new", {"i": "new"})  # 201 -> evict oldest
    assert "k0" not in app_module._search_cache
    assert "new" in app_module._search_cache


# ========================================================================== #
# /api/store/concierge
# ========================================================================== #

def test_concierge_returns_events(patched):
    from datetime import date, timedelta
    occ = (date.today() + timedelta(days=10)).isoformat()
    patched.db.tables["concierge_events"] = [{
        "event_id": 1, "name": "Premium Night", "venue_name": "MSG",
        "venue_location": "New York, NY", "occurs_at_local": "2026-07-01",
        "occurs_date": occ, "from_price": 500.0, "prem_max_price": 1200.0,
        "prem_tickets": 4, "primary_performer_name": "Knicks",
    }]
    r = patched.client.get("/api/store/concierge?city=NYC&days=60&limit=18")
    body = r.json()
    assert body["count"] == 1
    ev = body["events"][0]
    # The route remaps event_id -> id via {**r, "id": r.pop("event_id")};
    # the spread copies event_id before pop mutates the original, so the
    # response card carries BOTH keys with the same value.
    assert ev["id"] == 1
    assert ev["from_price"] == 500.0


def test_concierge_query_failure_returns_empty(patched, monkeypatch):
    class _DB(_FakeDB):
        def table(self, name):
            raise RuntimeError("concierge view missing")
    monkeypatch.setattr(app_module, "require_sb", lambda: _DB())
    r = patched.client.get("/api/store/concierge")
    assert r.json() == {"count": 0, "events": []}


def test_concierge_days_clamped(patched):
    patched.db.tables["concierge_events"] = []
    r = patched.client.get("/api/store/concierge?days=999&limit=999")
    assert r.json()["count"] == 0


# ========================================================================== #
# /api/store/movers  (cache wrapper)
# ========================================================================== #

def _reset_movers(monkeypatch):
    monkeypatch.setattr(app_module, "_movers_cache", {})
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_REFRESHING", set())


def test_movers_cold_then_fresh(patched, monkeypatch):
    _reset_movers(monkeypatch)
    calls = {"n": 0}

    def _compute(db, city, days, cap):
        calls["n"] += 1
        return {"city": city, "count": calls["n"], "events": []}
    monkeypatch.setattr(app_module, "_compute_movers", _compute)
    r1 = patched.client.get("/api/store/movers?city=NYC&days=21&limit=8")
    r2 = patched.client.get("/api/store/movers?city=NYC&days=21&limit=8")
    assert calls["n"] == 1  # second is a fresh cache hit
    assert r1.json() == r2.json()


def test_movers_stale_schedules_refresh(patched, monkeypatch):
    _reset_movers(monkeypatch)
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_TTL", 0.0)  # everything stale
    calls = {"n": 0}

    def _compute(db, city, days, cap):
        calls["n"] += 1
        return {"city": city, "count": calls["n"], "events": []}
    monkeypatch.setattr(app_module, "_compute_movers", _compute)
    patched.client.get("/api/store/movers?city=NYC")     # cold compute (n=1)
    r2 = patched.client.get("/api/store/movers?city=NYC")  # stale -> bg refresh
    # Stale branch serves the old payload synchronously...
    assert r2.json()["count"] == 1
    # ...and the background task ran the refresh (n=2) after the response.
    assert calls["n"] == 2


def test_movers_stale_refresh_in_flight_not_duplicated(patched, monkeypatch):
    _reset_movers(monkeypatch)
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_TTL", 0.0)
    key = app_module._movers_cache_key("NYC", 21, 8)
    # Pre-seed a stale entry + mark the key as already refreshing.
    monkeypatch.setattr(app_module, "_movers_cache", {key: (0.0, {"count": 7})})
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_REFRESHING", {key})
    calls = {"n": 0}

    def _compute(db, city, days, cap):
        calls["n"] += 1
        return {"count": calls["n"]}
    monkeypatch.setattr(app_module, "_compute_movers", _compute)
    r = patched.client.get("/api/store/movers?city=NYC&days=21&limit=8")
    assert r.json()["count"] == 7      # stale payload returned
    assert calls["n"] == 0             # no refresh scheduled (already in flight)


def test_refresh_movers_success(patched, monkeypatch):
    _reset_movers(monkeypatch)
    monkeypatch.setattr(app_module, "require_sb", lambda: None)
    monkeypatch.setattr(app_module, "_compute_movers",
                        lambda db, c, d, l: {"ok": True})
    key = "NYC|21|8"
    app_module._MOVERS_CACHE_REFRESHING.add(key)
    app_module._refresh_movers("NYC", 21, 8, key)
    assert app_module._movers_cache[key][1] == {"ok": True}
    assert key not in app_module._MOVERS_CACHE_REFRESHING


def test_refresh_movers_failure_clears_flag(patched, monkeypatch):
    _reset_movers(monkeypatch)
    monkeypatch.setattr(app_module, "require_sb", lambda: None)

    def _boom(db, c, d, l):
        raise RuntimeError("compute down")
    monkeypatch.setattr(app_module, "_compute_movers", _boom)
    key = "NYC|21|8"
    app_module._MOVERS_CACHE_REFRESHING.add(key)
    app_module._refresh_movers("NYC", 21, 8, key)  # must not raise
    assert key not in app_module._MOVERS_CACHE_REFRESHING
    assert key not in app_module._movers_cache


# ========================================================================== #
# /api/store/home
# ========================================================================== #

def test_home_empty_lem(patched):
    patched.db.tables = {"latest_event_metrics": []}
    r = patched.client.get("/api/store/home")
    body = r.json()
    assert body["count"] == 0 and body["events"] == [] and body["source"] == "sql"


def test_home_full_enrichment_and_premium_sort(patched):
    patched.db.tables = {
        "latest_event_metrics": [
            _lem(1, owned=10, retail_min=1500.0),  # premium
            _lem(2, owned=50, retail_min=20.0),    # not premium, sooner
        ],
        "events": [
            _event(1, performer_ids=[16303, 55578]),
            _event(2),
        ],
        "event_lifecycle": [_lc(1), _lc(2)],
    }
    r = patched.client.get("/api/store/home")
    body = r.json()
    by_id = {e["id"]: e for e in body["events"]}
    assert by_id[1]["signal"] == "premium"
    assert by_id[2]["signal"] is None
    # Away performer enrichment from performer_ids second entry.
    assert by_id[1]["away_performer_id"] == 55578
    assert by_id[1]["away_performer_name"] == "Cavaliers"
    assert by_id[1]["from_price"] == 1500.0
    assert body["events"][0]["id"] == 1  # premium first


def test_home_lem_failure_returns_empty(patched, monkeypatch):
    class _DB(_FakeDB):
        def table(self, name):
            raise RuntimeError("LEM down")
    monkeypatch.setattr(app_module, "require_sb", lambda: _DB())
    r = patched.client.get("/api/store/home")
    assert r.json()["count"] == 0


def test_home_events_query_failure_returns_empty(patched, monkeypatch):
    class _DB(_FakeDB):
        def __init__(self):
            super().__init__({"latest_event_metrics": [_lem(1)]})

        def table(self, name):
            if name == "events":
                raise RuntimeError("events down")
            return super().table(name)
    monkeypatch.setattr(app_module, "require_sb", lambda: _DB())
    r = patched.client.get("/api/store/home")
    assert r.json()["count"] == 0
    assert r.json()["source"] == "sql"


def test_home_inactive_dropped(patched):
    patched.db.tables = {
        "latest_event_metrics": [_lem(1), _lem(2)],
        "events": [_event(1), _event(2)],
        "event_lifecycle": [_lc(1, True), _lc(2, False)],
    }
    r = patched.client.get("/api/store/home")
    assert [e["id"] for e in r.json()["events"]] == [1]


def test_home_lifecycle_query_failure_swallowed(patched, monkeypatch):
    class _DB(_FakeDB):
        def __init__(self):
            super().__init__({
                "latest_event_metrics": [_lem(1)],
                "events": [_event(1)],
            })

        def table(self, name):
            if name == "event_lifecycle":
                raise RuntimeError("lc down")
            return super().table(name)
    monkeypatch.setattr(app_module, "require_sb", lambda: _DB())
    r = patched.client.get("/api/store/home")
    # lifecycle read raises -> inactive set empty -> event kept.
    assert [e["id"] for e in r.json()["events"]] == [1]


def test_home_speculative_dropped_empty_after_filter(patched):
    patched.db.tables = {
        "latest_event_metrics": [_lem(1)],
        "events": [_event(1, name="Game (If Necessary)")],
        "event_lifecycle": [_lc(1)],
    }
    r = patched.client.get("/api/store/home")
    # Only event was speculative -> events_by_id empty -> early empty return.
    assert r.json()["count"] == 0


def test_home_city_filter(patched):
    patched.db.tables = {
        "latest_event_metrics": [_lem(i) for i in (1, 2, 3)],
        "events": [
            _event(1, venue_location="Bronx, NY"),
            _event(2, venue_location="Los Angeles, CA"),
            _event(3, venue_location="Somewhere, NY"),  # matches ", NY"
        ],
        "event_lifecycle": [_lc(i) for i in (1, 2, 3)],
    }
    r = patched.client.get("/api/store/home?city=NYC")
    assert sorted(e["id"] for e in r.json()["events"]) == [1, 3]


def test_home_city_filter_empties_returns_early(patched):
    patched.db.tables = {
        "latest_event_metrics": [_lem(1)],
        "events": [_event(1, venue_location="Los Angeles, CA")],
        "event_lifecycle": [_lc(1)],
    }
    r = patched.client.get("/api/store/home?city=NYC")
    assert r.json()["count"] == 0


def test_home_performer_id_coercion_edges(patched):
    # primary_performer_id None + a bad performer_ids entry exercise the
    # try/except coercion branches without crashing.
    ev = _event(1, performer_id=None, performer_ids=["bad", 55578])
    patched.db.tables = {
        "latest_event_metrics": [_lem(1)],
        "events": [ev],
        "event_lifecycle": [_lc(1)],
    }
    r = patched.client.get("/api/store/home")
    card = r.json()["events"][0]
    assert card["primary_performer_id"] is None
    # First valid (non-primary) performer_ids entry becomes away.
    assert card["away_performer_id"] == 55578


def test_home_non_int_primary_id_and_bad_retail_min(patched):
    # primary_performer_id is a truthy non-int string -> exercises the
    # TypeError/ValueError coercion branches in BOTH the perf_ids gather
    # (4753-4754) and the per-card int() (4769-4770). retail_min a
    # non-numeric string -> float() raises -> rm None (4788-4789).
    ev = _event(1, performer_id="not-a-number")
    lem = _lem(1)
    lem["retail_min"] = "free"
    patched.db.tables = {
        "latest_event_metrics": [lem],
        "events": [ev],
        "event_lifecycle": [_lc(1)],
    }
    r = patched.client.get("/api/store/home")
    card = r.json()["events"][0]
    assert card["primary_performer_logo"] is None  # primary_pid coerced None
    assert card["from_price"] is None              # bad retail_min -> None
    assert card["signal"] is None


def test_home_retail_min_none_no_signal(patched):
    lem = _lem(1)
    lem["retail_min"] = None
    patched.db.tables = {
        "latest_event_metrics": [lem],
        "events": [_event(1)],
        "event_lifecycle": [_lc(1)],
    }
    r = patched.client.get("/api/store/home")
    card = r.json()["events"][0]
    assert card["from_price"] is None
    assert card["signal"] is None


def test_home_limit_clamped(patched):
    patched.db.tables = {
        "latest_event_metrics": [_lem(i) for i in range(1, 6)],
        "events": [_event(i) for i in range(1, 6)],
        "event_lifecycle": [_lc(i) for i in range(1, 6)],
    }
    r = patched.client.get("/api/store/home?limit=2")
    body = r.json()
    assert body["count"] == 2 and body["limit"] == 2


def test_events_non_int_performer_ids_do_not_500(patched):
    """A non-numeric performer id must not crash the catalog (regression for the
    unguarded int(pid) gather bug). The event still renders, just without
    performer assets. Exercises the three int()-coercion guards in the handler:
    the perf_ids gather + the primary and away per-card coercions."""
    ev = _tevo_ev(7, performances=[
        {"primary": True, "performer": {"id": "not-an-int", "name": "Home"}},
        {"primary": False, "performer": {"id": "also-bad", "name": "Away"}},
    ])
    _set_evo(patched, _FakeEvo({1: [ev]}))
    r = patched.client.get("/api/store/events?limit=1")
    assert r.status_code == 200
    card = r.json()["events"][0]
    # Bad ids coerced to None -> no assets attached, but the card still renders.
    assert card["primary_performer_logo"] is None
    assert card["primary_performer_league"] is None
