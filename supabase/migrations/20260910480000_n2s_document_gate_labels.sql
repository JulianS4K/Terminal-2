-- ============================================================================
-- Migration 20260910480000 — document the six-gate cascade for consumers
--
-- Lane: D7 · Level: data-collection · Pre-reqs: 20260910420000, 20260910470000
--
-- Adds two manual steps (gates, zones), eight gate codes, and RETIRES N2S-C200.
--
-- ── ⚠ N2S-C200 IS RETIRED, NOT REWORDED ────────────────────────────────────
-- C200 stated that unprofitable covers are "deliberately EXCLUDED from
-- n2s_profitable_cover". Gates 2/4/6 send them, so that is now false. The
-- registry's own published promise is that a code is NEVER re-pointed at a new
-- meaning — so C200 gets retired_at set, its row kept so existing consumer
-- lookups still resolve, and N2S-G200 issued in its place. We hold ourselves to
-- the rule we published to integrators; quietly rewriting C200 would have been
-- easier and would have broken exactly the guarantee that makes codes useful.
-- ============================================================================

INSERT INTO public.n2s_integration_doc (slug, step_no, title, body) VALUES
 ('gates', 7, 'The label — read this before acting on any row',
  'Every cover carries a cover_label. It is not a quality score; it is a WORKFLOW INSTRUCTION telling you what may be done with the row. Six gates, checked in order, first match wins:

  1  Index                       exact section, same row or better, PROFITABLE
  2  S4KTrading                  exact section, same row or better, at or under 200% of sale
  3  Index offer subs            same curated ZONE, same row or better, PROFITABLE
  4  offer subs s4ktrading       same curated ZONE, same row or better, under 200%
  5  Index Down offer subs       up to 5 rows further back, PROFITABLE
  6  Down offer subs S4KTrading  up to 5 rows further back, under 200%

*** "offer subs" IN A LABEL MEANS DO NOT JUST BUY IT. *** Gates 1 and 2 keep the
buyer in the exact section they purchased, so they are actionable directly.
Gates 3-6 MOVE the buyer — a different section within the same zone, or up to
five rows further back — so the buyer must be OFFERED the substitute and accept
it before you purchase. Acting on a gate 3-6 row without asking is how you turn
a covered order into a dispute.

*** "Index" vs "S4KTrading" IS PROFIT, NOT QUALITY. *** Index rows make money on
the cover. S4KTrading rows cost more than the sale but stay within a 200%
ceiling — they are a trading decision, not an error. Nothing above 200% is ever
sent, on any gate.

*** SUFFIX "repost single" MEANS YOU ARE BUYING A SPARE SEAT. *** The lot could
not be split to the exact quantity owed, so sub_qty is one greater than the
obligation and the spare is reposted for sale separately. BUY sub_qty, not
sold_qty — see the columns step.

Filter on cover_gate (integer, stable) rather than parsing cover_label text.
The label wording may be clarified; the gate numbers will not be re-pointed.'),
 ('zones', 8, 'What "same zone" means, and when it is refused',
  'Zones are curated per (performer, venue) — in practice the home side at their
own venue — and they are scoped by SECTION *AND* ROW, not section alone. Many
zones are price tiers stacked inside one section: sections 121-124 at one venue
run Metro Gold/Plat (rows 1-6), Metro Silver (7-12), Metro Bronze (13-22),
Metro Box (23-35).

That is why a gate 3/4 match cannot hand you a cheaper tier in the same section
— a Gold seat and a Silver seat resolve to different zones and will not match.

WHERE A ZONE IS AMBIGUOUS, WE REFUSE IT RATHER THAN GUESS. If a section+row
falls into two curated zones, no zone is assigned and the cover falls through to
gates 5/6 instead. A wrong zone label would be worse than none. Roughly 8% of
lookups are refused this way, plus stadium configurations that differ by
competition, which are excluded entirely.

order_zone and sub_zone are exposed on every row so you can see what was matched.
Both NULL on a gate 1/2 row is normal — those matched by exact section and never
needed a zone.

⚠ A gate 5/6 downgrade is NOT zone-capped: moving up to five rows back can cross
a row-based price tier. That is a deliberate operator decision, which is exactly
why gates 5 and 6 say "offer subs" — the buyer decides, not the pipeline.')
ON CONFLICT (slug) DO UPDATE SET
  step_no=EXCLUDED.step_no, title=EXCLUDED.title, body=EXCLUDED.body, updated_at=now();

UPDATE public.n2s_integration_doc SET step_no = 9  WHERE slug='columns';
UPDATE public.n2s_integration_doc SET step_no = 10 WHERE slug='error-codes';
UPDATE public.n2s_integration_doc SET step_no = 11 WHERE slug='troubleshooting';
UPDATE public.n2s_integration_doc SET step_no = 12 WHERE slug='guarantees';

UPDATE public.n2s_error_code
   SET retired_at = now(),
       what_to_do = 'RETIRED 2026-09-10, superseded by N2S-G200. This code stated that unprofitable covers are excluded from the feed. That stopped being true when the gate cascade began sending them under the S4KTrading labels. The row is kept so existing lookups still resolve; stop matching on it.'
 WHERE code = 'N2S-C200' AND retired_at IS NULL;

INSERT INTO public.n2s_error_code
  (code, category, severity, title, meaning, emitted_by, what_to_do, sort_order)
VALUES
 ('N2S-G100','gate','info','Gate 1 — Index',
  'Exact section, same row or better, and the cover is profitable.',
  'n2s_cover_candidates.cover_gate = 1',
  'Directly actionable. The buyer stays in the section they purchased.',300),
 ('N2S-G200','gate','info','Gate 2 — S4KTrading',
  'Exact section, same row or better, cover costs more than the sale but stays at or under 200% of it.',
  'n2s_cover_candidates.cover_gate = 2',
  'A trading decision, not a fault. Supersedes the retired N2S-C200, which wrongly said such covers are excluded from the feed.',310),
 ('N2S-G300','gate','warn','Gate 3 — Index offer subs',
  'Different section within the same curated zone, same row or better, profitable.',
  'n2s_cover_candidates.cover_gate = 3',
  'OFFER TO THE BUYER FIRST. This moves them out of the section they purchased; do not buy before they accept.',320),
 ('N2S-G400','gate','warn','Gate 4 — offer subs s4ktrading',
  'Different section within the same curated zone, same row or better, under the 200% ceiling.',
  'n2s_cover_candidates.cover_gate = 4',
  'OFFER TO THE BUYER FIRST, and it costs more than the sale. Both a move and a trading decision.',330),
 ('N2S-G500','gate','warn','Gate 5 — Index Down offer subs',
  'Up to five rows further back than purchased, profitable.',
  'n2s_cover_candidates.cover_gate = 5',
  'OFFER TO THE BUYER FIRST — this is a downgrade in position, and it is not zone-capped, so it can cross a row-based price tier.',340),
 ('N2S-G600','gate','warn','Gate 6 — Down offer subs S4KTrading',
  'Up to five rows further back, and over the sale price but within 200%.',
  'n2s_cover_candidates.cover_gate = 6',
  'OFFER TO THE BUYER FIRST. The weakest gate: a downgrade that also costs more than the sale.',350),
 ('N2S-G700','gate','info','Suffix: repost single',
  'The chosen lot could not be split to the exact quantity owed, so sub_qty is one greater than the obligation and the spare seat is reposted separately.',
  'cover_label ending " repost single"',
  'BUY sub_qty, not sold_qty. Buying the obligation quantity will fail — that lot is only sellable in the larger size, which is why it was cheap.',360),
 ('N2S-G800','gate','info','No gate — not sent',
  'A cover exists but matched no gate: over the 200% ceiling, more than five rows back, or outside both the section and any unambiguous zone.',
  'n2s_cover_candidates (row filtered out)',
  'Expected. The obligation still stands even though no cover is offered — an over-ceiling cover is withheld deliberately, not missing by accident.',370)
ON CONFLICT (code) DO UPDATE SET
  category=EXCLUDED.category, severity=EXCLUDED.severity, title=EXCLUDED.title,
  meaning=EXCLUDED.meaning, emitted_by=EXCLUDED.emitted_by,
  what_to_do=EXCLUDED.what_to_do, sort_order=EXCLUDED.sort_order;
