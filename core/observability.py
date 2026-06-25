"""Observability bootstrap — structured logging + optional error tracking.

Two concerns, both safe-by-default:

- **Logging**: `configure_logging()` installs one stdout handler with a
  timestamped, leveled, named format (Render captures stdout). Level comes from
  `LOG_LEVEL` (default INFO). This replaces the bare `print()` calls that used
  to scatter unstructured lines to stderr.

- **Error tracking (Sentry)**: `init_sentry()` is a no-op unless `SENTRY_DSN`
  is set AND the `sentry_sdk` package imports. It's lazy-imported so a missing
  dep never breaks boot (mirrors the supabase/cryptography lazy-import pattern).
  Until the operator sets `SENTRY_DSN`, nothing changes.

`init_observability()` runs both at import-time from app.py and returns a small
status dict (handy for /healthz to report whether error-tracking is live).
"""
from __future__ import annotations

import logging
import os
import sys

_LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"


def _resolve_level(level: str | None) -> int:
    """Map a LOG_LEVEL string to a logging constant; fall back to INFO on an
    unknown value rather than raising at boot."""
    name = (level or os.environ.get("LOG_LEVEL") or "INFO").upper()
    resolved = logging.getLevelName(name)
    return resolved if isinstance(resolved, int) else logging.INFO


def configure_logging(level: str | None = None) -> None:
    """Install a single stdout logging handler. `force=True` so it wins even if
    a dependency called basicConfig first."""
    logging.basicConfig(
        level=_resolve_level(level),
        format=_LOG_FORMAT,
        stream=sys.stdout,
        force=True,
    )


def _environment() -> str:
    """Best-effort environment tag for Sentry events."""
    explicit = os.environ.get("ENVIRONMENT")
    if explicit:
        return explicit
    return "production" if os.environ.get("RENDER") else "development"


def init_sentry(dsn: str | None = None) -> bool:
    """Initialize Sentry error tracking. Returns True iff it was actually
    initialized. No-op (False) when no DSN is configured or the sdk is absent."""
    dsn = dsn if dsn is not None else os.environ.get("SENTRY_DSN")
    if not dsn:
        return False
    try:
        import sentry_sdk
    except ImportError:
        logging.getLogger(__name__).warning(
            "SENTRY_DSN is set but sentry-sdk is not installed — error tracking disabled"
        )
        return False
    try:
        traces = float(os.environ.get("SENTRY_TRACES_SAMPLE_RATE") or 0.0)
    except ValueError:
        traces = 0.0
    sentry_sdk.init(
        dsn=dsn,
        environment=_environment(),
        traces_sample_rate=traces,
        release=os.environ.get("RENDER_GIT_COMMIT") or os.environ.get("GIT_COMMIT"),
    )
    logging.getLogger(__name__).info("Sentry error tracking initialized (env=%s)", _environment())
    return True


def init_observability() -> dict:
    """Configure logging and (if DSN present) Sentry. Returns a status dict."""
    configure_logging()
    return {"sentry": init_sentry()}
