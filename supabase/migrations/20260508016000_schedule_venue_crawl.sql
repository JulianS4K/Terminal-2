-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 02:06 UTC.
--
-- Cron: every 3 minutes, fire one crawl batch (5 venues, ~50s wall budget).
-- Self-paces: function pulls oldest-crawled venues first, sweeps through all
-- ~159 venues in ~100 minutes, then keeps refreshing the oldest.

SELECT cron.schedule(
  'crawl-venues-and-performers-3min',
  '*/3 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/crawl-venues-and-performers',
    headers := '{"Content-Type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6cml6amVheGxxY3hmcnRjenBxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY5NjE3ODgsImV4cCI6MjA5MjUzNzc4OH0.c-rIrhb-WLzyWAAN1Yf_zJXWnu0E_zZ2XDB_T7urvNc"}'::jsonb,
    body := '{"venue_limit": 5, "events_per_venue": 25}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
