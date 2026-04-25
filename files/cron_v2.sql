-- ============================================================
-- pg_cron schedule for v2 listings-based pipeline
-- ============================================================
-- Apply ONLY after confirming the collect-listings edge function
-- works end-to-end via manual invocation.
--
-- Prereqs:
--   1. pg_cron and pg_net extensions enabled (Dashboard > Database > Extensions)
--   2. Edge function `collect-listings` deployed
--   3. Substitute <PROJECT_REF> and <CRON_SECRET> below
--
-- Runs:
--   Every 20 min:   events occurring within 24 hours
--   Every 1 hour:   events occurring in 1-7 days
--   Every 4 hours:  events occurring in 7-30 days
--   Every 12 hours: events occurring in 30-60 days
--   Every 24 hours: events occurring 60+ days out
--   Nightly:        sweep listings older than 60 days
-- ============================================================

-- Drop existing jobs (safe to re-run)
select cron.unschedule('collect-listings-0-24h')   where exists (select 1 from cron.job where jobname = 'collect-listings-0-24h');
select cron.unschedule('collect-listings-1-7d')    where exists (select 1 from cron.job where jobname = 'collect-listings-1-7d');
select cron.unschedule('collect-listings-7-30d')   where exists (select 1 from cron.job where jobname = 'collect-listings-7-30d');
select cron.unschedule('collect-listings-30-60d')  where exists (select 1 from cron.job where jobname = 'collect-listings-30-60d');
select cron.unschedule('collect-listings-60d+')    where exists (select 1 from cron.job where jobname = 'collect-listings-60d+');
select cron.unschedule('sweep-old-listings')       where exists (select 1 from cron.job where jobname = 'sweep-old-listings');

-- 0-24 hours: every 20 minutes
select cron.schedule(
  'collect-listings-0-24h',
  '*/20 * * * *',
  $$
  select net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/collect-listings?window=0-24h',
    headers := '{"X-Cron-Secret": "<CRON_SECRET>", "Content-Type": "application/json"}'::jsonb,
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
  $$
);

-- 1-7 days: every 1 hour
select cron.schedule(
  'collect-listings-1-7d',
  '5 * * * *',   -- offset :05 to avoid collisions with :00 jobs
  $$
  select net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/collect-listings?window=1-7d',
    headers := '{"X-Cron-Secret": "<CRON_SECRET>", "Content-Type": "application/json"}'::jsonb,
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
  $$
);

-- 7-30 days: every 4 hours
select cron.schedule(
  'collect-listings-7-30d',
  '10 */4 * * *',
  $$
  select net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/collect-listings?window=7-30d',
    headers := '{"X-Cron-Secret": "<CRON_SECRET>", "Content-Type": "application/json"}'::jsonb,
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
  $$
);

-- 30-60 days: every 12 hours
select cron.schedule(
  'collect-listings-30-60d',
  '15 */12 * * *',
  $$
  select net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/collect-listings?window=30-60d',
    headers := '{"X-Cron-Secret": "<CRON_SECRET>", "Content-Type": "application/json"}'::jsonb,
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
  $$
);

-- 60+ days: every 24 hours at 02:20
select cron.schedule(
  'collect-listings-60d+',
  '20 2 * * *',
  $$
  select net.http_post(
    url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/collect-listings?window=60d%2B',
    headers := '{"X-Cron-Secret": "<CRON_SECRET>", "Content-Type": "application/json"}'::jsonb,
    body    := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
  $$
);

-- Nightly retention sweep at 03:00
select cron.schedule(
  'sweep-old-listings',
  '0 3 * * *',
  $$ select sweep_old_listings(); $$
);

-- Verify
select jobid, schedule, command from cron.job where jobname like 'collect-listings-%' or jobname = 'sweep-old-listings';
