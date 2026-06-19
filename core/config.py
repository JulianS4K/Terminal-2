"""Runtime configuration constants (env-derived).

Extracted verbatim from app.py's bootstrap block (BR-CODE-1 core extraction).
app.py imports these names, so existing `app.<NAME>` reads + the test
monkeypatches against the app module continue to work unchanged.

NOTE: the auth kill-switch (`AUTH_DISABLED` / `_is_production`) intentionally
STAYS in app.py — it is part of the auth gate (`require_auth`) and is read +
monkeypatched there. Only the pure config values live here.
"""
from __future__ import annotations

import os

# ---------- Supabase + cross-cutting ----------
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_SERVICE_ROLE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
CRON_SECRET = os.environ.get("CRON_SECRET")
ALLOWED_EMAIL_DOMAIN = os.environ.get("ALLOWED_EMAIL_DOMAIN", "s4kent.com")

# ---------- Storefront mode flags ----------
# STOREFRONT_SQL_ONLY — demo mode for pre-checkout MVP. When on, store routes
# read from listings_snapshots (cron-collected) instead of going live to TEvo,
# /reserve skips TEvo validation, and /events/near forces source=supabase.
STOREFRONT_SQL_ONLY = os.environ.get("STOREFRONT_SQL_ONLY", "false").lower() == "true"
if STOREFRONT_SQL_ONLY:
    print("STOREFRONT_SQL_ONLY=true — storefront serves from listings_snapshots; no live TEvo calls on store routes.")

# STOREFRONT_SEARCH_SQL_ONLY — independent flag for /api/store/search routing.
# Splits search off from STOREFRONT_SQL_ONLY so search defaults to SQL while
# event-detail stays on TEvo live. STOREFRONT_SQL_ONLY=true still wins (both SQL).
STOREFRONT_SEARCH_SQL_ONLY = os.environ.get("STOREFRONT_SEARCH_SQL_ONLY", "true").lower() == "true"
if STOREFRONT_SEARCH_SQL_ONLY and not STOREFRONT_SQL_ONLY:
    print("STOREFRONT_SEARCH_SQL_ONLY=true — /api/store/search uses _search_sql_only; event-detail still live TEvo.")

# STOREFRONT_PREFER_INTERNAL_ZONES — flip on once the hand-curated granular
# zones cover most/all sections; default surfaces the well-covered consumer-bowl.
STOREFRONT_PREFER_INTERNAL_ZONES = (
    os.environ.get("STOREFRONT_PREFER_INTERNAL_ZONES", "false").lower() == "true"
)
if STOREFRONT_PREFER_INTERNAL_ZONES:
    print("STOREFRONT_PREFER_INTERNAL_ZONES=true — granular zones preferred when (performer, venue) has them.")

# Reserve endpoint auth gate. Default true — unauthenticated state-changing
# routes are wrong by default. MVP demo envs must explicitly opt out.
STOREFRONT_RESERVE_REQUIRES_AUTH = (
    os.environ.get("STOREFRONT_RESERVE_REQUIRES_AUTH", "true").lower() == "true"
)
if not STOREFRONT_RESERVE_REQUIRES_AUTH:
    print("STOREFRONT_RESERVE_REQUIRES_AUTH=false — /api/store/reserve is UNAUTHENTICATED (MVP demo mode).")

# TEvo Hosted Checkout — DORMANT until the operator provisions the domain.
STOREFRONT_CHECKOUT_DOMAIN = os.environ.get("STOREFRONT_CHECKOUT_DOMAIN", "").strip()
# Live online checkout is intentionally DISABLED (operator directive 2026-06):
# /api/public/config force-returns checkout off regardless of the env var.
STOREFRONT_CHECKOUT_DISABLED = True
if STOREFRONT_CHECKOUT_DOMAIN and STOREFRONT_CHECKOUT_DISABLED:
    print(f"STOREFRONT_CHECKOUT_DOMAIN={STOREFRONT_CHECKOUT_DOMAIN} is set but IGNORED — live checkout is force-disabled (STOREFRONT_CHECKOUT_DISABLED).")

# ---------- Bot protection: Google reCAPTCHA v3 ----------
# DORMANT unless both keys are set. When enabled, store.js fetches a v3 token,
# the server issues a short-lived signed cookie; fails OPEN on a Google outage.
RECAPTCHA_SITE_KEY = os.environ.get("RECAPTCHA_SITE_KEY", "").strip()
RECAPTCHA_SECRET_KEY = os.environ.get("RECAPTCHA_SECRET_KEY", "").strip()
try:
    RECAPTCHA_MIN_SCORE = float(os.environ.get("RECAPTCHA_MIN_SCORE", "0.5"))
except ValueError:
    RECAPTCHA_MIN_SCORE = 0.5
RECAPTCHA_ENABLED = bool(RECAPTCHA_SITE_KEY and RECAPTCHA_SECRET_KEY)
if RECAPTCHA_ENABLED:
    print(f"reCAPTCHA v3 ENABLED — sitewide bot gate active (min score {RECAPTCHA_MIN_SCORE}).")
else:
    print("reCAPTCHA v3 dormant (RECAPTCHA_SITE_KEY/RECAPTCHA_SECRET_KEY unset) — honeypot + rate limits still active.")
