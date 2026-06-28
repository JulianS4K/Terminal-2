"""Supabase client construction with bounded per-request timeouts.

Production-readiness P0 (`docs/production_readiness.md` row 2): the app talks to
Supabase via PostgREST over HTTP (supabase-py). With no timeout, a Supabase blip
lets requests hang and pile up until the dyno OOMs. Bounding the PostgREST /
storage / function client timeout makes a blip fail *fast* (per-request) instead
of accumulating — the cheapest, highest-leverage slice of "connection pooling".

The timeout is env-tunable via `SUPABASE_TIMEOUT_SECONDS` (clamped to a sane
range). Heavy admin RPCs rarely exceed the default; if one does, bump the env var
rather than removing the bound.
"""
from __future__ import annotations

import os
from typing import Callable

# Import ClientOptions from the canonical top-level export, NOT the deprecated
# `supabase.lib.client_options` shim. On supabase >=2.31 the shim's ClientOptions
# lacks the `storage` attribute that `create_client` -> `_init_supabase_auth_client`
# reads, so passing a shim-built options object raises AttributeError at client
# construction -> sb=None -> every DB-backed route 500s. The top-level export has
# `storage`. (Regression caught by tests/test_core_db.py::test_make_supabase_client_real_constructor.)
from supabase import create_client, ClientOptions

# Generous enough for the heaviest movers/admin RPCs (~1s warm, a few seconds
# cold) yet far below the unbounded-hang failure mode. Override per-env.
DEFAULT_TIMEOUT_SECONDS = 30.0
_MIN_TIMEOUT_SECONDS = 1.0
_MAX_TIMEOUT_SECONDS = 120.0


def supabase_timeout_seconds(env: dict | None = None) -> float:
    """Resolve the per-request Supabase timeout from `SUPABASE_TIMEOUT_SECONDS`.

    Falls back to DEFAULT_TIMEOUT_SECONDS when unset or unparseable; clamps to
    [1, 120]s so a typo can't disable the bound or set an absurd ceiling.
    """
    source = os.environ if env is None else env
    raw = source.get("SUPABASE_TIMEOUT_SECONDS")
    if not raw:
        return DEFAULT_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return DEFAULT_TIMEOUT_SECONDS
    return max(_MIN_TIMEOUT_SECONDS, min(value, _MAX_TIMEOUT_SECONDS))


def make_supabase_client(
    url: str,
    key: str,
    timeout: float | None = None,
    _create_client: Callable = create_client,
):
    """Build a Supabase client whose PostgREST/storage/function calls are bounded
    by `timeout` seconds (default: `supabase_timeout_seconds()`).

    `_create_client` is injectable so tests can assert the wiring without a live
    Supabase; production calls the real `supabase.create_client`.
    """
    t = supabase_timeout_seconds() if timeout is None else timeout
    options = ClientOptions(
        postgrest_client_timeout=t,
        storage_client_timeout=t,
        function_client_timeout=t,
    )
    return _create_client(url, key, options=options)
