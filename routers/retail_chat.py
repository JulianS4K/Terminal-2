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
import os
import threading
from datetime import datetime, timezone
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


# ---------- Cost guard (cheap, in-process) ----------
#
# A zero-infra backstop on top of the edge function's per-IP/minute limit. It
# refuses BEFORE any LLM/TEvo spend, so a runaway client can't run up a bill.
# This is distinct from STOREFRONT_CONCIERGE_ENABLED: that server config flag is
# the storefront-only soft kill (returns a friendly canned reply, HTTP 200); the
# guard below is a HARD kill + daily cost ceiling that also covers the terminal.
# Tunables (all env, hot-set without code):
#   RETAIL_CHAT_ENABLED      "false" → kill switch: both endpoints 503 instantly.
#   RETAIL_CHAT_DAILY_MAX    global LLM-bound requests/UTC-day across surfaces
#                            (0 = unlimited). Default 1000.
#   RETAIL_CHAT_IP_DAILY_MAX per-IP requests/UTC-day on the PUBLIC store
#                            (0 = unlimited). Default 40.
# Cheap-to-test: set the caps low (e.g. =20) while testing so you cannot burn
# cost, then raise them — or flip RETAIL_CHAT_ENABLED=false to spend nothing.
#
# Caveat: counters are per-process and reset on restart/redeploy; this is a
# cost CEILING, not exact metering. The durable per-IP/min limit lives in the
# edge function (check_chat_rate_limit). Promote to a DB counter later if a
# multi-instance, restart-proof quota is needed.
_RETAIL_CHAT_ENABLED = os.environ.get("RETAIL_CHAT_ENABLED", "true").lower() != "false"
try:
    _RETAIL_CHAT_DAILY_MAX = int(os.environ.get("RETAIL_CHAT_DAILY_MAX", "1000"))
except ValueError:
    _RETAIL_CHAT_DAILY_MAX = 1000
try:
    _RETAIL_CHAT_IP_DAILY_MAX = int(os.environ.get("RETAIL_CHAT_IP_DAILY_MAX", "40"))
except ValueError:
    _RETAIL_CHAT_IP_DAILY_MAX = 40

_retail_chat_lock = threading.Lock()
_retail_chat_usage: dict = {"day": None, "total": 0, "by_ip": {}}


def _retail_chat_budget_check(ip: str, public: bool) -> None:
    """Raise 503/429 when over the cheap in-process cost budget, BEFORE we
    forward to the (paid) edge function. Counts a request only once it passes —
    malformed/over-budget calls never consume the LLM. `public` (the storefront)
    also bears the per-IP daily cap; the email-gated terminal does not."""
    if not _RETAIL_CHAT_ENABLED:
        raise HTTPException(503, "chat is temporarily disabled")
    today = datetime.now(timezone.utc).date().isoformat()
    with _retail_chat_lock:
        if _retail_chat_usage["day"] != today:
            _retail_chat_usage["day"] = today
            _retail_chat_usage["total"] = 0
            _retail_chat_usage["by_ip"] = {}
        if _RETAIL_CHAT_DAILY_MAX and _retail_chat_usage["total"] >= _RETAIL_CHAT_DAILY_MAX:
            raise HTTPException(429, "the assistant has hit today's usage cap — please try again tomorrow")
        if public and _RETAIL_CHAT_IP_DAILY_MAX:
            used = _retail_chat_usage["by_ip"].get(ip, 0)
            if used >= _RETAIL_CHAT_IP_DAILY_MAX:
                raise HTTPException(429, "you've reached today's message limit — please try again tomorrow")
        _retail_chat_usage["total"] += 1
        if public:
            _retail_chat_usage["by_ip"][ip] = _retail_chat_usage["by_ip"].get(ip, 0) + 1


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


def _chat_edge_post(history: list[dict], scope: str, client_ip: str):
    """POST the transcript to the deployed `chat` edge function and return the
    raw requests response. Shared by the web retail-chat proxy below and the
    group-chat concierge (routers/store_group_chat.py) — scope is always set
    by the trusted server caller, never the client."""
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
        return requests.post(
            url,
            headers=headers,
            json={"history": history, "scope": "all" if scope == "all" else "owned"},
            timeout=45,
        )
    except Exception as e:
        logging.getLogger(__name__).error("retail-chat proxy upstream error: %s", e)
        raise HTTPException(502, "chat service unreachable")


def _proxy_retail_chat(history: list[dict], scope: str, client_ip: str) -> JSONResponse:
    r = _chat_edge_post(history, scope, client_ip)
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
        ip = _client_ip(request)
        _retail_chat_budget_check(ip, public=False)
        return _proxy_retail_chat(history, "all", ip)

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
        ip = _client_ip(request)
        _retail_chat_budget_check(ip, public=True)
        return _proxy_retail_chat(history, "owned", ip)

    return router
