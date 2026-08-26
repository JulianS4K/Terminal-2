-- Migration 20260826140000 · lane:A1 (data plane — ingest/discovery) ·
--   writes (DDL): td_discover_targets_platform_check (widen: +'dice') ·
--                 td_pull_queue_platform_check        (widen: +'DI') ·
--                 ticketsdata_event_xref_platform_check (widen: +'DI') ·
--                 td_api_platform()  (add 'DI' -> 'dice' branch) ·
--   writes on run: none (no rows seeded, no crons scheduled) ·
--   reads: — ·
--   spends: nothing at apply time. Enabling the platform does not by itself
--           fire a call; td_events_discover('dice', …) / td_pull_queue rows
--           spend TicketsData credits (1/call), budget-gated by td_budget_ok() ·
--   pre: 20260609130000 (td_discover_targets + td_events_discover[_drain]),
--        20260708180000 (last widening of the discover-targets CHECK)
--
-- ## NOT YET APPLIED — author-only. Apply is an operator-directed Applier
--    action (CLAUDE.md Rule 1). Idempotent + reversible (guarded DROP/ADD
--    CONSTRAINT + CREATE OR REPLACE); re-apply is a no-op.
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- Dice (Dice.fm) is one of the nine marketplaces TicketsData serves behind
-- /fetch + /events. We parked it 2026-06-09 via the client-side gate
-- (ticketsdata_client.OPERATOR_DISABLED_PLATFORMS). Operator directive
-- 2026-08-26 re-enables it; the client gate is lifted in the same change.
--
-- The DB side has three CHECK gates + one code-mapper that still reject Dice,
-- so lifting the client gate alone would let a /fetch through and then fail on
-- insert. This migration widens all four, mirroring the Eventbrite re-enable
-- (mig 20260708180000) one-for-one:
--   1. td_discover_targets.platform         -> admit 'dice'  (API-name spelling)
--   2. td_pull_queue.platform               -> admit 'DI'    (2-letter code)
--   3. ticketsdata_event_xref.platform      -> admit 'DI'
--   4. td_api_platform('DI')                -> 'dice'
--
-- On the two spellings: td_discover_targets stores the TicketsData API's own
-- platform token ('gametime', 'eventbrite', …), while the pull/xref/snapshot
-- tables store the 2-letter source code. Dice's code is 'DI', which is exactly
-- what td_events_discover_drain()'s generic ELSE branch already derives
-- (upper(left('dice',2))) — so the drain needs no per-platform edit, same as
-- Eventbrite. Credits log under platform 'DI' in ticketsdata_credit_usage.
--
-- DEFERRED (follow-up, gated on live envelope verification — do NOT guess):
--   - a ticketsdata_normalize_listings('DI', …) branch. The Dice /fetch
--     listings envelope is UNVERIFIED. Repo convention (mig 20260609130000
--     SCOPE NOTE, restated in 20260708180000) is to add a platform's normalize
--     path only after its shape is confirmed on a live call — a guessed branch
--     silently drops or mis-maps rows. Until then a Dice /fetch stores its raw
--     envelope and normalizes to zero rows; it does NOT corrupt anything.
--   - seeding td_discover_targets rows (needs a Dice.fm venue/promoter URL from
--     the operator) and scheduling recurring discover/drain crons (auto
--     credit-spend = an operator budget decision). Runbook at the foot of file.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1) discover targets: admit the 'dice' API token ──────────────────────────
--    Existing rows are all previously-allowed platforms, so the re-ADD
--    validates without touching data. DROP IF EXISTS keeps this re-runnable.
ALTER TABLE public.td_discover_targets
  DROP CONSTRAINT IF EXISTS td_discover_targets_platform_check;
ALTER TABLE public.td_discover_targets
  ADD CONSTRAINT td_discover_targets_platform_check
  CHECK (platform IN ('seatgeek','stubhub','vividseats',
                      'gametime','tickpick','ticketmaster','eventbrite','dice'));

-- ── 2) pull queue: admit the 'DI' source code ────────────────────────────────
ALTER TABLE public.td_pull_queue
  DROP CONSTRAINT IF EXISTS td_pull_queue_platform_check;
ALTER TABLE public.td_pull_queue
  ADD CONSTRAINT td_pull_queue_platform_check
  CHECK (platform IN ('SH','VD','GT','TM','TP','SG','DI'));

-- ── 3) event xref: admit the 'DI' source code ────────────────────────────────
ALTER TABLE public.ticketsdata_event_xref
  DROP CONSTRAINT IF EXISTS ticketsdata_event_xref_platform_check;
