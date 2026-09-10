-- Migration 20260910620000 · level:secondary-sales · lane:D7 · writes:n2s_error_code,n2s_integration_doc · reads:none · pre:20260910610000
-- ============================================================================
-- Migration 20260910620000 — a row downgrade must stay WITHIN the zone
--
-- Lane: D7 · Pre-reqs: 20260910420000 (the cascade), 20260910610000
--
-- Operator 2026-09-10, reversing the earlier "downgrade is not zone based for
-- now": row downgrade within zone, same profit/cap split as every other gate.
--
-- 20260910420000 shipped gates 5/6 with NO zone check and recorded the hazard
-- it accepted: 436 of 5,524 zone rules are row-bound PRICE TIERS, not
-- geography (sections 121-124 run Metro Gold rows 1-6, Silver 7-12, Bronze
-- 13-22), so a +5 row move inside one section can cross a tier — a product
-- downgrade wearing a row number. That header named the fix as "one predicate
-- on gates 5/6". This is that predicate.
--
-- ── THE RULE ───────────────────────────────────────────────────────────────
--   zone_ok := sub_zone IS NOT DISTINCT FROM order_zone
-- Read as three cases, because the NULLs carry meaning:
--   both zones named and EQUAL  → verified in-zone            → ships, gate 5/6
--   both zones NULL             → venue has no curated zones, so there is no
--                                 tier to cross               → ships, SUFFIXED
--   zones differ, or one NULL   → we know the sold seat sits in a priced tier
--                                 and cannot show the sub does → NOT SENT
-- The asymmetric case is refused deliberately. A NULL sub_zone against a named
-- order_zone means the substitute's row falls outside every curated range for
-- that section — precisely the unknown a tier check exists to catch.
--
-- ── ⚠ THE ZONE BRANCH WAS ALREADY SAFE; ONLY match_exact WAS NOT ───────────
-- `match_zone` joins on `lz.zone = oz.order_zone`, and n2s_zone_of() is scoped
-- on section AND row, so a zone-branch downgrade that crossed a tier already
-- resolved to a different zone name and fell out. The hole was entirely in
-- `match_exact`: same section, worse row, no zone comparison anywhere. That is
-- why this is one predicate and not a redesign.
--
-- ── ⚠ WHY A SUFFIX AND NOT A SEVENTH GATE ──────────────────────────────────
-- "both zones NULL" is not a worse cover, it is an unverifiable claim. Giving
-- it its own gate number would sort it below a real gate 6 in every consumer
-- that orders by cover_gate, which is wrong — a same-section 2-row drop at an
-- unzoned venue is not worse than a tier-verified 5-row drop. A suffix leaves
-- the ordering alone and still stops the label claiming a guarantee we did not
-- check. New code N2S-G1000.
--
-- ── ⚠ GATES 5/6 NARROW; THEY ARE NOT RE-POINTED ────────────────────────────
-- N2S-G500/G600 keep their labels and their numbers. Their meaning tightens
-- (a strict subset of what they used to admit), which is a narrowing, not a
-- new meaning, so the codes stay live and their `meaning` text is corrected.
-- Anything that no longer qualifies gets NO gate and is simply not sent —
-- N2S-G800 already covers that.
--
-- NOT APPLIED AT AUTHORING TIME: the Supabase MCP token expired this session,
-- so the coverage impact is UNMEASURED. The last measurement, taken while
-- authoring 20260910420000, was 0 of 49 live obligations crossing a named zone
-- at +5 — i.e. expected to drop nothing — but that is a stale snapshot and the
-- query in the PR must be run before this is applied.
-- ============================================================================

