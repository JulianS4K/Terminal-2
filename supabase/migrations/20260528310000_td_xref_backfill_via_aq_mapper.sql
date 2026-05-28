-- 20260528310000_td_xref_backfill_via_aq_mapper.sql
--
-- Backfill ticketsdata_event_xref for unmapped TD events using the existing
-- aq_event_map direct-ID columns (tier1 of match_to_aq_event_id logic):
--
--   SH  → aq_event_map.sh_event_id     = ticketsdata_listings_snapshots.event_id
--   VD  → aq_event_map.vivid_event_id  = ticketsdata_listings_snapshots.event_id
--   GT  → aq_event_map.sg_event_id     = ticketsdata_listings_snapshots.event_id
--         (GT uses SG-compatible event IDs in the listings feed)
--
-- Dry-run confirmed 27 new xref rows (SH=13, VD=12, GT=2) covering the
-- highest-traffic unmapped events (BTS@Allegiant, OKC/Spurs, WNBA games,
-- Don Toliver@Prudential, Los Fabulosos Cadillacs, etc.)
--
-- One event (Hell's Kitchen at Pantages, SH 157509976) resolves an
-- aq_short_event_id but has no tevo_event_id in sg_events_canonical —
-- it's a theatre/Broadway run not in the TEvo catalogue. Inserted with
-- active=true so it stops appearing as "unmapped"; the snapshot JOIN on
-- event_metrics won't find it, which is correct.
--
-- match_method = 'aq_event_map_tier1' to distinguish from 'events_api'
-- entries added by the TD collection pipeline.

INSERT INTO public.ticketsdata_event_xref
  (event_id, platform, aq_short_event_id, match_method, active, created_at, updated_at)

SELECT DISTINCT ON (u.event_id, u.platform)
  u.event_id,
  u.platform,
  aem.aq_short_event_id,
  'aq_event_map_tier1',
  true,
  now(),
  now()
FROM (
  -- All distinct TD event_id+platform combos that have no active xref entry
  SELECT DISTINCT tds.event_id, tds.platform
  FROM public.ticketsdata_listings_snapshots tds
  WHERE NOT EXISTS (
    SELECT 1 FROM public.ticketsdata_event_xref tdx
    WHERE tdx.event_id = tds.event_id AND tdx.active = true
  )
) u
JOIN public.aq_event_map aem ON (
    (u.platform = 'SH' AND aem.sh_event_id     = u.event_id)
 OR (u.platform = 'VD' AND aem.vivid_event_id  = u.event_id)
 OR (u.platform = 'GT' AND aem.sg_event_id     = u.event_id)
)

ON CONFLICT (event_id, platform) DO UPDATE SET
  aq_short_event_id = EXCLUDED.aq_short_event_id,
  match_method      = EXCLUDED.match_method,
  active            = true,
  updated_at        = now();

-- Log result
DO $$
DECLARE v_n int;
BEGIN
  SELECT COUNT(*) INTO v_n
  FROM public.ticketsdata_event_xref
  WHERE match_method = 'aq_event_map_tier1';

  PERFORM public.bot_chat_log(
    'data-collection', 'D0', 'status',
    format('mig 310000: backfilled %s TD xref rows via aq_event_map tier1 (SH sh_event_id, VD vivid_event_id, GT sg_event_id)', v_n)
  );
END $$;
