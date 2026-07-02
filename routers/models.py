"""Pydantic request models for the storefront JSON write routes.

Testing/coding-recommendation #1: the store/share/reserve routes previously took
a raw ``payload: dict = Body(...)`` and hand-validated every field
(``int(payload.get("x") or 0)`` in a try/except, repeated per route). Declaring
the request shape as a model gives us, for free:

  * automatic 422 responses with field-level errors (was ad-hoc 400 strings),
  * declarative bounds — the reserve quantity cap and the share note-length /
    expiry-range checks are now `Field(...)` constraints, not imperative guards,
  * OpenAPI schema for every body.

Kept deliberately permissive where the old handlers were (extra keys ignored)
so no legitimate client payload starts 422-ing on an unrelated field.
"""
from __future__ import annotations

from pydantic import BaseModel, Field


class ShareCreateRequest(BaseModel):
    """Body for POST /api/store/share.

    `filters` stays a free-form dict — it's normalized by core.helpers
    .normalize_filters downstream (URL-param and JSON forms share that coercion),
    so modeling each sub-field here would duplicate that logic.
    """

    event_id: int = Field(..., gt=0, description="Numeric event id the share points at")
    filters: dict = Field(default_factory=dict)
    note: str | None = Field(default=None, max_length=500)
    # 0 / null == "use the event-end auto-expiry cap" (legacy semantics); a real
    # user pick is bounded to 1..365 days. ge=0 keeps the 0 sentinel valid; the
    # handler treats 0/None as "no explicit pick".
    expires_in_days: int | None = Field(default=None, ge=0, le=365)


class VerifyHumanRequest(BaseModel):
    """Body for POST /api/store/verify-human (reCAPTCHA v3 gate handshake)."""

    # store.js sends `recaptcha_token`; `token` is accepted as a legacy alias.
    recaptcha_token: str | None = None
    token: str | None = None


class ReserveRequest(BaseModel):
    """Body for POST /api/store/reserve (mock checkout — inventory validation).

    The quantity cap (≤ 50) that was an imperative 400 is now a declarative
    bound: a malformed client (quantity=999999) is rejected at parse time with a
    422 before any inventory/TEvo call. `hp` is the always-on honeypot field —
    modeled explicitly so the bot gate still sees it (a stray-field drop would
    silently disable the honeypot).
    """

    event_id: int = Field(..., gt=0)
    ticket_group_id: int = Field(..., gt=0)
    quantity: int = Field(..., gt=0, le=50)
    recaptcha_token: str | None = None
    hp: str | None = None  # honeypot — a human never fills this
