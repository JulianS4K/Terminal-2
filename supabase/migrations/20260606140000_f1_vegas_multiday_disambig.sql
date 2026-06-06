-- Migration 20260606140000 · lane:D0 · writes: sg_events_canonical.tevo_event_id
--   (3 targeted links) · then backfill_aq_maps() to propagate to hub
--
-- ## Already applied to prod · Applied via MCP 2026-06-06 (operator-authorized)
--
-- F1 Las Vegas Grand Prix — multi-day-pass disambiguation.
-- After the venue alias landed (20260606130000), cross_source_venue_resolve()
-- resolves "F1 Las Vegas Strip Autodrome" -> TEvo venue 43437 and the matcher's
-- name-consistency gate passes, but auto_match_sg_canonical_v3 still declined:
-- each race day carries TWO TEvo events on the same date (a single-day ticket AND
-- a multi-day pass, e.g. 11/19 "Thursday" + "3 Day Pass (11/19-11/21)"), so the
-- unique-target requirement is not met. The single-day SG events are linked here
-- day-exact; the multi-day passes are TEvo-only bundle SKUs with no SG twin and
-- are intentionally left unmatched.

update public.sg_events_canonical
  set tevo_event_id = 3026271, match_method = 'manual_multiday_disambig', match_confidence = 0.95, matched_at = now()
  where sg_event_id = 17565134 and tevo_event_id is null;   -- Thursday 11/19

update public.sg_events_canonical
  set tevo_event_id = 3026272, match_method = 'manual_multiday_disambig', match_confidence = 0.95, matched_at = now()
  where sg_event_id = 17565136 and tevo_event_id is null;   -- Friday 11/20

update public.sg_events_canonical
  set tevo_event_id = 3026273, match_method = 'manual_multiday_disambig', match_confidence = 0.95, matched_at = now()
  where sg_event_id = 17565138 and tevo_event_id is null;   -- Saturday 11/21

-- select public.backfill_aq_maps();  -- propagated 3 rows to aq_event_map hub
