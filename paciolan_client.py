"""Paciolan / eVenue seat-map normalizer (browser-extension-sourced).

Paciolan is the ticketing SaaS behind the consumer `eVenue` storefront
(`<tenant>.evenue.net/event/<price_type>/<perf>`, e.g.
`bgsufalcons.evenue.net/event/F26/F01`). Like AXS, the inventory lives behind a
live purchase flow — there is no clean public data endpoint we can pull
server-side, and this environment cannot even reach `evenue.net` (network egress
policy blocks the host and eVenue 403s non-browser clients). So collection is
**browser-extension-sourced**: the operator's real Chrome renders the seat map
and the `paciolan_extension/` content script reads the rendered DOM
(`[data-seat-key]` / `[data-level-section]`) and ships a normalized capture to
our own ingest endpoint. This module is the *server-side twin* of that
extension's JS parser — same normalized shape, kept in sync — plus the
pure-Python `group_consecutive()` that mirrors the SQL `v_paciolan_seat_groups`
gaps-and-islands view so the grouping rule is unit-testable without a DB.

RULE 2 (read-only upstream): we only ever READ the page eVenue already
rendered — never a POST/hold/order to any evenue.net / Paciolan host. This
module makes no network calls at all (the extension is the only thing that
touches a browser, and it only reads). The guard tokens below satisfy the
`scripts/check_readonly.py` static audit and `tests/test_readonly_guards.py`,
and `evenue.net` is a FORBIDDEN_HOST in that audit like every other source.
"""
from __future__ import annotations

import json
import re
from typing import Any, Iterable

# Mirrors the other *_client.py modules + scripts/check_readonly.py +
# tests/test_readonly_guards.py. This client never issues HTTP at all, but it
# declares the canonical RULE-2 guard so the new Paciolan upstream is locked
# read-only by the same mechanical audit as EVO / SeatGeek / AXS / Broadway.
ALLOWED_HTTP_METHODS = frozenset({"GET"})


class PaciolanReadOnlyError(RuntimeError):
    """Raised if anything ever attempts a non-GET against a Paciolan host."""


from core.readonly_guard import build_readonly_guard  # noqa: E402

# Canonical RULE-2 guard, single-sourced in core/readonly_guard.py (BR-CODE-2).
_assert_readonly_method = build_readonly_guard(
    PaciolanReadOnlyError, ALLOWED_HTTP_METHODS,
    "Reading eVenue's rendered seat map only — never drive the Paciolan "
    "order/hold flow.",
)

# --- seat-type classification --------------------------------------------
# The rendered map draws a crown SVG for premium/aisle seats (higher price
# tier) and a plain circle for standard seats. GA/lettered zones and the
# wheelchair (WC) level are their own types. seat_type is a *break key* in the
# consecutive-seat grouping (same as price), exactly like AXS seat_type.
STANDARD, PREMIUM, ACCESSIBLE, GA = "standard", "premium", "accessible", "ga"


def classify_seat_type(*, level: str | None, icon: str | None,
                        is_ga: bool) -> str:
    """Resolve a seat_type from the level prefix + rendered icon marker.

    icon: 'crown' (premium) | 'circle' (standard) as tagged by the extension
    from the seat element (crown <svg> vs plain <circle>)."""
    if is_ga:
        return GA
    if (level or "").upper() == "WC":
        return ACCESSIBLE
    if (icon or "").lower() == "crown":
        return PREMIUM
    return STANDARD


# --- DOM parsing (server-side twin of parse_seatmap.js) ------------------
_SEAT_KEY_RE = re.compile(r'data-seat-key="([^"]+)"')
_AVAIL_RE = re.compile(r'data-available="([^"]+)"')
_ARIA_RE = re.compile(r'aria-label="([^"]+)"')
_PRICE_RE = re.compile(r"\$([0-9]+(?:\.[0-9]{1,2})?)")
_LEVEL_SECTION_RE = re.compile(r'data-level-section="([^"]+)"')
_PERCENT_RE = re.compile(r'percent="([0-9.]+)"')


def split_level_section(token: str) -> tuple[str, str]:
    """`U:16U` -> ('U','16U'); `BN:20A` -> ('BN','20A'); `WC:WC11L` -> ('WC','WC11L').

    The level prefix (U/L/CH/BN/S/WC/PD/SC) is the map region; the remainder is
    the venue's own section label (which may itself carry a level letter, e.g.
    '16U'). We store them split, per the operator's schema choice."""
    parts = token.split(":", 1)
    if len(parts) == 2:
        return parts[0], parts[1]
    return "", token


