"""Bands in Town artist tour-tracking read routes (A1).

Wires the read-only `bandsintown_client` + the Instagram share-card generator
(`core/instagram_share`) into a broker endpoint: given an artist, return their
tour dates plus ready-to-post Instagram share bundles (SVG card + caption +
hashtags per date). Read-only against Bands in Town (GET only, RULE 2); no DB
writes, no third-party writes.

Factory takes a getter for the live `BandsInTownClient` factory + `require_auth`
(both owned by server.py) so the handler resolves current values at request time
(monkeypatch tests keep working) — mirrors `routers/seatdata.py`.
"""
from __future__ import annotations

from typing import Any, Callable

from fastapi import APIRouter, Depends, HTTPException, Query

from core.instagram_share import build_tour_shares


def build_bandsintown_router(
    get_bandsintown_client: Callable[[], Any],
    require_auth: Callable,
) -> APIRouter:
    router = APIRouter()

    @router.get("/api/broker/bandsintown/tour")
    def bandsintown_tour(
        artist: str = Query(..., min_length=1,
                            description='Artist name (percent-encoding handled) or an id_/mbid_ form'),
        date: str = Query("upcoming",
                          description='"upcoming" | "past" | "all" | "YYYY-MM-DD,YYYY-MM-DD"'),
        _=Depends(require_auth),
    ):
        """Artist profile + tour dates + one Instagram share bundle per date.

        Read-only. Returns 503 when `BANDSINTOWN_APP_ID` is not configured (env
        or Supabase Vault), 502 when the upstream call fails.
        """
        client = get_bandsintown_client()
        if not client:
            raise HTTPException(503, "BANDSINTOWN_APP_ID not set (env or Supabase Vault)")
        try:
            profile = client.get_artist(artist)
            events = client.get_artist_events(artist, date=date)
        except Exception as e:  # never leak upstream URL/body — status class only
            raise HTTPException(502, f"Bands in Town call failed: {type(e).__name__}")
        return {
            "artist": profile,
            "date_filter": date,
            "count": len(events),
            "events": events,
            "shares": build_tour_shares(events),
        }

    return router
