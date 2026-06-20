"""Substitution checker — row-level matching (pure logic).

When we double-sell or otherwise need to cover an owned ticket, we look for a
substitute from our OWN inventory. A valid sub is, in priority order:

  1. SAME section, SAME row  (a true like-for-like swap)
  2. SAME section, BETTER row (an upgrade — the customer ends up closer in)

"Better" means closer to the stage/field. By the usual venue convention a
LOWER number is better (row 19 upgrades row 20) and an EARLIER letter is better
(row A upgrades row B). This module implements ONLY the same-section row part;
finding a better SECTION is a deliberate future phase (see KANBAN / the route
docstring) and is out of scope here.

Everything in this file is pure (no DB, no network) so it is cheap to unit-test
exhaustively. The HTTP route in routers/broker.py feeds it the owned-listings
snapshot and returns the structured result verbatim.
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


def find_row_substitutions(
    section: str | None,
    row: str | None,
    qty_needed: int,
    candidates: list[dict],
    *,
    exclude_group_id=None,
    revenue_per_ticket: float | None = None,
    cost_fields: tuple[str, ...] = ("cost", "retail_price"),
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
    target = parse_row(row)
    qty_needed = max(1, int(qty_needed or 1))

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
        # Same-section only (row phase). Section normalization mirrors ingest.
        if clean_section(c.get("section")) != target_section:
            continue
        scanned += 1
        try:
            qty = int(c.get("quantity") or 0)
        except (TypeError, ValueError):
            qty = 0
        if qty < qty_needed:
            continue

        verdict = compare_rows(row, c.get("row"))
        if verdict == DOWNGRADE:
            continue

        cand_rank = parse_row(c.get("row"))
        row_delta = None
        if (verdict in (SAME, UPGRADE)
                and target.rank is not None and cand_rank.rank is not None):
            # Positive = rows of improvement (target rank minus candidate rank).
            row_delta = target.rank - cand_rank.rank

        unit_cost = _unit_cost(c)
        pnl_per_ticket = pnl_total = None
        if revenue_per_ticket is not None and unit_cost is not None:
            pnl_per_ticket = round(revenue_per_ticket - unit_cost, 2)
            pnl_total = round(pnl_per_ticket * qty_needed, 2)

        entry = {
            "match_type": verdict,
            "section": c.get("section"),
            "row": c.get("row"),
            "quantity": qty,
            "unit_cost": unit_cost,
            "row_delta": row_delta,
            "ticket_group_id": gid,
            "inv_source": c.get("inv_source"),
            "pnl_per_ticket": pnl_per_ticket,
            "pnl_total": pnl_total,
        }
        if verdict == INCOMPARABLE:
            ambiguous.append(entry)
        else:
            # over_delivery = rows better than sold (0 for same row). Unknown
            # when not rank-comparable (exact-match SAME on unknown kinds).
            over = row_delta if row_delta is not None else None
            subs.append((_row_sort_key(unit_cost, over, qty), entry))

    subs.sort(key=lambda x: x[0])
    sub_entries = [e for _, e in subs]

    return {
        "target": {
            "section": target_section,
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
