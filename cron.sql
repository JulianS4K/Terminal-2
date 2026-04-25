-- pg_cron schedule for the collector Edge Function.
--
-- *** NOT YET APPLIED ***
-- Apply this ONLY after you've confirmed the collect function works manually.
-- Run it via Supabase Dashboard → SQL Editor.
--
-- Before running, replace:
--   <PROJECT_REF>   with: hzrizjeaxlqcxfrtczpq
--   <CRON_SECRET>   with: the same CRON_SECRET you set via `supabase secrets set`
--
-- You must first enable these extensions in:
-- Dashboard → Database → Extensions
--   * pg_cron
--   * pg_net

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Every hour at :15 past the hour. Change expression as desired:
--   '*/15 * * * *'   = every 15 minutes (aggressive)
--   '15 * * * *'     = hourly at :15
--   '0 */4 * * *'    = every 4 hours
select cron.schedule(
  'evo-collect',
  '15 * * * *',
  $cron$
    select net.http_post(
      url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/collect',
      headers := jsonb_build_object(
        'Content-Type',    'application/json',
        'X-Cron-Secret',   '<CRON_SECRET>'
      ),
      body    := '{}'::jsonb,
      timeout_milliseconds := 120000
    );
  $cron$
);

-- Ops commands for later:
--
--   -- list active jobs
--   select jobid, jobname, schedule, active from cron.job;
--
--   -- see recent runs
--   select * from cron.job_run_details order by start_time desc limit 10;
--
--   -- unschedule
--   select cron.unschedule('evo-collect');
--
--   -- change schedule
--   select cron.alter_job(
--     job_id   => (select jobid from cron.job where jobname = 'evo-collect'),
--     schedule => '*/30 * * * *'
--   );
