-- The error-driven slow bands survive primary_poll_due's ladder clause (mig 20261126150000).
--
-- mig 20261126141500 guarded the GA band with ga_slow, a stored record of WHY that band was
-- chosen. The no-tickets and not-on-sale bands had no such record, so the ladder still
-- overrode them. primary_poll_event.cadence_pinned is that record, written by the settle.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker';

\echo '--- A. the knobs'
SELECT no_tickets_every, not_on_sale_every FROM public.axs_watch_config;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-pin', now(), 3)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-pin', finished_at = now();

-- All three 150 days out, priced and sized so the shared ladder wants 30 minutes.
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_attempt_at, next_poll_at, poll_interval, median_price, listed_quantity,
        watch, last_run)
SELECT 'axs', v.id, v.nm, (now() + interval '150 days')::date, now() + interval '150 days', 'Pin Arena',
       'https://www.axs.com/events/'||v.id, 'ok', now() - interval '40 minutes',
       now() + interval '20 minutes', interval '1 hour', 400, 6000, true, 'run-pin'
  FROM (VALUES ('P1','No Tickets Yet'), ('P2','Not On Sale Yet'), ('P3','Healthy Show')) AS v(id, nm)
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- B. before any read all three are unpinned, and the ladder overtakes all three'
SELECT source_event_id, cadence_pinned, poll_interval AS band,
       public.primary_poll_interval(event_date, median_price, listed_quantity) AS ladder
  FROM public.primary_poll_event WHERE source='axs' ORDER BY 1;
SELECT public.primary_poll_due('axs','["P1","P2","P3"]'::jsonb) AS due_before;

\echo '--- C. P1 answers "no tickets", P2 "not on sale": the settle sets the band AND pins it'
SELECT public.axs_watch_settle_one('P1', 200,
  $j${"body":{"status":"ok","exit_code":1,"error":"No tickets are currently available for this event."}}$j$::jsonb,
  false, NULL, false) - 'response_s' - 'quota_remaining' AS p1_settled;
SELECT public.axs_watch_settle_one('P2', 200,
  $j${"body":{"status":"ok","exit_code":1,"error":"This event is not on sale yet."}}$j$::jsonb,
  false, NULL, false) - 'response_s' - 'quota_remaining' AS p2_settled;
SELECT source_event_id, cadence_pinned, poll_interval AS band, poll_error
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id IN ('P1','P2') ORDER BY 1;

\echo '--- D. THE FIX: the ladder no longer overtakes P1 or P2. P3, never read, is still overtaken.'
SELECT public.primary_poll_due('axs','["P1","P2","P3"]'::jsonb) AS due_after;

\echo '--- E. said per event, so a change in list order cannot hide a regression'
SELECT e.source_event_id, e.cadence_pinned,
       jsonb_array_length(public.primary_poll_due('axs', jsonb_build_array(e.source_event_id))) = 1 AS due
  FROM public.primary_poll_event e WHERE e.source='axs' ORDER BY 1;

\echo '--- F. the pin SLOWS, it never stops: when P1''s own next_poll_at arrives it is due'
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '1 second'
 WHERE source='axs' AND source_event_id='P1';
SELECT jsonb_array_length(public.primary_poll_due('axs','["P1"]'::jsonb)) AS p1_due_when_its_time_comes;

-- 60 tickets, not a token 2: under thin_min_tickets (20, mig 20261126230000) a read finding
-- fewer than 20 sellable tickets is a preemptive sold out and would pin it straight back,
-- so the unpin this section is about would never be visible.
\echo '--- G. and it UNPINS: P1 comes back on sale, the band UPDATE sets cadence_pinned false again'
SELECT (public.axs_watch_settle_one('P1', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"P1"},"listings":[{"kind":"primary","section":"101","row":"A","seats":["1","2"],
  "quantity":60,"status":"Available","pricing":{"face":400,"fees_total":0,"tax":0,"all_in":400}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS p1_back_on_sale;
SELECT cadence_pinned, poll_interval AS band FROM public.primary_poll_event
 WHERE source='axs' AND source_event_id='P1';

\echo '--- H. inert for another source: nothing but the AXS settle writes cadence_pinned'
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('sitickets', 'run-si', now(), 1)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-si';
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_attempt_at, next_poll_at, poll_interval, median_price, listed_quantity, last_run)
VALUES ('sitickets','S1','Other Source', (now() + interval '150 days')::date, now() + interval '150 days',
        'Elsewhere','https://example.test/S1','ok', now() - interval '40 minutes',
        now() + interval '20 minutes', interval '1 hour', 400, 6000, 'run-si')
ON CONFLICT (source, source_event_id) DO NOTHING;
SELECT cadence_pinned, jsonb_array_length(public.primary_poll_due('sitickets','["S1"]'::jsonb)) = 1 AS still_overtaken
  FROM public.primary_poll_event WHERE source='sitickets' AND source_event_id='S1';

\echo '--- I. both guards are installed, not one'
SELECT pg_get_functiondef(p.oid) ~ 'NOT coalesce\(t\.ga_slow, false\)' AS ga_guard,
       pg_get_functiondef(p.oid) ~ 'NOT coalesce\(t\.cadence_pinned, false\)' AS pin_guard
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='primary_poll_due';
