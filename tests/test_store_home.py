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


def _event(eid: int, name: str = None, occurs: str = None,
           venue_location: str = "New York, NY", performer_id: int = 16303,
           performer_name: str = "Test Team") -> dict:
    # Relative default (not hardcoded) so the fixture event stays in the future
    # regardless of when the suite runs — store_home filters to upcoming events
    # via .gte("occurs_at_local", today). A fixed date silently became "past"
    # (the 2026-06-01 literal turned into a time-bomb on 2026-06-02). Same fix
    # already applied to the curation-order fixture (see _occurs() ~L291).
    if occurs is None:
        from datetime import date as _date, timedelta as _td
        occurs = f"{(_date.today() + _td(days=30)).isoformat()}T19:00:00-04:00"
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
    # Relative dates (not hardcoded) so the fixture events stay comfortably
    # in the future regardless of when the suite runs — store_home filters to
    # upcoming events, and a fixed date eventually becomes "today/past" and
    # silently drops the row (was a time-bomb: failed once real-time hit the
    # hardcoded 2026-05-20). Ordering preserved: event 2 < 3 < 1 by date.
    from datetime import date as _date, timedelta as _td
    def _occurs(days: int) -> str:
        return f"{(_date.today() + _td(days=days)).isoformat()}T19:00:00-04:00"
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
            _event(1, occurs=_occurs(26)),  # premium, far future
            _event(2, occurs=_occurs(2)),   # cheap, earliest non-premium
            _event(3, occurs=_occurs(7)),   # cheap, later
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
    from the event name string via _is_tbd().

    Updated 2026-05-16: "(If Necessary)" is now FILTERED at the speculative-
    event layer (sg_classify SKIP-override parity) rather than flagged with
    the tbd badge. Consumer surfaces should never surface playoff games
    that may not happen. "(Date TBD)" + "Date and Time TBD" still surface
    with the tbd badge — those games WILL happen, the time is just pending.
    See _is_speculative_event_name() vs _is_tbd().
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
    assert by_id[1]["tbd"] is True, "(Date TBD) must surface with tbd badge"
    assert 2 not in by_id, "(If Necessary) must be filtered out (speculative)"
    assert by_id[3]["tbd"] is True, "Date and Time TBD must surface with tbd badge"
    assert by_id[4]["tbd"] is False, "ordinary scheduled event must not be flagged tbd"


def test_home_speculative_events_filtered(store_home_client):
    """Consumer storefront drops CANCELLED + (If Necessary) — playoff games
    that may not happen. Mirrors broker-side sg_classify SKIP-override.
    Railway audit 2026-05-16 found these leaking; fix lands here."""
    store_home_client.fakedb.tables = {
        "latest_event_metrics": [_lem(i, retail_min=1000.0) for i in [1, 2, 3]],
        "events": [
            _event(1, name="Knicks vs Pacers G3 - CANCELLED"),
            _event(2, name="Pistons G7 (Home Game 4) (If Necessary)"),
            _event(3, name="Yankees vs Red Sox"),
        ],
        "event_lifecycle": [_lc(i) for i in [1, 2, 3]],
    }
    r = store_home_client.get("/api/store/home")
    by_id = {e["id"]: e for e in r.json()["events"]}
    assert 1 not in by_id, "CANCELLED games must not surface to consumers"
    assert 2 not in by_id, "(If Necessary) playoff placeholders must not surface"
    assert 3 in by_id, "real scheduled events must surface"


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


