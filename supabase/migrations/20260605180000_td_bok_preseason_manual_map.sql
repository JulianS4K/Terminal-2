-- ============================================================================
-- MIG 20260605180000 — Manually map BOK Center NBA-preseason game for TD
--
-- The lone concert-venue event that had no aq_event_map row:
--   TEvo 3349508 — "NBA Preseason - New Orleans Pelicans at Oklahoma City
--   Thunder" @ BOK Center, Tulsa OK, 2026-10-06 19:00 CT.
--
-- It was absent from aq_event_map and had no venue+date match candidate, so
-- the AQ matcher could not resolve it. The marketplace event IDs were
-- obtained directly from TicketsData's /events resolver (authoritative —
-- guarantees /fetch works), both verified to BOK Center / Tulsa / Oct 6:
--   StubHub    eventId    160789750
--                (https://www.stubhub.com/oklahoma-city-thunder-tulsa-tickets-10-6-2026/event/160789750/)
--   VividSeats production 6850349
--                (https://www.vividseats.com/.../production/6850349)
--
-- Inserting an aq_event_map row keyed by tevo_event_id lets the
-- td_target_events() concert_venues CTE (direct tevo link, mig 160000) pick
-- it up automatically, so it survives the daily td_watchlist_refresh.
-- ============================================================================

BEGIN;

INSERT INTO public.aq_event_map
  (aq_short_event_id, event_name, venue_name, event_date, city, state,
   performer, category, vivid_event_id, sh_event_id, tevo_event_id,
   aq_source, imported_at)
VALUES
  ('SYS-' || left(md5('tevo:3349508'), 8),
   'NBA Preseason - New Orleans Pelicans at Oklahoma City Thunder',
   'BOK Center',
   '2026-10-06 19:00:00'::timestamp,
   'Tulsa', 'OK',
   'Oklahoma City Thunder', 'Sports',
   6850349, 160789750, 3349508,
   'manual_td_concert_seed', now())
ON CONFLICT (aq_short_event_id) DO UPDATE
  SET vivid_event_id = EXCLUDED.vivid_event_id,
      sh_event_id    = EXCLUDED.sh_event_id,
      tevo_event_id  = EXCLUDED.tevo_event_id;

-- Activate the new SH+VD xref rows immediately (also reconciles the full
-- target set; concert_venues CTE now reaches this event via tevo_event_id).
SELECT public.td_apply_targets();

-- Seed an immediate first pull (td_pull_drain fires every minute).
INSERT INTO public.td_pull_queue
  (event_id, platform, event_url, interval_tag, created_at)
SELECT x.event_id, x.platform, x.event_url, 'bok_manual_seed', now()
FROM public.ticketsdata_event_xref x
JOIN public.aq_event_map aem ON aem.aq_short_event_id = x.aq_short_event_id
WHERE aem.tevo_event_id = 3349508
  AND x.active    = true
  AND x.event_url IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.td_pull_queue q
    WHERE q.event_id   = x.event_id
      AND q.platform   = x.platform
      AND q.resolved_at IS NULL
  );

COMMIT;
