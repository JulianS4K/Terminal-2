-- The AXS watch (mig 20261124190000): the list fills and retires by the venue quotas and the rules; the tick settles
-- TicketsData's answers into listings, charges the credit, fires the due events within the slots and the budget, and
-- slows down on upstream trouble.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

-- a smaller list: two venues watched, one disabled (the build's own first fill, against an empty export, is forgotten)
DELETE FROM public.axs_watch_venue;
DELETE FROM public.axs_watch_audit;
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled) VALUES
  (1, 'Big Arena', 3, true), (2, 'Small Hall', 1, true), (3, 'Closed Venue', 5, false);
UPDATE public.axs_watch_config SET max_in_flight = 2, reserve_credits = 0, target_events = 10, watch_from = current_date + 2;   -- the list starts two days out

-- the export: what AXS lists at the two venues
INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, event_title, major_category, venue_id, venue_name, venue_city, venue_state,
                                     event_date_local, event_date_utc, event_timezone, event_url, tevo_event_id, gone_at) VALUES
  (11, 'axs_primary',    'axs',  true,  'Lakers vs. Denver',            'Sports',       1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '3 days', 'YYYY-MM-DD') || 'T19:30:00', now() + interval '3 days',  'America/Los_Angeles', 'https://www.axs.com/events/11/lakers-tickets', 900011, NULL),
  (12, 'axs_primary',    'axs',  true,  'Vegas Vanguards vs. Boston',   'Sports',       1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '4 days', 'YYYY-MM-DD') || 'T19:00:00', now() + interval '4 days',  'America/Los_Angeles', 'https://www.axs.com/events/12/vanguards-tickets', NULL, NULL),
  (13, 'axs_primary',    'axs',  true,  'Harlem Globetrotters',         'Sports',       1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '5 days', 'YYYY-MM-DD') || 'T14:00:00', now() + interval '5 days',  'America/Los_Angeles', 'https://www.axs.com/events/13/globetrotters-tickets', NULL, NULL),
  (14, 'other_ticketer', 'nba',  true,  'Big Concert',                  'Music',        1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '6 days', 'YYYY-MM-DD') || 'T20:00:00', now() + interval '6 days',  'America/Los_Angeles', 'https://www.axs.com/events/14/big-concert-tickets', 900014, NULL),
  (15, 'axs_primary',    'axs',  true,  'Gone Concert',                 'Music',        1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '7 days', 'YYYY-MM-DD') || 'T20:00:00', now() + interval '7 days',  'America/Los_Angeles', 'https://www.axs.com/events/15/gone-tickets', NULL, now()),
  (16, 'other_ticketer', 'tm',   false, 'Ticketmaster Concert',         'Music',        1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '8 days', 'YYYY-MM-DD') || 'T20:00:00', now() + interval '8 days',  'America/Los_Angeles', 'https://www.axs.com/events/16/tm-tickets', NULL, NULL),
  (17, 'axs_primary',    'axs',  true,  'Concert Without A Page',       'Music',        1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '9 days', 'YYYY-MM-DD') || 'T20:00:00', now() + interval '9 days',  'America/Los_Angeles', NULL, NULL, NULL),
  (18, 'axs_primary',    'axs',  true,  'Disney On Ice presents Jump In!', 'ArtsOrFamily', 1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '20 days', 'YYYY-MM-DD') || 'T11:00:00', now() + interval '20 days', 'America/Los_Angeles', 'https://www.axs.com/events/18/disney-tickets', NULL, NULL),
  (19, 'axs_primary',    'axs',  true,  'Later Concert',                'Music',        1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '40 days', 'YYYY-MM-DD') || 'T20:00:00', now() + interval '40 days', 'America/Los_Angeles', 'https://www.axs.com/events/19/later-tickets', 900019, NULL),
  (20, 'axs_primary',    'axs',  true,  'Premium Parking - Lakers',     'Sports',       1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() + interval '3 days', 'YYYY-MM-DD') || 'T17:00:00', now() + interval '3 days',  'America/Los_Angeles', 'https://www.axs.com/events/20/parking-tickets', NULL, NULL),
  (21, 'axs_primary',    'axs',  true,  'Small Hall Show',              'Music',        2, 'Small Hall', 'Denver', 'CO', to_char(now() + interval '2 days', 'YYYY-MM-DD') || 'T19:00:00', now() + interval '2 days',  'America/Denver', 'https://www.axs.com/events/21/show-tickets', NULL, NULL),
  (22, 'axs_primary',    'axs',  true,  'Second Small Hall Show',       'Music',        2, 'Small Hall', 'Denver', 'CO', to_char(now() + interval '12 days', 'YYYY-MM-DD') || 'T19:00:00', now() + interval '12 days', 'America/Denver', 'https://www.axs.com/events/22/show2-tickets', NULL, NULL),
  (23, 'axs_primary',    'axs',  true,  'Tomorrow Small Hall Show',     'Music',        2, 'Small Hall', 'Denver', 'CO', to_char(now() + interval '1 day', 'YYYY-MM-DD') || 'T19:00:00', now() + interval '1 day',  'America/Denver', 'https://www.axs.com/events/23/show3-tickets', NULL, NULL),
  (31, 'axs_primary',    'axs',  true,  'Closed Venue Show',            'Music',        3, 'Closed Venue', 'Austin', 'TX', to_char(now() + interval '2 days', 'YYYY-MM-DD') || 'T19:00:00', now() + interval '2 days',  'America/Chicago', 'https://www.axs.com/events/31/closed-tickets', NULL, NULL),
  (41, 'axs_primary',    'axs',  true,  'Yesterday Concert',            'Music',        1, 'Big Arena', 'Los Angeles', 'CA', to_char(now() - interval '1 day', 'YYYY-MM-DD') || 'T20:00:00', now() - interval '1 day',  'America/Los_Angeles', 'https://www.axs.com/events/41/yesterday-tickets', NULL, NULL);