def test_csp_frame_ancestors_header_only_not_meta(store_home_client):
    """frame-ancestors is honored ONLY as an HTTP header, never in a <meta>
    CSP — browsers ignore it there and log a console error on every page
    load. So: the served HTML's <meta> CSP must NOT contain frame-ancestors,
    while the HTTP response header CSP MUST (clickjacking protection
    preserved). Guards against re-adding it to the meta tag."""
    r = store_home_client.get("/store")
    assert r.status_code == 200
    body = r.text
    # The meta CSP line must be present but without frame-ancestors.
    assert 'http-equiv="Content-Security-Policy"' in body
    # Isolate the meta tag content to avoid matching anything else.
    meta_idx = body.find('http-equiv="Content-Security-Policy"')
    meta_tag = body[meta_idx:body.find(">", meta_idx)]
    assert "frame-ancestors" not in meta_tag, (
        "frame-ancestors must not appear in the <meta> CSP (browsers ignore "
        "it there + log a console error)"
    )
    # HTTP-header CSP still enforces it.
    hdr_csp = r.headers.get("content-security-policy", "")
    assert "frame-ancestors 'none'" in hdr_csp, (
        "frame-ancestors 'none' must remain in the HTTP-header CSP"
    )


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
    monkeypatch.delenv("RAILWAY_GIT_COMMIT_SHA", raising=False)
    monkeypatch.setenv("GIT_COMMIT", "1234567890abcdef")
    assert app_module._build_storefront_version() == "1234567"


def test_build_storefront_version_uses_railway_git_commit_sha(monkeypatch):
    """Railway auto-sets RAILWAY_GIT_COMMIT_SHA — added 2026-05-16 to fix
    Railway audit finding that every deploy served ?v=dev (no Render env)."""
    monkeypatch.delenv("RENDER_GIT_COMMIT", raising=False)
    monkeypatch.delenv("GIT_COMMIT", raising=False)
    monkeypatch.setenv("RAILWAY_GIT_COMMIT_SHA", "abcdef1234567890")
    assert app_module._build_storefront_version() == "abcdef1"


def test_build_storefront_version_dev_epoch_when_unset(monkeypatch):
    """All git env vars unset → 'dev-<epoch>' so each container start gets a
    fresh cache-bust suffix even on misconfigured envs. Was 'dev' literal
    before — that defeated cache-bust on any deploy without git env wired."""
    monkeypatch.delenv("RENDER_GIT_COMMIT", raising=False)
    monkeypatch.delenv("RAILWAY_GIT_COMMIT_SHA", raising=False)
    monkeypatch.delenv("GIT_COMMIT", raising=False)
    v = app_module._build_storefront_version()
    assert v.startswith("dev-")
    assert v[4:].isdigit()
    assert int(v[4:]) > 1_700_000_000  # post-2023 epoch sanity check


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


def test_legal_pages_render(monkeypatch):
    """Sprint 3 trust + legal pages — /store/about, /store/privacy,
    /store/terms — all 200 on GET, no JS dependency. Smoke that the
    HTML files exist on disk and the routes are wired."""
    client = TestClient(app_module.app)
    for path in ("/store/about", "/store/privacy", "/store/terms"):
        r = client.get(path)
        assert r.status_code == 200, f"GET {path} expected 200, got {r.status_code}"
        body = r.text.lower()
        # Must include the page-specific h1 (about / privacy / terms).
        h1_word = path.rsplit("/", 1)[1]
        assert f"<h1>{h1_word.title()}" in r.text or h1_word in body, (
            f"{path} body should reference '{h1_word}'"
        )


def test_legal_pages_have_seo_head(monkeypatch):
    """Legal pages reached SEO parity with index.html — favicon link, a
    meta description, and an og:title. Guards against the D1-OPS-4 gap
    where about/privacy/terms shipped (PR #164) before the SEO scaffold
    (PR #166) and had only a bare <title>."""
    client = TestClient(app_module.app)
    for path in ("/store/about", "/store/privacy", "/store/terms"):
        body = client.get(path).text
        assert 'rel="icon"' in body, f"{path} missing favicon link"
        assert 'name="description"' in body, f"{path} missing meta description"
        assert 'property="og:title"' in body, f"{path} missing og:title"


def test_event_page_has_canonical_link(monkeypatch):
    """event.html carries a <link rel='canonical'> element (store.js fills
    href at mount to the filter-less URL, deduping ?zones= filter variants)."""
    client = TestClient(app_module.app)
    body = client.get("/store/event/3346001").text
    assert 'rel="canonical"' in body, "event page missing canonical link element"


