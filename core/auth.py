"""Auth gate — require_auth + the AUTH_DISABLED kill-switch.

Extracted from app.py (BR-CODE-1 core extraction). Security-critical: a
Supabase-JWT check + email-domain enforcement. Moved verbatim — behavior is
pinned by tests/test_security_hardening.py (accepts confirmed domain user;
rejects wrong audience 401 / unconfirmed email 403 / foreign domain 403).

app.py imports `require_auth`, `AUTH_DISABLED`, `_is_production` from here, so
existing `app.<NAME>` reads keep working. Tests that force the gate ON
monkeypatch `core.auth.AUTH_DISABLED` (require_auth reads it as a module
global here); the Supabase lookup stub patches the shared `requests` module,
which this module uses too.

One-directional import: core.auth -> core.config; never imports app.py.
"""
from __future__ import annotations

import hmac
import logging
import os
import secrets
import time

import requests
from fastapi import Header, HTTPException

from core.config import (
    ALLOWED_EMAIL_DOMAIN, CRON_SECRET, SUPABASE_ANON_KEY, SUPABASE_URL,
    RECAPTCHA_SECRET_KEY, RECAPTCHA_MIN_SCORE,
)

# AUTH_DISABLED is a local-dev kill switch. To prevent a misconfig from
# accidentally opening the whole API, it ONLY takes effect when:
#   (a) AUTH_DISABLED=true is set explicitly, AND
#   (b) at least ONE indicator says we're NOT in production.
# Hardened 2026-05-11; broadened beyond Railway-only check to be portable.
_AUTH_DISABLED_REQUESTED = os.environ.get("AUTH_DISABLED", "false").lower() == "true"


def _is_production() -> bool:
    """Conservative production detector. If ANY of these indicators say
    production, we treat it as production (deny the kill-switch)."""
    railway = (os.environ.get("RAILWAY_ENVIRONMENT") or "").lower() == "production"
    generic = (os.environ.get("ENVIRONMENT") or "").lower() == "production"
    node = (os.environ.get("NODE_ENV") or "").lower() == "production"
    py = (os.environ.get("PYTHON_ENV") or "").lower() == "production"
    fly = bool(os.environ.get("FLY_APP_NAME"))  # Fly.io
    render = bool(os.environ.get("RENDER"))     # Render
    # If NO env-indicator is set at all, we're likely local dev — only then
    # honor the kill switch. This errs heavily on the side of safety.
    any_prod_signal = railway or generic or node or py or fly or render
    return any_prod_signal


AUTH_DISABLED = _AUTH_DISABLED_REQUESTED and not _is_production()
if _AUTH_DISABLED_REQUESTED and not AUTH_DISABLED:
    print("WARNING: AUTH_DISABLED=true ignored — production indicator detected (RAILWAY_ENVIRONMENT / ENVIRONMENT / NODE_ENV / PYTHON_ENV / FLY_APP_NAME / RENDER).")


def require_auth(authorization: str | None = Header(None)):
    """Validate a Supabase-issued JWT + enforce email domain.

    Browser sends 'Authorization: Bearer <jwt>' on every API call.
    We hit Supabase's /auth/v1/user to validate the token and get the user,
    then check the email ends in the allowed domain.
    """
    if AUTH_DISABLED:
        return None
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.split(" ", 1)[1].strip()
    if not SUPABASE_URL or not SUPABASE_ANON_KEY:
        raise HTTPException(500, "Supabase auth not configured on server")
    try:
        r = requests.get(
            f"{SUPABASE_URL}/auth/v1/user",
            headers={"Authorization": f"Bearer {token}", "apikey": SUPABASE_ANON_KEY},
            timeout=5,
        )
    except Exception as e:
        # Don't surface internal exception detail externally — may expose
        # Supabase hostnames, connection error strings, or timeout messages
        # that are useful to an attacker mapping our internal topology.
        logging.getLogger(__name__).error("Auth check against Supabase failed: %s", e)
        raise HTTPException(502, "auth check failed — upstream auth service unreachable")
    if not r.ok:
        raise HTTPException(401, "invalid session")
    user = r.json()
    # Stop-gap hardening, mirrors d2_dashboard/main.py require_auth:
    #   - aud must be "authenticated"  → rejects service-role / anon tokens
    #   - email_confirmed_at must be set → rejects unconfirmed signups
    if user.get("aud") != "authenticated":
        raise HTTPException(401, "invalid token audience")
    if not user.get("email_confirmed_at"):
        raise HTTPException(403, "email not confirmed")
    email = (user.get("email") or "").lower()
    if not email.endswith("@" + ALLOWED_EMAIL_DOMAIN.lower()):
        raise HTTPException(403, f"access restricted to @{ALLOWED_EMAIL_DOMAIN}")
    return user


