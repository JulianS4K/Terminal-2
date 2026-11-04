-- Migration 20261103200000 · level:data-collection · lane:A1 (AXS ingest + AQ hub) · writes:axs_aq_event_xref(non-pinned 20261103090000 pairings deleted, then re-paired),aq_event_map(axs_event_id: ids only that matcher wrote cleared, then re-filled) · reads:axs_events,axs_catalog,td_match_results · pre:20261103190000
--
-- ============================================================================
-- Step 2 of AXS → AQ the EVO way (venues were step 1, mig 20261103190000): re-pair the AXS events
-- that the first matcher (mig 20261103090000: AQ venue + same date + name) paired, under the EVO
-- tiers of axs_aq_tier_match().
--   * its non-pinned pairings are deleted;
--   * the AQ ids it wrote are cleared — only ids no other source knows (axs_events, the non-export
--     catalogue, the June 'axs' AQ rows, /match results); ids that were already on aq_event_map
--     stay, and tier1 re-pairs them as direct ids;
--   * axs_export_match() then re-pairs everything in this run.
-- Rollback: none needed — re-running axs_export_match() is idempotent; pinned pairings are untouched.
-- ============================================================================

-- reset the pairings the previous matcher made (and the AQ ids they wrote), then re-pair now
-- An id is cleared only when no other source knows it (the hand-entered / enrolled list, the
-- non-export catalogue, the June 'axs' AQ rows, /match results): such an id can only have been
-- written by that matcher. Ids that were already on aq_event_map stay, and tier1 re-pairs them.
UPDATE public.aq_event_map m SET axs_event_id = NULL
  FROM public.axs_aq_event_xref p
 WHERE NOT p.pinned AND p.method IN ('venue_date', 'venue_date_time')
   AND m.aq_short_event_id = p.aq_short_event_id AND m.axs_event_id = p.axs_event_id::text
   AND m.aq_source IS DISTINCT FROM 'axs'
   AND NOT EXISTS (SELECT 1 FROM public.axs_events e WHERE e.axs_event_id = m.axs_event_id)
   AND NOT EXISTS (SELECT 1 FROM public.axs_catalog c WHERE c.axs_event_id = m.axs_event_id AND c.source <> 'axs_export')
   AND NOT EXISTS (SELECT 1 FROM public.td_match_results r
                    WHERE (coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '')) ~ ('axs\.com/events/' || m.axs_event_id || '(\D|$)'));
DELETE FROM public.axs_aq_event_xref p WHERE NOT p.pinned AND p.method IN ('venue_date', 'venue_date_time');

SELECT public.axs_export_match(100000);
