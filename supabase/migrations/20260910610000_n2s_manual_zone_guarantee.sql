-- Migration 20260910610000 · level:secondary-sales · lane:D7 · writes:n2s_integration_doc · reads:none · pre:20260910600000
-- ============================================================================
-- Migration 20260910610000 — publish the section-change guarantee
--
-- Lane: D7 · Pre-reqs: 20260910600000
--
-- The label step already describes all six labels. What it does not state is
-- the guarantee BEHIND the "offer subs" gates, which is the thing a receiver
-- most wants to know before showing a substitute to a buyer: we never move
-- someone to an arbitrary cheaper section. A section change is only ever
-- generated when the sold seat resolves to a curated zone AND the substitute
-- resolves to the same one.
--
-- That is structural, not a downstream filter. `n2s_cover_candidates` builds
-- its universe from exactly two branches — `match_exact` (same normalised
-- section) and `match_zone` (`order_zone IS NOT NULL AND lz.zone =
-- oz.order_zone AND section <> section`) — so a section change with no zone
-- match is never a candidate in the first place. Worth stating publicly
-- because it is a promise we can actually keep.
--
-- ⚠ The one honest carve-out is stated too: a row downgrade WITHIN the sold
-- section (gates 5/6 reached through `match_exact`) is not zone-checked, per
-- the operator's "downgrade is not zone based for now". 436 of 5,524 zone
-- rules are row-bound PRICE TIERS, so a +5 row move inside one section can
-- cross a tier. Telling receivers this is the difference between a guarantee
-- and a half-truth — they are the ones showing the seat to the buyer.
-- ============================================================================

UPDATE public.n2s_integration_doc SET body = $doc$Every cover carries a cover_label and a cover_gate. It is not a quality score; it is a WORKFLOW INSTRUCTION telling you what may be done with the row. Six gates, checked in order, first match wins:

  1  Index                       exact section, same row or better, PROFITABLE
  2  S4KTrading                  exact section, same row or better, at or under 200% of sale
  3  Index offer subs            same curated ZONE, same row or better, PROFITABLE
  4  offer subs s4ktrading       same curated ZONE, same row or better, under 200%
  5  Index Down offer subs       up to 5 rows further back, PROFITABLE
  6  Down offer subs S4KTrading  up to 5 rows further back, under 200%

*** THIS FEED CARRIES GATES 1, 3 AND 5 ONLY. *** n2s_profitable_cover is the profitable book, and gates 2/4/6 are the arms that cost more than the sale. They are listed above because they exist in the pipeline and in the error codes, not because they will appear in your rows. If you ever read an even gate here, something is wrong — report it.

*** "offer subs" IN A LABEL MEANS DO NOT JUST BUY IT. *** Gate 1 keeps the buyer in the exact section they purchased, so it is actionable directly. Gates 3 and 5 MOVE the buyer — a different section within the same zone, or up to five rows further back — so the buyer must be OFFERED the substitute and accept it before you purchase. Acting on a gate 3 or 5 row without asking is how you turn a covered order into a dispute.

*** THE SECTION NEVER CHANGES WITHOUT A ZONE MATCH. *** This is the guarantee behind the "offer subs" gates, and it is worth knowing before you put a substitute in front of a buyer. A different sub_section is only ever produced when the sold seat resolves to a curated seating zone AND the substitute resolves to the SAME zone — so order_zone and sub_zone will both be filled in and equal on any row where the section moved. We do not move a buyer to an arbitrary cheaper section, and we do not guess: where a section+row lands in two curated zones, the zone is treated as unknown and no section change is offered at all. Sections that merely LOOK different can still be gate 1 — "623" and "Grid Iron 623" normalise to the same section, so read cover_gate rather than eyeballing the strings.

*** THE ONE EXCEPTION, STATED PLAINLY. *** A row downgrade WITHIN the section the buyer bought is not zone-checked. Some venues use row ranges as PRICE TIERS inside a single section (rows 1-6 one product, 7-12 the next), so a gate 5 row that keeps sub_section equal to sold_section can still be a tier below what was sold. The row numbers are in the payload — sold_row and sub_row — and this is exactly why gate 5 says "offer subs": show the buyer the actual seat, not the label.

*** "Index" vs "S4KTrading" IS PROFIT, NOT QUALITY. *** Index rows make money on the cover. S4KTrading rows cost more than the sale but stay within a 200% ceiling — they are a trading decision, not an error, and they do not reach this feed. Nothing above 200% is ever sent, on any gate, to any surface.

*** SUFFIX "repost single" MEANS YOU ARE BUYING A SPARE SEAT. *** The lot could not be split to the exact quantity owed, so sub_qty is one greater than the obligation and the spare is reposted for sale separately. BUY sub_qty, not sold_qty — see the columns step.

Filter on cover_gate (integer, stable) rather than parsing cover_label text. The label wording may be clarified; the gate numbers will not be re-pointed.$doc$
WHERE slug = 'gates';