-- two events already watched: one has passed, one the export no longer knows
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, venue_name, ticket_url, announced_at) VALUES
  ('axs', '41', 'Yesterday Concert', current_date - 1, 'Big Arena', 'https://www.axs.com/events/41/yesterday-tickets', now()),
  ('axs', '99', 'Vanished Concert', current_date + 3, 'Big Arena', 'https://www.axs.com/events/99/vanished-tickets', now());

\echo '--- A. the rules: an excluded entry never, a sports event only for a major-league team'
SELECT t AS title, c AS category, public.axs_watch_rule_ok(c, t) AS ok
  FROM (VALUES ('Lakers vs. Denver', 'Sports'), ('Vegas Vanguards vs. Boston', 'Sports'), ('UFC 330', 'Sports'), ('Premium Parking - Lakers', 'Sports'),
               ('Minnesota Timberwolves vs. Utah', 'Sports'), ('Big Concert', 'Music'), ('Lynx vs. Aces', 'Sports'), ('VIP Pass - Festival', 'Music'),
               ('Passenger', 'Music'), ('2027 Season Tickets', 'Sports')) v(t, c);

\echo '--- B. a dry run reports; the fill retires the passed and the vanished, then fills Big Arena to 3 and Small Hall to 1 by date, from watch_from (tomorrow''s Small Hall show is before it)'
SELECT (public.axs_watch_fill(false)) - 'run' AS dry_run;
SELECT (public.axs_watch_fill(true)) - 'run' AS fill;
SELECT source_event_id AS id, name, event_date - current_date AS days_out, to_char(start_local_time, 'HH24:MI') AS at, venue_name, tevo_event_id AS tevo,
       tevo_match_method AS method, announced_at IS NOT NULL AS announced, poll_status, last_run IS NOT NULL AS in_run
  FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;
SELECT action, axs_event_id AS id, venue, note FROM public.axs_watch_audit ORDER BY id;
SELECT source, events, current_run IS NOT NULL AS has_run FROM public.primary_poll_source WHERE source = 'axs';
SELECT count(*) AS bot_chat_posts FROM public.bot_chat_posts;

\echo '--- C. a second fill changes nothing'
SELECT (public.axs_watch_fill(true)) - 'run' AS fill_again;

\echo '--- D. the tick: no pool reading and nothing recorded leaves the whole pool; with the pool at 0 nothing fires'
INSERT INTO public.ticketsdata_credit_usage (credits, platform, endpoint, status_code, quota_remaining) VALUES (1, 'AXS', '/events?mode=all', 200, 0);
SELECT (public.axs_watch_budget()) - 'next_reset' - 'days_left' - 'pool_read_at' AS budget_empty;
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' AS tick_no_budget;
SELECT count(*) AS requests_sent FROM net.sent;

\echo '--- E. with a pool, the tick fires the due events, most overdue first, never more than max_in_flight (2); the request names the page and the platform'
INSERT INTO public.ticketsdata_credit_usage (credits, platform, endpoint, status_code, quota_remaining) VALUES (1, 'AXS', '/events?mode=all', 200, 100000);
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' AS tick_fires;
SELECT s.id, s.url, s.params->>'platform' AS platform, s.params->>'event_url' AS event_url, s.params ? 'username' AS has_login,
       s.params->>'username' = 'secret-TICKETSDATA_USERNAME' AS login_from_vault, s.timeout_ms
  FROM net.sent s ORDER BY s.id;
SELECT request_id, axs_event_id, checked_at IS NULL AS pending FROM public.axs_watch_poll ORDER BY request_id;
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' AS tick_full;

