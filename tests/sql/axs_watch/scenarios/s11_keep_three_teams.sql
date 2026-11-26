-- The watch holds three teams and nothing else (mig 20261125232000). Operator 2026-11-25:
-- "poll kings, knights, rockets first and only push out those events" / "No just poll these remove rest for now".
-- The gate is on the TITLE, not the venue, because the three arenas also carry concerts, Disney On Ice and UFC;
-- and it applies to events ALREADY on the list, not only to new candidates, or the ones already there would
-- have stayed forever.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the gate: with no keep_regex every title that passes the other rules is kept'
UPDATE public.axs_watch_config SET keep_regex = NULL;
SELECT t AS title, public.axs_watch_rule_ok('Sports', t) AS kept
  FROM (VALUES ('LA Kings vs Vancouver Canucks'), ('Houston Rockets vs. Toronto Raptors'),
               ('Utah Mammoth vs. Vegas Golden Knights'), ('UFC 335'), ('PBR: PENDLETON WHISKY VELOCITY TOUR - 12/19')) v(t);

\echo '--- B. with the three teams set, the games are kept and everything else is not — concerts, ice shows, cage fights'
UPDATE public.axs_watch_config SET keep_regex = '(\mla kings\M|los angeles kings|vegas golden knights|houston rockets)';
SELECT t AS title, cat AS category, public.axs_watch_rule_ok(cat, t) AS kept
  FROM (VALUES ('LA Kings vs Vancouver Canucks',           'Sports'),
               ('Los Angeles Kings vs. Vegas Golden Knights','Sports'),  -- the away leg, at the Knights' arena
               ('Utah Mammoth vs. Vegas Golden Knights',   'Sports'),
               ('Houston Rockets vs. Toronto Raptors',     'Sports'),
               ('Houston Rockets vs. Sacramento Kings',    'Sports'),    -- a Rockets game, not a Kings one
               ('UFC 335',                                 'Sports'),
               ('PBR: PENDLETON WHISKY VELOCITY TOUR - 12/19','Sports'),
               ('Disney On Ice presents Jump In!',          'Family'),
               ('Trans-Siberian Orchestra',                 'Music'),
               ('KPop Demon Hunters',                       'Music'),
               ('Nickelback',                               'Music'),
               ('Sacramento Kings vs. Portland Trail Blazers','Sports')  -- basketball Kings: NOT the hockey one
         ) v(t, cat);

\echo '--- C. a fill over a mixed arena: only the games take places, however many concerts are on sale first'
DELETE FROM public.axs_watch_venue;
DELETE FROM public.axs_watch_audit;
DELETE FROM public.primary_poll_event WHERE source = 'axs';
DELETE FROM public.axs_export_event;
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled) VALUES (1, 'Crypto.com Arena', 10, true), (2, 'Toyota Center', 10, true);
UPDATE public.axs_watch_config SET target_events = 20, watch_from = current_date, backfill = true, watch_until_days = 180;
INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, status, event_title, major_category, venue_id, venue_name, venue_city, venue_state,
                                     event_date_local, event_date_utc, event_timezone, event_url, onsale_utc)
SELECT v.id, 'axs_primary', 'axs', true, 'Buy Tickets', v.title, v.cat, v.venue,
       CASE v.venue WHEN 1 THEN 'Crypto.com Arena' ELSE 'Toyota Center' END, 'Los Angeles', 'CA',
       to_char(now() + v.days * interval '1 day', 'YYYY-MM-DD') || 'T20:00:00', now() + v.days * interval '1 day', 'America/Los_Angeles',
       'https://www.axs.com/events/' || v.id || '/tickets', NULL::timestamptz
  FROM (VALUES (11, 1, 'Disney On Ice presents Jump In!',       'Family',  3),
               (12, 1, 'Trans-Siberian Orchestra',              'Music',   4),
               (13, 1, 'LA Kings vs Minnesota Wild',            'Sports',  8),
               (14, 1, 'LA Kings vs Utah Mammoth',              'Sports', 20),
               (15, 1, 'KPop Demon Hunters',                    'Music',  40),
               (21, 2, 'Houston Rockets vs. New York Knicks',   'Sports',  5),
               (22, 2, 'Nickelback',                            'Music',   6),
               (23, 2, 'Houston Rockets vs. Milwaukee Bucks',   'Sports', 70),
               (24, 2, 'Andrea Bocelli',                        'Music',  75)) v(id, venue, title, cat, days);
