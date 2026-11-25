-- One cadence for every watched event (mig 20261125204500, operator "event at 1 hour cadance until
-- event is 36 hours away then it drops to every 30 mins", then 75 minutes for the base rung after
-- being shown that 305 hourly is 90% of an average hour's measured throughput), and the daily limit
-- on the Eastern day taken from the 250k cycle (mig 20261125205000, operator "Limit resets midnight est").
-- The interval is SET, not floored: the ingest writes the ladder's value from date / price / quantity
-- first, and the settle replaces it, so a cheap far-out event and a dear near one read alike.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the cadence config'
SELECT base_every, near_every, near_within, not_on_sale_every FROM public.axs_watch_config;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-cad', now(), 3)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-cad', finished_at = now();
-- three watched events: far out, inside 36 hours, and one that will answer "not on sale"
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
VALUES ('axs','C1','Far Out Show',  (now() + interval '90 days')::date, now() + interval '90 days', 'Big Arena',
        'https://www.axs.com/events/C1', 'pending', now() - interval '1 hour', interval '6 hours', 'run-cad'),
       ('axs','C2','Soon Show',     (now() + interval '30 hours')::date, now() + interval '30 hours', 'Big Arena',
        'https://www.axs.com/events/C2', 'pending', now() - interval '1 hour', interval '6 hours', 'run-cad'),
       ('axs','C3','Not On Sale',   (now() + interval '60 days')::date, now() + interval '60 days', 'Small Hall',
        'https://www.axs.com/events/C3', 'pending', now() - interval '1 hour', interval '6 hours', 'run-cad')
ON CONFLICT (source, source_event_id) DO NOTHING;

\echo '--- B. a good read of the far-out event puts it on base_every (75 min), not the ladder''s 6 hours'
SELECT public.axs_watch_record('C1', 200, $j${"status": "ok", "response_s": 5.0, "quota_remaining": 99990, "body": {
  "status": "ok", "exit_code": 0, "elapsed_seconds": 5.0,
  "event": {"id": "C1", "title": "Far Out Show"},
  "offer": {"id": "700", "qty_min": 1, "qty_max": 8, "total_available": 50, "price_min": 40, "price_max": 90},
  "listings": [{"kind": "primary", "section": "101", "row": "A", "seats": ["1","2"], "quantity": 2, "status": "Available", "pricing": {"face": 40, "fees_total": 6, "tax": 0, "all_in": 46}}]}}$j$::jsonb) - 'request_id' AS far_out_read;
SELECT source_event_id AS id, poll_interval, next_poll_at > now() AS next_in_future
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C1';

\echo '--- C. the event inside 36 hours gets near_every (30 minutes)'
SELECT public.axs_watch_record('C2', 200, $j${"status": "ok", "response_s": 5.0, "quota_remaining": 99989, "body": {
  "status": "ok", "exit_code": 0, "elapsed_seconds": 5.0,
  "event": {"id": "C2", "title": "Soon Show"},
  "offer": {"id": "701", "qty_min": 1, "qty_max": 4, "total_available": 10, "price_min": 80, "price_max": 120},
  "listings": [{"kind": "primary", "section": "Floor", "row": "1", "seats": ["5","6"], "quantity": 2, "status": "Available", "pricing": {"face": 80, "fees_total": 12, "tax": 0, "all_in": 92}}]}}$j$::jsonb) - 'request_id' AS near_read;
SELECT source_event_id AS id, poll_interval FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C2';

\echo '--- D. "not on sale" still wins over the cadence: not_on_sale_every, not 1 hour'
SELECT public.axs_watch_record('C3', 200, $j${"status": "ok", "response_s": 4.0, "quota_remaining": 99988, "body": {
  "status": "error", "exit_code": 1, "error": "Tickets are not currently on sale for this event"}}$j$::jsonb) - 'request_id' AS not_on_sale_read;
SELECT source_event_id AS id, poll_interval FROM public.primary_poll_event WHERE source='axs' AND source_event_id='C3';

\echo '--- E. the config drives it: halve both rungs and the next read follows'
UPDATE public.axs_watch_config SET base_every = interval '2 hours', near_every = interval '15 minutes';
SELECT public.axs_watch_record('C1', 200, $j${"status": "ok", "response_s": 5.0, "quota_remaining": 99987, "body": {
  "status": "ok", "exit_code": 0, "elapsed_seconds": 5.0,
  "event": {"id": "C1", "title": "Far Out Show"},
  "listings": []}}$j$::jsonb) - 'request_id' AS far_out_again;
SELECT public.axs_watch_record('C2', 200, $j${"status": "ok", "response_s": 5.0, "quota_remaining": 99986, "body": {
  "status": "ok", "exit_code": 0, "elapsed_seconds": 5.0,
  "event": {"id": "C2", "title": "Soon Show"},
  "listings": []}}$j$::jsonb) - 'request_id' AS near_again;
SELECT source_event_id AS id, poll_interval FROM public.primary_poll_event
 WHERE source='axs' AND source_event_id IN ('C1','C2') ORDER BY 1;
UPDATE public.axs_watch_config SET base_every = interval '1 hour', near_every = interval '30 minutes';

\echo '--- E2. the phase is stable and inside the interval: two reads of one event land on the same mark'
-- next_poll_at is the next instant congruent to the event's own phase, so a read at any time puts it
-- back on ITS slot. Asserted as the offset within the interval, which is fixed, rather than as a
-- timestamp, which is not.
SELECT source_event_id AS id,
       (extract(epoch FROM next_poll_at)::bigint % extract(epoch FROM poll_interval)::bigint)
         = ((hashtext(source_event_id)::bigint & 2147483647) % extract(epoch FROM poll_interval)::bigint) AS on_its_own_phase,
       next_poll_at > now() AS in_future,
       next_poll_at <= now() + poll_interval AS within_one_interval
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id IN ('C1','C2') ORDER BY 1;

\echo '--- F. the daily limit is the Eastern day, and comes from the cycle, not a flat 7,500'
-- daily_cap itself is NOT printed: it is floor((pool - reserve) / days_left) and days_left shrinks
-- every day until the cycle resets on the 18th, so the number would only match on the day it was
-- generated (the s03 lesson). What is asserted is that the cap follows that formula and that the gate
-- reads the Eastern day.
SELECT (SELECT monthly_credits FROM public.axs_watch_config) AS cycle_credits,
       (SELECT reserve_credits FROM public.axs_watch_config) AS reserve,
       (public.axs_watch_budget()->>'daily_cap')::int
         = floor(((public.axs_watch_budget()->>'pool_remaining')::numeric
                  - (SELECT reserve_credits FROM public.axs_watch_config))
                 / (public.axs_watch_budget()->>'days_left')::numeric) AS cap_is_cycle_paced,
       public.td_credits_today() AS credits_eastern_day,
       public.td_daily_budget_ok() AS daily_ok;

\echo '--- G. the Eastern boundary, not UTC: a charge from 02:00Z today counts yesterday in Eastern'
INSERT INTO public.ticketsdata_credit_usage (called_at, credits, platform, endpoint, status_code)
VALUES (date_trunc('day', now()) + interval '2 hours', 1000, 'AXS', '/fetch', 200);
SELECT public.td_credits_today() AS eastern_day_unchanged_by_a_02Z_charge,
       (SELECT coalesce(sum(credits),0) FROM public.ticketsdata_credit_usage
         WHERE (called_at AT TIME ZONE 'UTC')::date = current_date) AS utc_day_would_include_it;
