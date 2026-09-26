"""Reverse proxy for the Exos SPA (/bridge/*, D4) to its own Render service.

Exos (source: JulianS4K/EXP) runs on its own service, `exos-web`, which serves
the app under /bridge/ and sets its own per-page security headers, link
previews and sitemap. When EXOS_ORIGIN is set (e.g. https://exos-web.onrender.com),
this app forwards /bridge/* there, so the Render link, the origin and the
Supabase session shared with the hub all stay the same.

Unset EXOS_ORIGIN to roll back: the routes serve static/bridge/ as before. The
same fallback kicks in per request when exos-web is unreachable or answering
502/503/504 (deploying, crashed), so the link never goes dark while the static
copy exists. Upstream headers pass through; the security middleware in
server.py only fills in headers that are missing (setdefault).
"""
from __future__ import annotations

import os
from typing import Callable

import requests
from fastapi import Request
from fastapi.responses import Response

# Not forwarded back: hop-by-hop, plus length/encoding, because requests
# already decoded the body.
_DROP_RESPONSE_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
    "trailers", "transfer-encoding", "upgrade", "content-encoding", "content-length",
}
# Request headers exos-web needs (the crawler check reads user-agent; caching
# uses the validators). Cookies and Authorization are deliberately not sent:
# the SPA authenticates with Supabase in the browser, not via this hop.
_FORWARD_REQUEST_HEADERS = (
    "user-agent", "accept", "accept-language", "if-none-match", "if-modified-since", "referer",
)
_FALLBACK_STATUSES = {502, 503, 504}

Fetch = Callable[..., requests.Response]


def exos_origin() -> str | None:
    """EXOS_ORIGIN without a trailing slash, or None when unset / not http(s)."""
    raw = (os.environ.get("EXOS_ORIGIN") or "").strip().rstrip("/")
    return raw if raw.startswith(("https://", "http://")) else None


def proxy_bridge(request: Request, origin: str, fetch: Fetch = requests.request, timeout: float = 10.0) -> Response | None:
    """Forward this /bridge request to `origin`. None means "serve locally":
    the upstream couldn't be reached or answered 502/503/504."""
    url = origin + request.url.path + (f"?{request.url.query}" if request.url.query else "")
    headers = {k: v for k in _FORWARD_REQUEST_HEADERS if (v := request.headers.get(k))}
    client = request.client.host if request.client else ""
    prior = request.headers.get("x-forwarded-for")
    headers["X-Forwarded-For"] = f"{prior}, {client}" if prior and client else (prior or client)
    headers["X-Forwarded-Host"] = request.headers.get("host", "")
    headers["X-Forwarded-Proto"] = request.headers.get("x-forwarded-proto", request.url.scheme)
    try:
        upstream = fetch(request.method, url, headers=headers, timeout=timeout, allow_redirects=False)
    except requests.RequestException as e:
        print(f"[bridge] exos-web unreachable for {request.url.path!r}: {e!r}; serving static/bridge")
        return None
    if upstream.status_code in _FALLBACK_STATUSES:
        print(f"[bridge] exos-web answered {upstream.status_code} for {request.url.path!r}; serving static/bridge")
        return None
    out = {k: v for k, v in upstream.headers.items() if k.lower() not in _DROP_RESPONSE_HEADERS}
    body = b"" if request.method == "HEAD" else upstream.content
    return Response(content=body, status_code=upstream.status_code, headers=out)
