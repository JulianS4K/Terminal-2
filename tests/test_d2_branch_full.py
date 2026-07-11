"""Branch-coverage closers for d2_dashboard.main.

Companion to tests/test_d2_dashboard.py (smoke) + tests/test_d2_dashboard_full.py
(line coverage). This file drives the remaining PARTIAL branches -- the "else"
arm of conditionals + loop-skip / loop-exhaust paths that the existing suites
only ever exercised the one way:

  247->251  _vault_secret: rpc data is neither str nor dict -> fall to `return None`
  652->647  _fetch_cron_freshness: duplicate non-queue row for an already-seen
            source -> the `if` is False, loop continues without overwrite
  839->845  _fetch_unified_orders_page: include_terminal=True skips the or_ filter
  858->860  _fetch_unified_orders_page: a row with last_seen_at falsy/older ->
            the as_of update `if` is False, fall to the count bump
  882->886  _fetch_unified_orders_page: a row whose event_name is already set ->
            the back-fill `if` is False, fall straight to rows.append
  1032->1034 _fetch_filtered_orders: as above (last_seen_at falsy/older)
  1351->1335 _fetch_unified_orders_fast: a row with last_seen_at falsy/older ->
            the as_of update `if` is False, loop continues

(109->119, 179->193 are import-time prod-guard branches, pragma'd in source,
same idea as the pre-existing 100/131 guards.)

No real network / DB -- everything is monkeypatched to in-memory fakes, mirroring
the FakeSupabase / _UOQuery conventions of the companion files.
"""
from __future__ import annotations

import os

import pytest

# Match the companion files: force AUTH_DISABLED before import + scrub prod
# indicators so the module-level constant evaluates true.
os.environ["AUTH_DISABLED"] = "true"
for _key in ("RAILWAY_ENVIRONMENT", "ENVIRONMENT", "NODE_ENV", "PYTHON_ENV", "FLY_APP_NAME", "RENDER"):
    os.environ.pop(_key, None)

from d2_dashboard import main as d2_main


@pytest.fixture(autouse=True, scope="module")
def _cleanup_d2_env_after_module():
    """Restore the import-time AUTH state on teardown. This module sorts BEFORE
    tests/test_d2_dashboard.py, whose tests rely on the module-level
    AUTH_DISABLED=True set at import and which has no per-test re-enable fixture.
    Leaving it True here (not False) keeps that smoke module green regardless of
    collection order; the smoke module's own teardown handles the final reset."""
    yield
    d2_main.AUTH_DISABLED = True


@pytest.fixture(autouse=True)
def _auth_disabled_by_default(monkeypatch):
    """The smoke-test module flips AUTH_DISABLED off on teardown; force it back
    on per-test so these direct-call tests don't depend on module order."""
    monkeypatch.setattr(d2_main, "AUTH_DISABLED", True)


class _RpcCall:
    def __init__(self, data):
        self._data = data
    def execute(self):
        return type("R", (), {"data": self._data})()


class _UOQuery:
    """Chainable PostgREST stub for unified_orders / v_event_base -- mirrors the
    one in test_d2_dashboard_full.py, with optional per-call capture."""
    def __init__(self, rows, capture=None):
        self._rows = rows
        self._capture = capture if capture is not None else {}
    def select(self, *a, **k): return self
    def eq(self, *a, **k): return self
    def or_(self, expr): self._capture.setdefault("or_", []).append(expr); return self
    def ilike(self, *a, **k): self._capture["ilike"] = a; return self
    def gte(self, *a, **k): self._capture.setdefault("gte", []).append(a); return self
    def lt(self, *a, **k): self._capture.setdefault("lt", []).append(a); return self
    def lte(self, *a, **k): return self
    def in_(self, col, vals): self._capture["in"] = (col, list(vals)); return self
    def order(self, *a, **k): return self
    def range(self, *a, **k): self._capture.setdefault("range", []).append(a); return self
    def limit(self, *a, **k): return self
    def execute(self):
        return type("R", (), {"data": self._rows})()


# --------------------------------------------------------------------------
# 247->251 -- _vault_secret: data neither str nor dict
# --------------------------------------------------------------------------

def test_vault_secret_non_str_non_dict_returns_none(monkeypatch):
    """rpc returns a payload that's neither str nor dict (e.g. a list) -> both
    isinstance checks fall through to the trailing `return None`."""
    sb = type("Sb", (), {"rpc": lambda self, n, a: _RpcCall(["not", "a", "scalar"])})()
    monkeypatch.setattr(d2_main, "_sb", lambda: sb)
    assert d2_main._vault_secret("X") is None

    # An int payload exercises the same fall-through.
    sb2 = type("Sb", (), {"rpc": lambda self, n, a: _RpcCall(123)})()
    monkeypatch.setattr(d2_main, "_sb", lambda: sb2)
    assert d2_main._vault_secret("X") is None


# --------------------------------------------------------------------------
# 652->647 -- _fetch_cron_freshness: duplicate non-queue row, source already seen
# --------------------------------------------------------------------------

