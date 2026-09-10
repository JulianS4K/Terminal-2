-- Migration 20260910650000 · level:secondary-sales · lane:D7 · writes:n2s_error_code,n2s_integration_doc · reads:none · pre:20260910640000
--
-- Already applied to prod · via MCP 2026-09-10 under operator direction.
-- ============================================================================
-- Migration 20260910650000 — " single ticket" suffix for a one-seat SALE
--
-- Lane: D7 · Pre-reqs: 20260910420000 (the cascade), 20260910620000, 20260910640000
--
-- Operator 2026-09-10: "add a single ticket suffix for when it's one seat buy
-- and add to onboarding docs and our output" — then, clarifying: "different
-- single purposes: one is over buy, other is a sale of one seat."
--
-- Two different "singles", two different purposes — do not conflate them:
--   " repost single"  is about the BUY: we over-buy a lot by one seat because
--                     it would not split, and repost the spare (20260910400000).
--   " single ticket"  is about the SALE: the obligation itself is for exactly
--                     one seat. The buyer bought a single.
-- A one-seat sale is a different obligation from a pair or a block: singles
-- are the hardest quantity to source (many listings refuse to split to one),
-- the ones most often rejected at checkout, and the ones a receiver most
-- wants to recognise before acting. sold_qty already says it, but a column a
-- label-only consumer never sees is not surfaced — the same argument that put
-- " obstructed view" on the label (20260910630000). So the fact goes on the
-- label too.
--
-- ── THE RULE ───────────────────────────────────────────────────────────────
--   quantity = 1  →  cover_label ends " single ticket"
-- `quantity` in the cascade is the SOLD quantity (i.qty on n2s_items), not
-- what we buy. The two suffixes CAN co-occur: a one-seat sale covered by a
-- listing that only sells as a pair is " single ticket repost single" — we
-- buy 2 for a sale of 1 and repost the spare. Both facts matter to the buyer
-- and both stay on the label.
--
-- ── ⚠ ONE ANCHORED EDIT, NOT A REDESIGN ────────────────────────────────────
-- The cascade body is patched in place, the way 20260910620000 added the zone
-- suffix: anchor on the exact " repost single" CASE, insert the new CASE just
-- before it so the suffix order is gate → zone → single ticket → repost
-- single. The assertion refuses a drifted body rather than half-patching it,
-- and a second
-- apply is refused too (the suffix is already present), so this is safe to
-- re-run only in the sense that it fails loudly.
--
-- Suffix vocabulary after this migration, in append order:
--   " zone unverified"  (cascade, 20260910620000)
--   " single ticket"    (cascade, this migration)
--   " repost single"    (cascade, 20260910400000)
--   " obstructed view"  (queue refresh, 20260910630000 — appended last)
-- ============================================================================

DO $do$
DECLARE d text; n text;
BEGIN
  d := pg_get_functiondef('public.n2s_cover_candidates(bigint[], interval, integer, text[])'::regprocedure);

  IF position(' single ticket' in d) > 0 THEN
    RAISE EXCEPTION 'n2s_cover_candidates already carries the " single ticket" suffix — 20260910650000 is applied; do not re-run';
  END IF;

  n := '|| CASE WHEN ded.buy_qty > ded.quantity THEN '' repost single'' ELSE '''' END';
  IF position(n in d) = 0 THEN
    RAISE EXCEPTION 'anchor (repost single suffix) not found — cascade body changed, re-derive this migration';
  END IF;
  IF (length(d) - length(replace(d, n, ''))) / length(n) <> 1 THEN
    RAISE EXCEPTION 'anchor (repost single suffix) expected exactly once, found more — re-derive this migration';
  END IF;

  d := replace(d, n,
    '|| CASE WHEN ded.quantity = 1 THEN '' single ticket'' ELSE '''' END' || E'\n' ||
    '             ' || n);

  EXECUTE d;
END $do$;

COMMENT ON FUNCTION public.n2s_cover_candidates(bigint[], interval, integer, text[]) IS
  'Ranked, LABELLED cover candidates. Six gates, first match wins: 1 Index / 2 S4KTrading (exact section) · 3 Index offer subs / 4 offer subs s4ktrading (same curated zone) · 5 Index Down offer subs / 6 Down offer subs S4KTrading (up to 5 rows back, WITHIN the same zone). Odd gates are profitable, even gates are within a 200% cost ceiling; no gate = not sent, so nothing above 200% ever ships. Suffixes, in append order: " zone unverified" (gate 5/6 at a venue with no curated zones, so the within-zone rule could not be checked) · " single ticket" (the SALE is for exactly one seat — sold_qty = 1 — the hardest quantity to source) · " repost single" (the BUY is one seat over the obligation and the spare is reposted). The two are different facts and can co-occur. The queue refresh appends " obstructed view" after these. "offer subs" in a label means the buyer is being MOVED and a human must offer it first. Zones come from n2s_zone_of(), which refuses ambiguity rather than guessing. A row downgrade is zone-capped as of 20260910620000.';

-- ---------------------------------------------------------------------------
-- Error code: the suffix, catalogued between the zone caveat and the view codes
-- ---------------------------------------------------------------------------
INSERT INTO public.n2s_error_code
  (code, category, severity, title, meaning, emitted_by, what_to_do, sort_order)
VALUES (
  'N2S-G1100', 'gate', 'info', 'Suffix: single ticket',
  $doc$A row whose label carries " single ticket". The SALE is for exactly one seat: sold_qty = 1. It can appear on any gate. It says nothing about the seat's quality; it tells you the obligation is a single, which is the hardest quantity to source (most listings refuse to split to one) and the one most often rejected at checkout. This is a different fact from " repost single", which is about the BUY (one seat over, spare reposted); a one-seat sale covered from a pair carries both.$doc$,
  'n2s_cover_candidates.cover_label LIKE ''% single ticket%''',
  $doc$Read sub_qty before buying. If the label also carries " repost single", sub_qty is 2 for a sale of 1 and the spare must be reposted; otherwise sub_qty is 1 and the listing was chosen because its splits permit a single. If a source refuses a single at checkout, the next refresh re-covers the obligation from a different listing.$doc$,
  395)
ON CONFLICT (code) DO UPDATE SET
  category = EXCLUDED.category, severity = EXCLUDED.severity,
  title = EXCLUDED.title, meaning = EXCLUDED.meaning,
  emitted_by = EXCLUDED.emitted_by, what_to_do = EXCLUDED.what_to_do,
  sort_order = EXCLUDED.sort_order;

-- ---------------------------------------------------------------------------
-- Manual: the gates step lists the suffixes; add the fourth in its place.
-- Idempotent: each rewrite is guarded on the text it replaces.
-- ---------------------------------------------------------------------------
UPDATE public.n2s_integration_doc
   SET body = replace(
         replace(body, 'Three suffixes can be appended to any of those:',
                       'Four suffixes can be appended to any of those:'),
         E'  ... repost single             sub_qty is one greater than the obligation; the spare is reposted\n',
         E'  ... single ticket             sold_qty is exactly 1 — the SALE is a single seat. Any gate can carry\n'
         || E'                                it. Different fact from repost single (the BUY); both can appear.\n'
         || E'  ... repost single             sub_qty is one greater than the obligation; the spare is reposted\n')
 WHERE slug = 'gates'
   AND body LIKE '%Three suffixes can be appended to any of those:%'
   AND body NOT LIKE '%... single ticket%';
