-- Migration 20260629150000 · lane:A1 (DB + ingest/cron — AXS↔SG cross-source anchor) · writes:sg_events_canonical.sg_url (AXS-linked future rows), new cron 'axs-sg-url-anchor-backfill' · reads:axs_events, aq_event_map · pre:20260629140000 · auth:operator-approved 2026-06-29 (julian@s4kent.com — "for axs map to other sources … excluding sg" → option A: SG as match-anchor only, never pulled)
--
-- WHY ------------------------------------------------------------------------
-- To map AXS events to StubHub/VividSeats (so we can pull them) the only working
-- cross-source matcher is the SeatGeek-anchored /match path: public.sg_match_map_tick()
-- (cron 'sg-match-map-tick', active, every 10 min) fires /match ONLY on events whose
-- aq_event_map.sg_event_id JOINs a sg_events_canonical row WITH sg_url IS NOT NULL,
-- then COALESCE-fills sh/vivid into aq_event_map. SG is used purely as the anchor
-- KEY/URL here — never enrolled, never pulled (RULE-2 safe: /match is a read GET).
--
-- The bottleneck: sg_url is essentially never auto-populated (only 28 of ~5,145
-- canonical rows have one), so 0 AXS candidates are matcher-ready even though 33
-- future AXS-linked canonical rows already have an sg_event_id. sg_url has a uniform
-- constructible form (every populated value = 'http://www.seatgeek.com/e/events/<id>'),
-- so the anchor is synthesizable from the sg_event_id we already hold.
--
-- WHAT -----------------------------------------------------------------------
-- (1) One-time: synthesize sg_url for future sg_events_canonical rows that are linked
--     (via aq_event_map) to an ACTIVE axs_event and currently lack a url (~33 rows).
--     These become matcher-ready immediately; sg-match-map-tick (AXS-prioritized,
--     budget-gated at <300 /match reports/mo, 10 used) fills their sh/vivid on the
--     next ticks, after which they enroll for SH/VD pulling via the established path.
-- (2) Daily cron 'axs-sg-url-anchor-backfill' (05:11, after the tevo→SG linker
--     sg_canonical_link_overnight at 04:46-59) repeats the scoped UPDATE so AXS events
--     newly linked to SG over time also become matcher-ready automatically.
--
-- SCOPE / SAFETY -------------------------------------------------------------
-- Deliberately AXS-SCOPED (sg_event_id IN active-AXS-linked set), NOT a blanket
-- sg_url backfill — so the SG matcher's working set widens only for AXS events, not
-- all of SeatGeek. sg_url is a deterministic derivable value; the matcher self-throttles
-- (1 /match per tick, 429-guarded, <300 reports/mo cap). No SG pull/order — anchor only.
-- Does NOT cover the ~124 AXS events that have NO sg_event_id at all (SeatGeek has no
-- linked canonical row for them) — those need SeatGeek DISCOVERY (performer seeding),
-- a separate effort; nor GT/TM enrollment, which is likewise gated on sg_event_id +
-- performer seeds. Idempotent (WHERE sg_url IS NULL); reversible (NULL the synthesized
-- urls / unschedule the cron).
--
-- ROLLBACK -------------------------------------------------------------------
--   SELECT cron.unschedule('axs-sg-url-anchor-backfill');
--   UPDATE public.sg_events_canonical SET sg_url=NULL
--   WHERE sg_url = 'http://www.seatgeek.com/e/events/' || sg_event_id::text;  -- if undoing the synth

-- (1) one-time backfill
UPDATE public.sg_events_canonical sgc
SET sg_url = 'http://www.seatgeek.com/e/events/' || sgc.sg_event_id::text
WHERE sgc.sg_url IS NULL
  AND sgc.sg_datetime_utc > now()
  AND sgc.sg_event_id IN (
    SELECT aem.sg_event_id
    FROM public.aq_event_map aem
    JOIN public.axs_events ax ON ax.aq_short_event_id = aem.aq_short_event_id
    WHERE ax.active = true AND aem.sg_event_id IS NOT NULL
  );

-- (2) keep AXS-linked rows anchored as the daily tevo→SG linker maps more over time
SELECT cron.schedule(
  'axs-sg-url-anchor-backfill',
  '11 5 * * *',
  $$
  UPDATE public.sg_events_canonical sgc
  SET sg_url = 'http://www.seatgeek.com/e/events/' || sgc.sg_event_id::text
  WHERE sgc.sg_url IS NULL
    AND sgc.sg_datetime_utc > now()
    AND sgc.sg_event_id IN (
      SELECT aem.sg_event_id
      FROM public.aq_event_map aem
      JOIN public.axs_events ax ON ax.aq_short_event_id = aem.aq_short_event_id
      WHERE ax.active = true AND aem.sg_event_id IS NOT NULL
    );
  $$
);
