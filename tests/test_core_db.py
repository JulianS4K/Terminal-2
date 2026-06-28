"""Tests for core/db.py — bounded-timeout Supabase client construction.

Covers the env-resolution branches + the make_supabase_client wiring (via an
injected fake create_client so no live Supabase is needed). Production-readiness
P0: a Supabase blip must fail fast per-request, not pile up into an OOM.
"""
from __future__ import annotations

from core import db as db_module
from core.db import (
    DEFAULT_TIMEOUT_SECONDS,
    make_supabase_client,
    supabase_timeout_seconds,
)


# --- supabase_timeout_seconds ------------------------------------------------

def test_timeout_default_when_unset():
    assert supabase_timeout_seconds(env={}) == DEFAULT_TIMEOUT_SECONDS


def test_timeout_default_when_empty_string():
    assert supabase_timeout_seconds(env={"SUPABASE_TIMEOUT_SECONDS": ""}) == DEFAULT_TIMEOUT_SECONDS


def test_timeout_reads_valid_value():
    assert supabase_timeout_seconds(env={"SUPABASE_TIMEOUT_SECONDS": "12.5"}) == 12.5


def test_timeout_default_when_unparseable():
    assert supabase_timeout_seconds(env={"SUPABASE_TIMEOUT_SECONDS": "abc"}) == DEFAULT_TIMEOUT_SECONDS


def test_timeout_clamps_below_min():
    assert supabase_timeout_seconds(env={"SUPABASE_TIMEOUT_SECONDS": "0.1"}) == 1.0


def test_timeout_clamps_above_max():
    assert supabase_timeout_seconds(env={"SUPABASE_TIMEOUT_SECONDS": "9999"}) == 120.0


def test_timeout_uses_real_os_environ_by_default(monkeypatch):
    # env=None path -> reads os.environ.
    monkeypatch.setenv("SUPABASE_TIMEOUT_SECONDS", "7")
    assert supabase_timeout_seconds() == 7.0


# --- make_supabase_client ----------------------------------------------------

class _FakeCreate:
    def __init__(self):
        self.calls = []

    def __call__(self, url, key, options=None):
        self.calls.append((url, key, options))
        return ("client", url, key, options)


def test_make_client_passes_bounded_timeout_to_all_three_clients():
    fake = _FakeCreate()
    out = make_supabase_client("https://x.supabase.co", "k", timeout=20.0, _create_client=fake)
    assert out[0] == "client"
    (url, key, options) = fake.calls[0]
    assert url == "https://x.supabase.co"
    assert key == "k"
    assert options.postgrest_client_timeout == 20.0
    assert options.storage_client_timeout == 20.0
    assert options.function_client_timeout == 20.0


def test_make_client_defaults_timeout_from_env(monkeypatch):
    monkeypatch.delenv("SUPABASE_TIMEOUT_SECONDS", raising=False)
    fake = _FakeCreate()
    make_supabase_client("u", "k", _create_client=fake)
    assert fake.calls[0][2].postgrest_client_timeout == DEFAULT_TIMEOUT_SECONDS


def test_module_exposes_real_create_client_default():
    # The default _create_client is the real supabase.create_client (we don't
    # call it here — just assert the wiring isn't accidentally the fake).
    import supabase
    assert db_module.create_client is supabase.create_client


def test_make_supabase_client_real_constructor():
    """Regression: build a client through the REAL supabase.create_client (no
    fake injected) so the ClientOptions we pass is actually consumed by
    create_client -> _init_supabase_auth_client. Catches the import-path bug
    where ClientOptions came from the deprecated `supabase.lib.client_options`
    shim (missing `.storage`), which raised AttributeError at construction ->
    sb=None -> every DB-backed route 500s. supabase clients construct lazily
    (no network), so this is safe + offline."""
    client = make_supabase_client("https://abcdefgh.supabase.co", "sb_secret_testkey")
    assert client is not None
    # The options object the module builds must carry `storage` (the attribute
    # create_client reads) — i.e. it's the canonical ClientOptions, not the shim.
    assert hasattr(db_module.ClientOptions(), "storage")
