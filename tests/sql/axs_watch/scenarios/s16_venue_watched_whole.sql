-- A venue can be watched WHOLE (mig 20261126044500): keep_all on axs_watch_venue lifts
-- keep_regex AND sports_keep_regex for that venue's events, and never lifts exclude_regex.
-- The fixture uses two fabricated venue ids rather than the seeded ones, so the assertions
-- do not move when an operator re-flags a real venue.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

-- 900001 is watched whole; 900002 is an ordinary venue the config regexes govern.
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by)
VALUES (900001, 'Whole Venue Arena',    10, true, true,  'scenario', 'test'),
       (900002, 'Title Rule Pavilion',  10, true, false, 'scenario', 'test'),
       (900003, 'Trusted Stadium',      10, true, true,  'scenario', 'test');
-- 900003 is the FC Dallas shape: the export marks its events other_ticketer, we know better
UPDATE public.axs_watch_venue SET trust_axs_sold = true WHERE axs_venue_id = 900003;

\echo '--- A. the flag exists, defaults false, and the operator''s venues carry it'
SELECT count(*) FILTER (WHERE keep_all) AS venues_watched_whole,
       count(*) FILTER (WHERE NOT keep_all AND enabled) AS venues_on_the_title_rule
  FROM public.axs_watch_venue;
SELECT venue_name, quota, keep_all FROM public.axs_watch_venue
 WHERE axs_venue_id IN (100988, 124913, 101242, 101949, 128331) ORDER BY axs_venue_id;

\echo '--- B. keep_regex is lifted at a whole venue, and still applied at the other'
-- the three-team regex as the operator set it, so this does not depend on the seed
UPDATE public.axs_watch_config
   SET keep_regex = '(\mla kings\M|vegas golden knights|houston rockets)',
       -- prod's value, pinned here: the template's seed carries neither the operator's
       -- 'olivia rodrigo' nor '^lakers vs\.' exclusion, so section D would otherwise be
       -- asserting about the seed rather than about the mechanism.
       exclude_regex = '(parking|suite|package|\mpass\M|vanguards|unrivaled|hoopfest|globetrotters|timberwolves|\mlynx\M|season|membership|deposit|^lakers vs\.|olivia rodrigo)';
SELECT t AS title,
       public.axs_watch_rule_ok('Music', t, 900001) AS at_whole_venue,
       public.axs_watch_rule_ok('Music', t, 900002) AS at_title_rule_venue
  FROM (VALUES ('Nickelback'), ('Trans-Siberian Orchestra'), ('Houston Rockets vs Someone')) v(t);

\echo '--- C. the sports allow-list is lifted too — without this, LA Galaxy admits nothing'
SELECT t AS title,
       public.axs_watch_rule_ok('Sports', t, 900001) AS at_whole_venue,
       public.axs_watch_rule_ok('Sports', t, 900002) AS at_title_rule_venue
  FROM (VALUES ('LA Galaxy v. San Jose Earthquakes'),
               ('U.S. Women''s National Team vs. Panama'),
               ('2027 NCAA Men''s Basketball - West Regional'),
               ('UFC 335')) v(t);

\echo '--- D. exclude_regex is NEVER lifted: these are not events, flag or no flag'
SELECT t AS title,
       public.axs_watch_rule_ok('Music', t, 900001) AS at_whole_venue,
       public.axs_watch_rule_ok('Music', t, 900002) AS at_title_rule_venue
  FROM (VALUES ('Nickelback - Parking'), ('2027 LA Galaxy Sprint Season Pass'),
               ('Suite Rental'), ('Olivia Rodrigo')) v(t);

\echo '--- E. the 2-arg form is unchanged: no venue means the regexes govern'
SELECT t AS title, public.axs_watch_rule_ok('Music', t) AS two_arg,
       public.axs_watch_rule_ok('Music', t, NULL::bigint) AS three_arg_null_venue
  FROM (VALUES ('Nickelback'), ('Houston Rockets vs Someone')) v(t);

\echo '--- F. the fill admits a whole venue''s events and not the other venue''s'
INSERT INTO public.axs_export_event
  (axs_event_id, axs_ticketed, status, event_title, major_category, venue_id, venue_name,
   venue_city, venue_state, event_date_local, event_date_utc, event_timezone, event_url)
SELECT v.id, v.axs, 'On Sale', v.title, v.cat, v.venue,
       CASE v.venue WHEN 900001 THEN 'Whole Venue Arena' WHEN 900002 THEN 'Title Rule Pavilion'
                    ELSE 'Trusted Stadium' END,
       'Denver', 'CO',
       to_char(now() + make_interval(days => v.days), 'YYYY-MM-DD"T"HH24:MI:SS'),
       now() + make_interval(days => v.days), 'America/Denver',
       'https://www.axs.com/events/' || v.id
  FROM (VALUES
         (9100001, true,  'Nickelback',                 'Music',  900001::bigint, 40),
         (9100002, true,  'LA Galaxy v. Austin FC',     'Sports', 900001,         45),
         (9100003, true,  'Nickelback - Parking',       'Music',  900001,         40),
         (9100004, true,  'Nickelback',                 'Music',  900002,         41),
         (9100005, true,  'Houston Rockets vs Someone', 'Sports', 900002,         42),
         (9100006, false, 'Someone Else',               'Music',  900001,         43),
         (9100007, false, 'FC Someone vs Another',      'Sports', 900003,         44)
       ) AS v(id, axs, title, cat, venue, days);
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill;
SELECT t.source_event_id AS id, left(t.name, 28) AS name, t.venue_name
  FROM public.primary_poll_event t WHERE t.source = 'axs' ORDER BY 1;

\echo '--- G. clearing the flag takes them back off at the next fill (the not_kept arm)'
UPDATE public.axs_watch_venue SET keep_all = false WHERE axs_venue_id = 900001;
SELECT (public.axs_watch_fill(true)) - 'run' - 'short' AS fill_after_unflagging;
SELECT coalesce(string_agg(t.source_event_id, ',' ORDER BY t.source_event_id), '(none)') AS still_watched
  FROM public.primary_poll_event t WHERE t.source = 'axs';
SELECT a.axs_event_id AS id, a.note FROM public.axs_watch_audit a
 WHERE a.action = 'retire' ORDER BY a.axs_event_id;

\echo '--- H. axs_ticketed = false is a hard gate, UNLESS the venue is trusted (FC Dallas)'
-- 9100006: export says not AXS, venue not trusted  -> never watched
-- 9100007: export says not AXS, venue IS trusted   -> watched, because we have the shop URL
SELECT exists (SELECT 1 FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9100006')
         AS untrusted_non_axs_watched,
       exists (SELECT 1 FROM public.primary_poll_event WHERE source='axs' AND source_event_id='9100007')
         AS trusted_non_axs_watched;
SELECT axs_venue_id, venue_name, keep_all, trust_axs_sold FROM public.axs_watch_venue
 WHERE axs_venue_id = 124913;
