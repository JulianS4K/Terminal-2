"""DB-touching broker helpers shared by app.py + routers/* (BR-CODE-1 helper pass).

Unlike core/helpers.py (pure), these take a live supabase `db` client as their
first argument and issue read-only queries. They hold no module state and import
nothing from app.py (one-directional: app.py/routers -> core, never reverse), so
they're safe to move out of the monolith incrementally. Moved verbatim from app.py.
"""
from __future__ import annotations


def bulk_performer_assets(db, performer_ids: list[int]) -> dict[int, dict]:
    """Fetch performer_metadata for many performer_ids at once. Returns map
    {performer_id: {logo_default_url, color_primary, ...}}. Used by event
    overview to attach home + away logos in a single roundtrip."""
    if not performer_ids:
        return {}
    rows = (db.table("performer_metadata")
              .select("performer_id, name, espn_team_id, espn_league, "
                      "color_primary, color_alternate, logo_default_url, logo_dark_url")
              .in_("performer_id", performer_ids)
              .execute()).data or []
    return {int(r["performer_id"]): r for r in rows}
