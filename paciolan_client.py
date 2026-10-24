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

import csv
import io
import json
import re
from collections import Counter
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


# --- eVenue inventory CSV (the box-office export) -------------------------
# The operator's canonical Paciolan/eVenue source is the "evenue_<org>_<season>_
# <item>_<ts>.csv" inventory export (e.g. evenue_343_FB26_FB01_...csv). Unlike
# the DOM scrape above, every row is an ALREADY-GROUPED consecutive-seat block
# (row/qty/seat_first/seat_last) carrying full pricing + fees, so no
# gaps-and-islands pass is needed — the export already did it. This parser is
# the server-side normalizer that turns that (messy) CSV into the payload the
# paciolan_csv_ingest() RPC saves. It makes NO network calls (RULE 2).
#
# The export is quirky and we defend against all of it, positionally (the header
# has DUPLICATE column names — opponent/venue/event_date/event_time repeat — so
# a name→index map is unsafe; the layout is a fixed 41 columns):
#   * cols 25..40 (the block payload) are CLEAN and identically aligned in every
#     data row — this is the reliable inventory.
#   * every OTHER data row has its first 20 columns overwritten with the literal
#     header strings ('host','org_id',…); those "header-junk" rows still carry a
#     valid block in 25..40, so we keep them.
#   * org_id (col 1) and event_url (col 8) are row-index-CORRUPTED (they drift
#     343,344,… / FB01,FB02,…) — we DERIVE org_id from the event_id prefix and
#     reconstruct the canonical event_url from host/season/item instead.
#   * the stable event identity (event_id, name, opponent, venue, date, season,
#     item) is read from the "clean" rows (col 0 ends in 'evenue.net') by mode.
_CSV_N_COLS = 41
# Fixed positional indices (do NOT map by header name — names duplicate).
_C_HOST, _C_ORG, _C_DIST, _C_POLICY, _C_GROUP, _C_SEASON, _C_ITEM = 0, 1, 2, 3, 4, 5, 6
_C_EVENT_ID, _C_TYPE, _C_EVENT_NAME = 7, 9, 10
_C_TIME_TBD, _C_DT_LOCAL, _C_DT_UTC, _C_SALE_FROM, _C_SOLD_OUT = 15, 16, 17, 18, 19
_C_OPPONENT, _C_VENUE, _C_EVENT_DATE, _C_EVENT_TIME = 20, 21, 22, 24
# Block payload (reliable in every data row).
_C_ROW, _C_QTY, _C_SEAT_FIRST, _C_SEAT_LAST, _C_SEATS_RANGE = 25, 26, 27, 28, 29
_C_PRICE_LEVEL, _C_PL_DESC, _C_PRICE_TYPE, _C_PT_DESC = 30, 31, 32, 33
_C_PRICE, _C_FACILITY_FEE, _C_PER_TICKET_FEE, _C_ALL_IN = 34, 35, 36, 37
_C_SEAT_KEY_FIRST, _C_SEAT_KEY_LAST, _C_VIEW_URL = 38, 39, 40


def _num(v: str | None) -> float | None:
    """'125' / '17.5' -> float; '' / None / junk -> None."""
    if v is None:
        return None
    v = v.strip()
    if not v:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def _int(v: str | None) -> int | None:
    n = _num(v)
    return int(n) if n is not None and n == int(n) else None


def _bool(v: str | None) -> bool | None:
    """eVenue writes TRUE/FALSE; be liberal, return None when absent/unknown."""
    s = (v or "").strip().lower()
    if s in ("true", "t", "1", "yes", "y"):
        return True
    if s in ("false", "f", "0", "no", "n"):
        return False
    return None


def parse_csv_seat_key(key: str | None) -> dict[str, str | None]:
    """`100:101:10:1` -> {level:'100', section:'101', row:'10', seat:'1'}.

    The eVenue seat key is `<level>:<section>:<row>:<seat>` (the view-from image
    p_101 and pl_desc 'Corners 100' confirm 101 = section, 100 = level/deck).
    Missing trailing parts come back as None; a fully-empty key -> all None."""
    parts = (key or "").split(":")
    parts += [None] * (4 - len(parts)) if len(parts) < 4 else []
    return {"level": parts[0] or None, "section": parts[1] or None,
            "row": parts[2] or None, "seat": parts[3] or None}


def _is_clean_row(row: list[str]) -> bool:
    """A 'clean' data row starts with the real host (…evenue.net); a
    'header-junk' row starts with the literal 'host'. Both carry a valid block."""
    return bool(row) and row[_C_HOST].strip().lower().endswith("evenue.net")


