-- Three operator answers (mig 20261127000000):
--   B "Park event uses credits outside the daily reserve, up to 50 polls daily."
--   C "stop sharing with API and delete last push"
--   D "Remove beyond horrizon but by soonest event"
--
-- B is the one with teeth: with the day's cap spent, a read of a PARKED event is still handed
-- out while a read of an active event is not, and the parked reads have their own ceiling.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker', queue_enabled = true,
       queue_lanes = 6, target_events = 50;

\echo '--- A. the knobs'
SELECT parked_daily_max, no_tickets_every, hot_every,
       coalesce(watch_until_days::text, 'NULL (no ceiling)') AS watch_until_days
  FROM public.axs_watch_config;

INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by)
VALUES (930001, 'Cap House', 0, true, true, 'scenario', 'test');
INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, true, 'On Sale', v.title, 'Music', 930001, 'Cap House', 'Denver', 'CO',
       to_char(now() + make_interval(days => v.days), 'YYYY-MM-DD"T"HH24:MI:SS'),
       now() + make_interval(days => v.days), 'America/Denver',
       'https://www.axs.com/events/' || v.id
  FROM (VALUES (9400001, 'Active Show', 40), (9400002, 'Parked Show', 41),
               (9400003, 'Far Future Show', 300)) AS v(id, title, days);
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-cap', now(), 3)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-cap', finished_at = now();
-- the active show is on a 90-minute band so it is NOT hot (hot_every is 30 minutes), which is
-- what makes the cap test below about the parked exemption and not about the hot overrun
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_ok_at, next_poll_at, poll_interval, cadence_pinned, sellable_tickets,
        listing_count, listed_quantity, watch, last_run)
VALUES ('axs','9400001','Active Show', (now()+interval '40 days')::date, now()+interval '40 days','Cap House',
        'https://www.axs.com/events/9400001','ok', now()-interval '2 hours', now()-interval '1 minute',
        interval '90 minutes', false, 500, 3, 500, true, 'run-cap'),
       ('axs','9400002','Parked Show', (now()+interval '41 days')::date, now()+interval '41 days','Cap House',
        'https://www.axs.com/events/9400002','ok', now()-interval '2 hours', now()-interval '1 minute',
        interval '1 day', true, 8, 1, 8, true, 'run-cap'),
       ('axs','9400003','Far Future Show', (now()+interval '300 days')::date, now()+interval '300 days','Cap House',
        'https://www.axs.com/events/9400003','pending', NULL, now()-interval '1 minute',
        interval '1 hour', false, NULL, 0, NULL, true, 'run-cap');

\echo '--- B. the day''s cap is spent: one read today against a cap of 1, charged to the ACTIVE event'
UPDATE public.axs_watch_config SET daily_cap_override = 1;
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, reader)
VALUES (8001, '9400001', now() - interval '10 minutes', now() - interval '10 minutes', 200, 'ok', 'worker');
SELECT (public.axs_watch_budget())->>'daily_cap' AS cap, (public.axs_watch_budget())->>'fired_today' AS fired_today;

\echo '--- C. THE EXEMPTION: the parked event is handed out, the active one is not'
-- projected rather than printed whole: the claim carries a release_at (a live timestamp) and a
-- queue_id from a sequence whose order depends on microsecond-level insert times, and neither is
-- stable across runs
WITH c AS (SELECT public.axs_queue_claim('w-cap', 6) AS j)
SELECT (SELECT jsonb_agg(i->>'id' || ' @' || (i->>'every_min') || 'min' ORDER BY i->>'id')
          FROM jsonb_array_elements(c.j->'items') i) AS handed_out,
       c.j->>'daily_cap' AS daily_cap, c.j->>'fired_today' AS fired_today,
       c.j->>'parked_today' AS parked_today, c.j->>'parked_daily_max' AS parked_daily_max
  FROM c;
SELECT q.axs_event_id, q.every_min, q.claimed_by IS NOT NULL AS claimed
  FROM public.axs_read_queue q WHERE q.axs_event_id LIKE '94%' ORDER BY 1;

\echo '--- D. the ceiling binds: with parked_daily_max 0 the parked read is refused too'
UPDATE public.axs_read_queue SET claimed_at = NULL, claimed_by = NULL, release_at = NULL, lease_until = NULL;
UPDATE public.axs_watch_config SET parked_daily_max = 0;
SELECT jsonb_array_length((public.axs_queue_claim('w-cap', 6))->'items') AS items_with_ceiling_zero;
UPDATE public.axs_watch_config SET parked_daily_max = 50, daily_cap_override = NULL;

\echo '--- E. and under the cap nothing is refused: both come back'
UPDATE public.axs_read_queue SET claimed_at = NULL, claimed_by = NULL, release_at = NULL, lease_until = NULL;
SELECT jsonb_array_length((public.axs_queue_claim('w-cap', 6))->'items') AS items_under_cap;

\echo '--- F. "DELETE LAST PUSH": a thin read clears the capture, and the measure survives it'
INSERT INTO public.primary_poll_listing (source, source_event_id, listing_id, market, section, quantity,
        price, all_in_price, ticket_type, general_admission, obstructed, ada)
VALUES ('axs','9400002','L-old','primary','101', 8, 65, 77, 'STANDARD', false, false, false);
SELECT count(*) AS listings_before FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='9400002';
SELECT (public.axs_watch_settle_one('9400002', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"9400002"},"listings":[{"kind":"primary","section":"101","row":"A","quantity":8,
  "status":"Available","pricing":{"face":65,"fees_total":12,"tax":0,"all_in":77}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS thin_read;
SELECT count(*) AS listings_after FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='9400002';
SELECT source_event_id, listing_count, listed_quantity, median_price, sellable_tickets, cadence_pinned,
       poll_interval AS band
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9400002';
SELECT count(*) AS still_in_the_feed FROM public.v_primary_poll_listings_feed
 WHERE source='axs' AND event_id='9400002';

\echo '--- G. nothing is lost: a read with real inventory republishes in full'
SELECT (public.axs_watch_settle_one('9400002', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"9400002"},"listings":[{"kind":"primary","section":"101","row":"A","quantity":300,
  "status":"Available","pricing":{"face":65,"fees_total":12,"tax":0,"all_in":77}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS healthy_read;
SELECT listing_count, listed_quantity, sellable_tickets, cadence_pinned, poll_interval AS band
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9400002';
SELECT count(*) AS back_in_the_feed FROM public.v_primary_poll_listings_feed
 WHERE source='axs' AND event_id='9400002';

\echo '--- H. "REMOVE BEYOND HORIZON": 300 days out is neither retired nor barred from the list'
SELECT source_event_id, event_date - current_date AS days_out, watch
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9400003';
SELECT (public.axs_watch_fill(false)) - 'run' - 'short' AS dry_fill;
SELECT source_event_id, event_date - current_date AS days_out, watch
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9400003';

\echo '--- I. put the horizon back and the same event IS retired — so the NULL is what did it'
UPDATE public.axs_watch_config SET watch_until_days = 180;
SELECT (public.axs_watch_fill(false)) - 'run' - 'short' AS dry_fill_with_horizon;
UPDATE public.axs_watch_config SET watch_until_days = NULL;
