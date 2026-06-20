"""Pure utility helpers shared by app.py + routers/* (BR-CODE-1 helper pass).

These have NO db/client/config dependencies — pure functions — so both app.py
and the router modules import them from here (one-directional: app.py/routers ->
core, never reverse). Moved verbatim from app.py.
"""
from __future__ import annotations

import re
from datetime import datetime

from fastapi import HTTPException


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


# Characters that conflict with PostgREST's `.or_()` clause parser, so a pattern
# containing them must be double-quoted in an or-clause value.
_OR_VALUE_RESERVED = (",", "(", ")")


def or_ilike_clause(col: str, pattern: str) -> str:
    """Build a single `col.ilike.<pattern>` clause for PostgREST `.or_()`.
    Wraps the pattern in double quotes when it contains characters that
    conflict with the or-clause parser (commas, parens). Embedded double
    quotes are doubled per PostgREST's quoting rules.
    """
    if any(c in pattern for c in _OR_VALUE_RESERVED) or '"' in pattern:
        escaped = pattern.replace('"', '""')
        return f'{col}.ilike."{escaped}"'
    return f"{col}.ilike.{pattern}"


# Event-name substrings signalling a game that may never happen as scheduled.
_SPECULATIVE_NAME_PATTERNS = (
    "CANCELLED",
    "(IF NECESSARY)",
)


def is_speculative_event_name(name: str | None) -> bool:
    """True when an event name contains any pattern indicating the game may
    never happen as scheduled (CANCELLED or playoff if-necessary). Consumer
    surfaces should drop these. (Date TBD) events are NOT speculative —
    they're real scheduled games with pending datetime confirmation, surfaced
    via the `tbd` badge."""
    if not name:
        return False
    upper = name.upper()
    return any(p in upper for p in _SPECULATIVE_NAME_PATTERNS)


_WORLD_CUP_RE = re.compile(
    r"\bworld\s*cup\s*soccer\b|\bworld\s*cup\b.{0,40}\bmatch\s+\d+", re.I
)


def classify_world_cup(event_name: str | None,
                       performer_name: str | None = None) -> bool:
    """True if the event is a FIFA World Cup soccer match.

    We surface owned World Cup matches in the storefront Featured rail
    regardless of host city — the rail is NYC-anchored, but the World Cup is
    a national draw and our owned WC inventory can sit at any host venue
    (e.g. Match 72 at Mercedes-Benz Stadium, Atlanta). The primary signal is
    the EVO performer name "World Cup Soccer"; the name regex is a fallback.
    """
    if performer_name and performer_name.strip().lower() == "world cup soccer":
        return True
    if not event_name:
        return False
    return bool(_WORLD_CUP_RE.search(event_name))


def clean_opt_url(v) -> str | None:
    """Coerce sentinel non-URLs to real None.

    `v_event_seating_chart` (and occasionally TEvo's inline config) carry the
    literal string "null" / "None" / "" for an absent seat-map URL. Passed
    through verbatim, the frontend treats the truthy string "null" as a URL
    and renders a broken <img> whose src resolves to /store/event/null. Coerce
    those sentinels to None so the no-chart placeholder path is taken.
    """
    if v is None:
        return None
    s = str(v).strip()
    if s.lower() in ("null", "none", ""):
        return None
    return v


# A 3-digit run in a TEvo client exception message — used to recover the
# upstream HTTP status so the route can map it to the right downstream code.
_TEVO_STATUS_RE = re.compile(r"\b(\d{3})\b")


def tevo_runtime_to_http(
    e: Exception, *, not_found_detail: str, failure_detail: str
) -> HTTPException:
    """Map a TEvo client runtime error to the right HTTPException: upstream
    400/404 -> 404 (event gone), 429/503 -> 503 (retryable), else 502."""
    m = _TEVO_STATUS_RE.search(str(e))
    upstream = int(m.group(1)) if m else None
    if upstream in (400, 404):
        return HTTPException(404, not_found_detail)
    if upstream in (429, 503):
        return HTTPException(503, failure_detail)
    return HTTPException(502, failure_detail)


def csv_list(v: str | None) -> list[str]:
    """Split a comma-separated string into a trimmed, empties-dropped list."""
    return [s.strip() for s in (v or "").split(",") if s.strip()]


def normalize_filters(raw: dict | None) -> dict:
    """Coerce a free-form filter dict (URL params or share_links.filters JSON)
    into the canonical shape the resolver expects. Drops empty values."""
    raw = raw or {}
    def _maybe_csv(v):
        if v is None:
            return []
        if isinstance(v, list):
            return [str(x).strip() for x in v if str(x).strip()]
        return csv_list(str(v))
    def _maybe_num(v):
        if v is None or v == "":
            return None
        try:
            return float(v)
        except (TypeError, ValueError):
            return None
    def _maybe_int(v):
        if v is None or v == "":
            return None
        try:
            return int(v)
        except (TypeError, ValueError):
            return None
    return {
        "section": _maybe_csv(raw.get("section")),
        "zones": _maybe_csv(raw.get("zones")),
        "min_price": _maybe_num(raw.get("min_price")),
        "max_price": _maybe_num(raw.get("max_price")),
        "min_qty": _maybe_int(raw.get("min_qty")),
    }


def ticket_group_to_listing(tg: dict) -> dict:
    """Reduce a TEvo ticket_group payload to the public-safe fields a buyer
    needs. Strips wholesale price, signature, office/brokerage attribution."""
    return {
        "id": tg.get("id"),
        "section": tg.get("section"),
        "row": tg.get("row"),
        "available_quantity": tg.get("available_quantity") or tg.get("quantity"),
        "splits": tg.get("splits") or [],
        "retail_price": tg.get("retail_price"),
        "format": tg.get("format"),
        "type": tg.get("type") or "event",
        "in_hand": tg.get("in_hand"),
        "in_hand_on": tg.get("in_hand_on"),
        "instant_delivery": tg.get("instant_delivery"),
        "public_notes": tg.get("public_notes"),
        "view_type": tg.get("view_type"),
        "wheelchair": tg.get("wheelchair"),
    }
