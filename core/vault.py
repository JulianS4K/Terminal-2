"""Shared Supabase-Vault secret resolver for the broker clients (BR-CODE-2).

Every client resolved its API key/token the same way — arg → env var → Supabase
Vault via the `get_app_secret` RPC — but each hand-rolled the RPC call + result
unwrapping + failure swallowing (ticketsdata + axs even had byte-identical
private `_vault_secret` helpers). This single-sources the Vault lookup.

`get_app_secret` returns the secret as a bare string on most paths, but some
supabase-py versions wrap it as `{"get_app_secret": value}` or `{"value": value}`
— this resolver handles all three shapes so callers don't each re-implement the
unwrap. The value is never logged; on failure `on_error(exc)` is invoked so the
caller can emit its own (value-free) message, and `None` is returned.
"""
from __future__ import annotations

from typing import Any, Callable


def vault_secret(
    db: Any,
    name: str,
    *,
    on_error: Callable[[Exception], None] | None = None,
) -> str | None:
    """Resolve secret `name` from Supabase Vault via the `get_app_secret` RPC.

    Returns the secret string, or ``None`` when `db` is None, the secret is
    absent/empty, or the lookup raises (in which case `on_error(exc)` fires).
    Requires a service-role `db` client. Never logs or returns the value on the
    error path.
    """
    if db is None:
        return None
    try:
        res = db.rpc("get_app_secret", {"p_name": name}).execute()
        data = getattr(res, "data", None)
        if isinstance(data, dict):
            # Some supabase-py paths wrap the scalar return value.
            data = data.get("get_app_secret") or data.get("value")
        return data or None
    except Exception as e:  # noqa: BLE001 - swallow; resolution failure must not crash construction
        if on_error is not None:
            on_error(e)
        return None
