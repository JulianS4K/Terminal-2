"""Trip planner — optimal multi-city itineraries around live events.

Shared server-side module used by both the D1 store (`/api/store/performers/{id}/trip-plan`)
and the D0 terminal (`/api/broker/performers/{id}/trip-plan`). Engine vendored from
axiom-orion/gigtrip (MIT) — see NOTICE.md.
"""
from .planner import (
    discover_tours_near,
    fetch_performer_rows,
    plan_from_rows,
    plan_multi_performer_tour,
    plan_performer_tour,
    plan_performer_trip,
    plan_tour_package,
    rank_tours_near,
    row_to_event,
)

__all__ = [
    "plan_performer_trip",
    "plan_performer_tour",
    "plan_multi_performer_tour",
    "plan_tour_package",
    "discover_tours_near",
    "rank_tours_near",
    "plan_from_rows",
    "fetch_performer_rows",
    "row_to_event",
]