DO $do$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.n2s_cover_candidates(bigint[], interval, integer, text[])'::regprocedure);

  -- 1. define zone_ok alongside row_ok / profitable / within_cap
  n := 'AS within_cap' || E'\n' || '      FROM mm';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 1 (within_cap/FROM mm) not found — cascade body changed, re-derive this migration';
  END IF;
  d := replace(d, n,
    'AS within_cap,' || E'\n' ||
    '           -- NOT DISTINCT FROM, so both-NULL (no curated zones at this' || E'\n' ||
    '           -- venue) passes while a named zone vs NULL is refused.' || E'\n' ||
    '           mm.sub_zone IS NOT DISTINCT FROM mm.order_zone           AS zone_ok' || E'\n' ||
    '      FROM mm');

  -- 2. gates 5/6 require it
  n := 'WHEN NOT row_ok AND profitable THEN 5';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 2 (gate 5) not found — cascade body changed, re-derive this migration';
  END IF;
  d := replace(d, n, 'WHEN NOT row_ok AND zone_ok AND profitable THEN 5');

  n := 'WHEN NOT row_ok AND within_cap THEN 6';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 3 (gate 6) not found — cascade body changed, re-derive this migration';
  END IF;
  d := replace(d, n, 'WHEN NOT row_ok AND zone_ok AND within_cap THEN 6');

  -- 3. the suffix, ahead of " repost single" so the zone qualifier sits with
  --    the gate it qualifies rather than after the quantity note
  n := '|| CASE WHEN ded.buy_qty > ded.quantity THEN '' repost single'' ELSE '''' END';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor 4 (repost single suffix) not found — cascade body changed, re-derive this migration';
  END IF;
  d := replace(d, n,
    '|| CASE WHEN ded.cover_gate >= 5 AND ded.order_zone IS NULL' || E'\n' ||
    '                     THEN '' zone unverified'' ELSE '''' END' || E'\n' ||
    '             ' || n);

  EXECUTE d;
END $do$;

COMMENT ON FUNCTION public.n2s_cover_candidates(bigint[], interval, integer, text[]) IS
  'Ranked, LABELLED cover candidates. Six gates, first match wins: 1 Index / 2 S4KTrading (exact section) · 3 Index offer subs / 4 offer subs s4ktrading (same curated zone) · 5 Index Down offer subs / 6 Down offer subs S4KTrading (up to 5 rows back, WITHIN the same zone). Odd gates are profitable, even gates are within a 200% cost ceiling; no gate = not sent, so nothing above 200% ever ships. Suffix " repost single" marks a qty+1 buy; suffix " zone unverified" marks a downgrade at a venue with no curated zones, where the within-zone rule could not be checked. "offer subs" in a label means the buyer is being MOVED and a human must offer it first. Zones come from n2s_zone_of(), which refuses ambiguity rather than guessing. A row downgrade is zone-capped as of 20260910620000 (operator reversal of "downgrade is not zone based") — a +5 move that crosses a row-based price tier now gets no gate.';

-- ---------------------------------------------------------------------------
-- Error codes: narrow 500/600, add the suffix code
-- ---------------------------------------------------------------------------
UPDATE public.n2s_error_code
   SET meaning = $doc$The substitute is up to 5 rows further back than the seat sold, stays WITHIN the same curated zone as the sold seat, and the cover is profitable. The buyer is being moved, so it must be offered and accepted before purchase.$doc$,
       what_to_do = $doc$Offer the substitute to the buyer. The zone is the same, so the price tier they bought is preserved — the change is the row. Purchase only after they accept.$doc$
 WHERE code = 'N2S-G500';

UPDATE public.n2s_error_code
   SET meaning = $doc$The substitute is up to 5 rows further back, stays WITHIN the same curated zone, and costs more than the sale but no more than 200% of it. A trading decision, not an error.$doc$,
       what_to_do = $doc$Offer the substitute to the buyer as with N2S-G500. The cover loses money by design; the 200% ceiling is the limit. Purchase only after they accept.$doc$
 WHERE code = 'N2S-G600';

INSERT INTO public.n2s_error_code
  (code, category, severity, title, meaning, emitted_by, what_to_do, sort_order)
VALUES (
  'N2S-G1000', 'gate', 'warn', 'Suffix: zone unverified',
  $doc$A gate 5 or 6 row whose label ends " zone unverified". The venue has no curated seating zones for this section and row, so neither the sold seat nor the substitute resolves to a named zone. The within-zone rule that gates 5 and 6 otherwise guarantee could not be checked here — there was nothing to check it against. It does NOT mean a tier was crossed; a downgrade we can see crossing a zone is refused outright and never reaches you.$doc$,
  'n2s_cover_candidates.cover_label LIKE ''% zone unverified''',
  $doc$Treat it as a gate 5/6 row that has lost one guarantee. Read sold_row against sub_row and judge the drop on its own merits before offering it, rather than relying on the zone rule. If this venue matters to you, ask for its zones to be curated and the suffix disappears on its own.$doc$,
  390)
ON CONFLICT (code) DO UPDATE SET
  category = EXCLUDED.category, severity = EXCLUDED.severity,
  title = EXCLUDED.title, meaning = EXCLUDED.meaning,
  emitted_by = EXCLUDED.emitted_by, what_to_do = EXCLUDED.what_to_do,
  sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------------
