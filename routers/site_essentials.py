"""Site-essentials routes (SEO + browser-tab UX) — robots.txt / sitemap.xml /
favicon.ico.

First slice of the app.py decomposition (BR-CODE-1). Browsers + crawlers probe
these at fixed paths; without explicit routes they'd 404 (Railway audit
2026-05-16 found all 3 missing on the deployed storefront).

Built via a factory so the deploy-specific storefront base URL is passed in
from app.py rather than imported back out of it (one-directional import graph).
Behavior is identical to the prior inline app.py routes — covered by
tests/test_public_infra_routes.py.
"""
from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import RedirectResponse, Response


def build_site_essentials_router(
    storefront_base_url: str,
    dynamic_paths_provider=None,
) -> APIRouter:
    """Return an APIRouter with /robots.txt, /sitemap.xml, /favicon.ico.

    `storefront_base_url` is this deploy's base (e.g. the Render external URL),
    so each environment advertises its own sitemap correctly.

    `dynamic_paths_provider`, when given, is a zero-arg callable returning an
    iterable of additional sitemap paths (e.g. /store/event/123,
    /store/performer/456) resolved at request time. Any exception or non-iterable
    return is treated as "no dynamic paths" so the sitemap never errors — the
    static surface map always renders.
    """
    router = APIRouter()

    robots_txt_body = (
        "User-agent: *\n"
        "Allow: /\n"
        "Disallow: /api/\n"
        "Disallow: /store/test\n"
        "Disallow: /store/test/\n"
        f"Sitemap: {storefront_base_url}/sitemap.xml\n"
    )

    @router.get("/robots.txt", include_in_schema=False)
    def robots_txt():
        """Crawler directive — public pages allowed, /api/ + test harness denied.
        Sitemap URL self-references this deploy's base so each environment
        advertises its own sitemap correctly."""
        return Response(content=robots_txt_body, media_type="text/plain; charset=utf-8")

    _STATIC_PATHS = ["/store", "/store/discover", "/store/about", "/store/privacy", "/store/terms"]

    @router.get("/sitemap.xml", include_in_schema=False)
    def sitemap_xml():
        """Sitemap: the static storefront surface plus dynamic per-event and
        per-performer landing URLs from `dynamic_paths_provider` (when wired).
        The provider is fully defensive — any failure falls back to just the
        static surface so the sitemap always renders valid XML."""
        seen = set()
        paths = []
        for p in _STATIC_PATHS:
            if p not in seen:
                seen.add(p)
                paths.append(p)
        if dynamic_paths_provider is not None:
            try:
                for p in (dynamic_paths_provider() or []):
                    if isinstance(p, str) and p.startswith("/") and p not in seen:
                        seen.add(p)
                        paths.append(p)
            except Exception:  # noqa: BLE001 — sitemap must never 500
                pass
        body = '<?xml version="1.0" encoding="UTF-8"?>\n'
        body += '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        for path in paths:
            body += f"  <url><loc>{storefront_base_url}{path}</loc></url>\n"
        body += "</urlset>\n"
        return Response(content=body, media_type="application/xml; charset=utf-8")

    @router.get("/favicon.ico", include_in_schema=False)
    def favicon_ico():
        """Browsers probe /favicon.ico even when the page declares an SVG.
        Redirect to the canonical SVG so users get the icon instead of a 404."""
        return RedirectResponse(url="/static/store/favicon.svg", status_code=308)

    return router
