-- The feed's freshness window follows the event's own band (mig 20261126213000).
--
-- listing_max_age (35 min) was set in 20261123190030, when every source polled on one
-- 30-minute cycle. Per-event bands arrived in 20261123194030 and the flat limit was never
-- revisited, so for any band over 35 minutes the window rested entirely on
-- next_poll_at + listing_grace — and the settle phase-ALIGNS next_poll_at, so it can be a
-- minute after a read or a full band after it. An hour-band event read just before its
-- grid slot got a 21-minute window on data we consider good for an hour.
--
-- E-grid is that event, and it is the whole point of the migration: its grid slot fell 10
-- minutes after its last read, so the old window was read+35 rather than read+80. E-late and
-- E-short are here to show what the fix does NOT do: it does not make the window unbounded,
-- and it does not loosen a band shorter than the floor.
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;
UPDATE public.primary_poll_config SET split_over_limit = false;   -- pieces are s02's subject

\echo '--- A. the knobs'
SELECT listing_max_age, listing_grace FROM public.primary_poll_config;

INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-fresh', now(), 5)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-fresh', finished_at = now();

-- five events, each a different relation between its band, its last good read and its next
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, poll_attempt_at, poll_ok_at, next_poll_at, poll_interval, last_run,
        listing_count, order_min, order_max)
SELECT 'axs', v.id, v.nm, current_date + 30, now() + interval '30 days', 'Fresh Arena',
       'https://www.axs.com/events/'||v.id, 'ok', now() - v.read_ago, now() - v.read_ago,
       now() + v.next_in, v.band, 'run-fresh', 1, 1, 4
  FROM (VALUES
         -- THE FIX. An hour band, read 50 min ago, and the grid put its next slot only 10
         -- minutes after that read — so the old window closed at read+35, not read+80, and
         -- the event went dark 15 minutes ago on data we consider good for an hour.
         ('E-grid',  'Grid Aligned Soon', interval '50 minutes', -interval '40 minutes',interval '1 hour'),
         -- unchanged: read 5 minutes ago, nothing overdue
         ('E-ontime','Read Just Now',     interval '5 minutes',  interval '55 minutes', interval '1 hour'),
         -- still withheld: an hour band, read 95 minutes ago. The window is band + grace, not
         -- unbounded, so an event this far behind is withheld under the new rule too.
         ('E-late',  'Really Late',       interval '95 minutes', -interval '85 minutes',interval '1 hour'),
         -- the 35-minute floor still governs a band under 15 minutes: unchanged, which is
         -- what keeps the Timberwolves source's 10-minute band from being loosened
         ('E-short', 'Ten Minute Band',   interval '40 minutes', -interval '30 minutes',interval '10 minutes'),
         -- no band at all falls back to the floor (COALESCE), not to zero
         ('E-null',  'No Band Yet',       interval '30 minutes', -interval '20 minutes',NULL::interval)
       ) AS v(id, nm, read_ago, next_in, band)
ON CONFLICT (source, source_event_id) DO NOTHING;

INSERT INTO public.primary_poll_listing (source, source_event_id, listing_id, market, section, quantity,
        price, all_in_price, ticket_type, general_admission, obstructed, ada)
SELECT 'axs', e.source_event_id, 'L-'||e.source_event_id, 'primary', 'Floor', 4, 100, 110, 'STANDARD',
       false, false, false
  FROM public.primary_poll_event e WHERE e.source='axs' AND e.source_event_id LIKE 'E-%'
ON CONFLICT (source, source_event_id, listing_id) DO NOTHING;

\echo '--- B. what each event looks like'
SELECT source_event_id, poll_interval AS band,
       round(extract(epoch FROM now() - poll_ok_at)/60.0)::int AS read_min_ago,
       round(extract(epoch FROM next_poll_at - now())/60.0)::int AS next_in_min
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id LIKE 'E-%' ORDER BY 1;

\echo '--- C. the old window (poll_ok_at + 35 min) against the new (band + grace, floored)'
SELECT e.source_event_id,
       now() < greatest(e.poll_ok_at + c.listing_max_age, e.next_poll_at + c.listing_grace) AS old_rule,
       now() < greatest(e.poll_ok_at + greatest(c.listing_max_age,
                                                coalesce(e.poll_interval, interval '0') + c.listing_grace),
                        e.next_poll_at + c.listing_grace) AS new_rule
  FROM public.primary_poll_event e CROSS JOIN public.primary_poll_config c
 WHERE e.source='axs' AND e.source_event_id LIKE 'E-%' ORDER BY 1;

\echo '--- D. THE FIX, in the listings feed: E-grid is published, E-late is still withheld'
SELECT event_id, count(*) AS rows_sent
  FROM public.v_primary_poll_listings_feed WHERE source='axs' AND event_id LIKE 'E-%'
 GROUP BY event_id ORDER BY event_id;

\echo '--- E. the events feed agrees with it, so the two cannot disagree about one event'
SELECT event_id, listings_available, listings_withheld, listing_count
  FROM public.v_primary_poll_events_feed WHERE source='axs' AND event_id LIKE 'E-%' ORDER BY event_id;

-- (that the two config lookups stay UNCORRELATED scalar subqueries — one InitPlan for the
-- whole scan rather than a lookup per row — is a property of how the arm is written, not
-- something asserted here: plan text is not stable enough to diff.)
\echo '--- F. the arm is in BOTH views, and the floor is still read from config'
SELECT c.relname,
       pg_get_viewdef(c.oid, true) ~ 'COALESCE\(t\.poll_interval' AS band_relative,
       pg_get_viewdef(c.oid, true) ~ 'listing_max_age' AS keeps_the_floor
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relname IN ('v_primary_poll_events_feed','v_primary_poll_listings_feed')
 ORDER BY 1;

\echo '--- G. each view keeps its own reloptions: the events feed is security_invoker, the listings feed is not'
SELECT c.relname, coalesce(array_to_string(c.reloptions, ','), '-') AS reloptions
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relname IN ('v_primary_poll_events_feed','v_primary_poll_listings_feed')
 ORDER BY 1;