# ---------- "human" cookie — lightweight signed bot-gate token ----------
# A signed, expiring opaque token proving a request cleared the bot gate
# (honeypot / rate-limit / reCAPTCHA). HMAC over the expiry; no PII. The secret
# prefers an explicit SESSION_SIGNING_SECRET, falls back to CRON_SECRET, then a
# per-process random (so a restart just re-issues on next interaction — fine for
# a demo).
_HUMAN_COOKIE_SECRET = (
    os.environ.get("SESSION_SIGNING_SECRET") or CRON_SECRET or secrets.token_hex(32)
).encode()
HUMAN_COOKIE_NAME = "vp_human"
HUMAN_TTL_SECONDS = 1800  # 30 min


def issue_human_token(ttl: int = HUMAN_TTL_SECONDS) -> str:
    """Mint a signed, expiring opaque token: '<exp>.<hex-hmac>'."""
    exp = int(time.time()) + ttl
    sig = hmac.new(_HUMAN_COOKIE_SECRET, str(exp).encode(), "sha256").hexdigest()
    return f"{exp}.{sig}"


def valid_human_token(tok: str | None) -> bool:
    """True iff `tok` is a non-expired token whose HMAC verifies."""
    if not tok or "." not in tok:
        return False
    exp_s, _, sig = tok.partition(".")
    try:
        exp = int(exp_s)
    except ValueError:
        return False
    if exp < int(time.time()):
        return False
    expected = hmac.new(_HUMAN_COOKIE_SECRET, exp_s.encode(), "sha256").hexdigest()
    return hmac.compare_digest(sig, expected)


def verify_recaptcha(token: str | None, expected_action: str, remote_ip: str | None) -> bool:
    """Verify a reCAPTCHA v3 token with Google. Callers gate on RECAPTCHA_ENABLED
    before calling this (so the dormant case never reaches here). Fails OPEN on a
    network/Google error (demo availability), CLOSED on a missing token / explicit
    failure / low score / action mismatch."""
    if not token:
        return False
    try:
        resp = requests.post(
            "https://www.google.com/recaptcha/api/siteverify",
            data={"secret": RECAPTCHA_SECRET_KEY, "response": token, "remoteip": remote_ip or ""},
            timeout=5,
        )
        data = resp.json()
    except Exception as e:  # noqa: BLE001 — network/parse: fail open so a Google blip can't break the demo
        print(f"[recaptcha] verify call failed ({e!r}) — failing open")
        return True
    if not data.get("success"):
        return False
    action = data.get("action")
    if action and expected_action and action != expected_action:
        return False
    return float(data.get("score") or 0.0) >= RECAPTCHA_MIN_SCORE


def require_cron_or_auth(authorization: str | None, x_cron_secret: str | None):
    """Allow either an authenticated user OR a matching X-Cron-Secret.

    Fails closed if CRON_SECRET is not configured on the server — never
    accepts an empty/placeholder secret.
    """
    if x_cron_secret and CRON_SECRET and hmac.compare_digest(x_cron_secret, CRON_SECRET):
        return {"cron": True}
    return require_auth(authorization)
