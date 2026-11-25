-- The worker-side reader (mig 20261125000000): the database chooses and settles, the worker reads. With reader = 'db'
-- the worker gets nothing; with reader = 'worker' the tick fires nothing, axs_watch_next hands out the due events most
-- overdue first within the batch and the cap, and axs_watch_record settles a read at once (the listings, the credit,
-- the ledger row), holds the worker while the upstream fails, and lets it go on when a read works again.
-- An event that was read gets a random slot inside its interval (mig 20261123194030), which the due check's slack
-- may reach: the scenario parks such an event a day ahead before asking what is due.
-- Event 33 is the hot-cadence one (section E). It is dated TOMORROW, not today, on purpose: axs_watch_next stops
-- handing out an event inside axs_watch_config.stop_before_start of its start (6 hours, mig 20261125150000), and with
-- start_utc unset the start falls back to (event_date + 1) midnight. Dated today it therefore vanished from the batch
-- from 18:00 UTC each day, so the expected output only matched before then.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

-- four watched events, all due; the pool has credits
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_local_time, venue_name, venue_city, venue_state, ticket_url, poll_status, next_poll_at, poll_interval)
VALUES ('axs', '31', 'Small Hall Show',  current_date + 20, '19:30', 'Small Hall', 'Austin', 'TX', 'https://www.axs.com/events/31', 'pending', now() - interval '3 hours', interval '1 hour'),
       ('axs', '32', 'Big Arena Show',   current_date + 30, '20:00', 'Big Arena',  'Austin', 'TX', 'https://www.axs.com/events/32', 'pending', now() - interval '2 hours', interval '1 hour'),
       ('axs', '33', 'Tomorrow''s Show', current_date + 1,  '20:00', 'Big Arena',  'Austin', 'TX', 'https://www.axs.com/events/33', 'pending', now() - interval '1 hour',  interval '10 minutes'),
       ('axs', '34', 'No Page Yet',      current_date + 40, '20:00', 'Big Arena',  'Austin', 'TX', NULL,                            'pending', now() - interval '4 hours', interval '1 hour');
INSERT INTO public.ticketsdata_credit_usage (credits, platform, endpoint, status_code, quota_remaining) VALUES (1, 'AXS', '/events?mode=all', 200, 100000);

\echo '--- A. the database reads by default: the worker is handed nothing, the tick fires as before (the most overdue event with a page)'
SELECT (SELECT reader FROM public.axs_watch_config) AS reader, public.axs_watch_next(20) AS next_for_worker;
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' - 'fired_today' AS tick_db_reads;
SELECT s.id, s.params->>'event_url' AS event_url FROM net.sent s ORDER BY s.id;

\echo '--- B. the worker reads: the tick still settles what pg_net brings (a 503) but fires nothing; next hands out the due events most overdue first (no page = never), within the batch asked'
UPDATE public.axs_watch_config SET reader = 'worker', read_spacing_ms = 3000, worker_batch = 20;
INSERT INTO net._http_response (id, status_code, content) VALUES (1, 503, '{"error":"worker unavailable"}');
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' - 'fired_today' AS tick_worker_reads;
SELECT count(*) AS requests_sent FROM net.sent;
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '3 hours' WHERE source = 'axs' AND source_event_id = '31';   -- due again after its failed read
SELECT (public.axs_watch_next(20)) - 'pool_remaining' - 'daily_cap' - 'fired_today' AS next_all;
SELECT jsonb_array_length((public.axs_watch_next(2))->'events') AS batch_of_two,
       (public.axs_watch_next(2))->'events'->0->>'id' AS first, (public.axs_watch_next(2))->'events'->1->>'id' AS second;

