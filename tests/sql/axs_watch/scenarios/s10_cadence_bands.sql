-- ONE cadence for the AXS watch (mig 20261125214500): the event's proximity band, scaled, set on a stable
-- per-event phase. Consolidates the two versions that were in flight — the flat 75-minute interval of
-- 20261125204500 (removed) and the 20/30/45 rungs of 20261125210000 — and is sized from measured
-- throughput rather than either reader's hardcoded numbers.
-- Also covers the daily limit on the Eastern day from the 250k cycle (mig 20261125205000).
\set QUIET on
\pset footer off
\pset null '-'
SET client_min_messages = warning;

\echo '--- A. the bands as seeded, and the scale'
SELECT band, max_days, every, sort_order, enabled FROM public.axs_watch_cadence ORDER BY sort_order;
SELECT cadence_scale, not_on_sale_every, hot_every FROM public.axs_watch_config;

\echo '--- B. the band an event falls in, by how close it is (no read needed: the function is pure)'
SELECT d AS days_out, public.axs_watch_cadence_every((now() + make_interval(mins => (d*1440)::int))::timestamptz, NULL) AS every
  FROM (VALUES (0.5),(1.9),(3.0),(6.9),(10.0),(13.9),(20.0),(29.9),(45.0),(59.9),(90.0),(119.9),(150.0),(179.0)) v(d);

\echo '--- C. the scale multiplies every band'
UPDATE public.axs_watch_config SET cadence_scale = 2.0;
SELECT d AS days_out, public.axs_watch_cadence_every((now() + make_interval(mins => (d*1440)::int))::timestamptz, NULL) AS every_at_scale_2
  FROM (VALUES (1.0),(10.0),(45.0),(150.0)) v(d);
UPDATE public.axs_watch_config SET cadence_scale = 1.0;

-- Each of the three reads carries a listing ON PURPOSE. mig 20261126214500 gives a read with
-- an EMPTY listings array the sold-out band (1 day, pinned, jittered rather than phase-aligned),
-- so an empty read here would stop this section testing bands and phases at all. The empty read
-- is s29's subject.
\echo '--- D. a read puts the event on its band, not on the shared ladder''s interval'
INSERT INTO public.primary_poll_source (source, current_run, finished_at, events)
VALUES ('axs', 'run-band', now(), 3)
ON CONFLICT (source) DO UPDATE SET current_run = 'run-band', finished_at = now();
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
VALUES ('axs','B1','Tomorrow Night',  (now() + interval '30 hours')::date, now() + interval '30 hours', 'Big Arena',
        'https://www.axs.com/events/B1', 'pending', now() - interval '1 hour', interval '6 hours', 'run-band'),
       ('axs','B2','Three Weeks Out', (now() + interval '21 days')::date,  now() + interval '21 days',  'Big Arena',
        'https://www.axs.com/events/B2', 'pending', now() - interval '1 hour', interval '6 hours', 'run-band'),
       ('axs','B3','Far Out',         (now() + interval '150 days')::date, now() + interval '150 days', 'Small Hall',
        'https://www.axs.com/events/B3', 'pending', now() - interval '1 hour', interval '10 minutes', 'run-band')
ON CONFLICT (source, source_event_id) DO NOTHING;
SELECT public.axs_watch_record('B1', 200, $j${"status":"ok","response_s":5.0,"quota_remaining":99990,"body":{"status":"ok","exit_code":0,"elapsed_seconds":5.0,"event":{"id":"B1"},"listings":[{"kind":"primary","section":"101","row":"A","seats":["1","2"],"quantity":2,"status":"Available","pricing":{"face":40,"fees_total":6,"tax":0,"all_in":46}}]}}$j$::jsonb) - 'request_id' AS read_b1;
SELECT public.axs_watch_record('B2', 200, $j${"status":"ok","response_s":5.0,"quota_remaining":99989,"body":{"status":"ok","exit_code":0,"elapsed_seconds":5.0,"event":{"id":"B2"},"listings":[{"kind":"primary","section":"101","row":"A","seats":["1","2"],"quantity":2,"status":"Available","pricing":{"face":40,"fees_total":6,"tax":0,"all_in":46}}]}}$j$::jsonb) - 'request_id' AS read_b2;
SELECT public.axs_watch_record('B3', 200, $j${"status":"ok","response_s":5.0,"quota_remaining":99988,"body":{"status":"ok","exit_code":0,"elapsed_seconds":5.0,"event":{"id":"B3"},"listings":[{"kind":"primary","section":"101","row":"A","seats":["1","2"],"quantity":2,"status":"Available","pricing":{"face":40,"fees_total":6,"tax":0,"all_in":46}}]}}$j$::jsonb) - 'request_id' AS read_b3;
SELECT source_event_id AS id, poll_interval,
       next_poll_at > now() AS in_future,
       -- the bound is due_slack + one interval, not one interval: mig 20261126023000 anchors the
       -- phase search at now() + due_slack so the chosen instant cannot land inside the window in
       -- which primary_poll_due would call the event due again. Asserting the narrower bound here
       -- failed about 3% of runs per event, whenever the phase instant fell in the last minute.
       next_poll_at > now() + (SELECT due_slack FROM public.primary_poll_config) AS clears_due_slack,
       next_poll_at <= now() + (SELECT due_slack FROM public.primary_poll_config) + poll_interval
         AS within_slack_plus_one_interval,
       (extract(epoch FROM next_poll_at)::bigint % extract(epoch FROM poll_interval)::bigint)
         = ((hashtext(source_event_id)::bigint & 2147483647) % extract(epoch FROM poll_interval)::bigint) AS on_its_own_phase
  FROM public.primary_poll_event WHERE source='axs' AND source_event_id IN ('B1','B2','B3') ORDER BY 1;

