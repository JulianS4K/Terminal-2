"""Retail-chat proxy — operator (`/api/retail-chat`) + storefront
(`/api/store/retail-chat`).

server.py decomposition slice (BR-CODE-1): the two retail-chat routes plus their
helpers (`_client_ip`, `_sanitize_chat_history`, `_proxy_retail_chat` — all
retail-chat-only) lifted verbatim behind unchanged paths.

The transcript-bound constants + the offline-reply string live here now;
server.py re-exports them so existing test references
(`app_module._RETAIL_CHAT_MAX_TURNS` / `_MAX_CHARS` / `_CONCIERGE_OFFLINE_REPLY`)
keep resolving — the same re-export compat pattern used for `core/auth`.

The concierge on/off flag stays a server.py config global (tests patch it
there) and is read via `get_concierge_enabled()` at request time. `requests` is
the shared module singleton (tests stub `app.requests.post`).
"""
from __future__ import annotations

import logging
from typing import Callable

import requests
from fastapi import APIRouter, Body, Depends, HTTPException, Request
from fastapi.responses import JSONResponse

from core.config import SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY

_RETAIL_CHAT_MAX_TURNS = 24
_RETAIL_CHAT_MAX_CHARS = 4000
_CONCIERGE_OFFLINE_REPLY = (
    "Our concierge is taking a short break right now. In the meantime you can browse "
    "everything we hold from the home page, or reach us directly and we'll find your seats."
)


def _client_ip(request: Request) -> str:
    """Best-effort real client IP behind the Render/Railway proxy. Forwarded
    to the edge function so its per-IP rate limit is per-user, not per-proxy."""
    # Use the RIGHTMOST X-Forwarded-For hop: that's the entry appended by our
    # own edge proxy and is the only one a client can't forge. Keying on the
    # leftmost (client-supplied) entry let a single client rotate fake IPs to
    # bypass the edge function's per-IP rate limit (audit 2026-06-10/06-22).
    xff = request.headers.get("x-forwarded-for")
    if xff:
        last = xff.split(",")[-1].strip()
        if last:
            return last
    real = request.headers.get("x-real-ip")
    if real:
        return real.strip()
    return (request.client.host if request.client else "") or "unknown"


def _sanitize_chat_history(payload: dict) -> list[dict]:
    """Validate + bound the client-supplied transcript before forwarding.
    Accepts either {history:[{role,content}...]} or {message:"..."}."""
    if not isinstance(payload, dict):
        raise HTTPException(400, "expected a JSON object")
    hist = payload.get("history")
    if hist is None and payload.get("message"):
        hist = [{"role": "user", "content": str(payload.get("message"))}]
    if not isinstance(hist, list) or not hist:
        raise HTTPException(400, "history or message required")
    out: list[dict] = []
    for item in hist[-_RETAIL_CHAT_MAX_TURNS:]:
        if not isinstance(item, dict):
            continue
        role = item.get("role")
        content = item.get("content")
        if role not in ("user", "assistant") or not isinstance(content, str):
            continue
        content = content.strip()
        if not content:
            continue
        out.append({"role": role, "content": content[:_RETAIL_CHAT_MAX_CHARS]})
    if not out:
        raise HTTPException(400, "no valid messages in history")
    if out[-1]["role"] != "user":
        raise HTTPException(400, "last message must be from the user")
    return out


def _proxy_retail_chat(history: list[dict], scope: str, client_ip: str) -> JSONResponse:
    if not (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY):
        raise HTTPException(503, "chat service not configured")
    url = f"{SUPABASE_URL.rstrip('/')}/functions/v1/chat"
    headers = {
        "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}",
        "apikey": SUPABASE_ANON_KEY or SUPABASE_SERVICE_ROLE_KEY,
        "Content-Type": "application/json",
        "x-real-ip": client_ip,
        "x-forwarded-for": client_ip,
    }
    try:
        r = requests.post(
            url,
            headers=headers,
            json={"history": history, "scope": "all" if scope == "all" else "owned"},
            timeout=45,
        )
    except Exception as e:
        logging.getLogger(__name__).error("retail-chat proxy upstream error: %s", e)
        raise HTTPException(502, "chat service unreachable")
    try:
        body = r.json()
    except Exception:
        body = {"error": "assistant returned a malformed response"}
    status = r.status_code if r.status_code >= 400 else 200
    return JSONResponse(body, status_code=status)


def build_retail_chat_router(require_auth: Callable, get_concierge_enabled: Callable[[], bool]) -> APIRouter:
    router = APIRouter()

    @router.post("/api/retail-chat")
    def retail_chat_terminal(request: Request, payload: dict = Body(...), _=Depends(require_auth)):
        """Operator-facing retail chat (email-gated). scope=all → full market."""
        history = _sanitize_chat_history(payload)
        return _proxy_retail_chat(history, "all", _client_ip(request))

    @router.post("/api/store/retail-chat")
    def retail_chat_store(request: Request, payload: dict = Body(...)):
        """Public storefront retail chat. scope=owned → hard-locked to our owned
        EVO inventory (enforced server-side; the consumer cannot widen it).

        Gated by STOREFRONT_CONCIERGE_ENABLED (off for now): when disabled we
        return a friendly canned reply with HTTP 200 so the widget renders it as
        a normal assistant message — and never call the paid chat edge function."""
        if not get_concierge_enabled():
            return JSONResponse({"reply": _CONCIERGE_OFFLINE_REPLY}, status_code=200)
        history = _sanitize_chat_history(payload)
        return _proxy_retail_chat(history, "owned", _client_ip(request))

    return router