def parse_seat_key(key: str) -> dict[str, Any] | None:
    """`U:16U:19:1` -> {level, section, row, seat}. Returns None if malformed."""
    parts = key.split(":")
    if len(parts) < 4:
        return None
    level, section, row, seat = parts[0], parts[1], parts[2], ":".join(parts[3:])
    return {"level": level, "section_label": section, "row_label": row,
            "seat_number": seat}


def _seat_no(seat_number: str | None) -> int | None:
    """Numeric seat number, or None for GA/lettered labels (stay qty-1)."""
    if seat_number and re.fullmatch(r"[0-9]+", seat_number):
        return int(seat_number)
    return None


def parse_seatmap_html(html: str) -> dict[str, list[dict[str, Any]]]:
    """Extract section summaries + available seats from rendered map markup.

    This is a resilient, order-independent attribute scan (NOT a full DOM
    parse) so it works on the exact `<path>`/`<circle>`/`<svg>` fragments the
    extension reads. It mirrors `paciolan_extension/parse_seatmap.js`."""
    sections: list[dict[str, Any]] = []
    for m in re.finditer(r"<path\b[^>]*data-level-section=[^>]*>", html):
        tag = m.group(0)
        ls = _LEVEL_SECTION_RE.search(tag)
        if not ls:
            continue
        level, section = split_level_section(ls.group(1))
        pct = _PERCENT_RE.search(tag)
        sections.append({
            "level": level,
            "section_label": section,
            "pct_available": float(pct.group(1)) if pct else None,
            "disabled": "disabled" in tag or "aria-disabled=\"true\"" in tag,
        })

    seats: list[dict[str, Any]] = []
    # Each seat element is a <circle ...data-seat-key> or <svg ...data-seat-key>.
    for m in re.finditer(r"<(circle|svg)\b[^>]*data-seat-key=[^>]*?>", html):
        tag = m.group(0)
        key_m = _SEAT_KEY_RE.search(tag)
        if not key_m:
            continue
        parsed = parse_seat_key(key_m.group(1))
        if not parsed:
            continue
        aria = _ARIA_RE.search(tag)
        aria_txt = aria.group(1) if aria else ""
        price_m = _PRICE_RE.search(aria_txt)
        avail_m = _AVAIL_RE.search(tag)
        available = (avail_m.group(1).lower() == "true") if avail_m else (
            "unavailable" not in aria_txt.lower())
        icon = "crown" if m.group(1) == "svg" else "circle"
        is_ga = "ga" in (parsed["section_label"] or "").lower() and \
            _seat_no(parsed["seat_number"]) is None
        seats.append({
            "data_seat_key": key_m.group(1),
            "level": parsed["level"],
            "section_label": parsed["section_label"],
            "row_label": parsed["row_label"],
            "seat_number": parsed["seat_number"],
            "seat_no": _seat_no(parsed["seat_number"]),
            "price": float(price_m.group(1)) if price_m else None,
            "seat_type": classify_seat_type(level=parsed["level"], icon=icon,
                                             is_ga=is_ga),
            "is_ga": is_ga,
            "available": available,
        })
    return {"sections": sections, "seats": seats}


# --- event metadata (for AQ mapping to EVO/SG/StubHub) -------------------
# The matcher (paciolan_aq_match, a mirror of axs_aq_match) needs event
# name + date + venue. eVenue event pages usually embed a schema.org Event as
# JSON-LD; we read that, then fall back to the page title. Teams are split from
# the matchup string ("Away at Home" / "Home vs Away"). Twin of
# parse_seatmap.js parseEventMeta().
_JSONLD_RE = re.compile(
    r'<script[^>]+type="application/ld\+json"[^>]*>(.*?)</script>', re.S | re.I)
_TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.S | re.I)


def split_teams(name: str | None) -> tuple[str | None, str | None]:
    """Matchup string → (home_team, away_team). '<away> at <home>' puts the
    home team second; '<home> vs <away>' puts it first. Returns (None, None)
    if no separator is found."""
    s = name or ""
    for sep, home_first in ((" at ", False), (" @ ", False),
                            (" vs. ", True), (" vs ", True), (" v ", True)):
        if sep in s:
            left, right = s.split(sep, 1)
            left, right = left.strip(), right.strip()
            return (left, right) if home_first else (right, left)
    return None, None


