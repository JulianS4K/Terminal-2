-- Migration 20260708180000 · lane:A1 (data plane — ingest/discovery) ·
--   writes (DDL): td_discover_targets_platform_check (widen to add 'eventbrite') ·
--   writes on run: td_discover_targets (seed one Eventbrite organizer target) ·
--   reads: — ·
--   spends: nothing at apply time. td_events_discover('eventbrite', …) spends
--           TicketsData /events = 1 credit/call, budget-gated by td_budget_ok() ·
--   pre: 20260609130000 (td_discover_targets + td_events_discover[_drain])
--
-- ## APPLIED via MCP 2026-07-08 (operator-directed). Idempotent + reversible
--    (guarded DROP/ADD CONSTRAINT + INSERT ... WHERE NOT EXISTS); re-apply is a
--    no-op. This file is the codification.
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- Wire Eventbrite into the TicketsData discovery pipeline, starting with a
-- single focus organizer (https://www.eventbrite.com/o/105655500371). The
-- client-side gate was lifted 2026-07-08 (ticketsdata_client.py:
-- OPERATOR_DISABLED_PLATFORMS no longer contains 'eventbrite'); the DB side
-- needs two things before the platform-generic discovery layer can target it:
--   1. td_discover_targets.platform CHECK must accept 'eventbrite'
--   2. a seeded target row for the focus organizer.
--
-- Eventbrite organizer pages (/o/<id>) are promoter feeds, so we register the
-- URL under venue_url — mirrors the Dice.fm venue/promoter convention noted in
-- ticketsdata_client.events(). Discovery then runs through the existing
-- platform-generic td_events_discover('eventbrite', N) + td_events_discover_drain()
-- (mig 20260609130000): those iterate td_discover_targets by platform, fire
-- /events with venue_url, and stage results in td_discovered_events — so NO
-- per-platform discover/drain code is needed for the /events staging step.
-- Eventbrite /events credits charge under source code 'EV' via the drain's
-- generic ELSE branch (upper(left('eventbrite',2))).
--
-- DEFERRED (follow-up, gated on live envelope verification — do NOT guess):
--   - live /fetch inventory + a ticketsdata_normalize_listings('EB', …) branch.
--     The Eventbrite /fetch + /events JSON shapes are UNVERIFIED; the codebase
--     convention is to add a platform's fetch/normalize path only after its
--     envelope is confirmed live (see mig 20260609130000 SCOPE NOTE). The drain
--     parses the common body.items[] shape best-effort until then.
--   - scheduling recurring discover/drain crons (auto credit-spend = an operator
--     budget decision). Runbook at the foot of this file.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1) Widen the platform CHECK to admit 'eventbrite' ────────────────────────
--    Existing rows are all previously-allowed platforms, so the re-ADD validates
--    without touching data. DROP IF EXISTS keeps this re-runnable.
ALTER TABLE public.td_discover_targets
  DROP CONSTRAINT IF EXISTS td_discover_targets_platform_check;
ALTER TABLE public.td_discover_targets
  ADD CONSTRAINT td_discover_targets_platform_check
  CHECK (platform IN ('seatgeek','stubhub','vividseats',
                      'gametime','tickpick','ticketmaster','eventbrite'));

-- ── 2) Seed the focus organizer as a discovery target ────────────────────────
--    performer_url is NULL here, so UNIQUE(platform, performer_url) does NOT
--    dedupe (NULLs are distinct) — guard the insert with NOT EXISTS on venue_url.
INSERT INTO public.td_discover_targets (platform, venue_url, label, active)
SELECT 'eventbrite',
       'https://www.eventbrite.com/o/105655500371',
       'Eventbrite organizer 105655500371',
       true
WHERE NOT EXISTS (
  SELECT 1 FROM public.td_discover_targets
  WHERE platform = 'eventbrite'
    AND venue_url = 'https://www.eventbrite.com/o/105655500371'
);


-- ── Operator runbook (manual, budget-gated) ──────────────────────────────────
-- Step 0 — verify the Eventbrite /events envelope shape live BEFORE relying on
--          the drain's generic parser (it expects body.items[] {event_id,
--          buy_url, name|title, event_date_utc, venue}). One /events call = 1 credit.
--          Client gate is already lifted, so either the DB path or the MVP script
--          can make the call:
--   SELECT public.td_events_discover('eventbrite', 5);   -- fires /events for seeded targets
--   -- wait ~30s for the pg_net response, then inspect the raw envelope:
--   SELECT t.venue_url, h.status_code,
--          jsonb_pretty(COALESCE(h.content::jsonb->'body'->'items',
--                                h.content::jsonb->'items','[]'::jsonb))
--   FROM public.td_discover_targets t
--   JOIN net._http_response h ON h.id = t.pending_request_id
--   WHERE t.platform='eventbrite';
-- Step 1 — drain: parse → td_discovered_events + best-effort match to local events:
--   SELECT public.td_events_discover_drain();
--   SELECT * FROM public.v_td_unmatched_discovered_events WHERE platform='eventbrite';
-- Step 2 — once the envelope is confirmed + coverage looks right, schedule a
--          recurring pull (weekly here; tune cadence to budget). Uncomment to apply:
--   SELECT cron.schedule('td_eb_discover', '20 8 * * 1',
--     $job$ DO $b$ BEGIN PERFORM public.td_events_discover('eventbrite', 10); END $b$; $job$);
--   SELECT cron.schedule('td_eb_discover_drain', '25 8 * * 1',
--     $job$ DO $b$ BEGIN PERFORM public.td_events_discover_drain(); END $b$; $job$);