def test_legal_pages_have_no_cache_revalidate_header(store_home_client):
    """Legal pages route through _render_storefront_page so they inherit
    the same Cache-Control: no-cache, must-revalidate header. Guards
    against future regressions where a separate handler bypasses the
    cache-control helper."""
    for path in ("/store/about", "/store/privacy", "/store/terms"):
        r = store_home_client.get(path)
        cc = r.headers.get("cache-control", "").lower()
        assert "no-cache" in cc, (
            f"{path} Cache-Control must include no-cache; got: {cc!r}"
        )


def test_legal_pages_respond_to_head(monkeypatch):
    """HEAD on the new legal routes returns 200 (same uptime-monitor
    reason as the other storefront pages — HEAD probes shouldn't 405)."""
    monkeypatch.setattr(app_module, "_read_storefront_html", lambda name: "<html>ok</html>")
    client = TestClient(app_module.app)
    for path in ("/store/about", "/store/privacy", "/store/terms"):
        r = client.head(path)
        assert r.status_code == 200, f"HEAD {path} expected 200, got {r.status_code}"


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


def test_static_store_asset_versioned_is_immutable(store_home_client):
    """D1-OPS-2: a versioned (?v=<sha>) /static/store asset request gets a
    1-year immutable Cache-Control so browsers stop revalidating every load.
    The ?v= query is what makes immutable safe — a new deploy serves a new
    URL."""
    r = store_home_client.get("/static/store/style.css?v=abc1234")
    assert r.status_code == 200, r.text
    cc = r.headers.get("cache-control", "").lower()
    assert "max-age=31536000" in cc and "immutable" in cc, (
        f"versioned static asset should be immutable-cached; got: {cc!r}"
    )


def test_static_store_asset_unversioned_short_ttl(store_home_client):
    """An unversioned /static/store hit (rare — crawler/manual) gets a short
    TTL, NOT immutable, so a deploy isn't masked forever for those callers."""
    r = store_home_client.get("/static/store/style.css")
    assert r.status_code == 200
    cc = r.headers.get("cache-control", "").lower()
    assert "immutable" not in cc, f"unversioned asset must not be immutable; got: {cc!r}"
    assert "max-age=600" in cc, f"expected short TTL; got: {cc!r}"


# ---------- /api/store/movers stale-while-revalidate cache ----------
#
# The movers route refactor in PR #144 wraps the ~1s compute path in a
# 5-min SWR cache so the homescreen only pays the compute cost once per
# (city, days, limit) tuple per TTL. These tests mock `_compute_movers`
# directly (the heavy SQL+joins path) so we can assert the cache wrapper
# semantics independent of the compute implementation.

def _setup_movers_cache_test(monkeypatch, ttl=300.0):
    """Reset cache state + provide a counting fake compute. Returns the
    counter dict so the caller can assert call counts."""
    monkeypatch.setattr(app_module, "_movers_cache", {})
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_REFRESHING", set())
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_TTL", ttl)
    monkeypatch.setattr(app_module, "require_sb", lambda: None)
    counter = {"n": 0}

    def _fake_compute(db, city, day_cap, cap):
        counter["n"] += 1
        return {
            "city": city,
            "days": day_cap,
            "count": counter["n"],  # encode call number so we can detect fresh vs stale
            "events": [{"id": counter["n"], "name": f"call {counter['n']}"}],
        }
    monkeypatch.setattr(app_module, "_compute_movers", _fake_compute)
    return counter


def test_movers_cache_cold_miss_computes(monkeypatch):
    """First-ever request for a (city, days, limit) tuple computes
    synchronously, populates the cache, returns fresh payload."""
    counter = _setup_movers_cache_test(monkeypatch)
    client = TestClient(app_module.app)

    r = client.get("/api/store/movers?city=NYC&days=21&limit=8")
    assert r.status_code == 200
    assert counter["n"] == 1, "cold miss must call _compute_movers exactly once"
    body = r.json()
    assert body["count"] == 1  # first call's encoded counter
    assert body["city"] == "NYC"

    # Cache populated under the expected key.
    assert app_module._movers_cache, "cache must be non-empty after cold-miss compute"


