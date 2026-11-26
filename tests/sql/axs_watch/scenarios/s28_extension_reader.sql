-- The extension reader (mig 20261126200000): our own Firefox extension reads the AXS pages, the database chooses and
-- settles as for the TicketsData worker. With reader = 'extension' only a worker id starting 'ext:' is handed events,
-- with no TicketsData cap and the extension's spacing and lanes; a read is settled with no credit spent and a ledger row
-- marked extension; a repeat of the same read returns the first. With reader = 'worker' the extension is handed nothing.
-- (Renumbered after main's scenarios each time main moved: s10, s13, s16, s18, s20, s22, now s28.)
-- Events are dated days ahead, so stop_before_start (6 hours) never reaches them whatever the hour.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_local_time, venue_name, venue_city, venue_state, ticket_url, poll_status, next_poll_at, poll_interval)
VALUES ('axs', '41', 'Arena Night',  current_date + 20, '19:30', 'Big Arena', 'Austin', 'TX', 'https://www.axs.com/events/41', 'pending', now() - interval '3 hours', interval '1 hour'),
       ('axs', '42', 'Theatre Night', current_date + 30, '20:00', 'Theatre',   'Austin', 'TX', 'https://www.axs.com/events/42', 'pending', now() - interval '2 hours', interval '1 hour');
-- a pool with no credits left: the extension does not need any
INSERT INTO public.ticketsdata_credit_usage (credits, platform, endpoint, status_code, quota_remaining) VALUES (1, 'AXS', '/events?mode=all', 200, 0);

\echo '--- A. the TicketsData worker reads: the extension is handed nothing'
UPDATE public.axs_watch_config SET reader = 'worker' WHERE id;
SELECT (public.axs_watch_next(10, 'ext:test'))->>'reason' AS ext_while_worker;

\echo '--- B. the extension reads: the TicketsData worker is handed nothing; the extension gets the due events, uncapped, with its spacing and lanes'
UPDATE public.axs_watch_config SET reader = 'extension', worker_id = NULL, worker_lease_until = NULL WHERE id;
SELECT (public.axs_watch_next(10, 'host:1'))->>'reason' AS worker_while_ext;
-- nor through the paced queue (mig 20261126030000), which feeds the same worker
UPDATE public.axs_watch_config SET queue_enabled = true WHERE id;
SELECT (public.axs_queue_claim('host:1', 10))->>'reason' AS queue_while_ext;
UPDATE public.axs_watch_config SET queue_enabled = false WHERE id;
SELECT jsonb_path_query_array(n->'events', '$[*].id') AS events, n->'spacing_ms' AS spacing_ms, n->'lanes' AS lanes,
       n->'daily_cap' AS daily_cap, (public.axs_watch_budget())->'unmetered' AS unmetered
  FROM (SELECT public.axs_watch_next(10, 'ext:test') AS n) x;

\echo '--- C. a read recorded: the listings stored, no credit charged, the ledger row marked extension, not counted against the TicketsData day'
SELECT public.axs_watch_record_ext('41', 200, $j${"response_s": 14.2, "body": {
    "status": "ok", "exit_code": 0, "elapsed_seconds": 14.2,
    "event": {"id": "41", "title": "Arena Night"},
    "onsale": {"offer_id": "700", "status": {"onSaleNow": true}},
    "groups": [{"offer_id": "700", "ticket_qty": {"min": 1, "max": 6}}],
    "listings": [
      {"kind": "primary", "section": "101", "row": "A", "seats": ["1", "2"], "quantity": 2, "seat_type": "STANDARD", "status": "Available", "offer_id": "700", "price_level": "Lower", "pricing": {"face": 80}},
      {"kind": "resale", "section": "102", "row": "B", "seats": ["7"], "quantity": 1, "seat_type": "FLASHSEATS", "offer_id": "9001", "pricing": {"face": 95.5}}
    ]}}$j$::jsonb, false, NULL, '2026-01-01T00:00:00Z') - 'request_id' AS recorded;
SELECT axs_event_id AS id, reader, status_code, outcome, listings, quota_remaining FROM public.axs_watch_poll ORDER BY request_id;
SELECT source_event_id AS id, poll_status, listing_count, order_max, price_min, price_max FROM public.primary_poll_event WHERE source = 'axs' AND source_event_id = '41';
SELECT market, section, seat_row AS "row", quantity AS qty, price FROM public.primary_poll_listing WHERE source = 'axs' AND source_event_id = '41' ORDER BY section;
SELECT count(*) AS fetch_credits_charged FROM public.ticketsdata_credit_usage WHERE endpoint = '/fetch';
SELECT (public.axs_watch_budget())->'fired_today' AS ticketsdata_fired_today;

\echo '--- D. the same read sent again returns the first record; a blocked page is a failed poll named for the AXS page'
SELECT (public.axs_watch_record_ext('41', 200, '{}'::jsonb, false, NULL, '2026-01-01T00:00:00Z'))->'repeated' AS repeated, count(*) AS ledger_rows
  FROM public.axs_watch_poll GROUP BY 1;
SELECT public.axs_watch_record_ext('42', 403, NULL, false, NULL, NULL) - 'request_id' AS blocked;

\echo '--- E. the pace counts the lanes (the hourly pacer sets cadence_scale from it): four lanes at a 14.2 s settle read every 3.8 s, held to the 4 s spacing'
UPDATE public.axs_watch_poll SET fired_at = checked_at - interval '14.2 seconds';   -- the scenario's reads took 14.2 s each
SELECT p->'reader' AS reader, p->'lanes' AS lanes, p->'spacing_s' AS spacing_s, p->'s_per_read' AS s_per_read, p->'reads_per_hour' AS reads_per_hour
  FROM (SELECT public.axs_watch_pace() AS p) x;