ALTER TABLE public.ticketsdata_event_xref
  ADD CONSTRAINT ticketsdata_event_xref_platform_check
  CHECK (platform IN ('SH','VD','GT','TM','TP','SG','DI'));

-- ── 4) code -> API platform token ────────────────────────────────────────────
--    Without the explicit branch the ELSE would return lower('DI') = 'di',
--    which TicketsData rejects as an unknown platform. Body is otherwise
--    unchanged from the live definition (the SeatGeek hard-disable guard and
--    every existing WHEN are preserved verbatim).
CREATE OR REPLACE FUNCTION public.td_api_platform(p_code text)
RETURNS text
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF lower(p_code) IN ('sg', 'seatgeek') AND NOT public.td_seatgeek_allowed() THEN
    RAISE EXCEPTION 'TD-seatgeek is hard-disabled: source SeatGeek from its primary API (brokerdata.seatgeek.com). To override for an emergency, set integration_policy.td_seatgeek_emergency_override = true.';
  END IF;
  RETURN CASE p_code
    WHEN 'SH' THEN 'stubhub'
    WHEN 'VD' THEN 'vividseats'
    WHEN 'GT' THEN 'gametime'
    WHEN 'TM' THEN 'ticketmaster'
    WHEN 'TP' THEN 'tickpick'
    WHEN 'SG' THEN 'seatgeek'
    WHEN 'DI' THEN 'dice'
    ELSE LOWER(p_code)
  END;
END;
$function$;


-- ── Operator runbook (manual, budget-gated) ──────────────────────────────────
-- Step 0 — sanity: the mapper round-trips and the gates accept Dice.
--   SELECT public.td_api_platform('DI');            -- expect 'dice'
--
-- Step 1 — seed one Dice.fm venue/promoter page as a discovery target. Dice
--          venue/promoter pages are feeds, so they register under venue_url
--          (same convention as the Eventbrite organizer, mig 20260708180000):
--   INSERT INTO public.td_discover_targets (platform, venue_url, label, active)
--   SELECT 'dice', '<https://dice.fm/venue/...>', '<label>', true
--   WHERE NOT EXISTS (SELECT 1 FROM public.td_discover_targets
--                     WHERE platform='dice' AND venue_url='<https://dice.fm/venue/...>');
--
-- Step 2 — verify the /events envelope live BEFORE relying on the drain's
--          generic parser (it expects body.items[] {event_id, buy_url,
--          name|title, event_date_utc, venue}). One /events call = 1 credit:
--   SELECT public.td_events_discover('dice', 5);
--   -- wait ~30s for the pg_net response, then inspect the raw envelope:
--   SELECT t.venue_url, h.status_code,
--          jsonb_pretty(COALESCE(h.content::jsonb->'body'->'items',
--                                h.content::jsonb->'items','[]'::jsonb))
--   FROM public.td_discover_targets t
--   JOIN net._http_response h ON h.id = t.pending_request_id
--   WHERE t.platform='dice';
--
-- Step 3 — drain: parse → td_discovered_events + best-effort local match:
--   SELECT public.td_events_discover_drain();
--   SELECT * FROM public.v_td_unmatched_discovered_events WHERE platform='dice';
--
-- Step 4 — capture ONE live /fetch envelope (1 credit) and only then author the
--          ticketsdata_normalize_listings('DI', …) branch from the real shape.
--          Dice.fm accepts a bare event ID as well as a full event URL.
--
-- Step 5 — once the envelopes are confirmed + coverage looks right, schedule a
--          recurring pull (weekly here; tune cadence to budget). Uncomment:
--   SELECT cron.schedule('td_di_discover', '40 8 * * 1',
--     $job$ DO $b$ BEGIN PERFORM public.td_events_discover('dice', 10); END $b$; $job$);
--   SELECT cron.schedule('td_di_discover_drain', '45 8 * * 1',
--     $job$ DO $b$ BEGIN PERFORM public.td_events_discover_drain(); END $b$; $job$);
--
-- ROLLBACK (park Dice again) ─────────────────────────────────────────────────
--   1. re-add 'dice' to ticketsdata_client.OPERATOR_DISABLED_PLATFORMS
--   2. UPDATE public.td_discover_targets SET active=false WHERE platform='dice';
--   3. the widened CHECKs may stay (a superset is harmless); narrow them only
--      after deleting any 'dice'/'DI' rows.
