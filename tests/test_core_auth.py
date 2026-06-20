"""Unit tests for the bot-gate token helpers moved into core/auth (BR-CODE-1).

These were untested while inline in app.py. core.auth imports cleanly without
live env (core.config env reads have defaults), so the HMAC round-trip is now
covered directly.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from core.auth import issue_human_token, valid_human_token  # noqa: E402


def test_human_token_roundtrip():
    assert valid_human_token(issue_human_token()) is True


def test_human_token_rejects_empty_and_malformed():
    assert valid_human_token(None) is False
    assert valid_human_token("") is False
    assert valid_human_token("no-dot") is False
    assert valid_human_token("notanint.deadbeef") is False


def test_human_token_rejects_expired():
    # ttl in the past -> exp < now -> invalid
    assert valid_human_token(issue_human_token(ttl=-10)) is False


def test_human_token_rejects_tampered_signature():
    tok = issue_human_token()
    exp_s, _, _sig = tok.partition(".")
    forged = f"{exp_s}.{'0' * 64}"
    assert valid_human_token(forged) is False


def test_human_token_rejects_extended_expiry_with_old_sig():
    # bump the expiry but keep the old signature -> HMAC mismatch -> invalid
    tok = issue_human_token()
    _exp_s, _, sig = tok.partition(".")
    forged = f"{int(time.time()) + 99999}.{sig}"
    assert valid_human_token(forged) is False


from core.auth import verify_recaptcha  # noqa: E402


def test_verify_recaptcha_missing_token_fails_closed():
    # No token -> False without any network call (callers gate on RECAPTCHA_ENABLED
    # before reaching here, so the dormant case never hits this function).
    assert verify_recaptcha(None, "submit", "1.2.3.4") is False
    assert verify_recaptcha("", "submit", None) is False


from core.auth import require_cron_or_auth  # noqa: E402


def test_require_cron_or_auth_accepts_matching_secret(monkeypatch):
    import core.auth as auth_mod
    monkeypatch.setattr(auth_mod, "CRON_SECRET", "s3cr3t")
    assert require_cron_or_auth(None, "s3cr3t") == {"cron": True}


def test_require_cron_or_auth_falls_through_to_auth_when_secret_absent(monkeypatch):
    import core.auth as auth_mod
    # no server secret configured -> never accept a header secret; defer to auth.
    monkeypatch.setattr(auth_mod, "CRON_SECRET", None)
    monkeypatch.setattr(auth_mod, "AUTH_DISABLED", True)  # require_auth returns None
    assert require_cron_or_auth(None, "anything") is None


def test_require_cron_or_auth_wrong_secret_defers_to_auth(monkeypatch):
    import core.auth as auth_mod
    monkeypatch.setattr(auth_mod, "CRON_SECRET", "s3cr3t")
    monkeypatch.setattr(auth_mod, "AUTH_DISABLED", True)
    assert require_cron_or_auth(None, "wrong") is None
