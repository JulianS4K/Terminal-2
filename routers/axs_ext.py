"""AXS watch, extension reader routes (operator 2026-11-25: "build our own" AXS poller, then "Build the extension for
Firefox, incorporate containers").

AXS's Cloudflare refuses a datacenter address, so the watch's own reader is a Firefox extension (axs_extension/) on an
ordinary connection. It asks this service what to read and sends back what each AXS page received; the database
chooses and settles (mig 20261125210000):

    POST /api/axs/ext/next     {"worker": "<install id>", "limit": n}   -> axs_watch_next(n, 'ext:<install id>')
    POST /api/axs/ext/record   one capture (core/axs_ext_doc.py)        -> axs_watch_record_ext(...)
    GET  /api/axs/ext/ping                                              -> the secret works, and who reads now

Gated by the shared **X-Ingest-Secret** header (AXS_EXT_INGEST_SECRET), as the Paciolan extension's ingest is: never
the service_role key, and closed (503) while the secret is unset. This service makes no request to AXS (RULE 2): the
reads are the page's own, in the operator's browser.
"""
from __future__ import annotations

import hmac
import os
import re
from typing import Any, Callable

from fastapi import APIRouter, Header, HTTPException

from core import axs_ext_doc

_WORKER = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
_EVENT = re.compile(r"^\d{1,20}$")
MAX_CAPTURES = 200


def _check(secret: str | None) -> None:
    expected = os.environ.get("AXS_EXT_INGEST_SECRET")
    if not expected:
        raise HTTPException(503, "AXS extension reader not configured")   # fail closed
    if not secret or not hmac.compare_digest(secret, expected):
        raise HTTPException(401, "bad or missing X-Ingest-Secret")


def build_axs_ext_router(get_require_sb: Callable[[], Callable]) -> APIRouter:
    router = APIRouter()

    def _rpc(name: str, params: dict) -> Any:
        db = get_require_sb()()
        return db.rpc(name, params).execute().data

    @router.get("/api/axs/ext/ping")
    def axs_ext_ping(x_ingest_secret: str | None = Header(None, alias="X-Ingest-Secret")):
        """The extension's options page: the secret is right, and the watch's switches."""
        _check(x_ingest_secret)
        db = get_require_sb()()
        rows = (db.table("axs_watch_config").select("enabled,reader,ext_lanes,ext_spacing_ms").limit(1).execute()).data or []
        return {"ok": True, **(rows[0] if rows else {})}

    @router.post("/api/axs/ext/next")
    def axs_ext_next(payload: dict[str, Any], x_ingest_secret: str | None = Header(None, alias="X-Ingest-Secret")):
        """The events due now for the extension (empty unless axs_watch_config.reader = 'extension')."""
        _check(x_ingest_secret)
        worker = str(payload.get("worker") or "")
        if not _WORKER.match(worker):
            raise HTTPException(422, "worker must be 1-64 of A-Z a-z 0-9 _ . : -")
        try:
            limit = max(1, min(int(payload.get("limit") or 10), 100))
        except (TypeError, ValueError):
            raise HTTPException(422, "limit must be a number")
        return _rpc("axs_watch_next", {"p_limit": limit, "p_worker": f"ext:{worker}"}) or {}

    @router.post("/api/axs/ext/record")
    def axs_ext_record(capture: dict[str, Any], x_ingest_secret: str | None = Header(None, alias="X-Ingest-Secret")):
        """One AXS page read by the extension, settled by the database."""
        _check(x_ingest_secret)
        if not _EVENT.match(str(capture.get("event_id") or "")):
            raise HTTPException(422, "event_id must be an AXS event number")
        caps = capture.get("captures") or []
        if not isinstance(caps, list) or len(caps) > MAX_CAPTURES:
            raise HTTPException(422, f"captures must be a list of at most {MAX_CAPTURES}")
        params = axs_ext_doc.build_record(capture)
        got = _rpc("axs_watch_record_ext", params) or {}
        return {**got, "sent_status": params["p_status_code"], "sent_error": params["p_error_msg"]}

    return router
