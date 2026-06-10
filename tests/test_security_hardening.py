"""Tests for the 2026-06-10 security-audit hardening in app.py.

Covers:
  1. require_auth — rejects non-"authenticated" token audience and
     unconfirmed-email accounts (parity with d2_dashboard's require_auth).
  2. _RateLimitMiddleware — keys per-IP buckets on the RIGHTMOST
     X-Forwarded-For entry (appended by our edge proxy), not the leftmost
     (client-forgeable), so a client can't rotate fake IPs to bypass caps.

No real Supabase or network calls — auth lookups are monkeypatched.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

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
from fastapi import HTTPException  # noqa: E402

TestClient = starlette_testclient.TestClient


# ---------- require_auth hardening ----------

class _FakeAuthResponse:
    def __init__(self, payload: dict, ok: bool = True):
        self._payload = payload
        self.ok = ok

    def json(self) -> dict:
        return self._payload


def _good_user(**overrides) -> dict:
    user = {
        "aud": "authenticated",
        "email": f"ops@{app_module.ALLOWED_EMAIL_DOMAIN}",
        "email_confirmed_at": "2026-01-01T00:00:00Z",
    }
    user.update(overrides)
    return user


@pytest.fixture()
def live_auth(monkeypatch):
    """Force the auth gate ON and stub the Supabase /auth/v1/user lookup."""
    monkeypatch.setattr(app_module, "AUTH_DISABLED", False)

    def _set_user(payload: dict, ok: bool = True):
        monkeypatch.setattr(
            app_module.requests, "get",
            lambda *a, **kw: _FakeAuthResponse(payload, ok=ok),
        )

    return _set_user


def test_require_auth_accepts_confirmed_domain_user(live_auth):
    live_auth(_good_user())
    user = app_module.require_auth("Bearer test-jwt")
    assert user["aud"] == "authenticated"


def test_require_auth_rejects_wrong_audience(live_auth):
    live_auth(_good_user(aud="anon"))
    with pytest.raises(HTTPException) as exc:
        app_module.require_auth("Bearer test-jwt")
    assert exc.value.status_code == 401
    assert "audience" in exc.value.detail


def test_require_auth_rejects_unconfirmed_email(live_auth):
    live_auth(_good_user(email_confirmed_at=None))
    with pytest.raises(HTTPException) as exc:
        app_module.require_auth("Bearer test-jwt")
    assert exc.value.status_code == 403
    assert "confirmed" in exc.value.detail


def test_require_auth_rejects_foreign_domain(live_auth):
    live_auth(_good_user(email="mallory@evil.example"))
    with pytest.raises(HTTPException) as exc:
        app_module.require_auth("Bearer test-jwt")
    assert exc.value.status_code == 403


# ---------- rate limiter XFF handling ----------

@pytest.fixture()
def captured_keys(monkeypatch):
    """Capture the keys _RateLimitMiddleware feeds to the limiter (always
    allowing the request through)."""
    keys: list[str] = []

    def _check(key: str, n: int, w: float) -> bool:
        keys.append(key)
        return True

    monkeypatch.setattr(app_module._ip_limiter, "check", _check)
    return keys


def test_rate_limit_keys_on_rightmost_xff_entry(captured_keys):
    client = TestClient(app_module.app)
    client.get(
        "/version.json",
        headers={"X-Forwarded-For": "6.6.6.6, 203.0.113.9"},
    )
    assert captured_keys, "rate limiter was not consulted"
    ip = captured_keys[-1].split("|")[0]
    assert ip == "203.0.113.9", (
        "limiter must key on the proxy-appended (rightmost) XFF hop, "
        f"got {ip!r} — leftmost is client-forgeable"
    )


def test_rate_limit_client_cannot_rotate_buckets_via_xff(captured_keys):
    client = TestClient(app_module.app)
    for fake in ("1.1.1.1", "2.2.2.2", "3.3.3.3"):
        client.get(
            "/version.json",
            headers={"X-Forwarded-For": f"{fake}, 203.0.113.9"},
        )
    ips = {k.split("|")[0] for k in captured_keys}
    assert ips == {"203.0.113.9"}, (
        f"prepending fake XFF entries must not change the bucket key: {ips}"
    )