def test_fetch_cron_freshness_keeps_first_when_dup_non_queue(monkeypatch):
    """When a source is already in by_source and the next row for it is NOT a
    queue-phase row, the `if src not in by_source or phase=='queue'` is False --
    the loop continues without overwriting (652->647)."""
    rows = [
        {"source": "evo", "phase": "queue",   "jobname": "evo_queue"},
        {"source": "evo", "phase": "process", "jobname": "evo_process"},  # dup, non-queue -> skipped
    ]
    class Sb:
        def rpc(self, name):
            assert name == "d2_cron_freshness"
            return _RpcCall(rows)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_cron_freshness()
    # The queue row stays; the later process row did NOT overwrite it.
    assert out["evo"]["jobname"] == "evo_queue"


# --------------------------------------------------------------------------
# 839->845 + 858->860 -- _fetch_unified_orders_page
# --------------------------------------------------------------------------

def test_fetch_unified_orders_page_include_terminal_skips_filter_and_null_last_seen(monkeypatch):
    """include_terminal=True skips the active-only or_ filter (839->845), and a
    row whose last_seen_at is None skips the as_of update (858->860) while still
    bumping per_source_count."""
    cap = {}
    rows = [{"source": "evo", "source_order_id": "1", "tevo_event_id": None,
             "source_status": "fulfilled", "canonical_status": "fulfilled",
             "quantity": 2, "gross_value": "100.0",
             "created_at": "2026-05-13T19:00:00Z", "last_seen_at": None,
             "event_name": "Show", "event_date": "2026-06-01"}]
    class Sb:
        _n = {"i": 0}
        def table(self, name):
            if name == "unified_orders":
                self._n["i"] += 1
                # Give the evo-rows once (first source pulled), empty otherwise.
                return _UOQuery(rows if self._n["i"] == 1 else [], cap)
            return _UOQuery([], cap)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_unified_orders_page(25, include_terminal=True)
    assert out is not None
    # or_ active-only filter NOT applied because include_terminal=True.
    assert "or_" not in cap
    # Row counted even though last_seen_at was None (no as_of recorded for it).
    counted = sum(out["per_source_count"].values())
    assert counted == 1
    assert "evo" not in out["per_source_as_of"]


# --------------------------------------------------------------------------
# 882->886 -- _fetch_unified_orders_page: row with native event_name present
# --------------------------------------------------------------------------

def test_fetch_unified_orders_page_native_event_name_skips_backfill(monkeypatch):
    """A row that already carries a native event_name skips the v_event_base
    back-fill block (882->886) and lands straight in rows.append. The
    v_event_base table must NOT be queried (no missing ids)."""
    rows = [{"source": "evo", "source_order_id": "9", "tevo_event_id": 42,
             "source_status": "accepted", "canonical_status": "accepted",
             "quantity": 1, "gross_value": "50.0",
             "created_at": "2026-05-13T19:00:00Z", "last_seen_at": "2026-05-13T20:00:00Z",
             "event_name": "Native Event", "event_date": "2026-06-01T19:30:00Z"}]
    class Sb:
        _n = {"i": 0}
        def table(self, name):
            if name == "unified_orders":
                self._n["i"] += 1
                return _UOQuery(rows if self._n["i"] == 1 else [])
            # tevo_event_id is set but event_name is too, so it's not 'missing'
            # -> missing_event_ids is empty -> no v_event_base query expected.
            raise AssertionError("v_event_base should not be queried -- event_name present")
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_unified_orders_page(25)
    matched = [r for r in out["rows"] if r["order_id"] == "9"]
    assert matched and matched[0]["event_name"] == "Native Event"


# --------------------------------------------------------------------------
# 1032->1034 -- _fetch_filtered_orders: null last_seen_at skips as_of update
# --------------------------------------------------------------------------

def test_fetch_filtered_orders_null_last_seen_skips_as_of(monkeypatch):
    """A filtered row whose last_seen_at is None skips the as_of update
    (1032->1034) but still bumps per_source_count."""
    rows = [{"source": "evo", "source_order_id": "1", "tevo_event_id": None,
             "event_name": "Native", "event_date": "2026-06-01",
             "quantity": 1, "gross_value": "1", "source_status": "accepted",
             "canonical_status": "accepted", "created_at": "2026-05-13T19:00:00Z",
             "last_seen_at": None}]
    class Sb:
        def table(self, name):
            if name == "v_event_base":
                return _UOQuery([])
            return _UOQuery(rows)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_filtered_orders("evo", 10)
    assert out["per_source_count"]["evo"] == 1
    assert "evo" not in out["per_source_as_of"]


# --------------------------------------------------------------------------
# 1351->1335 -- _fetch_unified_orders_fast: null last_seen_at skips as_of update
# --------------------------------------------------------------------------

def test_fetch_unified_orders_fast_null_last_seen_skips_as_of(monkeypatch):
    """A fast-path row whose last_seen_at is None skips the as_of update
    (1351->1335) while still being counted + returned."""
    cap = {}
    rows = [{"source": "evo", "source_order_id": "1", "tevo_event_id": None,
             "source_status": "accepted", "canonical_status": "accepted",
             "quantity": 2, "gross_value": "100.0",
             "created_at": "2026-05-13T19:00:00Z", "last_seen_at": None,
             "event_name": "Show", "event_date": "2026-06-01"}]
    class Sb:
        def table(self, name):
            return _UOQuery(rows, cap)
    monkeypatch.setattr(d2_main, "_sb", lambda: Sb())
    out = d2_main._fetch_unified_orders_fast(25)
    assert out["per_source_count"]["evo"] == 1
    assert "evo" not in out["per_source_as_of"]
    assert out["rows"][0]["event_name"] == "Show"
