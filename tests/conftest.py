"""Shared pytest fixtures.

Rate-limiter isolation: app._ip_limiter is a process-global sliding-window
singleton, so without a reset its per-IP/bucket counters accumulate across
every test in the session. Once the cumulative /api/store/* request count
crosses a bucket cap (e.g. 60/min) within a run, a later test gets a spurious
429 — exactly what flaked test_store_seatmap when the storefront test surface
grew. Clearing the limiter before each test isolates them.

Only resets when `app` is already imported (avoids forcing an app import for
tests that don't need it). The dedicated rate-limit tests in
test_security_hardening.py monkeypatch _ip_limiter.check directly, so they are
unaffected by clearing the backing counters.
"""
import sys

import pytest


@pytest.fixture(autouse=True)
def _reset_ip_rate_limiter():
    app_mod = sys.modules.get("app")
    limiter = getattr(app_mod, "_ip_limiter", None) if app_mod else None
    if limiter is not None:
        try:
            limiter._hits.clear()
        except Exception:  # noqa: BLE001 — best-effort isolation, never fail a test here
            pass
    yield
