"""Trip planner — optimal multi-city itineraries around live events.

Shared server-side module used by both the D1 store (`/api/store/performers/{id}/trip-plan`)
and the D0 terminal (`/api/broker/performers/{id}/trip-plan`). Engine vendored from
axiom-orion/gigtrip (MIT) — see NOTICE.md.
"""
from .planner import (
    fetch_performer_rows,
    plan_from_rows,
    plan_performer_trip,
    row_to_event,
)

__all__ = [
    "plan_performer_trip",
    "plan_from_rows",
    "fetch_performer_rows",
    "row_to_event",
]