\echo '--- F. the answers land: seats in blocks, a resale seat, a GA level by amount; an expired event is a failed poll; the credit is logged'
INSERT INTO net._http_response (id, status_code, content) VALUES
  (1, 200, $j${"quota_remaining": 99998, "body": {"status": "ok", "exit_code": 0, "elapsed_seconds": 41.2,
     "event": {"title": "Lakers vs. Denver", "starts_local": "2026-12-23 19:30:00"},
     "onsale": {"offer_id": 555, "status": {"onSaleNow": true}},
     "inventory": {
       "offer_search": [{"offers": [
          {"offerID": "555", "items": [
            {"sectionLabel": "101", "rowLabel": "A", "number": "1", "seatType": "STANDARD", "priceLevelID": "P1", "isGASection": false, "neighborhoodPrintDescription": "Lower Bowl", "statusCodeLabel": "AVAILABLE"},
            {"sectionLabel": "101", "rowLabel": "A", "number": "2", "seatType": "STANDARD", "priceLevelID": "P1", "isGASection": false, "neighborhoodPrintDescription": "Lower Bowl", "statusCodeLabel": "AVAILABLE"},
            {"sectionLabel": "101", "rowLabel": "A", "number": "3", "seatType": "STANDARD", "priceLevelID": "P1", "isGASection": false, "neighborhoodPrintDescription": "Lower Bowl", "statusCodeLabel": "AVAILABLE"},
            {"sectionLabel": "101", "rowLabel": "A", "number": "5", "seatType": "STANDARD", "priceLevelID": "P1", "isGASection": false, "neighborhoodPrintDescription": "Lower Bowl", "statusCodeLabel": "AVAILABLE"},
            {"sectionLabel": "101", "rowLabel": "A", "number": "6", "seatType": "STANDARD", "priceLevelID": "P2", "isGASection": false, "neighborhoodPrintDescription": "Lower Bowl", "statusCodeLabel": "AVAILABLE"},
            {"sectionLabel": "305", "rowLabel": "K", "number": "12", "seatType": "ADA", "priceLevelID": "P2", "isGASection": false, "neighborhoodPrintDescription": "Upper Bowl", "statusCodeLabel": "Wheelchair accessible"}]},
          {"offerID": "777", "items": [
            {"sectionLabel": "101", "rowLabel": "B", "number": "7", "seatType": "STANDARD", "priceLevelID": "R1", "isGASection": false, "originalPrice": "95.5"}]}]}],
       "inventory_v4": [{"offerPrices": [
          {"offerID": "555", "offerType": "Single", "min": 1, "max": 8, "zonePrices": [{"isSoldOut": false, "priceLevels": [
             {"priceLevelID": "P1", "label": "Lower", "prices": [{"base": 12500}], "availability": {"amount": 4}},
             {"priceLevelID": "P2", "label": "Upper", "prices": [{"base": 6000}], "availability": {"amount": 2}},
             {"priceLevelID": "G1", "label": "Standing Room", "prices": [{"base": 4000}], "availability": {"amount": 40}}]}]},
          {"offerID": "777", "offerType": "AXS Official Resale", "min": 1, "max": 2, "zonePrices": [{"isSoldOut": false, "priceLevels": [
             {"priceLevelID": "R1", "label": "Resale", "prices": [{"base": 9550}], "availability": {"amount": 1}}]}]}]}]}}}$j$),
  (2, 200, $j${"quota_remaining": 99997, "body": {"status": "expired", "message": "Event has passed"}}$j$);
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' - 'fired_today' AS tick_settles;
SELECT request_id, axs_event_id AS id, status_code, outcome, response_s, listings, quota_remaining, error FROM public.axs_watch_poll ORDER BY request_id;
SELECT source_event_id AS id, poll_status, poll_error, listing_count, offer_id, order_min, order_max, total_available, price_min, price_max, median_price, listed_quantity,
       (extract(epoch FROM poll_interval) / 60)::integer AS every_min, next_poll_at > now() AS next_in_future
  FROM public.primary_poll_event WHERE source = 'axs' AND source_event_id IN ('11', '21') ORDER BY source_event_id;
SELECT market, section, seat_row AS "row", seat_low, seat_high, seats, quantity AS qty, max_per_order AS max, price, fee, area, ticket_type, ada, general_admission AS ga, obstructed
  FROM public.primary_poll_listing WHERE source = 'axs' ORDER BY section, seat_row, seat_low;
SELECT platform, endpoint, status_code, quota_remaining, event_id, credits FROM public.ticketsdata_credit_usage WHERE endpoint = '/fetch' ORDER BY id;
SELECT (public.axs_watch_budget())->'fired_today' AS fired_today, (public.axs_watch_budget())->'in_flight' AS in_flight;

