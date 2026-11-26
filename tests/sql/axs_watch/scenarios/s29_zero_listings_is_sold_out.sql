-- A read that finds no listings is treated as sold out (mig 20261126214500).
--
-- AXS says "nothing to sell" two ways: exit_code 1 with "No tickets are currently available"
-- (outcome 'unparsed', handled since 20261126070000) and exit_code 0 with a proper event and
-- an EMPTY listings array (outcome 'empty', handled here). They mean the same thing, so they
-- now take the same band, the same pin, and the same retire rule.
--
-- Z3 and Z4 are regression guards: the branch head gained a parenthesis, and the CASE gained
-- a test that runs BEFORE the regex — v_error is NULL on an empty read, so the regex alone
-- would be NULL and fall through to the 6-hour rule.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker';

\echo '--- A. the knobs'
SELECT no_tickets_every, not_on_sale_every, no_tickets_retire_days FROM public.axs_watch_config;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-zero', now(), 4)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-zero', finished_at = now();

-- Z1/Z3/Z4 are 90 days out; Z2 is 3 days out, inside no_tickets_retire_days.
-- Priced and sized so the shared ladder wants 30 minutes, as in s23.
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_attempt_at, next_poll_at, poll_interval, median_price, listed_quantity,
        watch, last_run)
SELECT 'axs', v.id, v.nm, (now() + v.out)::date, now() + v.out, 'Zero Arena',
       'https://www.axs.com/events/'||v.id, 'ok', now() - interval '40 minutes',
       now() + interval '20 minutes', interval '1 hour', 400, 6000, true, 'run-zero'
  FROM (VALUES ('Z1','Empty Far Out',    interval '90 days'),
               ('Z2','Empty Next Week',  interval '3 days'),
               ('Z3','Says No Tickets',  interval '90 days'),
               ('Z4','Says Not On Sale', interval '90 days')) AS v(id, nm, out)
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- B. before any read: the proximity band, unpinned, and the ladder overtakes them'
SELECT source_event_id, poll_interval AS band, cadence_pinned,
       public.primary_poll_due('axs', jsonb_build_array(source_event_id)) <> '[]'::jsonb AS due
  FROM public.primary_poll_event WHERE source='axs' ORDER BY 1;

\echo '--- C. Z1 reads OK with an empty listings array: outcome empty'
SELECT public.axs_watch_settle_one('Z1', 200,
  $j${"status":"ok","body":{"status":"ok","exit_code":0,"event":{"id":"Z1"},"listings":[]}}$j$::jsonb,
  false, NULL, false) - 'response_s' - 'quota_remaining' AS z1_settled;

\echo '--- D. THE FIX: Z1 takes no_tickets_every (1 day) and is pinned, exactly like Z3 will'
SELECT public.axs_watch_settle_one('Z3', 200,
  $j${"body":{"status":"ok","exit_code":1,"error":"No tickets are currently available for this event."}}$j$::jsonb,
  false, NULL, false) - 'response_s' - 'quota_remaining' AS z3_settled;
SELECT public.axs_watch_settle_one('Z4', 200,
  $j${"body":{"status":"ok","exit_code":1,"error":"This event is not on sale yet."}}$j$::jsonb,
  false, NULL, false) - 'response_s' - 'quota_remaining' AS z4_settled;
SELECT source_event_id, poll_status, listing_count, poll_interval AS band, cadence_pinned, poll_error
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id IN ('Z1','Z3','Z4') ORDER BY 1;

\echo '--- E. and the ladder no longer overtakes any of the three'
SELECT source_event_id,
       public.primary_poll_due('axs', jsonb_build_array(source_event_id)) <> '[]'::jsonb AS due
  FROM public.primary_poll_event WHERE source='axs' ORDER BY 1;

\echo '--- F. the retire rule: an empty read counts like the error, and only within the window'
SELECT public.axs_watch_settle_one('Z2', 200,
  $j${"status":"ok","body":{"status":"ok","exit_code":0,"event":{"id":"Z2"},"listings":[]}}$j$::jsonb,
  false, NULL, false) - 'response_s' - 'quota_remaining' AS z2_settled;
SELECT e.source_event_id, e.event_date - current_date AS days_out,
       public.axs_watch_event_dead(e.source_event_id, e.event_date) AS dead
  FROM public.primary_poll_event e WHERE e.source='axs' ORDER BY 1;

-- (what axs_watch_fill then DOES with a dead event — take it off the watch, keep it out of
-- the candidates and out of the catalogue feed — is s18's and s20's subject, and is driven by
-- the export stub rather than by hand-inserted rows. This scenario owns the signal only.)

\echo '--- G. it UNPINS: Z1 comes back on sale and the band UPDATE restores its proximity band'
SELECT (public.axs_watch_settle_one('Z1', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"Z1"},"listings":[{"kind":"primary","section":"101","row":"A","seats":["1","2"],
  "quantity":2,"status":"Available","pricing":{"face":400,"fees_total":0,"tax":0,"all_in":400}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS z1_back_on_sale;
SELECT source_event_id, listing_count, poll_interval AS band, cadence_pinned
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='Z1';

\echo '--- H. an empty read is still a GOOD read: it clears the capture rather than keeping it'
SELECT count(*) AS listing_rows_for_z1 FROM public.primary_poll_listing
 WHERE source='axs' AND source_event_id='Z1';
SELECT public.axs_watch_settle_one('Z1', 200,
  $j${"status":"ok","body":{"status":"ok","exit_code":0,"event":{"id":"Z1"},"listings":[]}}$j$::jsonb,
  false, NULL, false) IS NOT NULL AS sold_out_again;
SELECT count(*) AS listing_rows_after_sell_out FROM public.primary_poll_listing
 WHERE source='axs' AND source_event_id='Z1';

\echo '--- I. both arms are installed in the settle, not one'
SELECT pg_get_functiondef(p.oid) ~ 'IF v_outcome = ''empty'' OR \(v_outcome = ''unparsed''' AS branch_head,
       pg_get_functiondef(p.oid) ~ 'CASE WHEN v_outcome = ''empty'' OR v_error ~\*' AS picks_one_day
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
