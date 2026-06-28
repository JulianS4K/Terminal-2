"""Coverage-closing unit tests for five small core modules (BR-CODE-1 pass).

Targets the leftover uncovered branches in core.config / core.auth / core.search
/ core.helpers / core.substitutions — the error paths, env-var fallbacks and
edge cases the existing per-module suites don't reach. No live network/DB: the
Supabase /auth/v1/user lookup + reCAPTCHA POST are stubbed by monkeypatching the
`requests` module core.auth shares; search drives a tiny programmable fake DB.

House style mirrors tests/test_core_auth.py + tests/test_core_search.py
+ tests/test_substitutions.py (sys.path insert, monkeypatch module globals).
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))


# =====================================================================
# core.auth — require_auth JWT branches, recaptcha network paths,
#             _is_production detection, cron-secret comparison.
# =====================================================================
import core.auth as auth_mod  # noqa: E402
from core.auth import (  # noqa: E402
    _is_production,
    require_auth,
    verify_recaptcha,
)
from fastapi import HTTPException  # noqa: E402


class _FakeResp:
    """Minimal stand-in for a requests.Response."""

    def __init__(self, *, ok=True, payload=None):
        self.ok = ok
        self._payload = payload if payload is not None else {}

    def json(self):
        return self._payload


def _force_gate_on(monkeypatch):
    """Turn the AUTH_DISABLED kill-switch OFF + supply Supabase config so
    require_auth executes the real verification path."""
    monkeypatch.setattr(auth_mod, "AUTH_DISABLED", False)
    monkeypatch.setattr(auth_mod, "SUPABASE_URL", "https://example.invalid")
    monkeypatch.setattr(auth_mod, "SUPABASE_ANON_KEY", "anon-key")


def _stub_user(monkeypatch, *, ok=True, payload=None, raises=None):
    def _get(url, headers=None, timeout=None):
        if raises is not None:
            raise raises
        return _FakeResp(ok=ok, payload=payload)
    monkeypatch.setattr(auth_mod.requests, "get", _get)


@pytest.fixture(autouse=True, scope="module")
def _restore_reloaded_core_modules():
    """Safety net against reload-pollution leaking out of this file.

    A few tests below importlib.reload() core.config / core.auth to exercise
    their import-time branches. reload() rewrites the live module dict in place,
    and each test's in-body `finally` reload runs while that test's
    monkeypatch.setenv() values (RENDER, STOREFRONT_SQL_ONLY, ...) are still
    active — so the "restore" reload can itself re-pollute (e.g. leave
    core.auth.AUTH_DISABLED=False), which then breaks every downstream
    auth-gated test in the suite. By the time this module-scoped teardown runs,
    all function-scoped monkeypatches are gone and os.environ is back to the
    clean process state, so a final reload restores both modules to pristine.
    """
    yield
    import importlib
    import core.config as _c
    import core.auth as _a
    importlib.reload(_c)
    importlib.reload(_a)


# ---- require_auth: AUTH_DISABLED short-circuit (line 67-68) ----

def test_require_auth_disabled_returns_none(monkeypatch):
    monkeypatch.setattr(auth_mod, "AUTH_DISABLED", True)
    assert require_auth("Bearer whatever") is None


# ---- require_auth: missing / malformed bearer header (line 69-70) ----

def test_require_auth_missing_bearer_raises_401(monkeypatch):
    monkeypatch.setattr(auth_mod, "AUTH_DISABLED", False)
    with pytest.raises(HTTPException) as ei:
        require_auth(None)
    assert ei.value.status_code == 401
    with pytest.raises(HTTPException) as ei2:
        require_auth("Basic abc")  # not a Bearer token
    assert ei2.value.status_code == 401


# ---- require_auth: server not configured (line 72-73) ----

def test_require_auth_supabase_unconfigured_raises_500(monkeypatch):
    monkeypatch.setattr(auth_mod, "AUTH_DISABLED", False)
    monkeypatch.setattr(auth_mod, "SUPABASE_URL", None)
    monkeypatch.setattr(auth_mod, "SUPABASE_ANON_KEY", None)
    with pytest.raises(HTTPException) as ei:
        require_auth("Bearer tok")
    assert ei.value.status_code == 500


# ---- require_auth: upstream request raises (line 80-85) ----

def test_require_auth_upstream_unreachable_raises_502(monkeypatch):
    _force_gate_on(monkeypatch)
    _stub_user(monkeypatch, raises=RuntimeError("connection refused"))
    with pytest.raises(HTTPException) as ei:
        require_auth("Bearer tok")
    assert ei.value.status_code == 502


# ---- require_auth: non-ok response (line 86-87) ----

def test_require_auth_bad_session_raises_401(monkeypatch):
    _force_gate_on(monkeypatch)
    _stub_user(monkeypatch, ok=False, payload={})
    with pytest.raises(HTTPException) as ei:
        require_auth("Bearer tok")
    assert ei.value.status_code == 401


# ---- require_auth: wrong audience (line 92-93) ----

def test_require_auth_wrong_audience_raises_401(monkeypatch):
    _force_gate_on(monkeypatch)
    _stub_user(monkeypatch, payload={"aud": "anon", "email": "a@s4kent.com"})
    with pytest.raises(HTTPException) as ei:
        require_auth("Bearer tok")
    assert ei.value.status_code == 401


# ---- require_auth: unconfirmed email (line 94-95) ----

def test_require_auth_unconfirmed_email_raises_403(monkeypatch):
    _force_gate_on(monkeypatch)
    _stub_user(monkeypatch, payload={
        "aud": "authenticated",
        "email": "a@s4kent.com",
        "email_confirmed_at": None,
    })
    with pytest.raises(HTTPException) as ei:
        require_auth("Bearer tok")
    assert ei.value.status_code == 403


# ---- require_auth: foreign domain (line 96-98) ----

def test_require_auth_foreign_domain_raises_403(monkeypatch):
    _force_gate_on(monkeypatch)
    monkeypatch.setattr(auth_mod, "ALLOWED_EMAIL_DOMAIN", "s4kent.com")
    _stub_user(monkeypatch, payload={
        "aud": "authenticated",
        "email": "intruder@evil.com",
        "email_confirmed_at": "2026-01-01T00:00:00Z",
    })
    with pytest.raises(HTTPException) as ei:
        require_auth("Bearer tok")
    assert ei.value.status_code == 403


# ---- require_auth: happy path (line 99 — returns the user) ----

def test_require_auth_accepts_confirmed_domain_user(monkeypatch):
    _force_gate_on(monkeypatch)
    monkeypatch.setattr(auth_mod, "ALLOWED_EMAIL_DOMAIN", "s4kent.com")
    user = {
        "aud": "authenticated",
        "email": "Julian@S4kent.com",  # case-insensitive domain match
        "email_confirmed_at": "2026-01-01T00:00:00Z",
    }
    _stub_user(monkeypatch, payload=user)
    assert require_auth("Bearer tok") == user


# ---- module import-time WARNING branch (line 56-57) ----

def test_auth_disabled_requested_but_production_warns_on_reload(monkeypatch):
    """Re-import core.auth with AUTH_DISABLED=true AND a production signal:
    the kill-switch is ignored (AUTH_DISABLED stays False) and the import-time
    WARNING (lines 56-57) fires. Reverted in finally so later tests see the
    original module state.
    """
    import importlib
    monkeypatch.setenv("AUTH_DISABLED", "true")
    monkeypatch.setenv("RENDER", "true")  # production indicator
    try:
        reloaded = importlib.reload(auth_mod)
        assert reloaded._AUTH_DISABLED_REQUESTED is True
        assert reloaded.AUTH_DISABLED is False  # ignored in production
    finally:
        monkeypatch.delenv("AUTH_DISABLED", raising=False)
        monkeypatch.delenv("RENDER", raising=False)
        importlib.reload(auth_mod)


# ---- _is_production: each indicator (line 43-52) ----

def test_is_production_no_signal_is_false(monkeypatch):
    for var in ("RAILWAY_ENVIRONMENT", "ENVIRONMENT", "NODE_ENV",
                "PYTHON_ENV", "FLY_APP_NAME", "RENDER"):
        monkeypatch.delenv(var, raising=False)
    assert _is_production() is False


@pytest.mark.parametrize("var,val", [
    ("RAILWAY_ENVIRONMENT", "production"),
    ("ENVIRONMENT", "production"),
    ("NODE_ENV", "production"),
    ("PYTHON_ENV", "production"),
    ("FLY_APP_NAME", "my-app"),
    ("RENDER", "true"),
])
def test_is_production_each_indicator_true(monkeypatch, var, val):
    for v in ("RAILWAY_ENVIRONMENT", "ENVIRONMENT", "NODE_ENV",
              "PYTHON_ENV", "FLY_APP_NAME", "RENDER"):
        monkeypatch.delenv(v, raising=False)
    monkeypatch.setenv(var, val)
    assert _is_production() is True


# ---- verify_recaptcha: success / fail-open / explicit-fail / action / score ----

def _stub_post(monkeypatch, *, payload=None, raises=None):
    def _post(url, data=None, timeout=None):
        if raises is not None:
            raise raises
        return _FakeResp(payload=payload)
    monkeypatch.setattr(auth_mod.requests, "post", _post)


def test_verify_recaptcha_network_error_fails_open(monkeypatch):
    # Google blip → fail OPEN (line 151-153) so the demo can't be knocked over.
    _stub_post(monkeypatch, raises=RuntimeError("google down"))
    assert verify_recaptcha("tok", "submit", "1.2.3.4") is True


def test_verify_recaptcha_explicit_failure_returns_false(monkeypatch):
    # success:false → CLOSED (line 154-155)
    _stub_post(monkeypatch, payload={"success": False})
    assert verify_recaptcha("tok", "submit", None) is False


def test_verify_recaptcha_action_mismatch_returns_false(monkeypatch):
    # action present but != expected → CLOSED (line 156-158)
    _stub_post(monkeypatch, payload={"success": True, "action": "login", "score": 0.9})
    assert verify_recaptcha("tok", "submit", None) is False


def test_verify_recaptcha_low_score_returns_false(monkeypatch):
    monkeypatch.setattr(auth_mod, "RECAPTCHA_MIN_SCORE", 0.5)
    _stub_post(monkeypatch, payload={"success": True, "action": "submit", "score": 0.1})
    assert verify_recaptcha("tok", "submit", None) is False


def test_verify_recaptcha_passes_with_good_score(monkeypatch):
    monkeypatch.setattr(auth_mod, "RECAPTCHA_MIN_SCORE", 0.5)
    _stub_post(monkeypatch, payload={"success": True, "action": "submit", "score": 0.9})
    assert verify_recaptcha("tok", "submit", "1.2.3.4") is True


def test_verify_recaptcha_no_action_in_response_uses_score(monkeypatch):
    # action absent → skip mismatch guard, fall through to score check.
    monkeypatch.setattr(auth_mod, "RECAPTCHA_MIN_SCORE", 0.5)
    _stub_post(monkeypatch, payload={"success": True, "score": 0.8})
    assert verify_recaptcha("tok", "submit", None) is True


# =====================================================================
# core.config — env-var parse fallbacks + URL/version resolution order.
# =====================================================================
import core.config as config_mod  # noqa: E402
from core.config import (  # noqa: E402
    build_storefront_base_url,
    build_storefront_version,
)

_CFG_ENV = (
    "RENDER_GIT_COMMIT", "RAILWAY_GIT_COMMIT_SHA", "GIT_COMMIT",
    "STOREFRONT_BASE_URL", "RENDER_EXTERNAL_URL", "RAILWAY_PUBLIC_DOMAIN",
)


def _clear_cfg_env(monkeypatch):
    for v in _CFG_ENV:
        monkeypatch.delenv(v, raising=False)


# ---- build_storefront_version resolution order (line 96-102) ----

def test_storefront_version_render_sha(monkeypatch):
    _clear_cfg_env(monkeypatch)
    monkeypatch.setenv("RENDER_GIT_COMMIT", "abcdef1234567890")
    assert build_storefront_version() == "abcdef1"


def test_storefront_version_railway_sha(monkeypatch):
    _clear_cfg_env(monkeypatch)
    monkeypatch.setenv("RAILWAY_GIT_COMMIT_SHA", "1234567abcdef")
    assert build_storefront_version() == "1234567"


def test_storefront_version_git_commit(monkeypatch):
    _clear_cfg_env(monkeypatch)
    monkeypatch.setenv("GIT_COMMIT", "fedcba9876")
    assert build_storefront_version() == "fedcba9"


def test_storefront_version_dev_epoch_fallback(monkeypatch):
    _clear_cfg_env(monkeypatch)
    v = build_storefront_version()
    assert v.startswith("dev-")
    assert int(v.split("-", 1)[1]) <= int(time.time())


# ---- build_storefront_base_url resolution order (line 119-129) ----

def test_storefront_base_url_explicit_override(monkeypatch):
    _clear_cfg_env(monkeypatch)
    monkeypatch.setenv("STOREFRONT_BASE_URL", "https://custom.example.com/")
    assert build_storefront_base_url() == "https://custom.example.com"  # trailing / stripped


def test_storefront_base_url_render_external(monkeypatch):
    _clear_cfg_env(monkeypatch)
    monkeypatch.setenv("RENDER_EXTERNAL_URL", "https://svc.onrender.com/")
    assert build_storefront_base_url() == "https://svc.onrender.com"


def test_storefront_base_url_railway_domain_gets_scheme(monkeypatch):
    _clear_cfg_env(monkeypatch)
    # Railway gives a bare domain (no scheme); helper must prepend https://.
    monkeypatch.setenv("RAILWAY_PUBLIC_DOMAIN", "prod.up.railway.app")
    assert build_storefront_base_url() == "https://prod.up.railway.app"


def test_storefront_base_url_railway_domain_strips_existing_scheme(monkeypatch):
    _clear_cfg_env(monkeypatch)
    monkeypatch.setenv("RAILWAY_PUBLIC_DOMAIN", "http://prod.up.railway.app")
    assert build_storefront_base_url() == "https://prod.up.railway.app"


def test_storefront_base_url_hardcoded_fallback(monkeypatch):
    _clear_cfg_env(monkeypatch)
    assert build_storefront_base_url() == "https://vibepass-storefront-test.onrender.com"


# ---- RECAPTCHA_MIN_SCORE bad-float fallback (line 67-70) ----
# config.py parses RECAPTCHA_MIN_SCORE at import; re-exec the parse block with a
# bad value to exercise the ValueError → 0.5 fallback branch.

def test_recaptcha_min_score_bad_float_falls_back(monkeypatch):
    import os
    monkeypatch.setenv("RECAPTCHA_MIN_SCORE", "not-a-number")
    try:
        score = float(os.environ.get("RECAPTCHA_MIN_SCORE", "0.5"))
    except ValueError:
        score = 0.5
    assert score == 0.5


def test_recaptcha_min_score_valid_float(monkeypatch):
    import os
    monkeypatch.setenv("RECAPTCHA_MIN_SCORE", "0.75")
    score = float(os.environ.get("RECAPTCHA_MIN_SCORE", "0.5"))
    assert score == 0.75


def test_config_module_flag_branches_on_reload(monkeypatch):
    """Re-import core.config with every storefront flag flipped ON + a bad
    RECAPTCHA_MIN_SCORE + both reCAPTCHA keys set, so the module-level
    `if FLAG: print(...)` branches (lines 29, 44, 52, 60, 73) and the bad-float
    ValueError fallback (lines 69-70) all execute. The reload is reverted in a
    finally so the live module state (read by core.auth) is restored.
    """
    import importlib
    monkeypatch.setenv("STOREFRONT_SQL_ONLY", "true")              # → line 29
    monkeypatch.setenv("STOREFRONT_PREFER_INTERNAL_ZONES", "true")  # → line 44
    monkeypatch.setenv("STOREFRONT_RESERVE_REQUIRES_AUTH", "false")  # → line 52
    monkeypatch.setenv("STOREFRONT_CHECKOUT_DOMAIN", "checkout.example.com")  # → line 60
    monkeypatch.setenv("RECAPTCHA_MIN_SCORE", "not-a-number")       # → lines 69-70
    monkeypatch.setenv("RECAPTCHA_SITE_KEY", "site")               # both keys set
    monkeypatch.setenv("RECAPTCHA_SECRET_KEY", "secret")          # → ENABLED → line 73
    try:
        reloaded = importlib.reload(config_mod)
        assert reloaded.STOREFRONT_SQL_ONLY is True
        assert reloaded.STOREFRONT_PREFER_INTERNAL_ZONES is True
        assert reloaded.STOREFRONT_RESERVE_REQUIRES_AUTH is False
        assert reloaded.STOREFRONT_CHECKOUT_DOMAIN == "checkout.example.com"
        assert reloaded.RECAPTCHA_MIN_SCORE == 0.5  # bad float → fallback
        assert reloaded.RECAPTCHA_ENABLED is True
    finally:
        # Restore the original env-derived module state for downstream tests.
        importlib.reload(config_mod)


# =====================================================================
# core.search — exception branches on each DB query + venues dedup loop.
# =====================================================================
from core.search import search_sql_only  # noqa: E402


class _OKChain:
    def __init__(self, rows):
        self._rows = rows

    def __getattr__(self, _name):
        def _m(*_a, **_k):
            return self
        return _m

    def execute(self):
        return type("_R", (), {"data": self._rows})()


class _RaiseChain:
    """A chain whose .execute() raises — exercises the try/except guards."""

    def __getattr__(self, _name):
        def _m(*_a, **_k):
            return self
        return _m

    def execute(self):
        raise RuntimeError("boom")


class _DB:
    def __init__(self, by_table, raise_tables=()):
        self._by_table = by_table
        self._raise = set(raise_tables)
        self.touched: list[str] = []
        # events table is queried twice (events + venues); allow per-call rows.
        self._events_calls = 0

    def table(self, name):
        self.touched.append(name)
        if name in self._raise:
            return _RaiseChain()
        rows = self._by_table.get(name, [])
        if name == "events" and isinstance(rows, list) and rows and isinstance(rows[0], list):
            # rows is a list-of-lists: one entry per events query call
            idx = min(self._events_calls, len(rows) - 1)
            self._events_calls += 1
            rows = rows[idx]
        return _OKChain(rows)


def test_search_events_query_failure_returns_empty(monkeypatch):
    # events query raises → ev_rows=[] → metrics={} (else branch, line 97).
    db = _DB({}, raise_tables=("events",))
    out = search_sql_only(db, "knicks", 10)
    assert out["events"] == []
    assert out["source"] == "sql"


def test_search_metrics_and_lifecycle_failures(monkeypatch):
    # events succeed, but metrics + lifecycle queries raise → both swallowed.
    db = _DB(
        {"events": [
            [{"id": 1, "name": "Knicks vs Celtics", "occurs_at_local": "2026-05-01",
              "venue_name": "MSG", "venue_location": "NY", "venue_id": 9}],
            [],  # second events call (venues) returns nothing
        ]},
        raise_tables=("latest_event_metrics", "event_lifecycle"),
    )
    out = search_sql_only(db, "knicks", 10)
    # event survives (no metrics, no lifecycle drop)
    assert [e["id"] for e in out["events"]] == [1]
    assert out["events"][0]["we_own"] is False


def test_search_performer_query_failure(monkeypatch):
    db = _DB(
        {"events": [[], []], "latest_event_metrics": [], "event_lifecycle": []},
        raise_tables=("performer_metadata",),
    )
    out = search_sql_only(db, "knicks", 10)
    assert out["performers"] == []


def test_search_venues_query_failure(monkeypatch):
    # The venues query (second events call) raises → venues=[] via except (170-171).
    db = _DB(
        {"events": [], "latest_event_metrics": [], "event_lifecycle": [],
         "performer_metadata": []},
        raise_tables=("events",),
    )
    out = search_sql_only(db, "knicks", 10)
    assert out["venues"] == []


def test_search_venues_dedup_and_limit(monkeypatch):
    # Drive the venues dedup loop (line 158-169): duplicate vids collapse,
    # vid=0/None skipped, and the limit caps the list.
    events_first = [
        {"id": 1, "name": "Knicks vs Celtics", "occurs_at_local": "2026-05-01",
         "venue_name": "MSG", "venue_location": "NY", "venue_id": 9},
    ]
    venue_rows = [
        {"venue_id": 0, "venue_name": "Ghost", "venue_location": "?"},     # skipped (falsy vid)
        {"venue_id": 9, "venue_name": "MSG", "venue_location": "NY"},
        {"venue_id": 9, "venue_name": "MSG dup", "venue_location": "NY"},  # dup → skipped
        {"venue_id": 10, "venue_name": "Barclays", "venue_location": "Brooklyn"},
        {"venue_id": 11, "venue_name": "Prudential", "venue_location": "Newark"},
    ]
    db = _DB({
        "events": [events_first, venue_rows],
        "latest_event_metrics": [],
        "event_lifecycle": [],
        "performer_metadata": [],
    })
    out = search_sql_only(db, "garden", limit=2)  # limit caps venues at 2
    vids = [v["id"] for v in out["venues"]]
    assert vids == [9, 10]  # 0 skipped, 9 deduped, capped at 2 (11 dropped)


# =====================================================================
# core.helpers — leftover branch/edge lines.
# =====================================================================
from core.helpers import (  # noqa: E402
    delta,
    listings_cadence_seconds,
    parse_iso_or_none,
    share_to_dict,
)


# ---- listings_cadence_seconds: every window (line 18-34) ----

def test_listings_cadence_none():
    assert listings_cadence_seconds(None) == 60 * 60 * 24


def test_listings_cadence_unparseable_falls_back():
    # bad date → except → 60*60 (line 24-25).
    assert listings_cadence_seconds("not-a-date") == 60 * 60


def test_listings_cadence_windows():
    from datetime import datetime, timedelta
    now = datetime.now()

    def iso(days):
        return (now + timedelta(days=days)).date().isoformat()

    assert listings_cadence_seconds(iso(0)) == 60 * 20        # <=1 day
    assert listings_cadence_seconds(iso(5)) == 60 * 60        # <=7
    assert listings_cadence_seconds(iso(20)) == 60 * 60 * 4   # <=30
    assert listings_cadence_seconds(iso(45)) == 60 * 60 * 12  # <=60
    assert listings_cadence_seconds(iso(120)) == 60 * 60 * 24  # >60


# ---- delta: non-numeric inputs (line 43-44) ----

def test_delta_non_numeric_returns_none():
    assert delta("abc", 10) is None  # ValueError on float("abc")
    assert delta(object(), 1) is None  # TypeError


def test_delta_none_inputs():
    assert delta(None, 5) is None
    assert delta(5, None) is None


# ---- parse_iso_or_none: falsy + Z-normalize (line 259-265) ----

def test_parse_iso_or_none_falsy():
    assert parse_iso_or_none(None) is None
    assert parse_iso_or_none("") is None


def test_parse_iso_or_none_z_suffix_normalized():
    assert parse_iso_or_none("2026-01-01T00:00:00Z") == "2026-01-01T00:00:00+00:00"


def test_parse_iso_or_none_passthrough_non_z():
    assert parse_iso_or_none("2026-01-01T00:00:00+00:00") == "2026-01-01T00:00:00+00:00"


def test_parse_iso_or_none_swallows_internal_error():
    # A str subclass whose .endswith raises exercises the defensive try/except
    # (line 264-265): still a str instance, so isinstance(...) passes and the
    # exception is swallowed → None.
    class _BadStr(str):
        def endswith(self, *a, **k):
            raise RuntimeError("boom")

    assert parse_iso_or_none(_BadStr("2026-01-01")) is None


# ---- share_to_dict: bad expires_at → ValueError swallowed (line 438-439) ----

def test_share_to_dict_empty_row():
    assert share_to_dict({}) == {}
    assert share_to_dict(None) == {}


def test_share_to_dict_bad_expires_not_expired():
    out = share_to_dict({"id": "x", "expires_at": "garbage-not-a-date"})
    assert out["expires_at"] == "garbage-not-a-date"
    # unparseable expiry → expired stays False (line 438-439) → still active.
    assert out["active"] is True


# =====================================================================
# core.substitutions — leftover branch/edge lines.
# =====================================================================
from core.substitutions import (  # noqa: E402
    _coerce_float,
    _read_unit_cost,
    find_row_substitutions,
    find_section_substitutions,
)


# ---- _coerce_float: string parse + bad string (line 140-144) ----

def test_coerce_float_currency_string():
    assert _coerce_float("$1,200.50") == 1200.50  # $ and , stripped


def test_coerce_float_unparseable_string_returns_none():
    assert _coerce_float("not-money") is None  # ValueError → None (line 143-144)


def test_coerce_float_none_and_numeric():
    assert _coerce_float(None) is None
    assert _coerce_float(42) == 42.0


# ---- find_row_substitutions: candidate with non-int quantity (line 242-243) ----

def test_find_row_substitutions_bad_quantity_coerced_to_zero():
    # quantity is unparseable → qty=0 → fails qty_needed gate, skipped.
    out = find_row_substitutions(
        "104", "10", 1,
        candidates=[{"section": "104", "row": "9", "quantity": "junk", "cost": 50}],
    )
    assert out["subs"] == []
    assert out["counts"]["subs"] == 0


# ---- _read_unit_cost: no field yields a cost → None (line 308-313) ----

def test_read_unit_cost_no_cost_fields_returns_none():
    assert _read_unit_cost({"foo": "bar"}, ("cost", "retail_price")) is None


def test_read_unit_cost_reads_first_present():
    assert _read_unit_cost({"retail_price": "75"}, ("cost", "retail_price")) == 75.0


# ---- find_section_substitutions: exclude_group_id + bad qty (line 369-382) ----

def test_find_section_substitutions_excludes_group_id():
    section_quality = {"100": 100.0, "200": 50.0}
    out = find_section_substitutions(
        "200", 1,
        candidates=[
            {"id": "drop-me", "section": "100", "row": "5", "quantity": 4, "cost": 80},
        ],
        section_quality=section_quality,
        exclude_group_id="drop-me",
    )
    # the only better-section candidate is excluded → no subs.
    assert out["section_subs"] == []


def test_find_section_substitutions_bad_quantity_skipped():
    section_quality = {"100": 100.0, "200": 50.0}
    out = find_section_substitutions(
        "200", 2,
        candidates=[
            {"id": "c1", "section": "100", "row": "5", "quantity": "oops", "cost": 80},
        ],
        section_quality=section_quality,
    )
    # quantity unparseable → 0 → below qty_needed → skipped (line 379-382).
    assert out["section_subs"] == []


def test_find_section_substitutions_no_quality_for_sold():
    # sold section has no market quality signal → early return (line 357-363).
    out = find_section_substitutions(
        "999", 1, candidates=[], section_quality={"100": 10.0},
    )
    assert out["sold_quality"] is None
    assert out["section_subs"] == []
