"""Pure utility helpers shared by app.py + routers/* (BR-CODE-1 helper pass).

These have NO db/client/config dependencies — pure functions — so both app.py
and the router modules import them from here (one-directional: app.py/routers ->
core, never reverse). Moved verbatim from app.py.
"""
from __future__ import annotations

import math
import re
from datetime import date, datetime, timedelta, timezone

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
    if s.lower() in ("null", "none", "undefined", ""):
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


# ---- numeric / date coercion (lenient: bad input -> None, never raises) ----

def parse_iso_or_none(s):
    """Normalize a TEvo ISO timestamp's 'Z' suffix to '+00:00' (Python 3.11+
    fromisoformat handles the rest). Returns None for falsy/bad input."""
    if not s:
        return None
    try:
        # TEvo emits 'Z' suffix; Python 3.11+ fromisoformat handles it
        return s.replace("Z", "+00:00") if isinstance(s, str) and s.endswith("Z") else s
    except Exception:
        return None


def to_int_or_none(v):
    """int(v) or None — empty/None/uncoercible -> None, never raises."""
    if v is None or v == "":
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def to_num_or_none(v):
    """float(v) or None — empty/None/uncoercible -> None, never raises."""
    if v is None or v == "":
        return None
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


# ---- geo / venue-name fuzzy matching ----