def test_movers_cache_fresh_hit_skips_compute(monkeypatch):
    """Second request within TTL returns cached payload without invoking
    _compute_movers again. This is the whole point — eliminate the ~1s
    compute on every homescreen load past the first."""
    counter = _setup_movers_cache_test(monkeypatch)
    client = TestClient(app_module.app)

    r1 = client.get("/api/store/movers?city=NYC&days=21&limit=8")
    r2 = client.get("/api/store/movers?city=NYC&days=21&limit=8")

    assert counter["n"] == 1, (
        f"second call within TTL must NOT recompute; saw {counter['n']} calls"
    )
    # Both responses must be byte-identical (same cached object).
    assert r1.json() == r2.json()
    assert r2.json()["count"] == 1  # still the first call's payload


def test_movers_cache_separate_keys_compute_independently(monkeypatch):
    """Cache key includes (city, days, limit) — different tuples must
    each get their own compute on cold-miss."""
    counter = _setup_movers_cache_test(monkeypatch)
    client = TestClient(app_module.app)

    r1 = client.get("/api/store/movers?city=NYC&days=21&limit=8")
    r2 = client.get("/api/store/movers?city=NYC&days=14&limit=8")  # different days
    r3 = client.get("/api/store/movers?city=NYC&days=21&limit=4")  # different limit

    assert counter["n"] == 3, (
        f"three distinct keys must trigger three computes; saw {counter['n']}"
    )
    # r1 and a hypothetical r4 with the same params would share — confirm:
    r4 = client.get("/api/store/movers?city=NYC&days=21&limit=8")
    assert counter["n"] == 3, "r4 hits the r1 cache slot, no new compute"
    assert r4.json() == r1.json()


def test_movers_cache_key_folds_city_case(monkeypatch):
    """'nyc' / 'NYC' / 'New York' map to the same cache slot via the
    canonical key (uppercased). Prevents per-casing duplicate cache entries."""
    counter = _setup_movers_cache_test(monkeypatch)
    client = TestClient(app_module.app)

    client.get("/api/store/movers?city=NYC&days=21&limit=8")
    client.get("/api/store/movers?city=nyc&days=21&limit=8")
    client.get("/api/store/movers?city=Nyc&days=21&limit=8")
    # All three collapse to key "NYC|21|8". Note: the route maps NEW YORK
    # + NEW YORK CITY through the same venue_patterns, so they ALSO
    # cache-key to NYC. But that mapping happens inside _compute_movers,
    # NOT the cache key — so 'NEW YORK' would key as 'NEW YORK|21|8'
    # separately. This test only proves case-insensitive folding on a
    # single token; alias-folding would be a separate cache-key change.
    assert counter["n"] == 1, (
        f"case-insensitive city should share one cache slot; saw {counter['n']} computes"
    )


def test_movers_cache_failed_compute_doesnt_poison(monkeypatch):
    """If _compute_movers raises on cold-miss, the exception propagates
    (no cached payload to fall back to) AND no stale entry is written
    to the cache. Next call retries cleanly."""
    monkeypatch.setattr(app_module, "_movers_cache", {})
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_REFRESHING", set())
    monkeypatch.setattr(app_module, "require_sb", lambda: None)

    counter = {"n": 0}
    def _flaky_compute(db, city, day_cap, cap):
        counter["n"] += 1
        if counter["n"] == 1:
            raise RuntimeError("simulated compute failure")
        return {"city": city, "days": day_cap, "count": counter["n"], "events": []}
    monkeypatch.setattr(app_module, "_compute_movers", _flaky_compute)

    client = TestClient(app_module.app)

    # First call: compute raises — endpoint should 5xx (any server-error
    # status; FastAPI returns 502 in this configuration, 500 in others —
    # we don't care which, only that the cache wasn't poisoned).
    try:
        r1 = client.get("/api/store/movers?city=NYC&days=21&limit=8")
        assert 500 <= r1.status_code < 600, (
            f"compute failure must surface as 5xx; got {r1.status_code}"
        )
    except RuntimeError:
        pass  # acceptable — TestClient sometimes re-raises sync handler exceptions

    assert not app_module._movers_cache, (
        "failed cold-miss compute must NOT write a poisoned entry into the cache"
    )

    # Second call: succeeds and caches.
    r2 = client.get("/api/store/movers?city=NYC&days=21&limit=8")
    assert r2.status_code == 200
    assert r2.json()["count"] == 2
    assert app_module._movers_cache, "successful compute writes to cache"


