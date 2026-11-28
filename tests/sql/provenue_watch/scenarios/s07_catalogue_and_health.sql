-- Mig 20261128100000: every game of the two tickets.dev watches is published (not_polled until read), as the AXS
-- catalogue is; and their health is graded by their own cadence, not by how many games carry listings.
\pset footer off
-- the watches as shipped, before the operator's settings (mig 20261128130000)
UPDATE public.sgp_watch_config SET enabled = false, only_event_ids = NULL, daily_cap = 10;
UPDATE public.provenue_watch_config SET daily_cap = 33;
INSERT INTO public.mlb_ticket_game (mlb_game_id, sport_id, game_type, game_date, game_time_utc, game_time_local, time_zone_local, home_abbrev, away_abbrev,
       home_name, away_name, venue_name, venue_city, ticket_url, primary_seller, primary_event_id, tevo_event_id)
VALUES ('A', 1, 'R', (now() + interval '3 days')::date, now() + interval '3 days', '2027-03-30T18:45:00', 'America/New_York', 'PHI', 'NYM',
        'Philadelphia Phillies', 'New York Mets', 'Citizens Bank Park', 'Philadelphia', 'https://mlb.tickets.com/?orgid=21&pid=9000001', 'provenue', '9000001', 3500001),
       ('B', 1, 'R', (now() + interval '4 days')::date, now() + interval '4 days', '2027-03-31T13:05:00', 'America/New_York', 'CIN', 'PIT',
        'Cincinnati Reds', 'Pittsburgh Pirates', 'Great American Ball Park', 'Cincinnati', 'https://mlb.tickets.com?orgid=6&pid=9000002', 'provenue', '9000002', NULL);
INSERT INTO public.sgp_watch_game (sg_event_id, team, name, event_utc, event_local, venue_name, venue_city, venue_state, timezone, url) VALUES
 ('18412995', 'New Orleans Pelicans', 'Los Angeles Lakers at New Orleans Pelicans', now() + interval '5 days', '2099-12-02T19:00:00-06:00',
  'Smoothie King Center', 'New Orleans', 'LA', 'America/Chicago', 'https://seatgeek.com/x/18412995'),
 ('18412996', 'New Orleans Pelicans', 'TBD at New Orleans Pelicans (Date TBD) (If Necessary)', now() + interval '9 days', '2099-12-06T19:00:00-06:00',
  'Smoothie King Center', 'New Orleans', 'LA', 'America/Chicago', 'https://seatgeek.com/x/18412996');

\echo '== 1. the catalogue: every game published with no read; the playoff placeholder is not a game'
SELECT public.provenue_catalogue_fill(), public.sgp_catalogue_fill();
SELECT source, source_event_id, name, event_date, start_local_time, watch, poll_status, tevo_event_id, tevo_match_method, announced_at IS NOT NULL AS announced
  FROM public.primary_poll_event WHERE source IN ('provenue', 'seatgeek_primary') ORDER BY 1, 2;
SELECT source, event_id, listings_available, listings_withheld FROM public.v_primary_poll_events_feed
 WHERE source IN ('provenue', 'seatgeek_primary') ORDER BY 1, 2;

\echo '== 2. a game that leaves the schedule leaves the catalogue; one that was read stays'
UPDATE public.mlb_ticket_game SET removed_at = now() WHERE mlb_game_id = 'B';
SELECT public.provenue_catalogue_fill();
SELECT source_event_id FROM public.primary_poll_event WHERE source = 'provenue' ORDER BY 1;

\echo '== 3. health by cadence: off while reading is off; down with no read for 2 days; ok once reads come back'
SELECT public.tdev_watch_health('seatgeek_primary') - 'cadence' - 'last_at' - 'age_seconds';
UPDATE public.provenue_watch_config SET enabled = true;
SELECT public.tdev_watch_health('provenue') - 'cadence' - 'last_at' - 'age_seconds';
INSERT INTO public.provenue_watch_poll (request_id, pid, fired_at, checked_at, outcome)
SELECT g, '9000001', now() - interval '3 hours', now() - interval '3 hours', 'ok' FROM generate_series(1, 6) g;
SELECT public.tdev_watch_health('provenue') - 'cadence' - 'last_at' - 'reads_today';
\echo '   three of the last ten failed: degraded; eight: down'
INSERT INTO public.provenue_watch_poll (request_id, pid, fired_at, checked_at, outcome)
SELECT 100 + g, '9000001', now() - interval '1 hour', now() - interval '1 hour', 'capture_failed' FROM generate_series(1, 3) g;
SELECT (public.tdev_watch_health('provenue'))->>'status' AS status, (public.tdev_watch_health('provenue'))->>'detail' AS detail;
INSERT INTO public.provenue_watch_poll (request_id, pid, fired_at, checked_at, outcome)
SELECT 200 + g, '9000001', now() - interval '30 minutes', now() - interval '30 minutes', 'capture_failed' FROM generate_series(1, 5) g;
SELECT (public.tdev_watch_health('provenue'))->>'status' AS status, (public.tdev_watch_health('provenue'))->>'detail' AS detail;
SELECT public.tdev_watch_health('axs') IS NULL AS other_sources_untouched;

\echo '== 4. the nightly catalogue'
SELECT jobname, schedule FROM cron.job WHERE jobname = 'tdev_catalogue_fill_daily';
