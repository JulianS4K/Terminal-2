-- Migration 20260901185000 · level:data-collection · lane:A1 · writes:aq_event_map · reads:gotickets_event · pre:none
--
-- Give the AQ hub a GoTickets id, backfilled from our own matcher.
--
-- WHY. aq_event_map carries a column per source (sh/sg/vivid/tm/sd/axs) but
-- none for GoTickets, so nothing could resolve a GoTickets event through the
-- hub. That gap is what made the GoTickets listings for StubHub order
-- 644308803 unusable: two GT events pointed at one tevo event and there was no
-- hub row to arbitrate.
--
-- SOURCE. public.gotickets_event already holds gt_event_id -> tevo_event_id
-- from A1's matcher (185,587 GT events, 4,180 mapped). No new matching is
-- invented here; this projects an existing mapping onto the hub.
--
-- ⚠ TWO GUARDS, BOTH LEARNED THE HARD WAY.
--
-- 1. map_score >= 0.80. A first pass without this wrote GT 1210331 onto tevo
--    3170362. GT 1210331 is "US Open Tennis - Session 8 (Louis Armstrong ...)";
--    tevo 3170362 is Session 8 at ARTHUR ASHE — a different venue, whose event
--    is 3170363. It scored 0.536 via the instant_performer tier, which does not
--    weigh venue. Start time cannot arbitrate it either: both Session 8s begin
--    19:00 ET. All 234 sub-0.80 rows were reverted; every one came from that
--    same tier. A weak id in the hub is worse than no id — every lane resolves
--    through here.
--
-- 2. Unambiguous in gotickets_event: 73 tevo events have more than one
--    gt_event_id, and writing either would assert a match we cannot prove.
--
-- KNOWN RESIDUAL. Ambiguity is tested against gotickets_event (185k rows), not
-- gotickets_listings_snapshots, which also carries gt_event_id but is 381M rows
-- / 130 GB and cannot be scanned for distinct pairs interactively — the attempt
-- timed out repeatedly. tevo 3170362 was exactly such a case (a second
-- gt_event_id appearing only in listings) and was removed by guard 1, not
-- guard 2. Closing that properly needs an indexed or materialised
-- (tevo_event_id, gt_event_id) projection off the listings table; the smaller
-- gotickets_deals_feed shows 0 ambiguity across its 814 pairs, which is
-- consistent but far from a proof.

ALTER TABLE public.aq_event_map
  ADD COLUMN IF NOT EXISTS gotickets_event_id bigint,
  ADD COLUMN IF NOT EXISTS gotickets_map_score numeric(4,3);

COMMENT ON COLUMN public.aq_event_map.gotickets_event_id IS
  'GoTickets event id, projected from public.gotickets_event (A1 matcher). Only unambiguous mappings scoring >= 0.80 are stored.';
COMMENT ON COLUMN public.aq_event_map.gotickets_map_score IS
  'Confidence from gotickets_event.map_score. Nothing below 0.80 is stored — that tier produced a cross-venue mismatch.';

CREATE INDEX IF NOT EXISTS aq_event_map_gotickets_event_id_idx
  ON public.aq_event_map (gotickets_event_id) WHERE gotickets_event_id IS NOT NULL;

WITH unambiguous AS (
  SELECT tevo_event_id,
         min(gt_event_id) AS gt_event_id,
         max(map_score)   AS map_score
    FROM public.gotickets_event
   WHERE tevo_event_id IS NOT NULL
   GROUP BY tevo_event_id
  HAVING count(DISTINCT gt_event_id) = 1
     AND max(map_score) >= 0.80
)
UPDATE public.aq_event_map a
   SET gotickets_event_id  = u.gt_event_id,
       gotickets_map_score = u.map_score
  FROM unambiguous u
 WHERE a.tevo_event_id = u.tevo_event_id
   AND a.gotickets_event_id IS NULL;   -- fill only, never overwrite
