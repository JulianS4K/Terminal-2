"""Tests for core/observability.py — structured logging config + opt-in Sentry.

No real Sentry network: sentry_sdk.init is monkeypatched to capture its kwargs.
Every branch (DSN present/absent, sdk import-error, bad LOG_LEVEL / traces rate,
env detection) is exercised so the module stays at 100% line+branch.
"""
from __future__ import annotations

import builtins
import logging

import sentry_sdk

from core import observability as obs


# ---------- _resolve_level ----------

def test_resolve_level_default_info(monkeypatch):
    monkeypatch.delenv("LOG_LEVEL", raising=False)
    assert obs._resolve_level(None) == logging.INFO


def test_resolve_level_from_env(monkeypatch):
    monkeypatch.setenv("LOG_LEVEL", "warning")
    assert obs._resolve_level(None) == logging.WARNING


def test_resolve_level_explicit_arg_wins(monkeypatch):
    monkeypatch.setenv("LOG_LEVEL", "ERROR")
    assert obs._resolve_level("debug") == logging.DEBUG


def test_resolve_level_unknown_falls_back_to_info(monkeypatch):
    monkeypatch.delenv("LOG_LEVEL", raising=False)
    assert obs._resolve_level("NOPE") == logging.INFO


# ---------- configure_logging ----------

def test_configure_logging_sets_level(monkeypatch):
    obs.configure_logging("WARNING")
    assert logging.getLogger().level == logging.WARNING
    obs.configure_logging("INFO")  # restore a sane default for the rest of the run


# ---------- _environment ----------

def test_environment_explicit(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "staging")
    assert obs._environment() == "staging"


def test_environment_render_implies_production(monkeypatch):
    monkeypatch.delenv("ENVIRONMENT", raising=False)
    monkeypatch.setenv("RENDER", "true")
    assert obs._environment() == "production"


def test_environment_default_development(monkeypatch):
    monkeypatch.delenv("ENVIRONMENT", raising=False)
    monkeypatch.delenv("RENDER", raising=False)
    assert obs._environment() == "development"


# ---------- init_sentry ----------

def test_init_sentry_no_dsn_is_noop(monkeypatch):
    monkeypatch.delenv("SENTRY_DSN", raising=False)
    assert obs.init_sentry() is False


def test_init_sentry_with_dsn_initializes(monkeypatch):
    captured = {}

    def fake_init(**kwargs):
        captured.update(kwargs)

    monkeypatch.setattr(sentry_sdk, "init", fake_init)
    monkeypatch.setenv("ENVIRONMENT", "production")
    monkeypatch.setenv("SENTRY_TRACES_SAMPLE_RATE", "0.25")
    monkeypatch.setenv("RENDER_GIT_COMMIT", "abc123")
    assert obs.init_sentry("https://k@example.ingest.sentry.io/1") is True
    assert captured["dsn"].endswith("/1")
    assert captured["environment"] == "production"
    assert captured["traces_sample_rate"] == 0.25
    assert captured["release"] == "abc123"


def test_init_sentry_bad_traces_rate_defaults_zero(monkeypatch):
    captured = {}
    monkeypatch.setattr(sentry_sdk, "init", lambda **kw: captured.update(kw))
    monkeypatch.setenv("SENTRY_TRACES_SAMPLE_RATE", "not-a-float")
    assert obs.init_sentry("https://k@x.sentry.io/2") is True
    assert captured["traces_sample_rate"] == 0.0


def test_init_sentry_missing_sdk_is_noop(monkeypatch, caplog):
    # Force `import sentry_sdk` to raise ImportError inside init_sentry.
    real_import = builtins.__import__

    def fake_import(name, *a, **k):
        if name == "sentry_sdk":
            raise ImportError("no sentry_sdk")
        return real_import(name, *a, **k)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    with caplog.at_level(logging.WARNING):
        assert obs.init_sentry("https://k@x.sentry.io/3") is False
    assert any("sentry-sdk is not installed" in r.message for r in caplog.records)


# ---------- init_observability ----------

def test_init_observability_reports_status(monkeypatch):
    monkeypatch.delenv("SENTRY_DSN", raising=False)
    status = obs.init_observability()
    assert status == {"sentry": False}