SELECT (public.axs_watch_fill(true)) - 'run' AS fill;
SELECT source_event_id AS id, name, venue_name AS venue FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;

\echo '--- D. an event already on the list that the rule no longer covers is RETIRED, and its stored listings go with it'
-- the concert is forced on, as it would have been before this migration, together with a listing of its own
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name, ticket_url, poll_status, listing_count)
VALUES ('axs', '12', 'Trans-Siberian Orchestra', (now() + interval '4 days')::date, now() + interval '4 days',
        'Crypto.com Arena', 'https://www.axs.com/events/12/tickets', 'ok', 1);
INSERT INTO public.primary_poll_listing (source, source_event_id, listing_id, market, section, quantity, price, obstructed)
VALUES ('axs', '12', 'L-tso', 'primary', 'Floor 2', 4, 95, false);
SELECT count(*) AS concert_on_the_list FROM public.primary_poll_event WHERE source='axs' AND source_event_id='12';
SELECT count(*) AS its_listings FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='12';
SELECT (public.axs_watch_fill(true)) - 'run' AS fill_retires_it;
SELECT coalesce((SELECT 'still here' FROM public.primary_poll_event WHERE source='axs' AND source_event_id='12'), 'retired') AS concert_now;
SELECT count(*) AS its_listings_after FROM public.primary_poll_listing WHERE source='axs' AND source_event_id='12';
SELECT action, axs_event_id AS id, venue, note FROM public.axs_watch_audit WHERE note = 'not_kept' ORDER BY id;

\echo '--- E. the games are untouched by all of that: the list is the games, in date order'
SELECT source_event_id AS id, name FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;

\echo '--- F. a game added to the export later joins on its own — the rule is a pattern, not a list of ids'
INSERT INTO public.axs_export_event (axs_event_id, type, ticketer, axs_ticketed, status, event_title, major_category, venue_id, venue_name, venue_city, venue_state,
                                     event_date_local, event_date_utc, event_timezone, event_url, onsale_utc)
VALUES (16, 'axs_primary', 'axs', true, 'Buy Tickets', 'LA Kings vs Vegas Golden Knights', 'Sports', 1, 'Crypto.com Arena', 'Los Angeles', 'CA',
        to_char(now() + interval '30 days', 'YYYY-MM-DD') || 'T20:00:00', now() + interval '30 days', 'America/Los_Angeles',
        'https://www.axs.com/events/16/tickets', NULL);
SELECT (public.axs_watch_fill(true)) - 'run' AS fill_adds_the_new_game;
SELECT source_event_id AS id, name FROM public.primary_poll_event WHERE source = 'axs' ORDER BY event_date, source_event_id;

\echo '--- G. "for now": clearing the one column puts the rest of the list back'
UPDATE public.axs_watch_config SET keep_regex = NULL;
SELECT (public.axs_watch_fill(true)) - 'run' AS fill_without_the_rule;
SELECT count(*) AS watched, count(*) FILTER (WHERE name ~* '(kings|knights|rockets)') AS games FROM public.primary_poll_event WHERE source = 'axs';
UPDATE public.axs_watch_config SET keep_regex = '(\mla kings\M|los angeles kings|vegas golden knights|houston rockets)';

\echo '--- H. the ladder the operator set (mig 20261126011500): three bands — a week, four months, beyond'
SELECT band, max_days, every, sort_order FROM public.axs_watch_cadence ORDER BY sort_order;
SELECT d AS days_out, public.axs_watch_cadence_every((now() + make_interval(mins => (d*1440)::int))::timestamptz, NULL) AS every
  FROM (VALUES (1.0),(5.0),(10.0),(20.0),(45.0),(90.0),(150.0)) v(d);

\echo '--- I. only the week band is at or inside hot_every, so over the cap it is the week''s games that are handed out'
SELECT (SELECT hot_every FROM public.axs_watch_config) AS hot_every,
       count(*) FILTER (WHERE every <= (SELECT hot_every FROM public.axs_watch_config)) AS bands_hot,
       count(*) AS bands_total
  FROM public.axs_watch_cadence WHERE enabled;