# ---------- /api/store/movers velocity-freshness gate ----------

def test_movers_drops_tix_d24h_when_velocity_stale(monkeypatch):
    """The velocity freshness gate bounds how old a v_event_velocity_windows
    sample can be before its d24h is dropped for rail membership. The window
    is 48h (revised 2026-05-25 from 3h — the 3h gate silently emptied the
    rails because owned MLB/NBA events re-poll on a ~24-48h cadence, so every
    qualifying event's sample was 21-141h old).

    Three events exercise the boundary:
      1001  72h-old sample  → STALE  → dropped from moving_fast
      1002  30min-old       → FRESH  → in moving_fast
      1003  24h-old         → FRESH (within 48h) → in moving_fast
             (1003 is the regression guard: under the old 3h gate it would
              have been wrongly dropped — exactly the bug this fix closes.)
    """
    from datetime import datetime, timezone, timedelta

    stale_ts = (datetime.now(timezone.utc) - timedelta(hours=72)).isoformat()
    fresh_ts = (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat()
    day_old_ts = (datetime.now(timezone.utc) - timedelta(hours=24)).isoformat()

    # All priced < $500 so premium never fires — the ONLY path to a rail is
    # via velocity, which is what the freshness gate governs.
    fake_metrics = [
        {"event_id": 1001, "owned_tickets_count": 100, "owned_groups_count": 10, "retail_min": 25.0},
        {"event_id": 1002, "owned_tickets_count": 100, "owned_groups_count": 10, "retail_min": 25.0},
        {"event_id": 1003, "owned_tickets_count": 100, "owned_groups_count": 10, "retail_min": 25.0},
    ]
    fake_events = [
        {"id": 1001, "name": "Stale event", "occurs_at_local": "2026-06-01T19:00:00-04:00",
         "venue_name": "MSG", "venue_location": "New York, NY",
         "primary_performer_id": 16303, "primary_performer_name": "Yankees"},
        {"id": 1002, "name": "Fresh event", "occurs_at_local": "2026-06-02T19:00:00-04:00",
         "venue_name": "MSG", "venue_location": "New York, NY",
         "primary_performer_id": 16303, "primary_performer_name": "Yankees"},
        {"id": 1003, "name": "Day-old event", "occurs_at_local": "2026-06-03T19:00:00-04:00",
         "venue_name": "MSG", "venue_location": "New York, NY",
         "primary_performer_id": 16303, "primary_performer_name": "Yankees"},
    ]
    fake_velocity = [
        {"tevo_event_id": 1001, "tevo_tix_now": 100, "tevo_tix_d24h": -500,
         "tevo_getin_now": 10.0, "tevo_getin_d24h_pct": -20.0, "tevo_now_at": stale_ts},
        {"tevo_event_id": 1002, "tevo_tix_now": 100, "tevo_tix_d24h": -500,
         "tevo_getin_now": 10.0, "tevo_getin_d24h_pct": -20.0, "tevo_now_at": fresh_ts},
        {"tevo_event_id": 1003, "tevo_tix_now": 100, "tevo_tix_d24h": -500,
         "tevo_getin_now": 10.0, "tevo_getin_d24h_pct": -20.0, "tevo_now_at": day_old_ts},
    ]
    fake_lifecycle = [
        {"event_id": 1001, "is_active": True},
        {"event_id": 1002, "is_active": True},
        {"event_id": 1003, "is_active": True},
    ]

    table_map = {
        "latest_event_metrics": fake_metrics,
        "events": fake_events,
        "event_lifecycle": fake_lifecycle,
        "v_event_velocity_windows": fake_velocity,
    }

    # Reuse the FakeSupabase pattern from test_store_home — minimal table stub.
    class _T:
        def __init__(self, rows): self._rows = rows
        def select(self, *_, **__): return self
        def in_(self, _col, _vals): return self
        def execute(self):
            class R:
                def __init__(s, data): s.data = data
            return R(self._rows)
        def gt(self, *_, **__): return self
        def gte(self, *_, **__): return self
        def lt(self, *_, **__): return self
        def lte(self, *_, **__): return self
        def eq(self, *_, **__): return self
        def is_(self, *_, **__): return self
        def not_(self, *_, **__): return self
        def or_(self, *_, **__): return self
        def order(self, *_, **__): return self
        def limit(self, *_, **__): return self
        def neq(self, *_, **__): return self

    class _DB:
        def table(self, name): return _T(table_map.get(name, []))

    monkeypatch.setattr(app_module, "require_sb", lambda: _DB())
    monkeypatch.setattr(app_module, "_bulk_performer_assets", lambda *a, **k: {})
    # Bypass the cache so we hit _compute_movers directly.
    monkeypatch.setattr(app_module, "_movers_cache", {})
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_REFRESHING", set())

    client = TestClient(app_module.app)
    r = client.get("/api/store/movers?city=NYC&days=30&limit=10")
    assert r.status_code == 200, r.text

    # Post-PR #274/#275: response is split into 4 themed arrays
    # (moving_fast, price_drops, climbing, specials). The fresh-velocity
    # event with -500 d24h qualifies for `moving_fast` (d24h <= -50).
    body = r.json()
    moving_fast_by_id = {e["id"]: e for e in body.get("moving_fast", [])}

    # Stale event (1001, 72h > 48h): velocity-suspect → tix_d24h dropped →
    # no qualification for moving_fast (no d24h, no SG sales stubbed).
    assert 1001 not in moving_fast_by_id, (
        "72h-stale velocity must NOT surface — tix_d24h suppressed"
    )

    # Fresh event (1002, 30min): velocity trusted; -500 drop → moving_fast.
    assert 1002 in moving_fast_by_id, "fresh-velocity event should make moving_fast"
    assert moving_fast_by_id[1002]["tix_d24h"] == -500

    # Day-old event (1003, 24h ≤ 48h): the regression guard. Under the old
    # 3h gate this was wrongly dropped, emptying the rail; the 48h window
    # admits it.
    assert 1003 in moving_fast_by_id, (
        "24h-old velocity is within the 48h window and MUST surface "
        "(regression guard for the 3h→48h fix)"
    )
    assert moving_fast_by_id[1003]["tix_d24h"] == -500


def test_movers_response_no_longer_includes_tix_d1h(monkeypatch):
    """tix_d1h was removed from the response (was equal to tix_d24h
    when collector cadence is the only available sample, misleading).
    Renderer never read it. Guard against accidental re-introduction."""
    from datetime import datetime, timezone, timedelta
    fresh_ts = (datetime.now(timezone.utc) - timedelta(minutes=15)).isoformat()

    fake_metrics = [{"event_id": 2001, "owned_tickets_count": 100, "owned_groups_count": 5, "retail_min": 30.0}]
    fake_events = [{"id": 2001, "name": "Test", "occurs_at_local": "2026-06-01T19:00:00-04:00",
                    "venue_name": "MSG", "venue_location": "New York, NY",
                    "primary_performer_id": 16303, "primary_performer_name": "Yankees"}]
    fake_velocity = [{"tevo_event_id": 2001, "tevo_tix_now": 50, "tevo_tix_d24h": -80,
                      "tevo_getin_now": 12.0, "tevo_getin_d24h_pct": -5.0, "tevo_now_at": fresh_ts}]
    fake_lifecycle = [{"event_id": 2001, "is_active": True}]
    table_map = {"latest_event_metrics": fake_metrics, "events": fake_events,
                 "event_lifecycle": fake_lifecycle, "v_event_velocity_windows": fake_velocity}

    class _T:
        def __init__(self, rows): self._rows = rows
        def select(self, *_, **__): return self
        def in_(self, _col, _vals): return self
        def execute(self):
            class R:
                def __init__(s, data): s.data = data
            return R(self._rows)
        def gt(self, *_, **__): return self
        def gte(self, *_, **__): return self
        def lt(self, *_, **__): return self
        def lte(self, *_, **__): return self
        def eq(self, *_, **__): return self
        def is_(self, *_, **__): return self
        def not_(self, *_, **__): return self
        def or_(self, *_, **__): return self
        def order(self, *_, **__): return self
        def limit(self, *_, **__): return self
        def neq(self, *_, **__): return self

    class _DB:
        def table(self, name): return _T(table_map.get(name, []))

    monkeypatch.setattr(app_module, "require_sb", lambda: _DB())
    monkeypatch.setattr(app_module, "_bulk_performer_assets", lambda *a, **k: {})
    monkeypatch.setattr(app_module, "_movers_cache", {})
    monkeypatch.setattr(app_module, "_MOVERS_CACHE_REFRESHING", set())

    client = TestClient(app_module.app)
    r = client.get("/api/store/movers?city=NYC&days=30&limit=10")
    assert r.status_code == 200
    body = r.json()
    # Inspect cards across all themed sections — none should leak tix_d1h.
    # Featured (PR 2026-05-19) added as a 5th key combining playoff + owned>200
    # + NYC specials; shares the same candidate pool so same anti-leak check.
    for key in ("featured", "moving_fast", "price_drops", "climbing", "specials"):
        for ev in body.get(key, []):
            assert "tix_d1h" not in ev, (
                f"tix_d1h must not appear in mover response; got keys: {list(ev.keys())}"
            )


def test_store_html_routes_respond_to_head(monkeypatch):
    """HEAD requests on the 4 production storefront HTML routes return
    200 (not 405). Uptime monitors that default to HEAD probes were
    alerting; PR adds HEAD support via @app.api_route(..., methods=...)."""
    monkeypatch.setattr(app_module, "_read_storefront_html", lambda name: "<html>ok</html>")
    client = TestClient(app_module.app)
    for path in ("/store", "/store/event/123", "/s/test-id", "/store/shares"):
        r = client.head(path)
        assert r.status_code == 200, (
            f"HEAD {path} expected 200, got {r.status_code}"
        )


# ---------- _section_featured / _section_specials holiday label tests ----------
#
# Operator directive 2026-05-19: distinguish the actual holiday day from
# adjacent days in rail badges. Day-of keeps the bare name ("Memorial Day"),
# weekend-of gets the framing ("Memorial Day Weekend"). holiday_by_eid value
# shape: {"name": str, "weekend": bool}.

def _featured_candidate(eid: int, owned: int = 150,
                        occurs: str = "2026-05-25T19:00:00-04:00",
                        med: float = 60.0) -> dict:
    """Minimal candidate dict that satisfies the Featured 'other category'
    branch fallthrough so we can test the holiday-tag path in isolation
    (owned > 100, no playoff/rivalry/marquee regex hits in name)."""
    return {
        "id": eid,
        "name": f"Test Event {eid}",   # no playoff/marquee keywords
        "occurs_at_local": occurs,
        "owned_tickets_count": owned,
        "owned_median_retail": med,
        "owned_share": 0.10,
    }


def test_section_featured_holiday_day_of_label():
    """Holiday day-of: bare name, no 'Weekend' suffix."""
    cand = _featured_candidate(1)
    out = app_module._section_featured(
        [cand],
        holiday_by_eid={1: {"name": "Memorial Day", "weekend": False}},
        rivalry_by_eid={},
    )
    assert len(out) == 1
    assert out[0]["_featured_tag"] == "Memorial Day"
    assert out[0]["_featured_kind"] == "holiday"


def test_section_featured_holiday_weekend_of_label():
    """Holiday weekend-of (±1/±2 from observed_date): 'Weekend' suffix."""
    cand = _featured_candidate(2)
    out = app_module._section_featured(
        [cand],
        holiday_by_eid={2: {"name": "Memorial Day", "weekend": True}},
        rivalry_by_eid={},
    )
    assert len(out) == 1
    assert out[0]["_featured_tag"] == "Memorial Day Weekend"
    assert out[0]["_featured_kind"] == "holiday"


def test_section_specials_holiday_day_of_label():
    """Specials rail mirrors Featured for the label semantics."""
    cand = _featured_candidate(3)
    out = app_module._section_specials(
        [cand],
        holiday_by_eid={3: {"name": "Father's Day", "weekend": False}},
        rivalry_by_eid={},
    )
    assert len(out) == 1
    assert out[0]["_special"] == "Father's Day"
    assert out[0]["_special_kind"] == "holiday"


def test_section_specials_holiday_weekend_of_label():
    """Specials rail — weekend-of gets the 'Weekend' framing."""
    cand = _featured_candidate(4)
    out = app_module._section_specials(
        [cand],
        holiday_by_eid={4: {"name": "Father's Day", "weekend": True}},
        rivalry_by_eid={},
    )
    assert len(out) == 1
    assert out[0]["_special"] == "Father's Day Weekend"
    assert out[0]["_special_kind"] == "holiday"


def test_section_specials_rivalry_wins_over_holiday():
    """When BOTH a rivalry tag and a holiday tag apply, the rivalry text
    is the more specific narrative — guard the prefer-rivalry behavior so
    the new holiday-label refactor doesn't regress it."""
    cand = _featured_candidate(5)
    out = app_module._section_specials(
        [cand],
        holiday_by_eid={5: {"name": "Memorial Day", "weekend": True}},
        rivalry_by_eid={5: "Yankees vs Red Sox"},
    )
    assert len(out) == 1
    assert out[0]["_special"] == "Yankees vs Red Sox"
    assert out[0]["_special_kind"] == "rivalry"


# ---------- _classify_holiday_proximity tests ----------
#
# Operator 2026-05-19 v6: "suffix only when weekend = true, not for a
# tuesday event". Helper returns "day_of" | "weekend_of" | None for the
# ±2-day window expansion around a holiday's observed_date.
# Reference holiday: Memorial Day Mon May 25, 2026 (weekday()=0).


def test_classify_holiday_proximity_day_of():
    """Candidate on the exact observed_date → 'day_of'."""
    assert app_module._classify_holiday_proximity(
        "2026-05-25", "2026-05-25"
    ) == "day_of"


def test_classify_holiday_proximity_saturday_before():
    """Saturday before Memorial Day Mon → 'weekend_of'."""
    assert app_module._classify_holiday_proximity(
        "2026-05-23", "2026-05-25"  # Sat May 23 (weekday 5) → weekend
    ) == "weekend_of"


def test_classify_holiday_proximity_sunday_before():
    """Sunday before Memorial Day Mon → 'weekend_of'."""
    assert app_module._classify_holiday_proximity(
        "2026-05-24", "2026-05-25"  # Sun May 24 (weekday 6) → weekend
    ) == "weekend_of"


def test_classify_holiday_proximity_tuesday_after_returns_none():
    """The operator's exact case: Tue May 26 after Memorial Day Mon
    May 25 is NOT 'Memorial Day Weekend'. Helper returns None so the
    upstream loop skips tagging this event with the holiday."""
    assert app_module._classify_holiday_proximity(
        "2026-05-26", "2026-05-25"  # Tue May 26 (weekday 1) → no tag
    ) is None


def test_classify_holiday_proximity_friday_before_returns_none():
    """Friday two days before Memorial Day Mon → no tag. Friday isn't
    Sat or Sun; the long-weekend lead-in is not Featured-as-holiday
    territory (the event still flows to other Featured branches if it
    qualifies on owned_median or market-anchor)."""
    assert app_module._classify_holiday_proximity(
        "2026-05-22", "2026-05-25"  # Fri May 22 (weekday 4) → no tag
    ) is None


def test_classify_holiday_proximity_fathers_day_saturday():
    """Father's Day = Sun Jun 21, 2026. Saturday Jun 20 → 'weekend_of'."""
    assert app_module._classify_holiday_proximity(
        "2026-06-20", "2026-06-21"  # Sat Jun 20 (weekday 5) → weekend
    ) == "weekend_of"


def test_classify_holiday_proximity_invalid_input_returns_none():
    """Malformed ISO date → None (defensive — caller may pass empty
    observed_date string when chosen row lacks the field)."""
    assert app_module._classify_holiday_proximity("", "2026-05-25") is None
    assert app_module._classify_holiday_proximity("not-a-date", "2026-05-25") is None
