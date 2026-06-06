-- Migration 20260606150000 · lane:D0 · writes: sg_events_canonical.tevo_event_id
--   (1 targeted link) · then backfill_aq_maps() to propagate to hub
--
-- ## Already applied to prod · Applied via MCP 2026-06-06 (operator-authorized)
--
-- San Jose Earthquakes vs LA Galaxy (2026-07-25) — venue-mismatch same-event link.
-- The match is genuinely at Stanford Stadium (operator-confirmed + tixr). SeatGeek
-- lists it at Stanford Stadium; TEvo carries the single event mislocated at PayPal
-- Park (TEvo 3226136) -- there is NO second TEvo event at Stanford, so it is a
-- TEvo venue error, not a duplicate listing. Upstream is read-only, so we link the
-- two same-game rows directly (NOT a PayPal<->Stanford venue alias, which would
-- mis-route every other Earthquakes home game).

update public.sg_events_canonical
  set tevo_event_id = 3226136, match_method = 'manual_venue_mismatch_same_event', match_confidence = 0.90, matched_at = now()
  where sg_event_id = 17921657 and tevo_event_id is null;

-- select public.backfill_aq_maps();  -- propagated 1 row to aq_event_map hub
