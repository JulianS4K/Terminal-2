-- Schedule crawl-espn-team-assets edge fn to drain the espn_asset_crawl_state queue.
-- Applied to prod 2026-05-08 ~23:30 UTC; this file captures it for git parity.
--
-- Why: the fn was deployed as v2 (copilot, captured into git earlier this session)
-- but had no cron driving it — leaving 104/169 performers pending without ESPN
-- logos / colors / venue assets. User asked for auto-population so logos are
-- available everywhere in the UI without manual triggers.
--
-- Cadence: every 3 minutes, processes up to 30 pending rows per tick → 104
-- backlog drains in ~12 min. After that the cron just keeps the queue fresh
-- as new performers land in espn_asset_crawl_state.
--
-- Auth: anon JWT in the Authorization header (matches existing pattern from
-- crawl-venues-and-performers-3min). The fn itself uses service-role for DB
-- writes via SUPABASE_SERVICE_ROLE_KEY env var.

SELECT cron.schedule(
  'crawl-espn-team-assets-3min',
  '*/3 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/crawl-espn-team-assets',
    headers := '{"Content-Type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6cml6amVheGxxY3hmcnRjenBxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY5NjE3ODgsImV4cCI6MjA5MjUzNzc4OH0.c-rIrhb-WLzyWAAN1Yf_zJXWnu0E_zZ2XDB_T7urvNc"}'::jsonb,
    body := '{"limit": 30}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
