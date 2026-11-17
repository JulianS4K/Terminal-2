"""Developer portal for the /mcp server — the `/developers` page + public
catalog JSON.

The page is where anyone signs in with Google and mints an external API key;
the key itself is issued by the SQL function ``mcp_self_issue_key`` called
from the browser with the user's own session (mig 20261021190000), so no
backend route ever sees a plaintext key. This router only serves the shell
and ``/api/mcp/catalog``: the tool list (from routers/mcp_api.py) and the
per-feed freshness report, cached in-process because they are the same for
every visitor.
"""
from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable

from fastapi import APIRouter
from fastapi.responses import HTMLResponse, PlainTextResponse

from routers import mcp_api

LIMITS = {"rate_per_min": mcp_api.DEFAULT_RATE_PER_MIN, "daily_quota": mcp_api.DEFAULT_DAILY_QUOTA,
          "max_rows_per_query": mcp_api.MAX_ROWS}


def build_developers_router(
    static_dir: str,
    *,
    get_require_sb: Callable[[], Callable],
    cache_ttl: float = 60.0,
) -> APIRouter:
    router = APIRouter()
    page_path = os.path.join(static_dir, "developers", "index.html")
    docs_path = os.path.join(os.path.dirname(static_dir), "docs", "mcp_onboarding.md")
    lock = threading.Lock()
    cached: dict[str, Any] = {"at": 0.0, "value": None}

    @router.api_route("/developers", methods=["GET", "HEAD"])
    def developers_page():
        with open(page_path, "r", encoding="utf-8") as f:
            body = f.read()
        return HTMLResponse(body, headers={"Cache-Control": "no-cache, must-revalidate"})

    @router.api_route("/developers/docs.md", methods=["GET", "HEAD"])
    def developers_docs():
        """The onboarding doc, raw Markdown — one source (docs/mcp_onboarding.md),
        readable by humans and fetchable by agents."""
        with open(docs_path, "r", encoding="utf-8") as f:
            body = f.read()
        return PlainTextResponse(body, media_type="text/markdown; charset=utf-8",
                                 headers={"Cache-Control": "public, max-age=300"})

    def _freshness() -> dict:
        try:
            sb = get_require_sb()()
            return sb.rpc("mcp_data_freshness", {}).execute().data or {"feeds": []}
        except Exception as e:  # noqa: BLE001 - the catalog page must render without the DB
            return {"feeds": [], "error": f"freshness unavailable: {type(e).__name__}"}

    @router.get("/api/mcp/catalog")
    def catalog():
        """Everything a bot author needs before they have a key: endpoint,
        auth scheme, limits, the external tool list and current data freshness."""
        with lock:
            if cached["value"] is None or time.monotonic() - cached["at"] > cache_ttl:
                cached["value"] = {
                    "endpoint": "/mcp",
                    "docs": "/developers/docs.md",
                    "transport": "streamable-http",
                    "auth": "Authorization: Bearer <key>  (or X-API-Key: <key>)",
                    "limits": LIMITS,
                    "instructions": mcp_api.INSTRUCTIONS,
                    "tools": mcp_api.tool_catalog(mcp_api.EXTERNAL_TOOLS),
                    "views": {k: list(v) for k, v in mcp_api.EXTERNAL_QUERY_VIEWS.items()},
                    "freshness": _freshness(),
                }
                cached["at"] = time.monotonic()
            return cached["value"]

    return router
