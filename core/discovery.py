"""Owned-inventory discovery helper — extracted from server.py (BR-CODE-1 core/
pass).

`attach_owned_metadata` intersects a list of TEvo event ids with our owned +
active inventory and decorates each with metadata + display distance. Shared by
the storefront "near me" hybrid + supabase modes (routers/store.py). Pure read
+ compute; depends outward only on core.helpers (one-directional). The
performer-asset bulk lookup is injected so the server-module monkeypatch
(app._bulk_performer_assets) keeps binding.
"""
from __future__ import annotations

from core.helpers import haversine_miles as _haversine_miles


def attach_owned_metadata(
    db,
    candidate_ids: list[int],
    user_lat: float,
    user_lon: float,
    *,
    bulk_performer_assets,
) -> list[dict]:
    """Given a list of TEvo event_ids, intersect with our owned + active set
    and decorate with metadata + display distance. Used by both 'hybrid' and
    'supabase' near-me modes to keep response shape identical.
    """
    if not candidate_ids:
        return []
    # Two-query merge (was `events!inner(...)` — PostgREST PGRST200 after
    # cache rebuilds because view-to-table FK inference is flaky).
    metrics_rows = (
        db.table("latest_event_metrics")
        .select("event_id,owned_tickets_count,owned_groups_count,retail_min")
        .gt("owned_tickets_count", 0)
        .in_("event_id", [int(e) for e in candidate_ids])
        .execute().data
    ) or []
    if not metrics_rows:
        return []
    metric_event_ids = [int(m["event_id"]) for m in metrics_rows if m.get("event_id")]
    events_rows = (
        db.table("events")
        .select("id,name,occurs_at_local,venue_id,venue_name,venue_location,"
                "primary_performer_id,primary_performer_name")
        .in_("id", metric_event_ids)
        .execute().data
    ) or []
    events_by_id = {int(e["id"]): e for e in events_rows if e.get("id")}
    rows = [
        {**m, "events": events_by_id.get(int(m["event_id"]))}
        for m in metrics_rows
        if events_by_id.get(int(m["event_id"]))
    ]
    if not rows:
        return []

    ev_ids = [r["event_id"] for r in rows]
    try:
        lc = (
            db.table("event_lifecycle").select("event_id,is_active")
            .in_("event_id", ev_ids).execute().data
        ) or []
        inactive = {r["event_id"] for r in lc if not r.get("is_active")}
    except Exception:
        inactive = set()

    venue_ids = list({(r.get("events") or {}).get("venue_id") for r in rows
                      if (r.get("events") or {}).get("venue_id")})
    coord_map: dict[int, tuple[float, float]] = {}
    if venue_ids:
        try:
            ca = (
                db.table("venue_assets").select("tevo_venue_id,latitude,longitude")
                .in_("tevo_venue_id", venue_ids).execute().data
            ) or []
            for c in ca:
                if c.get("latitude") is not None and c.get("longitude") is not None:
                    coord_map[int(c["tevo_venue_id"])] = (float(c["latitude"]), float(c["longitude"]))
        except Exception:
            coord_map = {}

    perf_ids = [int((r.get("events") or {}).get("primary_performer_id"))
                for r in rows
                if (r.get("events") or {}).get("primary_performer_id")
                and r["event_id"] not in inactive]
    perf_assets = bulk_performer_assets(db, perf_ids) if perf_ids else {}

    out: list[dict] = []
    for r in rows:
        eid = r["event_id"]
        if eid in inactive:
            continue
        ev = r.get("events") or {}
        coords = coord_map.get(int(ev.get("venue_id"))) if ev.get("venue_id") else None
        dist = _haversine_miles(user_lat, user_lon, coords[0], coords[1]) if coords else None
        a = perf_assets.get(int(ev.get("primary_performer_id"))) if ev.get("primary_performer_id") else None
        out.append({
            "id": eid,
            "name": ev.get("name"),
            "occurs_at_local": ev.get("occurs_at_local"),
            "venue_name": ev.get("venue_name"),
            "venue_location": ev.get("venue_location"),
            "primary_performer_name": ev.get("primary_performer_name"),
            "primary_performer_logo": (a or {}).get("logo_default_url"),
            "primary_performer_color": (a or {}).get("color_primary"),
            "from_price": r.get("retail_min"),
            "owned_tickets_count": r.get("owned_tickets_count"),
            "distance_miles": round(dist, 1) if dist is not None else None,
        })
    return out
