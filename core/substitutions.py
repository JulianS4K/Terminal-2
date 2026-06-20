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
    """
    kind: str          # "numeric" | "alpha" | "ga" | "unknown"
    rank: int | None   # lower = better; None when not rank-comparable
    raw: str | None
    norm: str          # upper/trimmed label ("" when empty)


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
        return RowRank("alpha", _alpha_to_rank(norm), row, norm)
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

    # Rank-comparable kinds (numeric vs numeric, alpha vs alpha).
    if t.kind == c.kind and t.kind in ("numeric", "alpha"):
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


def _row_sort_key(verdict: str, cand: RowRank) -> tuple:
    """Order substitutes best-first: upgrades before same-row, and within a
    bucket the closer-in (lower rank) seat first. Ranks may be None for
    exact-match SAME on unknown kinds — those sort last within their bucket."""
    bucket = 0 if verdict == UPGRADE else 1  # upgrades first
    rank = cand.rank if cand.rank is not None else 10**9
    return (bucket, rank)


def find_row_substitutions(
    section: str | None,
    row: str | None,
    qty_needed: int,
    candidates: list[dict],
    *,
    exclude_group_id=None,
) -> dict:
    """Find same-section, same-or-better-row substitutes from owned inventory.

    Args:
      section: the section of the ticket we need to cover.
      row: the row of the ticket we need to cover.
      qty_needed: how many seats we must replace; a candidate must have
        `quantity >= qty_needed` to qualify.
      candidates: owned listings. Each dict should carry at least
        `section`, `row`, `quantity`; `tevo_ticket_group_id`/`id` and
        `retail_price` are surfaced when present.
      exclude_group_id: a ticket-group id to drop from the candidate pool
        (e.g. the very listing that got double-sold).

    Returns a dict:
      {
        "target": {"section","row","row_kind","quantity_needed"},
        "subs":   [ {match_type, section, row, quantity, retail_price,
                     ticket_group_id, row_delta}, ... ],   # best-first
        "ambiguous": [ ... same shape, match_type="incomparable" ... ],
        "counts": {"subs","ambiguous","scanned"},
      }
    """
    target_section = clean_section(section)
    target = parse_row(row)
    qty_needed = max(1, int(qty_needed or 1))

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

        entry = {
            "match_type": verdict,
            "section": c.get("section"),
            "row": c.get("row"),
            "quantity": qty,
            "retail_price": c.get("retail_price"),
            "ticket_group_id": gid,
            "row_delta": row_delta,
        }
        if verdict == INCOMPARABLE:
            ambiguous.append(entry)
        else:
            subs.append((_row_sort_key(verdict, cand_rank), entry))

    subs.sort(key=lambda x: x[0])
    sub_entries = [e for _, e in subs]

    return {
        "target": {
            "section": target_section,
            "row": row,
            "row_kind": target.kind,
            "quantity_needed": qty_needed,
        },
        "subs": sub_entries,
        "ambiguous": ambiguous,
        "counts": {
            "subs": len(sub_entries),
            "ambiguous": len(ambiguous),
            "scanned": scanned,
        },
    }
