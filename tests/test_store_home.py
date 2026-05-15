"""Tests for /api/store/home and the /api/store/movers PostgREST comma-pattern fix.

/api/store/home is the SQL-only first-paint endpoint that joins
latest_event_metrics + events + event_lifecycle + performer_metadata,
returning enriched cards (from_price, owned counts, premium signal) in
<50ms. Catalog endpoint (/api/store/events) leaves from_price and
owned_tickets_count null on the TEvo-direct path, so /api/store/home is
what gives the home grid prices on first paint.

Velocity signals (selling_fast / demand_rising) intentionally NOT served
by this endpoint — joining v_event_velocity_windows was 702ms of the 738ms
total in the original design (95% of latency). They live on
/api/store/movers instead, surfaced in a separate strip below the grid.

/api/store/movers was returning count:0 in prod despite 17/18 NYC owned
events qualifying — the literal comma in the hardcoded "%, NY%" pattern was
being interpreted by PostgREST as a clause separator. Fix landed in
_or_ilike_clause helper.

These tests use a minimal FakeSupabaseClient that supports the fluent chain
(.table().select().gt().in_().gte().limit().execute()) and returns
programmable data per table. No real Supabase or TEvo calls.

Audit ref: F1 (catalog enrichment gap) + F5 (movers comma bug) +
docs/d1-bot-continues-here-rustling-sunrise.md §7d / §8.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

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

import app as app_module  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------- Fake Supabase client ----------
#
# Mirrors the supabase-py fluent API just enough to exercise the chains used
# by /api/store/home and /api/store/movers. Each method returns self so we
# can collect filter args; .execute() returns a _Response with .data set
# from the programmable table_data dict.

class _Response:
    def __init__(self, data):
        self.data = data


class _FakeTable:
    def __init__(self, table_name: str, all_rows: list[dict]):
        self.name = table_name
        self._rows = list(all_rows)
        # Filter state — applied at .execute() time so order-of-call doesn't
        # matter. Production code mixes select/filter order freely.
        self._select_cols: str | None = None
        self._filters: list[tuple] = []
        self._limit: int | None = None
        self._or_clauses: str | None = None

    def select(self, cols: str):
        self._select_cols = cols
        return self

    def gt(self, col: str, val):
        self._filters.append(("gt", col, val))
        return self

    def gte(self, col: str, val):
        self._filters.append(("gte", col, val))
        return self

    def lte(self, col: str, val):
        self._filters.append(("lte", col, val))
        return self

    def eq(self, col: str, val):
        self._filters.append(("eq", col, val))
        return self

    def in_(self, col: str, vals):
        self._filters.append(("in_", col, list(vals)))
        return self

    def ilike(self, col: str, pat: str):
        self._filters.append(("ilike", col, pat))
        return self

    def or_(self, clauses: str):
        self._or_clauses = clauses
        return self

    def order(self, *_args, **_kw):
        return self

    def limit(self, n: int):
        self._limit = n
        return self

    def _matches_one(self, row, op, col, val):
        if op == "gt":
            v = row.get(col)
            try:
                return v is not None and float(v) > float(val)
            except (TypeError, ValueError):
                return False
        if op == "gte":
            v = row.get(col)
            if v is None:
                return False
            return str(v) >= str(val)
        if op == "lte":
            v = row.get(col)
            if v is None:
                return False
            return str(v) <= str(val)
        if op == "eq":
            return row.get(col) == val
        if op == "in_":
            return row.get(col) in val
        if op == "ilike":
            # crude wildcard match: pattern uses %; row value substring match
            v = (row.get(col) or "")
            stripped = pat = val.strip("%")
            return stripped.lower() in v.lower()
        return True

    def execute(self):
        out = []
        for row in self._rows:
            if all(self._matches_one(row, op, col, val) for op, col, val in self._filters):
                out.append(row)
        if self._limit is not None:
            out = out[: self._limit]
        return _Response(out)


class _FakeDB:
    def __init__(self, tables: dict[str, list[dict]]):
        self.tables = tables
        self.table_calls: list[str] = []

    def table(self, name: str) -> _FakeTable:
        self.table_calls.append(name)
        return _FakeTable(name, self.tables.get(name, []))


# ---------- Helpers ----------

def _lem(eid: int, owned: int = 100, retail_min: float = 50.0,
         captured: str = "2026-05-14 16:00:00+00") -> dict:
    return {
        "event_id": eid,
        "owned_tickets_count": owned,
        "owned_groups_count": max(1, owned // 5),
        "retail_min": retail_min,
        "retail_median": retail_min * 2,
        "retail_p25": retail_min * 1.5,
        "retail_p75": retail_min * 2.5,
        "getin_price": retail_min,
        "captured_at": captured,
        "tickets_count": owned * 3,
    }


def _event(eid: int, name: str = None, occurs: str = "2026-06-01T19:00:00-04:00",
           venue_location: str = "New York, NY", performer_id: int = 16303,
           performer_name: str = "Test Team") -> dict:
    return {
        "id": eid,
        "name": name or f"Test Event {eid}",
        "occurs_at_local": occurs,
        "venue_id": 896,
        "venue_name": "Test Venue",
        "venue_location": venue_location,
        "primary_performer_id": performer_id,
        "primary_performer_name": performer_name,
        "tbd": False,
    }


def _lc(eid: int, active: bool = True) -> dict:
    return {"event_id": eid, "is_active": active}


@pytest.fixture
def store_home_client(monkeypatch):
    """TestClient with require_sb stubbed to return a programmable FakeDB.
    The FakeDB is bolted on as `monkeypatch.fakedb` so individual tests can
    populate it."""
    fake_db = _FakeDB({})
    monkeypatch.setattr(app_module, "require_sb", lambda: fake_db)
    monkeypatch.setattr(
        app_module, "_bulk_performer_assets",
        lambda db, pids: {
            16303: {"logo_default_url": "https://test/knicks.png",
                    "color_primary": "1d428a", "espn_league": "NBA"},
            55578: {"logo_default_url": None, "color_primary": None,
                    "espn_league": None},
        },
    )
    client = TestClient(app_module.app)
    client.fakedb = fake_db  # type: ignore[attr-defined]
    return client


# ---------- /api/store/home tests ----------

def test_home_empty_when_no_owned_events(store_home_client):
    """If LEM returns nothing, the endpoint serves an empty grid cleanly
    rather than 500-ing. Resilience baseline."""
    store_home_client.fakedb.tables = {"latest_event_metrics": []}
    r = store_home_client.get("/api/store/home")
    assert r.status_code == 200
    body = r.json()
    assert body["count"] == 0
    assert body["events"] == []
    assert body["source"] == "sql"


def test_home_returns_owned_with_enrichment(store_home_client):
    """The whole point of /api/store/home — return events with from_price and
    owned_tickets_count populated (which catalog endpoint leaves null)."""
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [_lem(1, owned=100, retail_min=25.0)],
        "events": [_event(1)],
        "event_lifecycle": [_lc(1, active=True)],
    }
    r = store_home_client.get("/api/store/home")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["count"] == 1
    ev = body["events"][0]
    assert ev["id"] == 1
    assert ev["from_price"] == 25.0, "from_price must be populated"
    assert ev["owned_tickets_count"] == 100, "owned_tix must be populated"
    assert ev["we_own"] is True
    # Performer enrichment from the stubbed assets dict.
    assert ev["primary_performer_logo"] == "https://test/knicks.png"
    assert ev["primary_performer_color"] == "1d428a"


def test_home_drops_inactive_events(store_home_client):
    """event_lifecycle.is_active=false rows are filtered out so ghost/
    cancelled events never appear on the home grid."""
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [
            _lem(1, owned=100), _lem(2, owned=200),
        ],
        "events": [_event(1), _event(2)],
        "event_lifecycle": [_lc(1, active=True), _lc(2, active=False)],
    }
    r = store_home_client.get("/api/store/home")
    assert r.status_code == 200
    out_ids = [e["id"] for e in r.json()["events"]]
    assert out_ids == [1], f"inactive event 2 should be dropped, got {out_ids}"


def test_home_signal_classification(store_home_client):
    """After dropping the v_event_velocity_windows join (perf optimization —
    EXPLAIN ANALYZE showed 702ms / 95% of latency was that view), the home
    grid only classifies `premium` (retail_min >= $500). selling_fast +
    demand_rising live on /api/store/movers, a separate endpoint surfaced
    in <section id="moversStrip"> below the grid.

    Order: premium → others, with date asc as the tiebreaker.
    """
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [
            # event 1: premium (expensive)
            _lem(1, owned=10, retail_min=1500.0),
            # event 2: cheap, NOT premium even with big d24h drop — no
            # velocity join means we can't see d24h, so signal is null.
            _lem(2, owned=50, retail_min=20.0),
            # event 3: cheap, NOT premium
            _lem(3, owned=5, retail_min=15.0),
        ],
        "events": [
            _event(1, occurs="2026-06-15T19:00:00-04:00"),
            _event(2, occurs="2026-05-20T19:00:00-04:00"),
            _event(3, occurs="2026-05-25T19:00:00-04:00"),
        ],
        "event_lifecycle": [_lc(i) for i in [1, 2, 3]],
    }
    r = store_home_client.get("/api/store/home")
    assert r.status_code == 200
    body = r.json()
    by_id = {e["id"]: e for e in body["events"]}
    assert by_id[1]["signal"] == "premium"
    assert by_id[2]["signal"] is None, "cheap event must not get a signal"
    assert by_id[3]["signal"] is None, "cheap event must not get a signal"
    # Order: premium first, then by date asc (event 2 before event 3).
    order = [e["id"] for e in body["events"]]
    assert order == [1, 2, 3], (
        f"sort must be premium first, then date asc; got {order}"
    )


def test_home_velocity_fields_always_null(store_home_client):
    """Renderer-compatibility: tix_d24h + getin_d24h_pct stay in the response
    schema (so store.js's card renderer doesn't break) but are always null
    on this endpoint. The values live on /api/store/movers instead."""
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [_lem(1, owned=100, retail_min=1500.0)],
        "events": [_event(1)],
        "event_lifecycle": [_lc(1)],
    }
    r = store_home_client.get("/api/store/home")
    ev = r.json()["events"][0]
    assert "tix_d24h" in ev and ev["tix_d24h"] is None
    assert "getin_d24h_pct" in ev and ev["getin_d24h_pct"] is None


def test_home_tbd_detected_from_name(store_home_client):
    """events.tbd column doesn't exist in our SQL schema — TBD is detected
    from the event name string via _is_tbd(). Patterns observed in prod:
    "(Date TBD)", "Date and Time TBD", "(If Necessary)".
    """
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [_lem(i, retail_min=1000.0) for i in [1, 2, 3, 4]],
        "events": [
            _event(1, name="TBD at New York Knicks (Round 3 - Home Game 1) (Date TBD)"),
            _event(2, name="TBD at New York Knicks (NBA Finals - Home Game 1) (If Necessary)"),
            _event(3, name="Some Concert (Date and Time TBD)"),
            _event(4, name="Real Scheduled Game"),
        ],
        "event_lifecycle": [_lc(i) for i in [1, 2, 3, 4]],
    }
    r = store_home_client.get("/api/store/home")
    by_id = {e["id"]: e for e in r.json()["events"]}
    assert by_id[1]["tbd"] is True, "(Date TBD) must be detected"
    assert by_id[2]["tbd"] is True, "(If Necessary) must be detected"
    assert by_id[3]["tbd"] is True, "Date and Time TBD must be detected"
    assert by_id[4]["tbd"] is False, "ordinary scheduled event must not be flagged tbd"


def test_is_tbd_helper_unit():
    """Unit test for the helper directly — case-insensitive + handles None."""
    assert app_module._is_tbd("TBD at Knicks (Date TBD)") is True
    assert app_module._is_tbd("Real Game (If Necessary)") is True
    assert app_module._is_tbd("Concert · Date and Time TBD") is True
    assert app_module._is_tbd("(date tbd)") is True  # case-insensitive
    assert app_module._is_tbd("Yankees vs Red Sox") is False
    assert app_module._is_tbd("") is False
    assert app_module._is_tbd(None) is False


def test_home_city_nyc_filters_correctly(store_home_client):
    """city=NYC restricts to NYC-area venues. Bronx + Flushing + Manhattan
    all pass; LA + Chicago must not."""
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [_lem(i) for i in [1, 2, 3, 4, 5]],
        "events": [
            _event(1, venue_location="Bronx, NY"),       # NYC ✓
            _event(2, venue_location="Flushing, NY"),    # NYC ✓
            _event(3, venue_location="Manhattan, NY"),   # NYC ✓
            _event(4, venue_location="Los Angeles, CA"), # not NYC
            _event(5, venue_location="Chicago, IL"),     # not NYC
        ],
        "event_lifecycle": [_lc(i) for i in [1, 2, 3, 4, 5]],
    }
    r = store_home_client.get("/api/store/home?city=NYC")
    out_ids = sorted([e["id"] for e in r.json()["events"]])
    assert out_ids == [1, 2, 3], f"NYC filter must keep 1/2/3, drop 4/5, got {out_ids}"


def test_home_respects_limit_param(store_home_client):
    """limit caps the response. Default 60, request smaller works, request
    bigger than 100 caps at 100."""
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [_lem(i) for i in range(1, 11)],
        "events": [_event(i) for i in range(1, 11)],
        "event_lifecycle": [_lc(i) for i in range(1, 11)],
    }
    r = store_home_client.get("/api/store/home?limit=3")
    body = r.json()
    assert body["count"] == 3
    assert body["limit"] == 3


def test_home_drops_cancelled_name_rows(store_home_client):
    """Events with CANCELLED in the name (case-insensitive) are filtered
    out — matches /api/store/events behavior."""
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [_lem(1), _lem(2)],
        "events": [
            _event(1, name="Real Event"),
            _event(2, name="CANCELLED — Postponed Show"),
        ],
        "event_lifecycle": [_lc(1), _lc(2)],
    }
    r = store_home_client.get("/api/store/home")
    out_ids = [e["id"] for e in r.json()["events"]]
    assert out_ids == [1], f"CANCELLED row should be dropped, got {out_ids}"


def test_home_no_tevo_call(store_home_client, monkeypatch):
    """The whole point is no-TEvo-on-cold-load. Replace app.client with an
    object whose .list_events raises — the endpoint must never invoke it."""
    class _NeverCallClient:
        def list_events(self, **_):
            raise AssertionError(
                "/api/store/home must NOT call TEvo; SQL-only contract violated"
            )
        def get_event(self, _):
            raise AssertionError(
                "/api/store/home must NOT call TEvo; SQL-only contract violated"
            )
    monkeypatch.setattr(app_module, "client", _NeverCallClient())
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [_lem(1)],
        "events": [_event(1)],
        "event_lifecycle": [_lc(1)],
    }
    r = store_home_client.get("/api/store/home")
    assert r.status_code == 200
    assert r.json()["source"] == "sql"


def test_home_lem_failure_returns_empty_not_500(store_home_client):
    """If the LEM matview read raises, the homepage must serve an empty grid
    rather than 500. UX contract: home view never breaks the storefront."""
    class _ExplodingTable:
        def __getattr__(self, name):
            raise RuntimeError("LEM down")

    class _ExplodingDB:
        def table(self, _):
            return _ExplodingTable()
    store_home_client.fakedb = _ExplodingDB()  # type: ignore[assignment]
    # Re-patch require_sb so it returns the exploding db.
    app_module.require_sb = lambda: store_home_client.fakedb  # type: ignore[assignment]
    r = store_home_client.get("/api/store/home")
    assert r.status_code == 200
    assert r.json()["count"] == 0


# ---------- _or_ilike_clause unit tests (movers fix) ----------

def test_or_ilike_clause_unquoted_for_safe_pattern():
    """Patterns without reserved chars stay unquoted so PostgREST parses
    them as a normal value. Backward-compatible with existing sites."""
    out = app_module._or_ilike_clause("venue_location", "%New York%")
    assert out == "venue_location.ilike.%New York%"


def test_or_ilike_clause_quoted_for_comma_pattern():
    """Patterns containing a literal comma MUST be double-quoted, or
    PostgREST treats the comma as a clause separator and the OR list
    silently breaks. This is the exact bug that broke /api/store/movers."""
    out = app_module._or_ilike_clause("venue_location", "%, NY%")
    assert out == 'venue_location.ilike."%, NY%"'


def test_or_ilike_clause_quoted_for_paren_pattern():
    """Parens also conflict with the or-clause grouping syntax."""
    out = app_module._or_ilike_clause("name", "%Subway Series (NL)%")
    assert out == 'name.ilike."%Subway Series (NL)%"'


def test_or_ilike_clause_escapes_embedded_double_quote():
    """PostgREST quoting: embedded double quotes are doubled."""
    out = app_module._or_ilike_clause("name", '%He said "yes",%')
    # The pattern contains both a comma and a double quote — both get
    # quoting treatment. The embedded " is doubled to "".
    assert out == 'name.ilike."%He said ""yes"",%"'


# ---------- Storefront cache-bust helper ----------

def test_store_home_html_includes_version_query_string(store_home_client, monkeypatch):
    """The /store HTML must rewrite static asset URLs to include `?v=<sha>`
    so browser caches invalidate on every deploy. Without this, frontend
    fixes appear undeployed for hours from the operator's perspective."""
    # Force a deterministic version for the test by clearing the in-memory
    # cache and stubbing the version constant.
    monkeypatch.setattr(app_module, "_STOREFRONT_VERSION", "abc1234")
    monkeypatch.setattr(app_module, "_STOREFRONT_HTML_CACHE", {})
    r = store_home_client.get("/store")
    assert r.status_code == 200
    body = r.text
    assert '/static/store/store.js?v=abc1234"' in body, (
        "store.js URL must include ?v=<sha> query string"
    )
    assert '/static/store/style.css?v=abc1234"' in body, (
        "style.css URL must include ?v=<sha> query string"
    )
    # Negative: the un-versioned URL should not appear anywhere in the
    # served HTML (we don't want a half-rewritten shell).
    assert '/static/store/store.js"' not in body
    assert '/static/store/style.css"' not in body


