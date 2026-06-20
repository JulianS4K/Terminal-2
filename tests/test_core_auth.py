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