\echo '--- E. "not on sale" still wins over the band'
INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_utc, venue_name,
        ticket_url, poll_status, next_poll_at, poll_interval, last_run)
VALUES ('axs','B4','Not On Sale', (now() + interval '40 days')::date, now() + interval '40 days', 'Small Hall',
        'https://www.axs.com/events/B4', 'pending', now() - interval '1 hour', interval '6 hours', 'run-band')
ON CONFLICT (source, source_event_id) DO NOTHING;
SELECT public.axs_watch_record('B4', 200, $j${"status":"ok","response_s":4.0,"quota_remaining":99987,"body":{"status":"error","exit_code":1,"error":"Tickets are not currently on sale for this event"}}$j$::jsonb) - 'request_id' AS read_b4;
SELECT source_event_id AS id, poll_interval FROM public.primary_poll_event WHERE source='axs' AND source_event_id='B4';

\echo '--- F. p_charge: the extension''s reads settle without spending a credit'
SELECT public.axs_watch_settle_one('B3', 200, $j${"body":{"status":"ok","exit_code":0,"event":{"id":"B3"},"listings":[]}}$j$::jsonb,
                                   false, NULL, false, 'the AXS page') ->> 'outcome' AS settled_unmetered;
SELECT count(*) AS credits_charged_for_axs_fetch
  FROM public.ticketsdata_credit_usage WHERE endpoint = '/fetch';

\echo '--- G. the demand report: the ladder against measured throughput and the day''s cap'
SELECT (public.axs_watch_cadence_demand()) - 'usable_per_hour' - 'daily_cap' - 'pct_of_throughput' - 'pct_of_daily_cap' - 'fits' AS demand_shape;

\echo '--- H. the daily limit is the Eastern day and comes from the cycle (mig 20261125205000)'
SELECT (SELECT monthly_credits FROM public.axs_watch_config) AS cycle_credits,
       (public.axs_watch_budget()->>'daily_cap')::int
         = floor(((public.axs_watch_budget()->>'pool_remaining')::numeric
                  - (SELECT reserve_credits FROM public.axs_watch_config))
                 / (public.axs_watch_budget()->>'days_left')::numeric) AS cap_is_cycle_paced,
       public.td_daily_budget_ok() AS daily_ok;
-- Two charges either side of EASTERN midnight, stated in Eastern so the assertion does not move with the UTC
-- clock. An earlier form of this put a charge at "today 02:00Z", which is the previous Eastern day only while
-- the UTC clock is past 05:00Z — so the test stopped demonstrating anything after midnight UTC.
INSERT INTO public.ticketsdata_credit_usage (called_at, credits, platform, endpoint, status_code)
VALUES ((date_trunc('day', now() AT TIME ZONE 'America/New_York') - interval '1 hour') AT TIME ZONE 'America/New_York',
        1000, 'AXS', '/fetch', 200),
       ((date_trunc('day', now() AT TIME ZONE 'America/New_York') + interval '1 hour') AT TIME ZONE 'America/New_York',
            7, 'AXS', '/fetch', 200);
SELECT public.td_credits_today() AS eastern_day_counts,
       (SELECT coalesce(sum(credits),0) FROM public.ticketsdata_credit_usage
         WHERE (called_at AT TIME ZONE 'America/New_York')::date
             < (now() AT TIME ZONE 'America/New_York')::date) AS credits_before_eastern_midnight,
       (SELECT coalesce(sum(credits),0) FROM public.ticketsdata_credit_usage) AS credits_in_the_ledger;