def test_build_storefront_version_prefers_render_git_commit(monkeypatch):
    """Render auto-sets RENDER_GIT_COMMIT to the full SHA on every deploy;
    we use the first 7 chars."""
    monkeypatch.setenv("RENDER_GIT_COMMIT", "deadbeefcafe0123456789abcdef")
    monkeypatch.delenv("GIT_COMMIT", raising=False)
    assert app_module._build_storefront_version() == "deadbee"


def test_build_storefront_version_falls_back_to_git_commit(monkeypatch):
    """Defensive fallback for CI/workflows that set GIT_COMMIT instead."""
    monkeypatch.delenv("RENDER_GIT_COMMIT", raising=False)
    monkeypatch.setenv("GIT_COMMIT", "1234567890abcdef")
    assert app_module._build_storefront_version() == "1234567"


def test_build_storefront_version_dev_when_unset(monkeypatch):
    """Both env vars unset → 'dev' literal. Local-dev behavior; in prod
    Render always sets RENDER_GIT_COMMIT so this branch only fires by
    accident."""
    monkeypatch.delenv("RENDER_GIT_COMMIT", raising=False)
    monkeypatch.delenv("GIT_COMMIT", raising=False)
    assert app_module._build_storefront_version() == "dev"


def test_store_html_response_has_no_cache_header(store_home_client):
    """Bootstrap-safety: /store HTML must include Cache-Control: no-cache
    so browsers revalidate on every page load and never get trapped on
    stale HTML pointing at un-versioned asset URLs.

    Without this header, a browser that cached /store before a cache-bust
    shipped would keep loading the old JS via the un-versioned URL until
    its heuristic cache expires (could be hours/days). The `?v=<sha>`
    query string on the asset URLs in PR #121 only helps once the BROWSER
    re-fetches /store and sees the new HTML — this header forces that
    re-fetch on every request.
    """
    r = store_home_client.get("/store")
    assert r.status_code == 200
    cc = r.headers.get("cache-control", "")
    assert "no-cache" in cc.lower(), (
        f"Cache-Control must include no-cache; got: {cc!r}"
    )


def test_all_storefront_html_routes_revalidate(store_home_client):
    """Every served /store/* HTML shell — index, event, share, shares —
    must carry the no-cache header. Catches a regression where someone
    swaps one route back to FileResponse or raw HTMLResponse without
    realizing the helper enforces revalidate.
    """
    # /store/event/{id} works without DB because the route only reads the
    # static HTML shell — the event_id is consumed by JS at runtime.
    paths = ["/store", "/store/event/3346000", "/s/test-id", "/store/shares"]
    for path in paths:
        r = store_home_client.get(path)
        assert r.status_code == 200, f"{path} → {r.status_code}"
        cc = r.headers.get("cache-control", "")
        assert "no-cache" in cc.lower(), (
            f"{path}: Cache-Control missing no-cache; got: {cc!r}"
        )
