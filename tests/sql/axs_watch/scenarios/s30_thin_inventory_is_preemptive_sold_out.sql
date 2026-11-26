-- An event with almost nothing to sell goes on the 24-hour list, is not published, and gives its
-- place back to the fill (mig 20261126230000).
--
-- Operator 2026-11-26: "if event has under 20 reserved tickets for sale put into 24 hour watch
-- list and replace with new event" / "Treat under 20 reserved tickets as preemptive sold out but
-- stop sharing with api".
--
-- T3 IS THE WHOLE REASON THE RULE MEASURES SELLABLE TICKETS AND NOT NON-GA TICKETS. A GA-only
-- show has ZERO reserved tickets by definition, so a literal reading of "under 20 reserved" is
-- true of every one of them. On the live watch it matched six events holding 12,428 GA tickets
-- between them — Nora En Pure, SIDEPIECE, A Boogie, The Escapement, Cloonee, CupcakKe — which
-- would have been parked at a day and dropped from the feed. If this scenario ever shows T3 thin,
-- that is the regression.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.primary_poll_config SET split_over_limit = false;   -- pieces are s02's subject

INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by)
VALUES (920001, 'Thin House', 0, true, true, 'scenario', 'test');
UPDATE public.axs_watch_config SET keep_regex = NULL, reader = 'worker', target_events = 2;

\echo '--- A. the knob and the stored measure'
SELECT thin_min_tickets, no_tickets_every FROM public.axs_watch_config;
SELECT column_name, data_type, is_nullable FROM information_schema.columns
 WHERE table_name = 'primary_poll_event' AND column_name = 'sellable_tickets';

INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, true, 'On Sale', v.title, 'Music', 920001, 'Thin House', 'Denver', 'CO',
       to_char(now() + make_interval(days => v.days), 'YYYY-MM-DD"T"HH24:MI:SS'),
       now() + make_interval(days => v.days), 'America/Denver',
       'https://www.axs.com/events/' || v.id
  FROM (VALUES (9300001, 'Thin Show', 40), (9300002, 'Healthy Show', 41),
               (9300003, 'Deep GA Show', 42)) AS v(id, title, days);
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-thin', now(), 3)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-thin', finished_at = now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_attempt_at, next_poll_at, poll_interval, watch, last_run, order_min, order_max)
SELECT 'axs', e.axs_event_id::text, e.event_title, e.event_date_utc::date, e.event_date_utc, e.venue_name,
       e.event_url, 'pending', NULL, now() - interval '1 minute', interval '1 hour', true, 'run-thin', 1, 8
  FROM public.axs_export_event e WHERE e.venue_id = 920001;

\echo '--- B. THE RULE: 8 sellable tickets is under 20, so T1 takes the one-day band and is pinned'
SELECT (public.axs_watch_settle_one('9300001', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"9300001"},"listings":[{"kind":"primary","section":"101","row":"A","quantity":8,
  "status":"Available","pricing":{"face":65,"fees_total":12,"tax":0,"all_in":77}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS t1_read;

\echo '--- C. 200 sellable tickets is not thin: T2 keeps its proximity band'
SELECT (public.axs_watch_settle_one('9300002', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"9300002"},"listings":[{"kind":"primary","section":"102","row":"B","quantity":200,
  "status":"Available","pricing":{"face":80,"fees_total":15,"tax":0,"all_in":95}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS t2_read;

\echo '--- D. THE LANDMINE: T3 has 5,000 GA tickets and ZERO reserved. It must NOT be thin.'
SELECT (public.axs_watch_settle_one('9300003', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"9300003"},"listings":[{"kind":"primary","section":"GA","quantity":5000,
  "general_admission":true,"status":"Available","pricing":{"face":50,"fees_total":10,"tax":0,"all_in":60}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS t3_read;

SELECT source_event_id, sellable_tickets, ga_tickets, ga_slow, cadence_pinned, poll_interval AS band,
       listing_count, listed_quantity
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id LIKE '93%' ORDER BY 1;

\echo '--- E. the feeds: T1 is withheld and SAYS WHY; T2 and the GA show are published'
SELECT event_id, listings_available, listings_withheld, listing_count
  FROM public.v_primary_poll_events_feed WHERE source='axs' AND event_id LIKE '93%' ORDER BY 1;
SELECT event_id, count(*) AS rows_sent, sum(quantity) AS tickets_sent
  FROM public.v_primary_poll_listings_feed WHERE source='axs' AND event_id LIKE '93%'
 GROUP BY event_id ORDER BY event_id;

\echo '--- F. a FAILED read never parks an event: the measure then describes the kept capture, not AXS'
SELECT (public.axs_watch_settle_one('9300002', 503, '{}'::jsonb, false, NULL, false))->>'outcome' AS t2_failed;
SELECT source_event_id, poll_status, cadence_pinned, poll_interval AS band, sellable_tickets
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9300002';

\echo '--- G. it UNPINS: T1 comes back with real inventory and the proximity band is restored'
SELECT (public.axs_watch_settle_one('9300001', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"9300001"},"listings":[{"kind":"primary","section":"101","row":"A","quantity":120,
  "status":"Available","pricing":{"face":65,"fees_total":12,"tax":0,"all_in":77}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS t1_back;
SELECT source_event_id, sellable_tickets, cadence_pinned, poll_interval AS band
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9300001';
SELECT event_id, listings_available, listings_withheld
  FROM public.v_primary_poll_events_feed WHERE source='axs' AND event_id='9300001';

\echo '--- H. "REPLACE WITH NEW EVENT": a parked event does not hold a place in the list'
-- target_events is 2 and three events are kept, all of them borrowed (the venue''s quota is 0).
-- With one parked the list counts as full at 2 and nothing is given back; unpin it and the same
-- dry run gives a place back, because the list then counts as 3 against a target of 2.
SELECT (public.axs_watch_settle_one('9300001', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"9300001"},"listings":[{"kind":"primary","section":"101","row":"A","quantity":8,
  "status":"Available","pricing":{"face":65,"fees_total":12,"tax":0,"all_in":77}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS t1_thin_again;
SELECT (public.axs_watch_fill(false)) - 'run' - 'short' AS dry_fill_with_one_parked;
UPDATE public.primary_poll_event SET cadence_pinned = false, poll_interval = interval '1 hour'
 WHERE source='axs' AND source_event_id='9300001';
SELECT (public.axs_watch_fill(false)) - 'run' - 'short' AS dry_fill_with_none_parked;

\echo '--- I. the rule is one knob: thin_min_tickets 0 switches it off, and nothing else does'
UPDATE public.axs_watch_config SET thin_min_tickets = 0;
SELECT (public.axs_watch_settle_one('9300001', 200, $j${"status":"ok","body":{"status":"ok","exit_code":0,
  "event":{"id":"9300001"},"listings":[{"kind":"primary","section":"101","row":"A","quantity":8,
  "status":"Available","pricing":{"face":65,"fees_total":12,"tax":0,"all_in":77}}]}}$j$::jsonb,
  false, NULL, false))->>'outcome' AS t1_with_rule_off;
SELECT source_event_id, sellable_tickets, cadence_pinned, poll_interval AS band
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9300001';
SELECT event_id, listings_available, listings_withheld
  FROM public.v_primary_poll_events_feed WHERE source='axs' AND event_id='9300001';