\echo '--- C. a read recorded: TicketsData''s JSON as the worker got it; the listings stored (the AXS Premium block not), the credit logged with the pool, the ledger row marked worker'
SELECT public.axs_watch_record('33', 200, $j${"status": "ok", "response_s": 7.9, "quota_remaining": 99990, "body": {
    "status": "ok", "exit_code": 0, "elapsed_seconds": 7.9,
    "event": {"id": "33", "title": "Tomorrow's Show"},
    "onsale": {"offer_id": "900", "status": {"onSaleNow": true}},
    "groups": [{"label": "Public", "offer_id": 900, "seat_type": "STANDARD", "ticket_qty": {"min": 1, "max": 8}}],
    "listings": [
      {"kind": "primary", "section": "101", "row": "A", "seats": ["1", "2"], "quantity": 2, "seat_type": "STANDARD", "status": "Available", "offer_id": "900", "offer_name": "Tomorrow's Show", "price_level": "Lower", "neighborhood": "Lower Bowl", "general_admission": false, "pricing": {"face": 80, "fees_total": 12, "tax": 0, "all_in": 92}},
      {"kind": "primary", "section": "PR04", "row": "3", "seats": ["1", "2"], "quantity": 2, "seat_type": "PREMIUM", "status": "AXS Premium POSTED AXS", "offer_id": "901", "offer_name": "Tomorrow's Show AXS Premium", "pricing": {"face": 134.5, "fees_total": 24.2, "tax": 0, "all_in": 158.7}},
      {"kind": "resale", "section": "102", "row": "B", "seats": ["7"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "9000000000000001", "pricing": {"face": 95.5, "connection_fee": 24.35, "tax": 0, "all_in": 119.85}}
    ]}}$j$::jsonb) - 'request_id' AS recorded;
SELECT request_id, axs_event_id AS id, reader, status_code, outcome, response_s, listings, quota_remaining, error, checked_at IS NOT NULL AS settled
  FROM public.axs_watch_poll ORDER BY request_id;
SELECT source_event_id AS id, poll_status, listing_count, offer_id, order_min, order_max, total_available, price_min, price_max, next_poll_at > now() AS next_in_future
  FROM public.primary_poll_event WHERE source = 'axs' AND source_event_id = '33';
SELECT market, section, seat_row AS "row", quantity AS qty, price, fee, all_in_price AS all_in, ticket_type
  FROM public.primary_poll_listing WHERE source = 'axs' AND source_event_id = '33' ORDER BY section, seat_row;
SELECT platform, endpoint, status_code, quota_remaining, credits FROM public.ticketsdata_credit_usage WHERE endpoint = '/fetch' ORDER BY id;
SELECT (public.axs_watch_budget())->'fired_today' AS fired_today, (public.axs_watch_budget())->'in_flight' AS in_flight;

\echo '--- D. the read event is no longer due; a transport failure and refusals are failed polls; after three the worker is held, and let go once a read works'
UPDATE public.primary_poll_event SET next_poll_at = now() + interval '1 day' WHERE source = 'axs' AND source_event_id = '33';   -- parked (see the header)
SELECT (public.axs_watch_next(20))->'events' AS next_after_read;
SELECT public.axs_watch_record('31', NULL, NULL, true, 'ReadTimeout: read timed out') - 'request_id' AS timed_out;
SELECT public.axs_watch_record('32', 429, NULL) - 'request_id' AS refused_once;
SELECT public.axs_watch_record('32', 429, NULL) - 'request_id' AS refused_twice;
SELECT (public.axs_watch_next(20)) - 'pool_remaining' - 'daily_cap' - 'fired_today' AS next_held;
SELECT source_event_id AS id, poll_status, poll_error, listing_count FROM public.primary_poll_event WHERE source = 'axs' AND source_event_id IN ('31', '32') ORDER BY 1;
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '1 hour' WHERE source = 'axs' AND source_event_id IN ('31', '32');
SELECT public.axs_watch_record('31', 200, $j${"status": "ok", "quota_remaining": 99989, "body": {"status": "ok", "exit_code": 0, "elapsed_seconds": 6.2, "event": {"id": "31"}, "listings": []}}$j$::jsonb) - 'request_id' AS read_again;
UPDATE public.primary_poll_event SET next_poll_at = now() + interval '1 day' WHERE source = 'axs' AND source_event_id = '31';   -- parked
SELECT (public.axs_watch_next(20))->'events' AS next_released;

\echo '--- E. over the day''s cap (pinned at 6; 6 reads today) only an event on a hot cadence is handed out, and only up to the overrun'
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '1 hour', poll_interval = interval '10 minutes' WHERE source = 'axs' AND source_event_id = '33';
UPDATE public.axs_watch_config SET daily_cap_override = 6, hot_overrun_pct = 50;
SELECT (public.axs_watch_next(20)) - 'pool_remaining' - 'spacing_ms' AS next_capped;
UPDATE public.axs_watch_config SET hot_overrun_pct = 0;
SELECT (public.axs_watch_next(20))->'events' AS next_capped_no_overrun;

\echo '--- F2. the lease (mig 20261125020000): the first worker to ask holds it; a second gets a hold while it is live; the first renews it; once it runs out the second takes over; a nameless ask takes none'
UPDATE public.axs_watch_config SET daily_cap_override = NULL, worker_lease_s = 180;
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '1 hour' WHERE source = 'axs' AND source_event_id IN ('31', '32');
SELECT jsonb_array_length((public.axs_watch_next(20, 'web-a:1'))->'events') AS a_gets, (public.axs_watch_next(20, 'web-a:1'))->>'lease_s' AS lease_s;
SELECT (public.axs_watch_next(20, 'web-b:2')) - 'lease_until' AS b_held;
SELECT worker_id, worker_lease_until > now() + interval '170 seconds' AS renewed FROM public.axs_watch_config;
UPDATE public.axs_watch_config SET worker_lease_until = now() - interval '1 second';   -- web-a stopped: its lease ran out
SELECT jsonb_array_length((public.axs_watch_next(20, 'web-b:2'))->'events') AS b_gets_after_expiry;
SELECT worker_id AS holder_now FROM public.axs_watch_config;
SELECT jsonb_array_length((public.axs_watch_next(20))->'events') AS nameless_gets;
SELECT worker_id AS holder_unchanged FROM public.axs_watch_config;

\echo '--- F3. the same read sent twice (a retried record) is recorded once: the second call returns the first row and settles nothing again'
SELECT (public.axs_watch_record('32', 200, $j${"status": "ok", "quota_remaining": 99980, "body": {"status": "ok", "exit_code": 0, "event": {"id": "32"}, "listings": [{"kind": "primary", "section": "101", "row": "A", "seats": ["1"], "quantity": 1, "seat_type": "STANDARD", "status": "Available", "pricing": {"face": 50, "all_in": 58}}]}}$j$::jsonb, false, NULL, '2026-01-01 12:00:00+00'))->>'request_id' AS first_id;
SELECT (public.axs_watch_record('32', 200, $j${"status": "ok", "quota_remaining": 99980, "body": {"status": "ok", "exit_code": 0, "event": {"id": "32"}, "listings": [{"kind": "primary", "section": "101", "row": "A", "seats": ["1"], "quantity": 1, "seat_type": "STANDARD", "status": "Available", "pricing": {"face": 50, "all_in": 58}}]}}$j$::jsonb, false, NULL, '2026-01-01 12:00:00+00')) - 'response_s' AS repeated;
SELECT count(*) AS rows_for_that_read FROM public.axs_watch_poll WHERE axs_event_id = '32' AND fired_at = '2026-01-01 12:00:00+00';
SELECT count(*) AS credits_for_that_read FROM public.ticketsdata_credit_usage WHERE endpoint = '/fetch' AND quota_remaining = 99980;

\echo '--- F. paused: nothing for the worker either; back to the database: the tick fires again'
UPDATE public.axs_watch_config SET enabled = false, daily_cap_override = NULL;
SELECT public.axs_watch_next(20) AS next_paused;
UPDATE public.axs_watch_config SET enabled = true, reader = 'db';
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' - 'fired_today' AS tick_db_again;
SELECT s.id, s.params->>'event_url' AS event_url FROM net.sent s ORDER BY s.id;

\echo '--- G. privileges: service_role only'
SELECT p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can, has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_can
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname IN ('axs_watch_next', 'axs_watch_record', 'axs_watch_settle_one') ORDER BY 1;
