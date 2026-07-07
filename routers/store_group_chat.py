"""Group-chat concierge — the VibePass number sits in a group text; anyone
@-mentions it to help the group curate a night out (222-style beta, D1).

Flow: the group adds our Twilio number to their thread (Twilio Conversations
Group MMS — the one Twilio product with true multi-party threads). Any member
writes "@vibe find us something Saturday" → Twilio fires its onMessageAdded
webhook at POST /api/store/group-chat/inbound → we re-read the recent thread
from Twilio's API, forward it as a speaker-labelled transcript to the same
`chat` edge function behind /store/chat (scope hard-locked to OWNED inventory,
like every public surface), and post the reply back into the thread for
everyone. Twilio holds all conversation state, so this router is stateless —
no DB table, no migration.

Wire-up (operator, all env — no code change):
  TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN   Twilio REST creds (read thread + reply).
  STORE_GROUP_CONCIERGE_ENABLED            kill switch, default false (server.py global).
  STORE_GROUP_CONCIERGE_PHONE              display number for the store-page card.
  STORE_GROUP_CONCIERGE_HANDLES            comma list, default "@vibe,@vibepass,@concierge".
  STORE_GROUP_CONCIERGE_IDENTITY           Conversations Author we post as (default "vibepass").
  STORE_GROUP_CONCIERGE_WEBHOOK_URL        exact public URL Twilio signs (set on Render;
                                           else reconstructed from X-Forwarded-*).
Twilio console: Conversations service → post-event webhook (onMessageAdded) →
this endpoint; enable address auto-creation so texting the number spawns the
conversation.

Cost posture mirrors the web concierge: default-off flag means zero spend, and
every group reply passes the shared retail-chat budget guard first (the per-IP
key is the ConversationSid → a per-group daily cap on top of the global one).
Loop safety: our own messages (Author == identity) are ignored, and a reply is
only ever produced for a message that @-mentions a configured handle.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import re
from typing import Callable
from urllib.parse import parse_qsl

import requests
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from routers.retail_chat import (
    _CONCIERGE_OFFLINE_REPLY,
    _RETAIL_CHAT_MAX_CHARS,
    _RETAIL_CHAT_MAX_TURNS,
    _chat_edge_post,
    _retail_chat_budget_check,
)

log = logging.getLogger(__name__)

TWILIO_ACCOUNT_SID = os.environ.get("TWILIO_ACCOUNT_SID", "").strip()
TWILIO_AUTH_TOKEN = os.environ.get("TWILIO_AUTH_TOKEN", "").strip()
STORE_GROUP_CONCIERGE_PHONE = os.environ.get("STORE_GROUP_CONCIERGE_PHONE", "").strip()
STORE_GROUP_CONCIERGE_IDENTITY = os.environ.get("STORE_GROUP_CONCIERGE_IDENTITY", "vibepass").strip()
_WEBHOOK_URL_OVERRIDE = os.environ.get("STORE_GROUP_CONCIERGE_WEBHOOK_URL", "").strip()

_HANDLES = [
    h.strip().lower()
    for h in os.environ.get("STORE_GROUP_CONCIERGE_HANDLES", "@vibe,@vibepass,@concierge").split(",")
    if h.strip()
]
PRIMARY_HANDLE = _HANDLES[0] if _HANDLES else "@vibe"
# "@vibe" must not fire inside "@vibepass" — match longest-first + word boundary.
_MENTION_RE = re.compile(
    "(" + "|".join(re.escape(h) for h in sorted(_HANDLES, key=len, reverse=True)) + r")(?![\w@])",
    re.IGNORECASE,
) if _HANDLES else None

_CONVERSATIONS_BASE = "https://conversations.twilio.com/v1/Conversations"
# Group MMS carrier ceiling is 1600 chars/message — keep headroom.
_REPLY_MAX_CHARS = 1500
_THREAD_FETCH_PAGE = 40


def _mentioned(body: str) -> bool:
    return bool(_MENTION_RE and _MENTION_RE.search(body or ""))


def _twilio_signature_ok(url: str, params: dict, signature: str) -> bool:
    """Validate X-Twilio-Signature per Twilio's spec: base64(HMAC-SHA1(auth
    token, url + concat(key+value sorted by key)))."""
    if not TWILIO_AUTH_TOKEN:
        return False
    payload = url + "".join(k + str(params[k]) for k in sorted(params))
    digest = hmac.new(TWILIO_AUTH_TOKEN.encode(), payload.encode("utf-8"), hashlib.sha1).digest()
    return hmac.compare_digest(base64.b64encode(digest).decode(), signature or "")


def _webhook_url(request: Request) -> str:
    """The exact public URL Twilio signed. Behind the Render proxy the ASGI
    scheme/host differ from the public ones, so prefer the env override; the
    X-Forwarded-* reconstruction is the local/dev fallback."""
    if _WEBHOOK_URL_OVERRIDE:
        return _WEBHOOK_URL_OVERRIDE
    proto = request.headers.get("x-forwarded-proto") or request.url.scheme
    host = request.headers.get("x-forwarded-host") or request.headers.get("host") or request.url.netloc
    url = f"{proto}://{host}{request.url.path}"
    if request.url.query:
        url += f"?{request.url.query}"
    return url


def _thread_history(conversation_sid: str, trigger_author: str, trigger_body: str) -> list[dict]:
    """Rebuild the group transcript from Twilio (newest page, chronological).
    Group members become speaker-labelled user turns ("Sam: pick a night");
    our own messages become assistant turns. Consecutive same-role turns merge
    (the edge fn's LLM requires alternating roles). Falls back to the single
    triggering message if the fetch fails — one degraded turn beats silence."""
    trigger_turn = {"role": "user", "content": f"{trigger_author}: {trigger_body}"[:_RETAIL_CHAT_MAX_CHARS]}
    try:
        r = requests.get(
            f"{_CONVERSATIONS_BASE}/{conversation_sid}/Messages",
            params={"Order": "desc", "PageSize": _THREAD_FETCH_PAGE},
            auth=(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN),
            timeout=15,
        )
        messages = list(reversed((r.json() or {}).get("messages") or []))
    except Exception as e:
        log.warning("group-chat thread fetch failed (%s) — single-turn fallback", e)
        return [trigger_turn]

    history: list[dict] = []
    for m in messages:
        author = (m.get("author") or "").strip()
        body = (m.get("body") or "").strip()
        if not body:
            continue  # media-only / system messages
        if author == STORE_GROUP_CONCIERGE_IDENTITY:
            role, content = "assistant", body
        else:
            role, content = "user", f"{author or 'guest'}: {body}"
        if history and history[-1]["role"] == role:
            history[-1]["content"] = (history[-1]["content"] + "\n" + content)[:_RETAIL_CHAT_MAX_CHARS]
        else:
            history.append({"role": role, "content": content[:_RETAIL_CHAT_MAX_CHARS]})
    history = history[-_RETAIL_CHAT_MAX_TURNS:]
    # The webhook can outrun the Messages read — make sure the triggering
    # mention is the closing user turn either way.
    if not history or history[0]["role"] != "user":
        history = history[1:] if history else []
    if not history or history[-1]["role"] != "user":
        history.append(trigger_turn)
    return history or [trigger_turn]


def _post_group_reply(conversation_sid: str, body: str) -> None:
    r = requests.post(
        f"{_CONVERSATIONS_BASE}/{conversation_sid}/Messages",
        data={"Author": STORE_GROUP_CONCIERGE_IDENTITY, "Body": body[:_REPLY_MAX_CHARS]},
        auth=(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN),
        timeout=15,
    )
    if r.status_code >= 400:
        log.error("group-chat reply post failed: %s", r.status_code)


def _handle_inbound(get_enabled: Callable[[], bool], url: str, form: dict, signature: str) -> JSONResponse:
    """The whole webhook decision path, sync + directly unit-testable (the
    async route wrapper below isn't attributable by coverage via TestClient —
    same pattern as server.py's render_deploy_webhook). Always answers 2xx for
    ignored events so Twilio doesn't retry-spam; non-2xx is reserved for
    misconfiguration (503) and bad signatures (403)."""
    if not get_enabled():
        return JSONResponse({"status": "disabled"}, status_code=200)
    if not (TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN):
        raise HTTPException(503, "group-chat concierge not configured")
    if not _twilio_signature_ok(url, form, signature):
        raise HTTPException(403, "invalid webhook signature")

    event_type = form.get("EventType", "onMessageAdded")
    conversation_sid = (form.get("ConversationSid") or "").strip()
    author = (form.get("Author") or "").strip()
    body = (form.get("Body") or "").strip()
    if event_type != "onMessageAdded" or not conversation_sid or not body:
        return JSONResponse({"status": "ignored"}, status_code=200)
    if author == STORE_GROUP_CONCIERGE_IDENTITY:
        return JSONResponse({"status": "own-message"}, status_code=200)
    if not _mentioned(body):
        return JSONResponse({"status": "no-mention"}, status_code=200)

    # Shared retail-chat budget: keyed by conversation → per-group daily
    # cap on top of the global one. Over budget → silent (a 4xx/5xx here
    # would only make Twilio redeliver the same paid request).
    try:
        _retail_chat_budget_check(conversation_sid, public=True)
    except HTTPException:
        log.warning("group-chat over budget — staying silent (%s)", conversation_sid)
        return JSONResponse({"status": "over-budget"}, status_code=200)

    history = _thread_history(conversation_sid, author or "guest", body)
    try:
        upstream = _chat_edge_post(history, "owned", conversation_sid)
        reply = (upstream.json() or {}).get("reply") or ""
    except Exception:  # any edge failure (incl. HTTPException) → friendly canned reply
        reply = ""
    if not reply.strip():
        reply = _CONCIERGE_OFFLINE_REPLY
    _post_group_reply(conversation_sid, reply)
    return JSONResponse({"status": "replied"}, status_code=200)


def build_store_group_chat_router(get_enabled: Callable[[], bool]) -> APIRouter:
    router = APIRouter()

    @router.post("/api/store/group-chat/inbound")
    async def group_chat_inbound(request: Request):  # pragma: no cover - async route body not attributable by coverage.py via TestClient; thin wrapper — logic + behavior covered via _handle_inbound in test_store_group_chat.py
        """Twilio Conversations post-event webhook (onMessageAdded). Twilio
        posts application/x-www-form-urlencoded — parsed with the stdlib
        (Starlette's request.form() would pull in python-multipart for
        nothing; keep the dependency surface flat)."""
        form = dict(parse_qsl((await request.body()).decode("utf-8"), keep_blank_values=True))
        return _handle_inbound(
            get_enabled, _webhook_url(request), form,
            request.headers.get("x-twilio-signature", ""),
        )

    return router
