"""Pure utility helpers shared by app.py + routers/* (BR-CODE-1 helper pass).

These have NO db/client/config dependencies — pure functions — so both app.py
and the router modules import them from here (one-directional: app.py/routers ->
core, never reverse). Moved verbatim from app.py.
"""
from __future__ import annotations

import re
from datetime import datetime


def listings_cadence_seconds(occurs_at_local: str | None) -> int:
    """Mirror collect-listings cron windows: closer events poll faster."""
    if not occurs_at_local:
        return 60 * 60 * 24
    try:
        # occurs_at_local is TEXT not TIMESTAMPTZ — known P1. Slice to date.
        d = datetime.fromisoformat(occurs_at_local[:10])
        days_out = (d - datetime.now()).days
    except Exception:
        return 60 * 60
    if days_out <= 1:
        return 60 * 20      # 20 min
    if days_out <= 7:
        return 60 * 60      # 60 min
    if days_out <= 30:
        return 60 * 60 * 4  # 4h
    if days_out <= 60:
        return 60 * 60 * 12  # 12h
    return 60 * 60 * 24     # 24h


def delta(curr, prev):
    """Compute delta + percent for a numeric metric. Returns dict or None."""
    if curr is None or prev is None:
        return None
    try:
        c = float(curr); p = float(prev)
    except (TypeError, ValueError):
        return None
    if c == p:
        return {"abs": 0, "pct": 0, "dir": "flat"}
    diff = c - p
    pct = (diff / p * 100) if p != 0 else None
    return {"abs": round(diff, 2), "pct": round(pct, 2) if pct is not None else None,
            "dir": "up" if diff > 0 else "down"}


# Playoff-specific phrases we recognize in event names. Order matters: more
# specific labels (NBA Finals) are tried before generic round indicators so
# the badge surfaces "NBA Finals" instead of "Playoffs" when both match.
_PLAYOFF_SPECIFIC_RE = re.compile(
    r"\b("
    r"NBA\s+Finals|"
    r"NBA\s+(?:Eastern|Western)\s+Conference\s+(?:Semi)?Finals|"
    r"NHL\s+Stanley\s+Cup\s+Finals|"
    r"NHL\s+(?:Eastern|Western)\s+Conference\s+(?:Semi)?Finals|"
    r"Stanley\s+Cup(?:\s+Finals?)?|"
    r"World\s+Series|"
    r"Super\s+Bowl(?:\s+L[IVX]+)?|"
    r"MLS\s+Cup|"
    r"NCAA\s+(?:Final\s+Four|National\s+Championship)|"
    r"College\s+Football\s+Playoff(?:\s+National\s+Championship)?"
    r")\b",
    re.IGNORECASE,
)
_PLAYOFF_GENERIC_RE = re.compile(
    r"\((?:Game\s+\d+|Round\s+\d+)|"           # parenthetical TEvo markers
    r"\b(?:Playoffs?|Postseason|Wild\s+Card|"
    r"Conference\s+Finals?|Conference\s+Semifinals?|"
    r"Division\s+Series)\b",
    re.IGNORECASE,
)


def classify_playoff(event_name: str | None) -> dict | None:
    """Return a playoff badge dict for the event name, or None.

    Two-tier:
      - specific  match (e.g. "NBA Finals") → that phrase is the label
      - generic   match (e.g. "Round 3", "(Game 7,") → label = "Playoffs"

    Falls back to None when nothing matches. Case-insensitive throughout.
    """
    if not event_name:
        return None
    m = _PLAYOFF_SPECIFIC_RE.search(event_name)
    if m:
        # Normalize whitespace so multi-word matches print cleanly.
        label = re.sub(r"\s+", " ", m.group(1)).strip()
        return {"label": label, "kind": "specific"}
    if _PLAYOFF_GENERIC_RE.search(event_name):
        return {"label": "Playoffs", "kind": "generic"}
    return None
