"""Per-performer (and multi-performer) trip planning over our canonical event data.

Bridges `public.v_event_base` rows into the vendored gigtrip optimizer (see `gigtrip/`,
MIT — `NOTICE.md`) and returns a JSON-serializable plan. Pure compute: no writes, no
upstream API calls — it only reads event geography/dates we already hold.

Split so the planning logic is testable offline:
  - `plan_from_rows(...)` — pure: rows -> itinerary dict (no DB).
  - `fetch_performer_rows(db, ...)` / `plan_performer_trip(db, ...)` — thin Supabase wrappers.
"""
from __future__ import annotations

from datetime import date

from .city_centroids import centroid_for
from .gigtrip.model import Constraints, Event, Itinerary
from .gigtrip.optimizer import plan_by_date, plan_optimal


# --------------------------------------------------------------------------- #
# row mapping + serialization
# --------------------------------------------------------------------------- #
def row_to_event(r: dict) -> Event:
    """Map one v_event_base-shaped row into a gigtrip Event.

    PostgREST returns numerics as strings, so lat/lon/date are coerced defensively.
    """
    d = r.get("event_date")
    day = d if isinstance(d, date) else date.fromisoformat(str(d)[:10])
    return Event(
        id=str(r["tevo_event_id"]),
        title=(r.get("primary_performer_name") or r.get("event_name") or "").strip(),
        kind="music",
        day=day,
        city=r.get("venue_city") or "",
        venue=r.get("venue_name") or "",
        lat=float(r["venue_lat"]),
        lon=float(r["venue_lon"]),
    )


def _event_dict(e: Event, csrc: dict[int, str]) -> dict:
    return {
        "event_id": int(e.id),
        "performer": e.title,
        "venue": e.venue,
        "city": e.city,
        "date": e.day.isoformat(),
        "lat": e.lat,
        "lon": e.lon,
        "coord_source": csrc.get(int(e.id), "venue"),  # "venue" (precise) | "city" (centroid)
    }


def _itin_dict(it: Itinerary, csrc: dict[int, str]) -> dict:
    return {
        "count": it.count,
        "value": round(it.value, 4),
        "travel_km": round(it.travel_km, 1),
        "events": [_event_dict(e, csrc) for e in it.events],
    }


# --------------------------------------------------------------------------- #
# pure planning (no DB) — unit-testable
# --------------------------------------------------------------------------- #
def plan_from_rows(rows: list[dict], home: dict, budget_km: float,
                   start: date, end: date, prefs: dict[str, float] | None = None,
                   max_events: int | None = None,
                   max_km_per_day: float = 1200.0) -> dict:
    """Build the optimal itinerary (and the sort-by-date baseline) from raw rows.

    `home` is {"name", "lat", "lon"}. `prefs` maps lowercased performer title -> weight;
    when omitted every distinct performer is weighted 1.0 (the single-performer case is
    just the uniform-weight degenerate of the general multi-performer optimizer).
    """
    usable = [r for r in rows if r.get("venue_lat") is not None
              and r.get("venue_lon") is not None]
    events = [row_to_event(r) for r in usable]
    csrc = {int(r["tevo_event_id"]): r.get("_coord_source", "venue") for r in usable}
    if prefs is None:
        prefs = {e.title.lower(): 1.0 for e in events}

    c = Constraints(
        home_name=home["name"], home_lat=float(home["lat"]), home_lon=float(home["lon"]),
        start=start, end=end, max_travel_km=float(budget_km),
        max_events=max_events, max_km_per_day=max_km_per_day,
    )
    optimal = plan_optimal(events, prefs, c)
    baseline = plan_by_date(events, prefs, c)

    titles = sorted({e.title for e in events})
    performer_label = titles[0] if len(titles) == 1 else f"{len(titles)} performers"
    n_city = sum(1 for v in csrc.values() if v == "city")

    return {
        "performer": performer_label,
        "home": home,
        "budget_km": float(budget_km),
        "window": {"start": start.isoformat(), "end": end.isoformat()},
        "tour_date_count": len(events),
        "coord_coverage": {
            "venue": len(usable) - n_city,        # precise venue geocode
            "city_fallback": n_city,              # approximated to city centroid
            "dropped_no_coords": len(rows) - len(usable),  # neither available -> excluded
        },
        "optimal": _itin_dict(optimal, csrc),
        "baseline_by_date": _itin_dict(baseline, csrc),
        "shows_gained": optimal.count - baseline.count,
        "all_dates": [_event_dict(e, csrc) for e in sorted(events, key=lambda e: (e.day, e.id))],
    }


# --------------------------------------------------------------------------- #
# DB-backed entry points (Supabase client) — used by app.py routes
# --------------------------------------------------------------------------- #
_SELECT = ("tevo_event_id, event_name, primary_performer_name, venue_name, "
           "venue_city, venue_state, event_date, venue_lat, venue_lon")


def fetch_performer_rows(db, performer_id: int, start: date, end: date,
                         limit: int = 500) -> list[dict]:
    """Upcoming events for one performer from v_event_base, calendar order.

    Returns ALL in-window rows (including those without a precise venue geocode); the
    city-centroid fallback fills coords for the un-geocoded ones before planning.
    """
    return (db.table("v_event_base")
            .select(_SELECT)
            .eq("tevo_performer_id", performer_id)
            .gte("event_date", start.isoformat())
            .lte("event_date", end.isoformat())
            .order("event_date")
            .limit(limit)
            .execute().data) or []


def _apply_coord_fallback(db, rows: list[dict]) -> None:
    """In-place: tag rows with a precise venue geocode as coord_source='venue'; for the rest,
    resolve EVO's `events.venue_location` 'City, ST' text to a city centroid (coord_source=
    'city'). Rows that resolve to neither keep NULL coords and are dropped at plan time."""
    missing = []
    for r in rows:
        if r.get("venue_lat") is not None and r.get("venue_lon") is not None:
            r["_coord_source"] = "venue"
        else:
            missing.append(r)
    if not missing:
        return
    ids = [int(r["tevo_event_id"]) for r in missing]
    locs = (db.table("events").select("id, venue_location")
            .in_("id", ids).execute().data) or []
    locmap = {int(x["id"]): x.get("venue_location") for x in locs}
    for r in missing:
        c = centroid_for(locmap.get(int(r["tevo_event_id"])))
        if c:
            r["venue_lat"], r["venue_lon"], r["_coord_source"] = c[0], c[1], "city"


def plan_performer_trip(db, performer_id: int, home_lat: float, home_lon: float,
                        budget_km: float, start: date, end: date,
                        home_name: str = "Home", max_events: int | None = None,
                        max_km_per_day: float = 1200.0) -> dict:
    """End-to-end: pull a performer's upcoming dates and plan the optimal trip."""
    rows = fetch_performer_rows(db, performer_id, start, end)
    _apply_coord_fallback(db, rows)
    home = {"name": home_name, "lat": home_lat, "lon": home_lon}
    payload = plan_from_rows(rows, home, budget_km, start, end,
                             max_events=max_events, max_km_per_day=max_km_per_day)
    payload["performer_id"] = int(performer_id)
    return payload
