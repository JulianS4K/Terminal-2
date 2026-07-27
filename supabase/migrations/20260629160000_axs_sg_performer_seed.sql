-- Migration 20260629160000 · lane:A1 (DB + ingest/cron — AXS↔SG discovery seed) · writes:td_sg_performers (10 clean AXS-candidate performers) · reads:aq_performer_map, aq_event_map, axs_events · pre:20260629150000 · auth:operator-approved 2026-06-29 (julian@s4kent.com — "yes do it": close the AXS→other-source gap, excl. SG-as-pull)
--
-- WHY ------------------------------------------------------------------------
-- 124 future active AXS-OK events have NO sg_event_id, so the SG-anchored matcher
-- can't map them to StubHub/Vivid. They acquire one only once SeatGeek DISCOVERS
-- the event, which is performer-seeded: td_sg_discover/_drain (crons 416/417) iterate
-- td_sg_performers. Seeding the candidates' performers feeds the existing automated
-- chain: td_sg_discover → drain → auto_match_sg_canonical_v3/sg_attempt_event_xref_v3
-- → backfill_aq_maps (sets aq_event_map.sg_event_id) → axs-sg-url-anchor-backfill
-- (sg_url) → sg_match_map_tick fills sh/vivid → SH/VD enrollment.
--
-- SCOPE: only the 11 performers (covering 16 of the 124 events) whose AXS label
-- resolves through aq_performer_map → a CLEAN Tevo performer name; their SeatGeek URL
-- is constructible by the verified rule (20/21 existing rows): 'https://seatgeek.com/'
-- + lower-hyphenated(name) + '-tickets'. Benson Boone (84524) is already seeded →
-- omitted (would be ON CONFLICT-skipped anyway). The other 95 candidate performers
-- carry raw AXS config labels ("…- Regular", "…- Public Onsale", embedded dates) that
-- slugify to invalid SeatGeek pages — DELIBERATELY NOT seeded (bad URLs waste /events
-- discovery calls); closing those needs an AXS-performer→clean-name resolution pass
-- (separate, fuzzier follow-up). GT/TM are NOT seeded here: their URLs already arrive
-- in td_match_results from the SG /match call and just need td_match_apply wired to
-- persist them — a separate change, not a performer seed.
--
-- SAFETY ---------------------------------------------------------------------
-- ≤10 new rows, ON CONFLICT (tevo_performer_id) DO NOTHING. Cost: td_sg_discover_drain
-- charges ~1 credit/performer/drain on a 7-day per-performer cooldown ⇒ ≤10 credits/week
-- (~5,800/day, ~170,800/mo headroom). SG used only as a read/discovery anchor — never
-- pulled/enrolled (RULE-2 safe). Reversible (DELETE the seeded rows / set active=false).
--
-- ROLLBACK -------------------------------------------------------------------
--   DELETE FROM public.td_sg_performers WHERE tevo_performer_id IN
--     (433,51564,85201,30854,29759,87924,8710,80285,9938,5997) AND last_discovered_at IS NULL;

INSERT INTO public.td_sg_performers (tevo_performer_id, performer_name, performer_url, active)
VALUES
  (433,   'Air Supply',           'https://seatgeek.com/air-supply-tickets',           true),
  (51564, 'Big Thief',            'https://seatgeek.com/big-thief-tickets',            true),
  (85201, 'Grupo Frontera',       'https://seatgeek.com/grupo-frontera-tickets',       true),
  (30854, 'Kacey Musgraves',      'https://seatgeek.com/kacey-musgraves-tickets',      true),
  (29759, 'Los Tigres del Norte', 'https://seatgeek.com/los-tigres-del-norte-tickets', true),
  (87924, 'Mamamoo',              'https://seatgeek.com/mamamoo-tickets',              true),
  (8710,  'Paul Simon',           'https://seatgeek.com/paul-simon-tickets',           true),
  (80285, 'Olivia Rodrigo',       'https://seatgeek.com/olivia-rodrigo-tickets',       true),
  (9938,  'Sawyer Brown',         'https://seatgeek.com/sawyer-brown-tickets',         true),
  (5997,  'Journey',              'https://seatgeek.com/journey-tickets',              true)
ON CONFLICT (tevo_performer_id) DO NOTHING;
