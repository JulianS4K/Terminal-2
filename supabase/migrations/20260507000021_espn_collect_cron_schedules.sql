-- pg_cron schedules for espn-collect v5 scoped runs.
--
-- Cadence (per user 2026-05-07):
--   roster      every 10 min       -> per-team injuries
--   gameday     every 10 min       -> event scores+odds for events occurring within ±24h
--                                     (offset by 5 min so the two 10-min crons don't fire simultaneously)
--   team_daily  daily 05:00 UTC    -> standings + news
--
-- Auth: same shared secret as collect-listings ('pick-any-random-string-and-save-it').
--
-- Idempotent: drops any prior cron with the same name before re-creating.
-- Applied to prod 2026-05-07 via MCP.

select cron.unschedule('espn-rosters-10min')  where exists (select 1 from cron.job where jobname='espn-rosters-10min');
select cron.unschedule('espn-collect-daily')  where exists (select 1 from cron.job where jobname='espn-collect-daily');
select cron.unschedule('espn-roster-10min')   where exists (select 1 from cron.job where jobname='espn-roster-10min');
select cron.unschedule('espn-gameday-10min')  where exists (select 1 from cron.job where jobname='espn-gameday-10min');
select cron.unschedule('espn-team-daily')     where exists (select 1 from cron.job where jobname='espn-team-daily');

-- 10-min injury sweep
select cron.schedule(
  'espn-roster-10min',
  '*/10 * * * *',
  $cron$
  select net.http_post(
    url     := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=roster',
    headers := jsonb_build_object('Content-Type','application/json','X-Cron-Secret','pick-any-random-string-and-save-it'),
    body    := '{}'::jsonb,
    timeout_milliseconds := 90000
  );
  $cron$
);

-- 10-min gameday sweep (offset by 5 min to spread load)
select cron.schedule(
  'espn-gameday-10min',
  '5-59/10 * * * *',
  $cron$
  select net.http_post(
    url     := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=gameday',
    headers := jsonb_build_object('Content-Type','application/json','X-Cron-Secret','pick-any-random-string-and-save-it'),
    body    := '{}'::jsonb,
    timeout_milliseconds := 90000
  );
  $cron$
);

-- Daily team standings + news at 05:00 UTC
select cron.schedule(
  'espn-team-daily',
  '0 5 * * *',
  $cron$
  select net.http_post(
    url     := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-collect?scope=team_daily',
    headers := jsonb_build_object('Content-Type','application/json','X-Cron-Secret','pick-any-random-string-and-save-it'),
    body    := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
  $cron$
);