def parse_event_meta(html: str) -> dict[str, Any]:
    """Extract {event_name, occurs_at, venue_name, home_team, away_team} from a
    rendered eVenue event page (schema.org Event JSON-LD, then <title>)."""
    meta: dict[str, Any] = {"event_name": None, "occurs_at": None,
                            "venue_name": None, "home_team": None,
                            "away_team": None}
    for m in _JSONLD_RE.finditer(html):
        try:
            data = json.loads(m.group(1))
        except (ValueError, TypeError):
            continue
        for it in (data if isinstance(data, list) else [data]):
            if not isinstance(it, dict):
                continue
            if not (it.get("@type") in ("Event", "SportsEvent")
                    or "startDate" in it):
                continue
            meta["event_name"] = meta["event_name"] or it.get("name")
            meta["occurs_at"] = meta["occurs_at"] or it.get("startDate")
            loc = it.get("location")
            if isinstance(loc, dict):
                meta["venue_name"] = meta["venue_name"] or loc.get("name")
            for key, dst in (("homeTeam", "home_team"), ("awayTeam", "away_team")):
                v = it.get(key)
                if isinstance(v, dict):
                    meta[dst] = meta[dst] or v.get("name")
                elif isinstance(v, str):
                    meta[dst] = meta[dst] or v
    if not meta["event_name"]:
        t = _TITLE_RE.search(html)
        if t:
            meta["event_name"] = t.group(1).strip() or None
    if meta["event_name"] and not (meta["home_team"] and meta["away_team"]):
        home, away = split_teams(meta["event_name"])
        meta["home_team"] = meta["home_team"] or home
        meta["away_team"] = meta["away_team"] or away
    return meta


# --- consecutive-seat grouping (twin of v_paciolan_seat_groups) ----------
def group_consecutive(seats: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Collapse AVAILABLE seats into "N together" blocks via gaps-and-islands.

    DATA RULE (mirrors v_paciolan_seat_groups / v_axs_seat_groups): seats that
    are CONSECUTIVE within the same section+row at the same price + seat_type
    are one sellable block. A sold/missing seat number breaks the run into a
    new block — **the missing seat is the qty break**. A price or seat_type
    change also breaks the block. Non-numeric (GA/lettered) seats can't be
    range-grouped, so each stays its own qty-1 block.

    Key: (level, section_label, row_label, seat_type, price). Returns rows with
    quantity, seat_from, seat_to, seat_numbers — the marketplace listing shape.
    """
    avail = [s for s in seats if s.get("available")]
    # Stable sort so gaps-and-islands sees seats in ascending order per key.
    avail.sort(key=lambda s: (
        s.get("level") or "", s.get("section_label") or "",
        s.get("row_label") or "", s.get("seat_type") or "",
        s.get("price") if s.get("price") is not None else -1.0,
        s.get("seat_no") if s.get("seat_no") is not None else 1 << 30,
        s.get("seat_number") or "",
    ))
    blocks: list[dict[str, Any]] = []
    cur: dict[str, Any] | None = None
    prev_seat_no: int | None = None
    for s in avail:
        key = (s.get("level"), s.get("section_label"), s.get("row_label"),
               s.get("seat_type"), s.get("price"))
        seat_no = s.get("seat_no")
        # A GA/lettered seat (seat_no is None) is always its own qty-1 block.
        contiguous = (
            cur is not None
            and cur["_key"] == key
            and seat_no is not None
            and prev_seat_no is not None
            and seat_no == prev_seat_no + 1
        )
        if not contiguous:
            cur = {
                "_key": key,
                "level": s.get("level"),
                "section_label": s.get("section_label"),
                "row_label": s.get("row_label"),
                "seat_type": s.get("seat_type"),
                "price": s.get("price"),
                "is_ga": bool(s.get("is_ga")),
                "quantity": 0,
                "seat_from": seat_no,
                "seat_to": seat_no,
                "seat_numbers": [],
            }
            blocks.append(cur)
        cur["quantity"] += 1
        cur["seat_numbers"].append(s.get("seat_number"))
        # seat_from is set at block creation (the first, hence smallest, seat in
        # the sorted run); only seat_to advances as the contiguous run extends.
        if seat_no is not None:
            cur["seat_to"] = seat_no
        cur["is_ga"] = cur["is_ga"] or bool(s.get("is_ga"))
        prev_seat_no = seat_no
    for b in blocks:
        b.pop("_key", None)
        b["seat_numbers"] = ",".join(x for x in b["seat_numbers"] if x)
    return blocks
