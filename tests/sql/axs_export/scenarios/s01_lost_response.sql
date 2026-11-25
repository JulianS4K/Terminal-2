-- A lost pg_net response no longer kills the AXS export feed (mig 20261125163500).
-- Regression for: ERROR "record r is not assigned yet", which stopped axs_export_tick on every run from
-- 2026-11-25 14:28Z after a database restart dropped net._http_response (bot_chat 7498).
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. a page in flight whose response has not landed yet, within 5 minutes: waits, nothing changes'
UPDATE public.axs_export_sync SET run_kind='full', run_started_at=now(), last_full_started_at=now(),
       run_params='{"country":"US","type":"all","limit":"5000"}', page=13, pages_in_run=12, rows_in_run=60000,
       cursor='axs_1550382', pending_request_id=8448, pending_since=now()-interval '2 minutes', tries=0 WHERE id=1;
SELECT public.axs_export_tick() AS tick;
SELECT page, tries, pending_request_id, cursor, run_kind FROM public.axs_export_sync;

\echo '--- B. the same page, response gone and older than 5 minutes (the restart case): retries, same cursor'
UPDATE public.axs_export_sync SET pending_since=now()-interval '2 hours' WHERE id=1;
SELECT public.axs_export_tick() AS tick;
\echo '    tries incremented, cursor unchanged, a new request fired at the same page:'
SELECT page, tries, cursor, run_kind, pending_request_id IS NOT NULL AS refired FROM public.axs_export_sync;
SELECT url, params->>'cursor' AS cursor_sent FROM net.sent ORDER BY id DESC LIMIT 1;

\echo '--- C. the sixth try on a lost response stops the run and records it as lost'
UPDATE public.axs_export_sync SET tries=5, pending_request_id=8448, pending_since=now()-interval '2 hours' WHERE id=1;
SELECT public.axs_export_tick() AS tick;
SELECT run_kind, tries, cursor, pending_request_id, last_error,
       last_full_error IS NOT NULL AS full_error_kept FROM public.axs_export_sync;

\echo '--- D. a 4xx that is not 429 stops the run at once, whatever tries says'
INSERT INTO net._http_response (id, status_code, content) VALUES (9001, 400, 'page too deep');
UPDATE public.axs_export_sync SET run_kind='full', page=52, tries=0, cursor='axs_9', last_error=NULL,
       last_full_error=NULL, pending_request_id=9001, pending_since=now()-interval '1 minute' WHERE id=1;
SELECT public.axs_export_tick() AS tick;
SELECT run_kind, tries, left(last_error,60) AS last_error FROM public.axs_export_sync;

\echo '--- E. a 429 is retried rather than stopping the run'
INSERT INTO net._http_response (id, status_code, content) VALUES (9002, 429, 'slow down');
UPDATE public.axs_export_sync SET run_kind='full', page=20, tries=1, cursor='axs_20', last_error=NULL,
       pending_request_id=9002, pending_since=now()-interval '1 minute' WHERE id=1;
SELECT public.axs_export_tick() AS tick;
SELECT run_kind, tries FROM public.axs_export_sync;

\echo '--- F. a 200 page with items lands: rows upserted, cursor advanced, next page fired'
INSERT INTO net._http_response (id, status_code, content) VALUES (9003, 200,
  '{"quota_remaining": 240000, "body": {"has_more": true, "next_cursor": "axs_next",
    "items": [{"event_id":"501","type":"axs_primary","ticketer":"axs","axs_ticketed":true,"status":"Buy Tickets",
               "event_title":"Landed Show","venue_id":"1","venue_name":"Big Arena","venue_country":"US",
               "event_date_local":"2027-05-01T20:00:00","event_date_utc":"2027-05-02T03:00:00Z",
               "event_url":"https://www.axs.com/events/501/tickets"}]}}');
UPDATE public.axs_export_sync SET run_kind='full', page=1, tries=0, cursor=NULL, last_error=NULL,
       pages_in_run=0, rows_in_run=0, pending_request_id=9003, pending_since=now() WHERE id=1;
SELECT public.axs_export_tick() AS tick;
SELECT page, pages_in_run, rows_in_run, cursor, run_kind FROM public.axs_export_sync;
SELECT axs_event_id, event_title, status FROM public.axs_export_event WHERE axs_event_id=501;
