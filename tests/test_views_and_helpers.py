"""Tests for canonical views + plpgsql helpers (haversine, HMAC).

Spot-coverage on critical SQL surface so a schema-altering migration that
breaks one of these surfaces will fail CI before merge.

Skipped automatically if SUPABASE_DB_URL not set (lets RULE 2 tests run in
minimal environments). When the URL IS set, runs read-only queries against
live DB.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
DB_URL = os.environ.get("SUPABASE_DB_URL")

skip_no_db = pytest.mark.skipif(
    not DB_URL,
    reason="SUPABASE_DB_URL env var not set; skipping live-DB tests",
)


# ---------- Static checks (don't need DB) ----------

def test_audit_script_passes():
    """check_readonly.py must pass on the current tree."""
    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "check_readonly.py")],
        capture_output=True, text=True, cwd=str(REPO_ROOT),
    )
    assert result.returncode == 0, f"audit failed:\n{result.stdout}\n{result.stderr}"
    assert "RULE 2 clean" in result.stdout


def test_audit_script_scans_plpgsql():
    """The extended audit covers plpgsql migrations now."""
    result = subprocess.run(
        [sys.executable, str(REPO_ROOT / "scripts" / "check_readonly.py")],
        capture_output=True, text=True, cwd=str(REPO_ROOT),
    )
    assert "plpgsql migrations" in result.stdout, \
        "audit script doesn't mention plpgsql scan in summary"


def test_audit_catches_plpgsql_violation(tmp_path: Path):
    """Synthesize a migration with net.http_post to a forbidden host, audit must catch."""
    bad_path = REPO_ROOT / "supabase" / "migrations" / "_test_synthetic_violation.sql"
    bad_path.write_text(
        "SELECT net.http_post(\n"
        "  url := 'https://api.ticketevolution.com/v9/orders',\n"
        "  body := '{}'::jsonb\n"
        ");\n",
        encoding="utf-8",
    )
    try:
        result = subprocess.run(
            [sys.executable, str(REPO_ROOT / "scripts" / "check_readonly.py")],
            capture_output=True, text=True, cwd=str(REPO_ROOT),
        )
        assert result.returncode == 1, "audit should fail on synthetic plpgsql violation"
        assert "_test_synthetic_violation" in result.stdout
        assert "api.ticketevolution.com" in result.stdout
    finally:
        bad_path.unlink(missing_ok=True)


# ---------- Live DB checks (require SUPABASE_DB_URL) ----------

def _run_query(sql: str) -> list[dict]:
    """Minimal psql-style runner. Returns list of dicts."""
    import psycopg2
    import psycopg2.extras
    with psycopg2.connect(DB_URL) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql)
            return [dict(r) for r in cur.fetchall()]


@skip_no_db
def test_haversine_returns_known_distance():
    """MSG → Yankee Stadium ≈ 6.6 miles. Tolerate ±0.5 mi for grid snap."""
    rows = _run_query(
        "SELECT haversine_miles(40.7505, -73.9934, 40.8296, -73.9262) AS d"
    )
    d = float(rows[0]["d"])
    assert 5.5 <= d <= 7.5, f"MSG→Yankee distance was {d}, expected ~6.6"


@skip_no_db
def test_haversine_zero_self_distance():
    """Same point distance is exactly 0."""
    rows = _run_query(
        "SELECT haversine_miles(40.0, -74.0, 40.0, -74.0) AS d"
    )
    assert float(rows[0]["d"]) == 0.0


@skip_no_db
def test_haversine_handles_nulls():
    """NULL inputs return NULL, not error."""
    rows = _run_query(
        "SELECT haversine_miles(NULL, -74.0, 40.0, -74.0) AS d"
    )
    assert rows[0]["d"] is None


@skip_no_db
def test_tevo_sign_get_strips_brackets():
    """The defensive bracket-strip should produce the same sig as a clean secret."""
    rows = _run_query(
        "SELECT tevo_sign_get('/v9/events', 'page=1', '<my-secret>') AS sig_wrapped, "
        "       tevo_sign_get('/v9/events', 'page=1', 'my-secret')   AS sig_clean"
    )
    assert rows[0]["sig_wrapped"] == rows[0]["sig_clean"], \
        "bracket-strip didn't normalize the signature"


@skip_no_db
def test_tevo_sign_get_canonical_format():
    """Different paths produce different signatures (sanity check)."""
    rows = _run_query(
        "SELECT tevo_sign_get('/v9/events', '', 's') AS a, "
        "       tevo_sign_get('/v9/orders', '', 's') AS b"
    )
    assert rows[0]["a"] != rows[0]["b"], "path is in canonical string but didn't affect sig"


@skip_no_db
def test_canonical_views_exist():
    """Every named canonical view must exist after migration replay."""
    rows = _run_query("""
        SELECT table_name FROM information_schema.views
        WHERE table_schema='public' AND table_name IN (
          'v_canonical_event','v_canonical_performer','v_canonical_venue',
          'v_canonical_coverage','v_event_full','v_event_full_sports',
          'v_pricing_cross_source','v_competing_events','v_event_weather',
          'v_event_weather_with_fallback','v_unmatched_events',
          'our_orders','our_orders_by_event','unified_orders','unified_listings'
        )
    """)
    found = {r["table_name"] for r in rows}
    missing = {
        'v_canonical_event','v_canonical_performer','v_canonical_venue',
        'v_canonical_coverage','v_event_full','v_event_full_sports',
        'v_pricing_cross_source','v_competing_events','v_event_weather',
        'v_event_weather_with_fallback','v_unmatched_events',
        'our_orders','our_orders_by_event','unified_orders','unified_listings'
    } - found
    assert not missing, f"missing canonical views: {missing}"


@skip_no_db
def test_unmatched_events_view_returns_rows():
    """v_unmatched_events should have entries from at least one source."""
    rows = _run_query(
        "SELECT count(*) AS n, count(DISTINCT source_key) AS sources FROM v_unmatched_events"
    )
    assert rows[0]["n"] > 0, "v_unmatched_events is empty — expected SG orphans"


@skip_no_db
def test_competing_events_window_is_24h():
    """All v_competing_events rows must satisfy |hours_offset| ≤ 24."""
    rows = _run_query(
        "SELECT max(abs(hours_offset)) AS max_offset FROM v_competing_events"
    )
    if rows[0]["max_offset"] is not None:
        assert float(rows[0]["max_offset"]) <= 24.0, \
            "v_competing_events leaked rows beyond ±24h"


@skip_no_db
def test_data_source_field_map_audit_clean():
    """No public-data tables should be unmapped in field_map_audit."""
    rows = _run_query(
        "SELECT count(*) AS unmapped FROM data_source_field_map_audit "
        "WHERE NOT has_field_map_rows"
    )
    assert rows[0]["unmapped"] == 0, \
        f"{rows[0]['unmapped']} tables added without field-map rows (drift!)"
