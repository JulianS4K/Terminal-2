-- ============================================================================
-- Migration 20260630250000 — Ticketmaster → MSG-only (venue 896)
--
-- Lane:     A1
-- Touches:  ticketsdata_event_xref (deactivate non-MSG TM rows; seed MSG TM rows).
-- Pre-reqs: 20260630240000 (breadth ladder; td_enqueue_peak treats TM as pass-through), aq_event_map
--           (tm_event_id), events (venue_id 896 = Madison Square Garden).
--
-- WHY (operator 2026-06-30): scope the Ticketmaster track to MSG only. Measured: all 21 active TM xref
-- rows are NON-MSG (0 at venue 896); MSG has 157 upcoming events, 22 with a tm_event_id. So restrict TM to
-- MSG by (1) deactivating every active TM row not at venue 896, and (2) seeding the 22 MSG events that
-- carry a tm_event_id (event_id = tevo_event_id per the clean TM convention; URL = ticketmaster.com/event/
-- {tm_event_id}; alphanumeric id stored in td_event_id). TM enqueue (td_enqueue_peak_tm) then polls only
-- MSG. TM discovery is OFF, so the active flag fully governs scope — no enqueue-function change needed.
--
-- Idempotent (guarded UPDATE + ON CONFLICT DO NOTHING). Re-apply is a no-op.
-- ============================================================================

-- 1. Deactivate any active TM xref that is NOT at MSG (venue 896).
UPDATE public.ticketsdata_event_xref x
   SET active = false, updated_at = now()
 WHERE x.platform = 'TM' AND x.active
   AND NOT EXISTS (
     SELECT 1 FROM public.aq_event_map a
     JOIN public.events e ON e.id = a.tevo_event_id
     WHERE a.aq_short_event_id = x.aq_short_event_id AND e.venue_id = 896);

-- 2. Seed MSG (venue 896) upcoming events that have a Ticketmaster id.
INSERT INTO public.ticketsdata_event_xref
  (event_id, platform, aq_short_event_id, event_url, td_event_id, active, match_method, meta)
SELECT DISTINCT ON (a.tevo_event_id)
       a.tevo_event_id, 'TM', a.aq_short_event_id,
       'https://www.ticketmaster.com/event/' || a.tm_event_id, a.tm_event_id, true, 'seed',
       jsonb_build_object('seed','tm_msg','seeded_at', now())
FROM public.aq_event_map a
JOIN public.events e ON e.id = a.tevo_event_id
WHERE e.venue_id = 896 AND a.tm_event_id IS NOT NULL
  AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}' AND e.occurs_at_local::timestamptz > now()
ORDER BY a.tevo_event_id
ON CONFLICT (event_id, platform) DO NOTHING;