def _mode(values: Iterable[str | None]) -> str | None:
    """Most-common non-empty value (defensive against stray per-row corruption)."""
    c = Counter(v.strip() for v in values if v and v.strip())
    return c.most_common(1)[0][0] if c else None


def parse_inventory_csv(text: str) -> dict[str, Any]:
    """Normalize an eVenue inventory CSV into the paciolan_csv_ingest payload.

    Returns {"event": {...}, "blocks": [ {...}, ... ]} where `event` is the
    single stable event header (identity read from clean rows by mode; org_id
    derived from the event_id prefix; event_url reconstructed canonically) and
    `blocks` is one row per already-grouped consecutive-seat block, with the
    level/section split out of the seat key. Rows without a usable block (no
    seat_key + no seats_range) are skipped. Raises ValueError on an empty file
    or a header that isn't the 41-column eVenue layout."""
    reader = csv.reader(io.StringIO(text))
    all_rows = [r for r in reader if any((c or "").strip() for c in r)]
    if not all_rows:
        raise ValueError("empty CSV")
    header = all_rows[0]
    if len(header) != _CSV_N_COLS or header[_C_HOST].strip() != "host":
        raise ValueError(
            f"unexpected eVenue layout: {len(header)} cols, "
            f"col0={header[_C_HOST]!r} (expected 41 cols, 'host')")

    data = [r for r in all_rows[1:] if len(r) == _CSV_N_COLS]
    clean = [r for r in data if _is_clean_row(r)]
    # Identity from clean rows (fall back to all data rows if none are clean).
    ident_src = clean or data

    def col(idx: int) -> str | None:
        return _mode(r[idx] for r in ident_src)

    event_id = col(_C_EVENT_ID)
    host = col(_C_HOST)
    season_cd = col(_C_SEASON)
    item_cd = col(_C_ITEM)
    # org_id / event_url are corrupted in the source — derive them.
    org_id = (event_id.split(":", 1)[0] if event_id and ":" in event_id
              else col(_C_ORG))
    event_url = (f"https://{host}/event/{season_cd}/{item_cd}"
                 if host and season_cd and item_cd else None)

    event = {
        "host": host,
        "org_id": org_id,
        "distributor_id": col(_C_DIST),
        "policy_cd": col(_C_POLICY),
        "group_code": col(_C_GROUP),
        "season_cd": season_cd,
        "item_cd": item_cd,
        "event_id": event_id,
        "event_url": event_url,
        "type": col(_C_TYPE),
        "event_name": col(_C_EVENT_NAME),
        "opponent": col(_C_OPPONENT),
        "venue": col(_C_VENUE),
        "event_date": col(_C_EVENT_DATE),
        "event_time": col(_C_EVENT_TIME),
        "time_tbd": _bool(col(_C_TIME_TBD)),
        "event_dt_local": col(_C_DT_LOCAL),
        "event_dt_utc": col(_C_DT_UTC),
        "sale_from_dt": col(_C_SALE_FROM),
        "sold_out": _bool(col(_C_SOLD_OUT)),
    }

    blocks: list[dict[str, Any]] = []
    for r in data:
        seat_key_first = (r[_C_SEAT_KEY_FIRST] or "").strip()
        seats_range = (r[_C_SEATS_RANGE] or "").strip()
        if not seat_key_first and not seats_range:
            continue  # no usable block on this row
        sk = parse_csv_seat_key(seat_key_first)
        blocks.append({
            "level": sk["level"],
            "section": sk["section"],
            "row": (r[_C_ROW] or "").strip() or sk["row"],
            "qty": _int(r[_C_QTY]),
            "seat_first": (r[_C_SEAT_FIRST] or "").strip() or None,
            "seat_last": (r[_C_SEAT_LAST] or "").strip() or None,
            "seats_range": seats_range or None,
            "price_level": (r[_C_PRICE_LEVEL] or "").strip() or None,
            "pl_desc": (r[_C_PL_DESC] or "").strip() or None,
            "price_type": (r[_C_PRICE_TYPE] or "").strip() or None,
            "pt_desc": (r[_C_PT_DESC] or "").strip() or None,
            "price_usd": _num(r[_C_PRICE]),
            "facility_fee_usd": _num(r[_C_FACILITY_FEE]),
            "per_ticket_fee_usd": _num(r[_C_PER_TICKET_FEE]),
            "all_in_price_usd": _num(r[_C_ALL_IN]),
            "seat_key_first": seat_key_first or None,
            "seat_key_last": (r[_C_SEAT_KEY_LAST] or "").strip() or None,
            "view_from_section_url": (r[_C_VIEW_URL] or "").strip() or None,
        })
    return {"event": event, "blocks": blocks}