def haversine_miles(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance in miles between two (lat,lon) pairs."""
    R_MI = 3958.7613  # Earth's mean radius in miles
    lat1r, lat2r = math.radians(lat1), math.radians(lat2)
    dlat = lat2r - lat1r
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2) ** 2 + math.cos(lat1r) * math.cos(lat2r) * math.sin(dlon / 2) ** 2
    return 2 * R_MI * math.asin(math.sqrt(a))


def venue_tokens(name: str) -> set[str]:
    """Crude venue-name token bag for fuzzy match. Strips 'Parking' suffix
    so 'Citi Field Parking' matches 'Citi Field'."""
    if not name:
        return set()
    n = name.lower().replace(" parking", "").replace("parking", "")
    return {tok for tok in re.split(r"[^a-z0-9]+", n) if len(tok) >= 3}


def venue_overlap(a: str, b: str) -> float:
    """Jaccard overlap between two venue names. 1.0 = identical, 0 = nothing
    in common. ~0.5 typically indicates a real match (e.g. 'Daikin Park'
    vs 'Daikin Park Houston')."""
    ta, tb = venue_tokens(a), venue_tokens(b)
    if not ta or not tb:
        return 0.0
    inter = ta & tb
    union = ta | tb
    return len(inter) / len(union) if union else 0.0


# ---- section / event-name predicates + cache-key normalization ----

_PARKING_RE = re.compile(r"\b(parking|garage|valet|lot)\b", re.IGNORECASE)


def is_event_seat(tg: dict) -> bool:
    """True if this ticket_group is a real event seat (not parking / suite /
    hospitality). TEvo's `type` field is the canonical signal — defaults to
    'event' for actual seats. As a backup, scan section/format strings for
    parking-style tokens."""
    t = (tg.get("type") or "event").lower()
    if t != "event":
        return False
    section = (tg.get("section") or "")
    if _PARKING_RE.search(section):
        return False
    fmt = (tg.get("format") or "").lower()
    if "parking" in fmt:
        return False
    return True


def clean_section(s: str | None) -> str | None:
    """Trim a section label to <=24 chars; empty -> None."""
    s = (s or "").strip()[:24]
    return s or None


def movers_cache_key(city: str, days: int, limit: int) -> str:
    """Canonical cache key — case-folds city so 'nyc'/'NYC'/'New York' map
    to a single slot. The endpoint already maps 'NEW YORK' + 'NEW YORK CITY'
    aliases through the same venue_patterns, so the cache key uppercase
    matches that intent."""
    return f"{(city or '').upper()}|{int(days)}|{int(limit)}"


def normalize_search_key(q: str) -> str:
    """Normalize a user query for cache slot identity. Collapses runs of
    whitespace + lowercases + strips, so "  Knicks  ", "knicks", "KNICKS"
    all collapse to the same slot. Mode (sql vs live) is appended at the
    callsite so the cache stays correct across STOREFRONT_SQL_ONLY flips."""
    return re.sub(r"\s+", " ", (q or "").strip().lower())


def is_tbd(name: str | None) -> bool:
    """Detect whether an event name signals a TBD date/opponent/necessity.

    TEvo doesn't expose a boolean `tbd` column on our `events` SQL table —
    only on the live API response. For SQL-only paths (e.g. /api/store/home)
    we detect it from the name string. Patterns observed in prod (verified
    against latest_event_metrics owned-future sample):

      "(Date TBD)"          — playoff games with unscheduled date
      "Date and Time TBD"   — concerts / non-sports with unscheduled time
      "(If Necessary)"      — playoff games not yet locked in

    All checks are case-insensitive.
    """
    if not name:
        return False
    up = name.upper()
    return (
        "(DATE TBD)" in up
        or "DATE AND TIME TBD" in up
        or "(IF NECESSARY)" in up
    )


def section_sort_key(s: str) -> tuple:
    """Sort key for venue sections. Letters before digits (Floor, Courtside,
    GA come before 100, 101, etc.); within each group, natural-numeric for
    digits and case-insensitive alpha for letters. Mixed strings (e.g. "100A")
    sort with the numeric group by their leading digits."""
    s = (s or "").strip()
    if not s:
        return (2, "")
    if s[0].isalpha():
        return (0, s.lower())
    # Numeric or mixed (digit-leading) — extract leading digits for natural sort.
    digits = ""
    for ch in s:
        if ch.isdigit():
            digits += ch
        else:
            break
    return (1, int(digits) if digits else 0, s.lower())


_CONSUMER_ZONE_NAME_RE = re.compile(
    r"^(Lower|Club|Upper|Floor|Field|Mezzanine|Balcony|Loge|Terrace)\s*\(\d+s\)$",
    re.IGNORECASE,
)


def is_bowl_pattern_name(name: str | None) -> bool:
    """Whether a zone name matches the programmatic bowl-level pattern."""
    return bool(_CONSUMER_ZONE_NAME_RE.match((name or "").strip()))


# ---- order / share-link projections + tour date window ----

def tour_dates(days: int):
    """Return (start_date, end_date) for a tour window, clamped to 1..730 days."""
    start = date.today()
    return start, start + timedelta(days=max(1, min(int(days), 730)))


def share_to_dict(row: dict) -> dict:
    """Public-safe representation of a share_links row."""
    if not row:
        return {}
    revoked = row.get("revoked_at")
    expires = row.get("expires_at")
    expired = False
    if expires:
        try:
            expired = datetime.fromisoformat(str(expires).replace("Z", "+00:00")) <= datetime.now(timezone.utc)
        except ValueError:
            expired = False
    return {
        "id": row.get("id"),
        "url": f"/s/{row.get('id')}",
        "event_id": row.get("event_id"),
        "filters": row.get("filters") or {},
        "note": row.get("note"),
        "created_at": row.get("created_at"),
        "expires_at": expires,
        "revoked_at": revoked,
        "view_count": row.get("view_count") or 0,
        "last_viewed_at": row.get("last_viewed_at"),
        "active": (revoked is None) and (not expired),
    }


def flatten_order_items(order: dict) -> list[dict]:
    """Project order.items[] into evo_order_items schema, mapping event_id."""
    out = []
    for it in (order.get("items") or []):
        tg = it.get("ticket_group") or {}
        ev = tg.get("event") or {}
        venue = ev.get("venue") or {}
        out.append({
            "evo_order_id":              to_int_or_none(order.get("id")),
            "evo_item_id":               to_int_or_none(it.get("id")),
            "quantity":                  to_int_or_none(it.get("quantity")),
            "price":                     to_num_or_none(it.get("price")),
            "ticket_group_id":           to_int_or_none(tg.get("id")),
            "ticket_group_remote_id":    tg.get("remote_id"),
            "ticket_group_office_id":    to_int_or_none(tg.get("office_id")),
            "ticket_group_section":      tg.get("section"),
            "ticket_group_row":          tg.get("row"),
            "ticket_group_seats":        tg.get("seats") or [],
            "ticket_group_quantity":     to_int_or_none(tg.get("quantity")),
            "ticket_group_retail_price": to_num_or_none(tg.get("retail_price")),
            "ticket_group_wholesale_price": to_num_or_none(tg.get("wholesale_price")),
            "ticket_group_external_notes": tg.get("external_notes"),
            "event_id":                  to_int_or_none(ev.get("id")),
            "event_name":                ev.get("name"),
            "occurs_at":                 parse_iso_or_none(ev.get("occurs_at")),
            "venue_id":                  to_int_or_none(venue.get("id")),
            "venue_name":                venue.get("name"),
            "eticket_available":         it.get("eticket_available"),
            "eticket_delivery":          it.get("eticket_delivery"),
            "eticket_downloaded_at":     parse_iso_or_none(it.get("eticket_downloaded_at")) or None,
            "eticket_downloaded_by":     to_int_or_none(it.get("eticket_downloaded_by")),
            "raw":                       it,
        })
    return out
