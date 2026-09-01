"""Substitution checker — row-level matching (pure logic).

When we double-sell or otherwise need to cover an owned ticket, we look for a
substitute — from our OWN inventory (a free swap) or from a market book we can
buy into (TEvo exchange, GoTickets). A valid sub is, in priority order:

  1. SAME section, SAME row  (a true like-for-like swap)
  2. SAME section, BETTER row (an upgrade — the customer ends up closer in)

"Better" means closer to the stage/field. By the usual venue convention a
LOWER number is better (row 19 upgrades row 20) and an EARLIER letter is better
(row A upgrades row B). This module implements ONLY the same-section row part;
finding a better SECTION is a deliberate future phase (see KANBAN / the route
docstring) and is out of scope here.

Candidates may come from different sources whose section labels disagree
("311" on the TEvo exchange is "Promenade  311" on GoTickets), so section
identity goes through `section_match_key` rather than a raw string compare.

Everything in this file is pure (no DB, no network) so it is cheap to unit-test
exhaustively. The HTTP route in routers/broker.py assembles the candidate pool
and returns the structured result verbatim.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from core.helpers import clean_section

# A row label is one of a few shapes. We only ever compare two rows when they
# share a comparable KIND — comparing "A" against "12" is meaningless, so those
# land in an "ambiguous" bucket for a human rather than a false upgrade claim.
#
#   numeric : "1", "2", "20"      -> rank = the integer (lower = better)
#   alpha   : "A".."Z","AA","AB"  -> rank = spreadsheet-column index (A=1, lower = better)
#   ga      : general admission    -> flat; any GA subs any GA, never an upgrade
#   unknown : empty / mixed / weird -> only an exact string match qualifies
# Match GA / GA1 / "General Admission" / "GEN ADM" but NOT words like "GATE":
# the prefix must be followed by a space, a digit, or end-of-string.
_GA_RE = re.compile(
    r"^(GA|GEN(ERAL)?\.?\s*ADM(ISSION)?)(\s|\d|$)", re.IGNORECASE
)
_NUMERIC_RE = re.compile(r"^\d+$")
_ALPHA_RE = re.compile(r"^[A-Za-z]{1,3}$")


@dataclass(frozen=True)
class RowRank:
    """Parsed, comparable view of a raw row label.

    `rank` is a sortable number where LOWER = a better (closer-in) seat, defined
    only when `kind` is "numeric" or "alpha". `norm` is the normalized label used
    for exact-match fallback on "unknown"/"ga" kinds.

    `alpha_width` is the letter count for alpha rows (1 for "A".."Z", 2 for
    "AA".."ZZ", ...). It exists because the ordering of double-letter rows
    relative to single-letter rows is VENUE-DEPENDENT: stadiums run A..Z then
    AA (AA behind Z), while some theaters put AA/BB as premium rows IN FRONT of
    A (AA ahead of Z). So two alpha rows are only safely comparable when their
    widths match; cross-width pairs ("A" vs "AA") are deliberately incomparable.
    """
    kind: str          # "numeric" | "alpha" | "ga" | "unknown"
    rank: int | None   # lower = better; None when not rank-comparable
    raw: str | None
    norm: str          # upper/trimmed label ("" when empty)
    alpha_width: int = 0  # letter count for alpha rows; 0 otherwise


def _alpha_to_rank(letters: str) -> int:
    """Spreadsheet-column index: A=1, B=2, ... Z=26, AA=27, AB=28, ...

    This keeps a strict monotonic order for BOTH common venue conventions —
    sequential (A,B,...,Z,AA,AB) and doubled (AA,BB,CC) — since AA<AB<...<BB
    holds either way. Absolute gaps may be off for doubled venues, but only the
    ORDER matters for same/better comparison."""
    acc = 0
    for ch in letters.upper():
        acc = acc * 26 + (ord(ch) - ord("A") + 1)
    return acc


def parse_row(row: str | None) -> RowRank:
    """Parse a raw row label into a comparable RowRank. Never raises."""
    norm = (row or "").strip().upper()
    if not norm:
        return RowRank("unknown", None, row, "")
    if _GA_RE.match(norm):
        return RowRank("ga", None, row, norm)
    if _NUMERIC_RE.match(norm):
        return RowRank("numeric", int(norm), row, norm)
    if _ALPHA_RE.match(norm):
        return RowRank("alpha", _alpha_to_rank(norm), row, norm, alpha_width=len(norm))
    return RowRank("unknown", None, row, norm)


# Comparison verdicts.
SAME = "same"
UPGRADE = "upgrade"        # candidate row is BETTER (closer in) than target
DOWNGRADE = "downgrade"    # candidate row is WORSE — never a valid sub
INCOMPARABLE = "incomparable"  # kinds don't line up — needs a human
# The sold section is a bare number and the pool holds MORE THAN ONE zoned
# label carrying it ("Loge 106" + "Lower 106"): the seat may be fine, but we
# can't prove which section it is, so it needs a human rather than a claim.
SECTION_AMBIGUOUS = "section_ambiguous"


def compare_rows(target: str | None, candidate: str | None) -> str:
    """Compare a candidate row against the target row we need to cover.

    Returns SAME / UPGRADE / DOWNGRADE / INCOMPARABLE. UPGRADE means the
    candidate is a strictly better (closer-in) seat than the target.
    """
    t = parse_row(target)
    c = parse_row(candidate)

    # Rank-comparable kinds (numeric vs numeric, alpha vs alpha). Alpha rows
    # only compare within the same letter-width — the AA-vs-Z direction is
    # venue-specific (see RowRank.alpha_width), so cross-width pairs fall
    # through to INCOMPARABLE for a human to judge.
    if t.kind == c.kind and t.kind in ("numeric", "alpha"):
        if t.kind == "alpha" and t.alpha_width != c.alpha_width:
            return INCOMPARABLE
        if c.rank == t.rank:
            return SAME
        return UPGRADE if c.rank < t.rank else DOWNGRADE  # type: ignore[operator]

    # GA is flat: a GA target is only ever swapped for another GA (a lateral
    # same), never "upgraded". Treat GA-to-GA as SAME, anything else as
    # incomparable.
    if t.kind == "ga" or c.kind == "ga":
        return SAME if (t.kind == "ga" and c.kind == "ga") else INCOMPARABLE

    # Mixed/unknown kinds: only an exact normalized-label match is a safe sub.
    if t.norm and c.norm and t.norm == c.norm:
        return SAME
    return INCOMPARABLE


# A section label may carry a zone/level prefix on one source and not another:
# the TEvo exchange lists "311" where GoTickets lists "Promenade  311" and
# SeatGeek may say "Section 311". They are the same physical section, so a bare
# label and a zoned one that share a trailing seat-block token are matched.
#
# Two ZONED labels sharing a token are NOT matched, because they are routinely
# different places — "Audi Yankees Club 3" and "Center Field Sports Bar 3" are
# both real sections of one event. Only the bare-vs-zoned direction is safe.
_SECTION_TRAILING_BLOCK_RE = re.compile(r"^(?:.*?[\s\-])?(\d{1,5}[A-Za-z]?)$")


def section_parts(section: str | None) -> tuple[str | None, str | None, bool]:
    """(normalized label, trailing seat-block token, is_bare).

    "Promenade  311" -> ("PROMENADE 311", "311", False)
    "311"            -> ("311", "311", True)
    "GA"             -> ("GA", None, False)
    """
    norm = re.sub(r"\s+", " ", (section or "").strip()).upper()
    if not norm:
        return None, None, False
    norm = norm[:24]
    m = _SECTION_TRAILING_BLOCK_RE.match(norm)
    key = m.group(1) if m else None
    return norm, key, key is not None and norm == key


def section_match_key(section: str | None) -> str | None:
    """The cross-source token a label matches on: its trailing seat block, or
    the whole normalized label when there isn't one. See `section_parts` for
    why an equal key alone is not sufficient to declare a match."""
    norm, key, _ = section_parts(section)
    if norm is None:
        return None
    return key if key is not None else norm


# PROJECT_BIBLE §6b — the buy-side link format. Both ids are columns on
# `gotickets_listings_snapshots`; `section_id` IS GoTickets' own URL section id,
# so it is a lookup, never derived from the section label. The slug segment is
# cosmetic and omitted. Price-ascending so the cheapest lands at the top.
GOTICKETS_EVENT_URL = "https://pro.gotickets.com/tickets/{event_id}/"


def gotickets_buy_url(gt_event_id, section_id=None) -> str | None:
    """Link to the GoTickets page for a listing's section. None without an
    event id — a link we can't build is omitted, never guessed."""
    if gt_event_id in (None, ""):
        return None
    url = GOTICKETS_EVENT_URL.format(event_id=gt_event_id)
    qs = "?sortBy=price&sortDirection=asc"
    if section_id not in (None, ""):
        qs += f"&sections={section_id}"
    return url + qs


