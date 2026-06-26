"""Storefront seat-map proxy + section crosswalk.

app.py decomposition slice (BR-CODE-1): the three `/api/store/seatmap/*` routes
plus their private `_fetch_tevo_seatmap_file` helper, lifted verbatim out of
app.py behind unchanged paths.

- `manifest.json` / `map.svg`: same-origin GET proxy to maps.ticketevolution.com
  (a public read host — RULE 2 OK; venue/config are int-typed so the upstream
  path can't be injected). The Tevomaps bundle fetches both; the CDN's missing
  CORS headers made the cross-origin browser fetch fail, so we proxy them.
- `section-map`: section -> seatmap-key crosswalk from `venue_section_map` via
  the service-role client (read-only SELECT — RULE 1 OK).

`requests` is imported here; tests stub `app.requests.get`, which is the same
module singleton, so the stub still binds. `sb` is resolved at request time via
`get_sb()` so the `app.sb` monkeypatch keeps working.
"""
from __future__ import annotations

from typing import Callable

import requests
from fastapi import APIRouter, HTTPException
from fastapi.responses import JSONResponse, Response

# Maps/manifests are immutable per venue/config — cache hard at edge + browser.
_SEATMAP_CACHE = "public, max-age=86400"


def _fetch_tevo_seatmap_file(venue_id: int, configuration_id: int, filename: str, accept: str):
    """Server-side GET of a TEvo seat-map asset, returned to the caller.

    Read-only GET passthrough (RULE 2 OK — maps.ticketevolution.com is a public
    read host, no write). venue_id / configuration_id are int-typed so the
    upstream path can't be injected.
    """
    url = f"https://maps.ticketevolution.com/{venue_id}/{configuration_id}/{filename}"
    try:
        r = requests.get(url, timeout=8, headers={"Accept": accept})
    except requests.RequestException:
        raise HTTPException(502, "seatmap fetch failed")
    if r.status_code == 404:
        raise HTTPException(404, "no seatmap for this venue/configuration")
    if not r.ok:
        raise HTTPException(502, f"seatmap upstream {r.status_code}")
    return r


def build_seatmap_router(get_sb: Callable[[], object]) -> APIRouter:
    router = APIRouter()

    @router.get("/api/store/seatmap/{venue_id}/{configuration_id}/manifest.json")
    def store_seatmap_manifest(venue_id: int, configuration_id: int):
        """Section manifest proxy. Consumed by the Tevomaps bundle (price-region
        matching) AND by seatmap.js's listing→section price-coloring index."""
        r = _fetch_tevo_seatmap_file(venue_id, configuration_id, "manifest.json", "application/json")
        try:
            body = r.json()
        except ValueError:
            raise HTTPException(502, "manifest not JSON")
        return JSONResponse(content=body, headers={"Cache-Control": _SEATMAP_CACHE})

    @router.get("/api/store/seatmap/{venue_id}/{configuration_id}/map.svg")
    def store_seatmap_svg(venue_id: int, configuration_id: int):
        """Map SVG proxy. The Tevomaps bundle fetches this then injects it as the
        interactive map; without the proxy the cross-origin fetch fails."""
        r = _fetch_tevo_seatmap_file(venue_id, configuration_id, "map.svg", "image/svg+xml")
        return Response(
            content=r.content,
            media_type="image/svg+xml",
            headers={
                "Cache-Control": _SEATMAP_CACHE,
                # Defense-in-depth: this is the only same-origin route that returns
                # SVG. An SVG opened directly as a document executes embedded
                # scripts; the bundle reads .text() so these headers don't affect
                # it, but a direct hit would otherwise be a script-execution sink.
                # `sandbox` (no tokens) blocks script execution on direct nav;
                # nosniff stops content-type confusion.
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox",
                "X-Content-Type-Options": "nosniff",
            },
        )

    @router.get("/api/store/seatmap/{venue_id}/{configuration_id}/section-map")
    def store_seatmap_section_map(venue_id: int, configuration_id: int, platform: str = "evo"):
        """Authoritative section -> seatmap-key crosswalk for the storefront map.

        Bridges `public.venue_section_map` (built by `build_venue_section_map()`)
        to the public storefront via the service-role client (read-only SELECT —
        RULE 1 OK). Config-aware: prefer the event's configuration bucket, fall
        back to the union bucket (configuration_id = 0). seatmap.js still falls
        back to its heuristic for any section the crosswalk hasn't mapped.
        """
        plat = (platform or "evo").lower()
        if plat not in ("evo", "sg"):
            raise HTTPException(400, "unsupported platform")
        db = get_sb()
        if db is None:
            return JSONResponse(content={"sections": {}, "config_used": None, "count": 0})

        def _rows(cfg: int):
            try:
                return (
                    db.table("venue_section_map")
                    .select("section_raw,seatmap_key")
                    .eq("tevo_venue_id", venue_id)
                    .eq("configuration_id", cfg)
                    .eq("platform", plat)
                    .execute().data
                ) or []
            except Exception:
                return []

        config_used = configuration_id
        rows = _rows(configuration_id)
        if not rows and configuration_id != 0:
            config_used = 0
            rows = _rows(0)

        sections: dict[str, str] = {}
        for row in rows:
            raw = (row.get("section_raw") or "").strip()
            key = (row.get("seatmap_key") or "").strip()
            if raw and key:
                sections[raw] = key
        # Crosswalk is rebuilt by the venue_section_map_refresh cron — cache
        # modestly (not the 24h used for immutable manifests/SVGs).
        return JSONResponse(
            content={"sections": sections, "config_used": config_used, "count": len(sections)},
            headers={"Cache-Control": "public, max-age=3600"},
        )

    return router