\echo '--- G. the feed serves the read event with its listings and withholds the failed one with the reason'
SELECT event_id, name, listings_available, listing_count, listings_withheld, poll_every_minutes, tevo_event_id FROM public.v_primary_poll_events_feed WHERE source = 'axs' ORDER BY event_id;
SELECT count(*) AS listings_in_feed, min(price) AS cheapest FROM public.v_primary_poll_listings_feed WHERE source = 'axs';

\echo '--- H. the two events not yet read were fired as soon as the settled ones freed their slots; a request that never answers is lost after stale_after and the poll fails'
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' AS tick_next;
SELECT request_id, axs_event_id AS id FROM public.axs_watch_poll WHERE checked_at IS NULL ORDER BY request_id;
UPDATE public.axs_watch_poll SET fired_at = now() - interval '20 minutes' WHERE request_id = 3;
INSERT INTO net._http_response (id, status_code, content) VALUES (4, 503, '{"error":"worker unavailable"}');
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' AS tick_lost_and_503;
SELECT request_id, axs_event_id AS id, status_code, outcome, error FROM public.axs_watch_poll WHERE request_id IN (3, 4) ORDER BY request_id;
SELECT source_event_id AS id, poll_status, poll_error, listing_count FROM public.primary_poll_event WHERE source = 'axs' ORDER BY source_event_id;

\echo '--- I. upstream trouble: with three of the last ten reads failing upstream the drainer holds to one in flight'
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '1 minute' WHERE source = 'axs';
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, outcome) VALUES (900, '11', now() - interval '5 minutes', now() - interval '4 minutes', 'timeout');
SELECT (public.axs_watch_tick()) - 'pool_remaining' - 'daily_cap' AS tick_slowed;
SELECT count(*) AS now_in_flight FROM public.axs_watch_poll WHERE checked_at IS NULL;

\echo '--- J. over the day''s cap (pinned at 5, 5 fired today) only the hot events (30 minutes or faster) are read, and only up to the overrun'
DELETE FROM public.axs_watch_poll WHERE checked_at IS NULL;
UPDATE public.primary_poll_event SET next_poll_at = now() - interval '1 minute', poll_interval = CASE WHEN source_event_id = '21' THEN interval '30 minutes' ELSE interval '1 hour' END WHERE source = 'axs';
UPDATE public.axs_watch_config SET hot_overrun_pct = 100, upstream_errors_max = 99, daily_cap_override = 5;
SELECT (public.axs_watch_budget()) - 'next_reset' - 'days_left' - 'pool_read_at' AS budget_pinned;
SELECT (public.axs_watch_tick()) - 'pool_remaining' AS tick_capped;
SELECT axs_event_id AS id FROM public.axs_watch_poll WHERE checked_at IS NULL ORDER BY request_id;
UPDATE public.axs_watch_config SET hot_overrun_pct = 0;
DELETE FROM public.axs_watch_poll WHERE checked_at IS NULL;
SELECT (public.axs_watch_tick()) - 'pool_remaining' AS tick_capped_no_overrun;
UPDATE public.axs_watch_config SET daily_cap_override = NULL;

\echo '--- K. paused: the tick still settles but fires nothing'
UPDATE public.axs_watch_config SET enabled = false;
DELETE FROM public.axs_watch_poll WHERE checked_at IS NULL;
INSERT INTO public.ticketsdata_credit_usage (credits, platform, endpoint, status_code, quota_remaining) VALUES (1, 'AXS', '/fetch', 200, 100000);
SELECT (public.axs_watch_tick()) AS tick_paused;
UPDATE public.axs_watch_config SET enabled = true;

\echo '--- L. three reads in a row saying AXS does not sell it retire the event; the venue refills from the next by date'
INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, outcome) VALUES
  (901, '14', now() - interval '3 minutes', now() - interval '3 minutes', 'not_axs'),
  (902, '14', now() - interval '2 minutes', now() - interval '2 minutes', 'expired'),
  (903, '14', now() - interval '1 minute',  now() - interval '1 minute',  'not_axs');
SELECT (public.axs_watch_fill(true)) - 'run' AS fill_after_not_axs;
SELECT source_event_id AS id, name, event_date - current_date AS days_out FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;
SELECT action, axs_event_id AS id, note FROM public.axs_watch_audit WHERE action = 'retire' ORDER BY id;

\echo '--- M. the crons'
SELECT jobname, schedule, command FROM cron.job WHERE jobname LIKE 'axs_watch%' ORDER BY jobname;

\echo '--- N. privileges: service_role only'
SELECT p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon, has_function_privilege('service_role', p.oid, 'EXECUTE') AS service
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname LIKE 'axs_watch%' ORDER BY 1;
