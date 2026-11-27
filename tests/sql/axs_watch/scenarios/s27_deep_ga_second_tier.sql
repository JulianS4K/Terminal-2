-- The deep-GA cadence is a LADDER, not one step (mig 20261126194500).
-- Operator 2026-11-26: "change it to every 4 hours if it's over 400 tickets", as a tier on top
-- of the existing 2-hour rule rather than replacing it.
--
--   GA-only and over ga_slow_min_tickets   -> ga_slow_every   (2h)
--   GA-only and over ga_slow2_min_tickets  -> ga_slow2_every   (4h)
--   either way: greatest(days_out_band, step), so a step may only ever SLOW an event.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker';

\echo '--- A. the ladder as seeded'
SELECT ga_slow_min_tickets, ga_slow_every, ga_slow2_min_tickets, ga_slow2_every
  FROM public.axs_watch_config;

\echo '--- B. the 4-arg cadence picks the step by ticket count, at 120 days out (90-min band)'
SELECT q.tickets,
       public.axs_watch_cadence_every(now() + interval '120 days', (now() + interval '120 days')::date,
                                      true, q.tickets) AS band,
       CASE WHEN q.tickets > 400 THEN '4h step' WHEN q.tickets > 100 THEN '2h step' ELSE 'no GA step' END AS expect
  FROM (VALUES (50), (100), (101), (400), (401), (5617)) q(tickets);

\echo '--- C. NOT ga_slow at all: the ticket count is ignored and the days-out band stands'
SELECT public.axs_watch_cadence_every(now() + interval '120 days', (now() + interval '120 days')::date,
                                      false, 9999) AS band_when_not_ga_only;

\echo '--- D. A STEP ONLY EVER SLOWS. An event 1 day out has a 30-min band; 5,617 GA tickets'
\echo '---    must not hold it at 4 hours... it must take the SLOWER of the two, which is 4h.'
\echo '---    And inside the last day the days-out band is what matters for a fast-moving event:'
\echo '---    greatest() is what guarantees the GA step never speeds anything up.'
SELECT public.axs_watch_cadence_every(now() + interval '1 day', (now() + interval '1 day')::date, false, 0) AS day_out_no_ga,
       public.axs_watch_cadence_every(now() + interval '1 day', (now() + interval '1 day')::date, true, 5617) AS day_out_deep_ga,
       public.axs_watch_cadence_every(now() + interval '400 days', (now() + interval '400 days')::date, true, 5617) AS far_out_deep_ga,
       public.axs_watch_cadence_every(now() + interval '400 days', (now() + interval '400 days')::date, false, 0) AS far_out_no_ga;

\echo '--- E. the 3-arg overload still exists and still behaves as before (nothing else moved)'
SELECT public.axs_watch_cadence_every(now() + interval '120 days', (now() + interval '120 days')::date, true) AS three_arg_ga,
       public.axs_watch_cadence_every(now() + interval '120 days', (now() + interval '120 days')::date, false) AS three_arg_plain;

\echo '--- F. the ladder CHECK refuses an inverted ladder'
DO $$
BEGIN
  UPDATE public.axs_watch_config SET ga_slow2_every = interval '1 hour';
  RAISE WARNING 'an inverted ladder was ACCEPTED';
EXCEPTION WHEN check_violation THEN RAISE WARNING 'a second step faster than the first is refused'; END $$;
DO $$
BEGIN
  UPDATE public.axs_watch_config SET ga_slow2_min_tickets = 50;
  RAISE WARNING 'a lower second threshold was ACCEPTED';
EXCEPTION WHEN check_violation THEN RAISE WARNING 'a second threshold below the first is refused'; END $$;

\echo '--- G. END TO END: the settle stores the ticket count and lands the event on the 4h step'
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-ga2', now(), 2) ON CONFLICT (source) DO UPDATE SET current_run = 'run-ga2';
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, watch, last_run)
SELECT 'axs', v.id, v.nm, (now() + interval '120 days')::date, now() + interval '120 days', 'GA Field',
       'https://www.axs.com/events/'||v.id, 'pending', true, 'run-ga2'
  FROM (VALUES ('G2A','Big Rave'), ('G2B','Small Rave')) AS v(id, nm)
ON CONFLICT (source, source_event_id) DO NOTHING;
-- A 900-ticket GA-only block: over the second threshold, so it must land on the 4h step.
-- NO ADA listing here on purpose. The ADA-beside-GA case — that an accessible listing next to
-- a GA block does not make the event reserved-seating — is s20's, and s20 passes. Feeding one
-- through this harness does not exercise it: axs_watch_parse derives ada and ticket_type from
-- AXS's own field names in the raw response, and neither an "ada" key nor a "ticket_type" key
-- on this simplified listings array reaches that logic, so the row lands as neither GA nor ADA
-- and counts as reserved. A half-faithful ADA fixture here would assert nothing and could
-- encode a wrong expectation, so this scenario tests only the ladder.
SELECT (public.axs_watch_settle_one('G2A', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"G2A"},"listings":[
    {"kind":"primary","section":"General Admission","quantity":900,"status":"Available",
     "general_admission":true,
     "pricing":{"face":50,"fees_total":0,"tax":0,"all_in":50}}]}}$j$::jsonb, false, NULL, false))->>'outcome' AS big_rave;
-- a 250-ticket GA block: over the first threshold, under the second
SELECT (public.axs_watch_settle_one('G2B', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"G2B"},"listings":[
    {"kind":"primary","section":"General Admission","quantity":250,"status":"Available",
     "ticket_type":"STANDARD","general_admission":true,
     "pricing":{"face":30,"fees_total":0,"tax":0,"all_in":30}}]}}$j$::jsonb, false, NULL, false))->>'outcome' AS small_rave;
SELECT source_event_id, ga_slow, ga_tickets, poll_interval AS band, cadence_pinned
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id IN ('G2A','G2B') ORDER BY 1;
SELECT source_event_id, section, quantity, general_admission, ada, ticket_type
  FROM public.primary_poll_listing WHERE source='axs' AND source_event_id IN ('G2A','G2B')
 ORDER BY 1, ada;

\echo '--- H. and both are still pinned against the shared ladder (migs 141500 / 150000 hold)'
SELECT source_event_id,
       jsonb_array_length(public.primary_poll_due('axs', jsonb_build_array(source_event_id))) AS due_now,
       next_poll_at > now() AS not_yet_its_time
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id IN ('G2A','G2B') ORDER BY 1;
