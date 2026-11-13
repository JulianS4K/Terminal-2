"""StubHub OAuth connect flow — our own seller account, read-only, OFF by default.

Routes:
  GET /api/admin/stubhub/status     (auth) switch + token status, no secrets
  GET /api/admin/stubhub/connect    (auth) → {"authorize_url": …}: open it, sign in on StubHub, approve
  GET /api/stubhub/oauth/callback   StubHub redirects here with ?code&state after the approval

Both the code→token swap and the refresh run in SQL (stubhub_oauth_complete /
stubhub_token_refresh, mig 20261113250000) with the app's client secret read from
Vault, so this router never sees a secret or a token: it only passes the one-time
`state` and the `code` through. Scopes are read:* only (see stubhub_client.READ_SCOPES).

OFF until the Render env var STUBHUB_API_ENABLED=1 AND stubhub_api_config.enabled is
true (operator 2026-11-13: "wire the api but keep turned off and read only till we get
tokens"). While off, connect/callback answer 503 and nothing reaches StubHub.
"""
from __future__ import annotations

import html
import re
from typing import Any, Callable

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import HTMLResponse

from stubhub_client import stubhub_enabled

_STATE_RE = re.compile(r"^[0-9a-f]{48}$")

_RESULT_TEXT = {
    "connected": "StubHub is connected. The token refreshes automatically; you can close this tab.",
    "bad_state": "This link expired or was already used. Start again from Connect StubHub.",
    "disabled": "The StubHub integration is switched off.",
    "no_code": "StubHub did not send an authorization code.",
    "no_client_credentials": "StubHub app credentials are not set up yet.",
    "write_scope_refused": "StubHub granted write access; the token was refused (read-only integration).",
    "request_failed": "Could not reach StubHub. Try again.",
}


def _page(title: str, body: str, status: int = 200) -> HTMLResponse:
    return HTMLResponse(
        "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
        f"<title>{html.escape(title)}</title>"
        "<body style='font-family:system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem'>"
        f"<h1 style='font-size:1.25rem'>{html.escape(title)}</h1><p>{html.escape(body)}</p></body>",
        status_code=status,
    )


def build_stubhub_oauth_router(*, get_require_sb: Callable[[], Callable], require_auth: Callable) -> APIRouter:
    router = APIRouter()

    def _sb() -> Any:
        return get_require_sb()()

    @router.get("/api/admin/stubhub/status")
    def stubhub_status(_=Depends(require_auth)):
        sb = _sb()
        cfg = (sb.table("stubhub_api_config").select("enabled,env,scopes,redirect_uri").limit(1).execute().data or [{}])[0]
        tok = (sb.table("stubhub_token_state")
                 .select("connected_at,refreshed_at,expires_at,scope,last_attempt_at,last_http,last_error")
                 .limit(1).execute().data or [{}])[0]
        return {"env_switch_on": stubhub_enabled(), "config": cfg, "token": tok}

    @router.get("/api/admin/stubhub/connect")
    def stubhub_connect(user=Depends(require_auth)):
        if not stubhub_enabled():
            raise HTTPException(503, "StubHub integration is switched off (STUBHUB_API_ENABLED).")
        email = (user or {}).get("email") or "unknown"
        try:
            url = _sb().rpc("stubhub_oauth_begin", {"p_created_by": email}).execute().data
        except Exception as e:  # noqa: BLE001 - the SQL raises a readable reason (switched off, no client id …)
            msg = str(getattr(e, "message", "") or e)
            reason = next((t for t in ("switched off", "redirect_uri", "STUBHUB_CLIENT_ID") if t in msg), None)
            raise HTTPException(409, f"StubHub connect unavailable: {reason or 'not configured'}")
        if not isinstance(url, str) or not url.startswith("https://"):
            raise HTTPException(502, "StubHub connect unavailable: no authorize URL")
        return {"authorize_url": url}

    @router.get("/api/stubhub/oauth/callback")
    def stubhub_callback(code: str | None = Query(None, max_length=2000),
                         state: str | None = Query(None, max_length=64),
                         error: str | None = Query(None, max_length=200)):
        if not stubhub_enabled():
            return _page("StubHub", _RESULT_TEXT["disabled"], 503)
        if error:
            return _page("StubHub not connected", "StubHub reported: " + error, 400)
        if not state or not _STATE_RE.match(state) or not code:
            return _page("StubHub not connected", _RESULT_TEXT["bad_state"], 400)
        try:
            res = _sb().rpc("stubhub_oauth_complete", {"p_state": state, "p_code": code}).execute().data
        except Exception:  # noqa: BLE001 - never echo DB errors to an unauthenticated page
            return _page("StubHub not connected", "Something went wrong on our side. Try again.", 502)
        res = res if isinstance(res, str) else ""
        if res == "connected":
            return _page("StubHub connected", _RESULT_TEXT["connected"])
        key = res.split(":", 1)[0]
        text = _RESULT_TEXT.get(key, "StubHub did not accept the sign-in. Try again.")
        return _page("StubHub not connected", text, 400)

    return router