def splits_allow(candidate: dict, qty_needed: int) -> bool:
    """Whether a listing can actually be bought at `qty_needed`.

    `splits` is the set of purchasable lot sizes: a 4-seat listing with
    splits [2, 4] sells 2 or 4, never 3, so "quantity >= needed" alone would
    offer a sub that cannot be transacted. Absent/unparseable splits mean the
    source didn't tell us — allow, rather than silently dropping real subs.
    """
    raw = candidate.get("splits")
    if not raw:
        return True
    try:
        allowed = {int(x) for x in raw}
    except (TypeError, ValueError):
        return True
    return qty_needed in allowed


_INF = float("inf")


def _coerce_float(v) -> float | None:
    """Best-effort numeric parse for cost/price fields ($, commas tolerated)."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().replace("$", "").replace(",", "")
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def _row_sort_key(unit_cost: float | None, over_delivery: int | None,
                  qty: int) -> tuple:
    """Cost-aware ordering. A valid sub must already be same-or-better row +
    enough quantity; among those the cheapest is best, because over-delivering
    a better seat than was sold is wasted money. Tiebreak by the SMALLEST
    acceptable upgrade (closest to the row actually sold) then the smallest
    lot (don't burn a big block to cover a few seats).

    Missing cost sorts last (we can't prove it's cheap), and missing/unknown
    over-delivery sorts after known ones."""
    cost = unit_cost if unit_cost is not None else _INF
    over = over_delivery if over_delivery is not None else 10**9
    return (cost, over, qty)


def _landed(unit_cost: float | None, fee_pct: float, fee_flat: float) -> float | None:
    """Landed per-ticket cost = ask + buy-in fees. For a market buy-in the ask
    isn't what we actually pay — marketplace buyer fees (a % and/or a flat
    per-ticket charge) push it up, so P&L must be computed on the landed cost.
    Owned swaps pass fee_pct=fee_flat=0 (we already hold them — no purchase)."""
    if unit_cost is None:
        return None
    if not fee_pct and not fee_flat:
        return unit_cost
    return round(unit_cost * (1 + (fee_pct or 0) / 100.0) + (fee_flat or 0), 2)


def _landed_for(candidate: dict, unit_cost: float | None, fee_pct: float,
                fee_flat: float) -> float | None:
    """Landed cost for one candidate, honouring `fee_exempt`.

    A source may quote a price that ALREADY includes buyer fees (GoTickets
    `all_in_price` is what checkout charges). Applying the buy-in fee % to it
    would double-charge, so those candidates carry fee_exempt=True.
    """
    if candidate.get("fee_exempt"):
        return _landed(unit_cost, 0.0, 0.0)
    return _landed(unit_cost, fee_pct, fee_flat)


def find_row_substitutions(
    section: str | None,
    row: str | None,
    qty_needed: int,
    candidates: list[dict],
    *,
    exclude_group_id=None,
    revenue_per_ticket: float | None = None,
    cost_fields: tuple[str, ...] = ("cost", "retail_price"),
    fee_pct: float = 0.0,
    fee_flat: float = 0.0,
) -> dict:
    """Find same-section, same-or-better-row substitutes, ranked by COST.

    Args:
      section: the section of the ticket we need to cover.
      row: the row of the ticket we need to cover.
      qty_needed: how many seats we must replace; a candidate must have
        `quantity >= qty_needed` to qualify.
      candidates: candidate listings (our owned inventory, or a market book to
        buy into). Each dict should carry at least `section`, `row`,
        `quantity`; `tevo_ticket_group_id`/`id` is surfaced when present, and a
        unit cost is read from the first present of `cost_fields`.
      exclude_group_id: a ticket-group id to drop (e.g. the listing that got
        double-sold).
      revenue_per_ticket: what we received per seat on the sale. When given,
        each sub carries `pnl_per_ticket` / `pnl_total` (revenue − unit cost,
        projected over qty_needed) so the loss/margin of covering is explicit.
      cost_fields: ordered field names to read a unit cost from. Owned books
        carry a real cost basis (`cost`); a market buy-in uses the ask
        (`retail_price`).

    Subs are ordered cheapest-first (then smallest acceptable upgrade, then
    smallest lot). Returns:
      {
        "target": {"section","row","row_kind","quantity_needed","revenue_per_ticket"},
        "subs":   [ {match_type, section, row, quantity, unit_cost, row_delta,
                     ticket_group_id, pnl_per_ticket, pnl_total}, ... ],
        "ambiguous": [ ... same shape, match_type="incomparable" ... ],
        "counts": {"subs","ambiguous","scanned"},
        "best": <the cheapest sub or None>,
      }
    """
    target_section = clean_section(section)
    target_norm, target_key, target_bare = section_parts(section)
    target = parse_row(row)
    qty_needed = max(1, int(qty_needed or 1))

    # A bare sold section ("311") is resolvable against ONE zoned label
    # ("Promenade  311"). Two or more zoned labels carrying the same token are
    # different places we can't choose between, so those go to `ambiguous`.
    zoned_on_key = {
        norm for norm, key, bare in (section_parts(c.get("section")) for c in candidates)
        if key is not None and key == target_key and not bare
    }
    section_ambiguous = target_bare and len(zoned_on_key) > 1

    def _unit_cost(c: dict) -> float | None:
        for f in cost_fields:
            v = _coerce_float(c.get(f))
            if v is not None:
                return v
        return None

    subs: list[tuple[tuple, dict]] = []
    ambiguous: list[dict] = []
    scanned = 0

    for c in candidates:
        gid = c.get("tevo_ticket_group_id", c.get("id"))
        if exclude_group_id is not None and gid is not None and gid == exclude_group_id:
            continue
        # Same-section only (row phase). An exact label always matches; a
        # bare/zoned pair matches on its shared token (so a GoTickets
        # "Promenade  311" covers an exchange "311").
        c_norm, c_key, c_bare = section_parts(c.get("section"))
        if c_norm is None or target_norm is None:
            continue
        keyed = (target_key is not None and c_key == target_key
                 and (target_bare or c_bare))
        if c_norm != target_norm and not keyed:
            continue
        scanned += 1
        try:
            qty = int(c.get("quantity") or 0)
        except (TypeError, ValueError):
            qty = 0
        if qty < qty_needed:
            continue
        # Enough seats exist, but the lot may not be sellable at this size.
        if not splits_allow(c, qty_needed):
            continue

        verdict = compare_rows(row, c.get("row"))
        if verdict == DOWNGRADE:
            continue
        # Right token, but we can't say WHICH zoned section it is.
        if keyed and c_norm != target_norm and section_ambiguous:
            verdict = SECTION_AMBIGUOUS

        cand_rank = parse_row(c.get("row"))
        row_delta = None
        if (verdict in (SAME, UPGRADE)
                and target.rank is not None and cand_rank.rank is not None):
            # Positive = rows of improvement (target rank minus candidate rank).
            row_delta = target.rank - cand_rank.rank

        unit_cost = _unit_cost(c)
        landed_cost = _landed_for(c, unit_cost, fee_pct, fee_flat)
        pnl_per_ticket = pnl_total = None
        if revenue_per_ticket is not None and landed_cost is not None:
            pnl_per_ticket = round(revenue_per_ticket - landed_cost, 2)
            pnl_total = round(pnl_per_ticket * qty_needed, 2)

        entry = {
            "match_type": verdict,
            "section": c.get("section"),
            "row": c.get("row"),
            "quantity": qty,
            "splits": c.get("splits"),
            "unit_cost": unit_cost,
            "landed_cost": landed_cost,
            "row_delta": row_delta,
            "ticket_group_id": gid,
            "inv_source": c.get("inv_source"),
            "buy_url": c.get("buy_url"),
            "pnl_per_ticket": pnl_per_ticket,
            "pnl_total": pnl_total,
        }
        if verdict in (INCOMPARABLE, SECTION_AMBIGUOUS):
            ambiguous.append(entry)
        else:
            # over_delivery = rows better than sold (0 for same row). Unknown
            # when not rank-comparable (exact-match SAME on unknown kinds).
            over = row_delta if row_delta is not None else None
            subs.append((_row_sort_key(landed_cost, over, qty), entry))

    subs.sort(key=lambda x: x[0])
    sub_entries = [e for _, e in subs]

    return {
        "target": {
            "section": target_section,
            "section_key": target_key,
            "row": row,
            "row_kind": target.kind,
            "quantity_needed": qty_needed,
            "revenue_per_ticket": revenue_per_ticket,
        },
        "subs": sub_entries,
        "ambiguous": ambiguous,
        "counts": {
            "subs": len(sub_entries),
            "ambiguous": len(ambiguous),
            "scanned": scanned,
        },
        "best": sub_entries[0] if sub_entries else None,
    }


def _read_unit_cost(c: dict, cost_fields: tuple[str, ...]) -> float | None:
    for f in cost_fields:
        v = _coerce_float(c.get(f))
        if v is not None:
            return v
    return None


SECTION_UPGRADE = "section_upgrade"


def find_section_substitutions(
    section: str | None,
    qty_needed: int,
    candidates: list[dict],
    section_quality: dict,
    *,
    exclude_group_id=None,
    revenue_per_ticket: float | None = None,
    cost_fields: tuple[str, ...] = ("cost", "retail_price"),
    fee_pct: float = 0.0,
    fee_flat: float = 0.0,
) -> dict:
    """Find BETTER-section substitutes — the fallback when no same-section row
    sub works.

    Sections here are compared on their raw labels (unlike the row phase, which
    reconciles a bare label with a zoned one): ranking needs a quality score per
    section, and `section_quality` is keyed on the exchange's own labels. A
    zone-prefixed source (GoTickets) therefore participates in the ROW phase
    only — better than scoring it against whichever same-numbered section
    happened to land in the map first.

    A "better section" is one whose market quality score is >= the sold
    section's. `section_quality` maps a (cleaned) section label to a numeric
    quality score where HIGHER = better; the caller supplies it, typically the
    market `retail_median` per section (a pricier section is a better section).
    The row WITHIN a better section need not beat the sold row — moving up a
    section is itself the upgrade.

    Ranked cheapest-first, then by the SMALLEST section over-upgrade (closest in
    quality to what was sold, so we don't burn a premium section needlessly),
    then the smallest lot. Same-section candidates are skipped (the row phase
    owns those). Returns:
      {
        "sold_section", "sold_quality",
        "section_subs": [ {match_type:"section_upgrade", to_section,
                           section_quality, section_delta, row, quantity,
                           unit_cost, ticket_group_id, inv_source,
                           pnl_per_ticket, pnl_total}, ... ],
        "best", "counts": {"section_subs","scanned"}, "note"?
      }
    """
    sold = clean_section(section)
    qty_needed = max(1, int(qty_needed or 1))
    sold_q = _coerce_float(section_quality.get(sold))
    if sold_q is None:
        return {
            "sold_section": sold, "sold_quality": None,
            "section_subs": [], "best": None,
            "counts": {"section_subs": 0, "scanned": 0},
            "note": "no market quality signal for the sold section; cannot rank sections",
        }

    out: list[tuple[tuple, dict]] = []
    scanned = 0
    for c in candidates:
        gid = c.get("tevo_ticket_group_id", c.get("id"))
        if exclude_group_id is not None and gid is not None and gid == exclude_group_id:
            continue
        sec = clean_section(c.get("section"))
        if sec is None or sec == sold:
            continue  # same section is the row phase's job
        q = _coerce_float(section_quality.get(sec))
        if q is None or q < sold_q:
            continue  # unknown or worse section — never a section upgrade
        try:
            qty = int(c.get("quantity") or 0)
        except (TypeError, ValueError):
            qty = 0
        if qty < qty_needed:
            continue
        if not splits_allow(c, qty_needed):
            continue
        scanned += 1

        unit_cost = _read_unit_cost(c, cost_fields)
        landed_cost = _landed_for(c, unit_cost, fee_pct, fee_flat)
        pnl_per_ticket = pnl_total = None
        if revenue_per_ticket is not None and landed_cost is not None:
            pnl_per_ticket = round(revenue_per_ticket - landed_cost, 2)
            pnl_total = round(pnl_per_ticket * qty_needed, 2)
        section_delta = round(q - sold_q, 2)

        entry = {
            "match_type": SECTION_UPGRADE,
            "to_section": sec,
            "section_quality": q,
            "section_delta": section_delta,
            "row": c.get("row"),
            "quantity": qty,
            "splits": c.get("splits"),
            "unit_cost": unit_cost,
            "landed_cost": landed_cost,
            "ticket_group_id": gid,
            "inv_source": c.get("inv_source"),
            "buy_url": c.get("buy_url"),
            "pnl_per_ticket": pnl_per_ticket,
            "pnl_total": pnl_total,
        }
        cost_key = landed_cost if landed_cost is not None else _INF
        out.append(((cost_key, section_delta, qty), entry))

    out.sort(key=lambda x: x[0])
    section_subs = [e for _, e in out]
    return {
        "sold_section": sold,
        "sold_quality": sold_q,
        "section_subs": section_subs,
        "best": section_subs[0] if section_subs else None,
        "counts": {"section_subs": len(section_subs), "scanned": scanned},
    }
