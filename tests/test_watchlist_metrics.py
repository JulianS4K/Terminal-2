"""Wiring tests for the home watchlist at-a-glance metrics (PR: watchlist metrics).

Two layers:
  • Static contract checks (always run) — pin the RPC↔frontend wiring so a field
    renamed on one side but not the other fails CI. The home watchlist is a direct
    Supabase RPC (event_watchlist_list) consumed by static/terminal/home.js, so the
    contract is "the metric keys the RPC emits == the keys home.js reads."
  • Live-DB checks (skipped unless SUPABASE_DB_URL is set) — exercise the deployed
    function: SECURITY DEFINER, payload shape, and the opening-bell vs 24h basis
    branch against the live clock.

Mirrors tests/test_views_and_helpers.py for the live-DB harness + skip gate.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
MIGRATION = REPO_ROOT / "supabase" / "migrations" / "20260606170000_watchlist_list_metrics.sql"
HOME_JS = REPO_ROOT / "static" / "terminal" / "home.js"

DB_URL = os.environ.get("SUPABASE_DB_URL")
skip_no_db = pytest.mark.skipif(not DB_URL, reason="SUPABASE_DB_URL not set; skipping live-DB tests")

# The contract. Each metric the RPC emits inside the per-item `metrics` object must
# be consumed by home.js as `m.<key>` (and vice-versa for the displayed/delta set).
DISPLAY_KEYS = ["getin", "median", "p90", "tickets"]   # rendered as table columns
DELTA_KEYS = ["d_getin", "d_getin_pct"]                # headline Δ on the get-in


@pytest.fixture(scope="module")
def migration_sql() -> str:
    assert MIGRATION.exists(), f"migration file missing: {MIGRATION}"
    return MIGRATION.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def home_js() -> str:
    assert HOME_JS.exists(), f"home.js missing: {HOME_JS}"
    return HOME_JS.read_text(encoding="utf-8")


# ---------- Static contract checks (no DB) ----------

def test_rpc_emits_all_metric_keys(migration_sql: str):
    """Every display + delta key is a jsonb key in the RPC's metrics object."""
    for key in DISPLAY_KEYS + DELTA_KEYS + ["basis", "cur_at", "base_at"]:
        assert f"'{key}'" in migration_sql, f"RPC migration missing metrics key '{key}'"


def test_frontend_consumes_all_metric_keys(home_js: str):
    """home.js reads each metric/delta key off the per-item `metrics` object."""
    for key in DISPLAY_KEYS + DELTA_KEYS:
        assert f"m.{key}" in home_js, f"home.js does not consume m.{key}"


def test_rpc_and_fe_key_sets_agree(migration_sql: str, home_js: str):
    """Guard against drift: any m.<key> the FE reads must be emitted by the RPC."""
    fe_keys = set(re.findall(r"\bm\.([a-z_][a-z0-9_]*)\b", home_js))
    # Keys the FE reads off the metrics object (exclude unrelated locals if any).
    metric_like = {k for k in fe_keys if k in set(DISPLAY_KEYS + DELTA_KEYS)
                   or k.startswith("d_")}
    for key in metric_like:
        assert f"'{key}'" in migration_sql, \
            f"home.js reads m.{key} but the RPC never emits '{key}'"


def test_frontend_calls_the_rpc_and_reads_envelope(home_js: str):
    """FE calls event_watchlist_list and reads items + basis off the envelope."""
    assert "event_watchlist_list" in home_js
    assert "res.data" in home_js and ".items" in home_js
    assert ".basis" in home_js and "_wlBasis" in home_js


def test_basis_labels_present_both_sides(migration_sql: str, home_js: str):
    """'bell' / '24h' basis values exist in the RPC and are labeled in the UI."""
    assert "'bell'" in migration_sql and "'24h'" in migration_sql
    assert "'bell'" in home_js and "'24h'" in home_js
    assert "opening bell" in home_js.lower()


def test_opening_bell_is_noon_et_with_24h_fallback(migration_sql: str):
    """Bell = today 12:00 America/New_York; fallback = trailing 24h."""
    assert "America/New_York" in migration_sql
    assert "interval '12 hours'" in migration_sql
    assert "interval '24 hours'" in migration_sql


def test_rpc_payload_backward_compatible(migration_sql: str):
    """The existing envelope keys are preserved and metrics is NULL-guarded."""
    for key in ["'user_email'", "'count'", "'items'"]:
        assert key in migration_sql, f"RPC dropped backward-compat envelope key {key}"
    assert "CASE WHEN c.event_id IS NULL THEN NULL" in migration_sql, \
        "metrics must be NULL when the event has no event_metrics row"


# ---------- Live-DB checks (require SUPABASE_DB_URL) ----------

def _run_query(sql: str) -> list[dict]:
    psycopg2 = pytest.importorskip("psycopg2")
    import psycopg2.extras
    with psycopg2.connect(DB_URL) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql)
            return [dict(r) for r in cur.fetchall()]


def _run_as_email(email: str, sql: str) -> list[dict]:
    """Run sql in a transaction with the JWT email GUC set (SECDEF reads auth.jwt())."""
    psycopg2 = pytest.importorskip("psycopg2")
    import psycopg2.extras
    with psycopg2.connect(DB_URL) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                        (json.dumps({"email": email}),))
            cur.execute(sql)
            return [dict(r) for r in cur.fetchall()]


@skip_no_db
def test_function_exists_and_is_secdef():
    rows = _run_query(
        "SELECT prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
        "WHERE n.nspname='public' AND p.proname='event_watchlist_list'"
    )
    assert rows, "event_watchlist_list not found"
    assert rows[0]["prosecdef"] is True, "event_watchlist_list must be SECURITY DEFINER"


@skip_no_db
def test_payload_shape_for_empty_user():
    """A user with no rows still gets a well-formed envelope (no crash, basis set)."""
    rows = _run_as_email("smoketest@s4kent.com",
        "SELECT (public.event_watchlist_list()->>'basis') AS basis, "
        "(public.event_watchlist_list()->>'count')::int AS count, "
        "jsonb_typeof(public.event_watchlist_list()->'items') AS items_type")
    assert rows[0]["basis"] in ("bell", "24h")
    assert rows[0]["items_type"] == "array"
    assert rows[0]["count"] >= 0


@skip_no_db
def test_basis_branch_matches_live_clock():
    """The chosen basis equals the independently-computed bell-vs-now decision."""
    rows = _run_as_email("smoketest@s4kent.com",
        "SELECT (public.event_watchlist_list()->>'basis') AS got, "
        "(CASE WHEN now() >= ((date_trunc('day', now() AT TIME ZONE 'America/New_York') "
        "  + interval '12 hours') AT TIME ZONE 'America/New_York') "
        "  THEN 'bell' ELSE '24h' END) AS expected")
    assert rows[0]["got"] == rows[0]["expected"]


@skip_no_db
def test_email_gate_rejects_non_s4kent():
    """The SECDEF email gate must reject a non-@s4kent.com caller."""
    psycopg2 = pytest.importorskip("psycopg2")
    with pytest.raises(psycopg2.Error):
        _run_as_email("intruder@example.com", "SELECT public.event_watchlist_list()")