-- Manual: the label step, superseding 20260910610000's body. That migration
-- published the tier-crossing hole as a stated exception; this one closes the
-- hole, so the exception paragraph is replaced by the suffix that now marks
-- the only remaining unverified case.
-- ---------------------------------------------------------------------------
UPDATE public.n2s_integration_doc SET body = $doc$Every cover carries a cover_label and a cover_gate. It is not a quality score; it is a WORKFLOW INSTRUCTION telling you what may be done with the row. Six gates, checked in order, first match wins:

  1  Index                       exact section, same row or better, PROFITABLE
  2  S4KTrading                  exact section, same row or better, at or under 200% of sale
  3  Index offer subs            same curated ZONE, same row or better, PROFITABLE
  4  offer subs s4ktrading       same curated ZONE, same row or better, under 200%
  5  Index Down offer subs       up to 5 rows back, SAME ZONE, PROFITABLE
  6  Down offer subs S4KTrading  up to 5 rows back, SAME ZONE, under 200%

Two suffixes can be appended to any of those:

  ... repost single             sub_qty is one greater than the obligation; the spare is reposted
  ... zone unverified           gate 5/6 only — this venue has no curated zones, so the same-zone
                                rule could not be checked. It does NOT mean a zone was crossed.

*** THIS FEED CARRIES GATES 1, 3 AND 5 ONLY. *** n2s_profitable_cover is the profitable book, and gates 2/4/6 are the arms that cost more than the sale. They are listed above because they exist in the pipeline and in the error codes, not because they will appear in your rows. If you ever read an even gate here, something is wrong — report it.

*** "offer subs" IN A LABEL MEANS DO NOT JUST BUY IT. *** Gate 1 keeps the buyer in the exact section they purchased, so it is actionable directly. Gates 3 and 5 MOVE the buyer — a different section within the same zone, or up to five rows further back — so the buyer must be OFFERED the substitute and accept it before you purchase. Acting on a gate 3 or 5 row without asking is how you turn a covered order into a dispute.

*** THE SECTION NEVER CHANGES WITHOUT A ZONE MATCH. *** A different sub_section is only ever produced when the sold seat resolves to a curated seating zone AND the substitute resolves to the SAME zone — so order_zone and sub_zone will both be filled in and equal on any row where the section moved. We do not move a buyer to an arbitrary cheaper section, and we do not guess: where a section+row lands in two curated zones, the zone is treated as unknown and no section change is offered. Sections that merely LOOK different can still be gate 1 — "623" and "Grid Iron 623" normalise to the same section, so read cover_gate rather than eyeballing the strings.

*** NEITHER DOES THE ROW, AS OF 2026-09-10. *** A downgrade is now held to the same rule. Some venues price by row range inside one section — rows 1-6 one product, 7-12 the next — so a five-row move can be a tier downgrade wearing a row number. Gates 5 and 6 therefore require the substitute to resolve to the SAME zone as the sold seat. A downgrade we can see crossing a zone gets no gate at all and never reaches you. Where neither seat resolves to a zone, because the venue has none curated, the row still ships and the label says " zone unverified" — the rule could not be checked, and we would rather tell you that than let the plain label imply a guarantee. Where the sold seat IS in a named zone and the substitute is not, the row is refused: that is exactly the unknown the rule exists to catch.

*** "Index" vs "S4KTrading" IS PROFIT, NOT QUALITY. *** Index rows make money on the cover. S4KTrading rows cost more than the sale but stay within a 200% ceiling — they are a trading decision, not an error, and they do not reach this feed. Nothing above 200% is ever sent, on any gate, to any surface. The profit rule does not change with the downgrade: gate 5 is the profitable arm and gate 6 the at-or-under-200% arm, exactly as gates 1/2 and 3/4 split.

*** SUFFIX "repost single" MEANS YOU ARE BUYING A SPARE SEAT. *** The lot could not be split to the exact quantity owed, so sub_qty is one greater than the obligation and the spare is reposted for sale separately. BUY sub_qty, not sold_qty — see the columns step.

Filter on cover_gate (integer, stable) rather than parsing cover_label text. The label wording may be clarified; the gate numbers will not be re-pointed. If you match on suffixes, match with a suffix test (LIKE '% zone unverified') rather than equality on the whole label, since two suffixes can appear together.$doc$
WHERE slug = 'gates';
