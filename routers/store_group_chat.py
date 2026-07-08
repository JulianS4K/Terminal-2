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
from fastapi import APIRouter, Body, HTTPException, Request
from fastapi.responses import JSONResponse

from core.config import STOREFRONT_BASE_URL
from routers.retail_chat import (
    _CONCIERGE_OFFLINE_REPLY,
    _RETAIL_CHAT_MAX_CHARS,
    _RETAIL_CHAT_MAX_TURNS,
    _chat_edge_post,
    _client_ip,
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

# ---------- Direct store links in replies ----------
#
# The chat edge fn's sanitizeReply STRIPS every URL from the model's text
# (deliberate for the web widget), so we can't ask the model for links
# directly. Instead the transcript we build carries a standing instruction to
# tag each recommended event with [event:<event_id>] — plain tokens survive
# sanitization, and the v26 strict-whitelist means the model can only use ids
# actually resolved in the conversation. We then rewrite each tag into a
# direct D1 event-page link (STOREFRONT_BASE_URL + /store/event/{id}) before
# the reply reaches the group — but ONLY after the owned-EVO check below.
#
# ---------- HARD RULE: owned EVO data only (no bypass) ----------
#
# The group-chat surface pulls exclusively from OUR OWNED EVO INVENTORY.
# Enforced in three independent layers, none of which trusts the others:
#   1. Wire scope — every edge-fn call goes through _owned_chat_edge_post,
#      which hard-codes scope='owned' (the edge fn clamps its listing tools to
#      owned-EVO rows; the client/group has no scope input at all).
#   2. Prompt — the transcript instruction forbids recommending anything the
#      model couldn't find owned seats for.
#   3. Output gate — every [event:<id>] tag is VERIFIED against
#      listings_snapshots.is_owned in the DB before a link is emitted; ids
#      that don't verify (or any DB error) FAIL CLOSED and the tag is
#      stripped, so a link to a non-owned event can never reach the group.
_STORE_BASE = (STOREFRONT_BASE_URL or "").rstrip("/")
_GROUP_CONTEXT_NOTE = (
    "(group-chat context: you are inside a friends' group text; each line of "
    "mine is prefixed with the sender's name — address the whole group, warm "
    "and brief. STRICT RULES: "
    "1) Recommend ONLY events from our owned inventory — your listing tools "
    "are already restricted to it; never name an event you could not find "
    "owned seats for. "
    "2) Reply format, nothing else: up to 3 numbered picks, ONE line each — "
    "\"N. <event> <day time> — <section/row> · <qty> together · $<all-in "
    "each> [event:<event_id>]\" — then ONE short closing question. "
    "3) Whole reply under 6 lines; plain text, no markdown, no URLs — the "
    "[event:...] tag is the link.)"
)
_EVENT_TAG_RE = re.compile(r"\s*\[event:(\d{7,10})\]")
_EVENT_TAG_JUNK_RE = re.compile(r"\s*\[event:[^\]]*\]?")
_OWNED_CHECK_MAX_IDS = 6  # tags per reply are ≤3 by the format rule; hard-cap the DB loop

# Wired by build_store_group_chat_router (the live server require_sb). Left
# None in isolation → _owned_event_ids fails closed and no links are emitted.
_get_require_sb: Callable[[], Callable] | None = None


def _owned_chat_edge_post(history: list[dict], client_key: str):
    """The ONLY way group-chat code talks to the chat edge fn. scope='owned'
    is hard-coded here (HARD RULE layer 1) — there is deliberately no scope
    parameter for a caller to widen."""
    return _chat_edge_post(history, "owned", client_key)


def _owned_event_ids(event_ids: set[str]) -> set[str]:
    """HARD RULE layer 3: return the subset of event_ids that have owned-EVO
    rows in listings_snapshots (is_owned=true). Any failure — sb unwired, DB
    down, bad id — FAILS CLOSED (id treated as not owned, tag stripped)."""
    owned: set[str] = set()
    if not event_ids or _get_require_sb is None:
        return owned
    try:
        db = _get_require_sb()()
        for eid in sorted(event_ids)[:_OWNED_CHECK_MAX_IDS]:
            rows = (
                db.table("listings_snapshots")
                .select("event_id")
                .eq("event_id", int(eid))
                .eq("is_owned", True)
                .limit(1)
                .execute().data
            )
            if rows:
                owned.add(eid)
    except Exception as e:
        log.warning("owned-EVO verification failed (%s) — failing closed, no links", e)
        return set()
    return owned


def _linkify_events(reply: str) -> str:
    """[event:3091462] → ' <base>/store/event/3091462' — but only for ids that
    VERIFY as owned EVO (_owned_event_ids). Non-owned, malformed, or leftover
    tags are stripped so neither raw tokens nor non-owned links ever reach the
    group."""
    tagged = set(_EVENT_TAG_RE.findall(reply))
    owned = _owned_event_ids(tagged) if (tagged and _STORE_BASE) else set()
    if owned:
        reply = _EVENT_TAG_RE.sub(
            lambda m: f" {_STORE_BASE}/store/event/{m.group(1)}" if m.group(1) in owned else "",
            reply,
        )
    return _EVENT_TAG_JUNK_RE.sub("", reply).strip()


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


def _build_history(messages: list[dict], trigger_author: str, trigger_body: str) -> list[dict]:
    """CHRONOLOGICAL [{author, body}] → the transcript the chat edge fn
    expects. Group members become speaker-labelled user turns ("Sam: pick a
    night"); our own messages become assistant turns. Consecutive same-role
    turns merge (the edge fn's LLM requires alternating roles). Shared by the
    Twilio webhook path and the /simulate test harness."""
    trigger_turn = {"role": "user", "content": f"{trigger_author}: {trigger_body}"[:_RETAIL_CHAT_MAX_CHARS]}
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
    # Standing group-context + [event:<id>] tagging instruction rides the
    # FIRST user turn (away from the edge fn's NLU entity pre-extract, which
    # reads only the LAST user message).
    history[0] = {"role": "user", "content": f"{_GROUP_CONTEXT_NOTE}\n\n{history[0]['content']}"[:_RETAIL_CHAT_MAX_CHARS]}
    return history


def _thread_history(conversation_sid: str, trigger_author: str, trigger_body: str) -> list[dict]:
    """Rebuild the group transcript from Twilio (newest page → chronological).
    Falls back to the single triggering message if the fetch fails — one
    degraded turn beats silence."""
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
        messages = []
    return _build_history(messages, trigger_author, trigger_body)


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
    _post_group_reply(conversation_sid, _concierge_reply(history, conversation_sid))
    return JSONResponse({"status": "replied"}, status_code=200)


def _concierge_reply(history: list[dict], client_key: str) -> str:
    """Ask the chat edge fn (scope hard-locked 'owned' via
    _owned_chat_edge_post); any failure — incl. HTTPException — or an empty
    reply degrades to the friendly offline line. [event:<id>] tags become
    direct store-event links only after the owned-EVO verification gate."""
    try:
        upstream = _owned_chat_edge_post(history, client_key)
        reply = (upstream.json() or {}).get("reply") or ""
    except Exception:
        reply = ""
    return _linkify_events(reply.strip()) or _CONCIERGE_OFFLINE_REPLY


def _simulate_messages(payload: dict) -> list[dict]:
    """Validate + bound the /simulate harness thread: a non-empty list of
    {author, body}, last message being the (would-be) triggering text."""
    msgs = payload.get("messages") if isinstance(payload, dict) else None
    if not isinstance(msgs, list) or not msgs:
        raise HTTPException(400, "messages required — [{author, body}, ...]")
    clean: list[dict] = []
    for m in msgs[-_THREAD_FETCH_PAGE:]:
        if not isinstance(m, dict):
            continue
        author = str(m.get("author") or "").strip()
        body = str(m.get("body") or "").strip()[:_RETAIL_CHAT_MAX_CHARS]
        if body:
            clean.append({"author": author or "guest", "body": body})
    if not clean:
        raise HTTPException(400, "no valid messages")
    return clean


def build_store_group_chat_router(
    get_enabled: Callable[[], bool],
    get_is_production: Callable[[], bool],
    get_require_sb: Callable[[], Callable],
) -> APIRouter:
    # Wire the owned-EVO verifier (HARD RULE layer 3) to the live server db.
    global _get_require_sb
    _get_require_sb = get_require_sb
    router = APIRouter()

    @router.post("/api/store/group-chat/simulate")
    def group_chat_simulate(request: Request, payload: dict = Body(...)):
        """Twilio-free test harness for the group-chat concierge (drives the
        /store/test/groupchat page): the same pipeline as the webhook —
        mention gate → transcript build → chat edge fn with scope hard-locked
        'owned' — but the thread comes from the request body and the reply
        returns as JSON instead of posting to Twilio. Non-prod only (404 in
        production, like every /store/test/* page) and shares the retail-chat
        budget guard keyed per client IP; unlike the webhook, over-budget is
        surfaced to the tester (429) rather than silent. Does NOT require
        STORE_GROUP_CONCIERGE_ENABLED — the point is testing before Twilio
        exists."""
        if get_is_production():
            raise HTTPException(404, "not found")
        msgs = _simulate_messages(payload)
        trigger = msgs[-1]
        if not _mentioned(trigger["body"]):
            return JSONResponse({"status": "no-mention", "reply": None}, status_code=200)
        ip = _client_ip(request)
        _retail_chat_budget_check(f"gc-sim:{ip}", public=True)
        history = _build_history(msgs, trigger["author"], trigger["body"])
        reply = _concierge_reply(history, ip)
        # history echoed back so the harness can show exactly what the LLM saw.
        return JSONResponse(
            {"status": "replied", "reply": reply[:_REPLY_MAX_CHARS], "history": history},
            status_code=200,
        )

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
