"""Storefront HTML page-shell routes (BR-CODE-1 decomposition).

The customer-facing storefront *pages* (as opposed to the `/api/store/*` JSON
surface, which lives in routers/store.py): the catalog, event detail, discover,
tour, concierge chat, the legal shells, share permalinks, and the PWA service
worker. Each is a thin HTML/asset server.

The version/base-rewrite + cache helper (`_render_storefront_page` ->
`_read_storefront_html` -> `_STOREFRONT_HTML_CACHE`) stays in server.py — the
tests call those helpers directly and mutate the cache — and is injected here via
`get_render_storefront_page`, resolved at request time so the test monkeypatches
(`_STOREFRONT_VERSION`, `_STOREFRONT_HTML_CACHE`) keep binding through the factory.
"""
from __future__ import annotations

import os
from typing import Callable

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, Response

from core.seo import inject_event_meta, is_link_crawler


def build_storefront_pages_router(
    static_dir: str,
    *,
    get_render_storefront_page: Callable[[], Callable],
    get_read_storefront_html: Callable[[], Callable],
    get_resolve_event: Callable[[], Callable],
    base_url: str,
) -> APIRouter:
    router = APIRouter()

    @router.api_route("/store/chat", methods=["GET", "HEAD"])
    def store_chat_page():
        """Storefront concierge chat. Mounts the shared retail-chat widget
        (static/shared/retail-chat-widget.js) against /api/store/retail-chat."""
        return get_render_storefront_page()("chat.html")

    @router.api_route("/store", methods=["GET", "HEAD"])
    def store_index_page():
        return get_render_storefront_page()("index.html")

    @router.api_route("/store-sw.js", methods=["GET", "HEAD"], include_in_schema=False)
    def store_service_worker():
        """Serve the storefront PWA service worker from a ROOT path so it can claim
        the '/store' scope. A service worker only controls pages at/below its own URL
        directory, so served from /static/store/ it could never cover the /store
        routes. store.js registers it with { scope: '/store' }; the
        Service-Worker-Allowed header authorizes that broader-than-directory scope."""
        path = os.path.join(static_dir, "store", "sw.js")
        with open(path, "r", encoding="utf-8") as f:
            body = f.read()
        return Response(
            content=body,
            media_type="application/javascript",
            headers={
                "Cache-Control": "no-cache, must-revalidate",
                "Service-Worker-Allowed": "/store",
            },
        )

    @router.api_route("/store/event/{event_id}", methods=["GET", "HEAD"])
    def store_event_page(event_id: int, request: Request):
        """Serve the event-page shell. For link-unfurl / SEO crawlers (no JS),
        inject per-event Open Graph / Twitter / JSON-LD metadata server-side so
        shared links render a real preview. Humans get the fast static shell and
        store.js fills the per-event tags client-side once the payload resolves.
        The crawler fetch is fully defensive (any failure falls back to the
        unchanged shell) — see core.seo.inject_event_meta."""
        shell = get_read_storefront_html()("event.html")
        if is_link_crawler(request.headers.get("user-agent")):
            shell = inject_event_meta(shell, event_id, base_url, get_resolve_event())
        return HTMLResponse(
            content=shell,
            headers={"Cache-Control": "no-cache, must-revalidate"},
        )

    @router.api_route("/store/discover", methods=["GET", "HEAD"])
    def store_discover_page():
        """Reverse discovery — 'what tours can I catch near me'. Backed by
        /api/store/tours/near; mounts via store.js (data-page=discover)."""
        return get_render_storefront_page()("discover.html")

    @router.api_route("/store/tour", methods=["GET", "HEAD"])
    def store_tour_page():
        """Follow-the-tour — pick a ticket count and attend a performer's whole tour;
        tickets auto-selected per date. Backed by /api/store/performers/{id}/tour-package;
        mounts via store.js (data-page=tour). Performer id read from ?performer=."""
        return get_render_storefront_page()("tour.html")

    # ---------- Static informational pages (Sprint 3 trust + legal) ----------
    # Plain HTML shells with no JS. Same Cache-Control: no-cache pattern as
    # the rest of the storefront so future edits propagate without browser
    # cache hangups. Footer links from every storefront page point here.

    @router.api_route("/store/about", methods=["GET", "HEAD"])
    def store_about_page():
        return get_render_storefront_page()("about.html")

    @router.api_route("/store/privacy", methods=["GET", "HEAD"])
    def store_privacy_page():
        return get_render_storefront_page()("privacy.html")

    @router.api_route("/store/terms", methods=["GET", "HEAD"])
    def store_terms_page():
        return get_render_storefront_page()("terms.html")

    @router.api_route("/s/{share_id}", methods=["GET", "HEAD"])
    def store_shared_page(share_id: str):  # noqa: ARG001 — id read by JS from URL
        """Serves the same event detail page; JS detects /s/ prefix and resolves
        the share via /api/store/share/{id} instead of using URL filter params."""
        return get_render_storefront_page()("event.html")

    @router.api_route("/store/shares", methods=["GET", "HEAD"])
    def store_shares_page():
        return get_render_storefront_page()("shares.html")

    return router
