-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-08 00:11 UTC.
--
-- Cron: every 5 min, fire one backfill batch (~150 events, 50s wall budget).
-- Self-terminates when nothing left to backfill since OR query returns empty.
SELECT cron.schedule(
  'backfill-event-configurations-5min',
  '*/5 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/backfill-event-configurations',
    headers := '{"Content-Type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6cml6amVheGxxY3hmcnRjenBxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY5NjE3ODgsImV4cCI6MjA5MjUzNzc4OH0.c-rIrhb-WLzyWAAN1Yf_zJXWnu0E_zZ2XDB_T7urvNc"}'::jsonb,
    body := '{"all_chat_tracked": true, "limit": 150}'::jsonb,
    timeout_milliseconds := 60000
  );
  $$
);
