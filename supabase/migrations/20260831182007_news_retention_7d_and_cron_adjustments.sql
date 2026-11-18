-- Migration 20260831182007 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "news_retention_7d_and_cron_adjustments" (version 20260831182007) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

-- Migration 20260831160000 — 7d news retention, sg_seller cadence, pause X news
-- Full rationale: supabase/migrations/20260831160000_news_retention_7d_and_cron_adjustments.sql
UPDATE public.retention_policy
   SET keep_days = 7,
       notes = 'X news wire rows — 7d (operator 2026-08-31). Was 3d. NOTE: writer paused by this migration; table is empty.',
       updated_at = now()
 WHERE table_name = 'x_news';

INSERT INTO public.retention_policy
  (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes)
VALUES
  ('reddit_news', 'pulled_at', 7, true, 50000, 60, 100,
   'Reddit news wire rows — 7d (operator 2026-08-31). Writer live since mig 20260831150000.')
ON CONFLICT (table_name) DO UPDATE
  SET keep_days = EXCLUDED.keep_days, ts_column = EXCLUDED.ts_column,
      enabled = EXCLUDED.enabled, notes = EXCLUDED.notes, updated_at = now();

INSERT INTO public.retention_policy
  (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes)
VALUES
  ('reddit_news_pending', 'fired_at', 3, true, 50000, 60, 100,
   'Reddit news pg_net queue bookkeeping — 3d, mirrors x_news_pending. Added 2026-08-31 after audit found 120k unresolved rows back to 2026-07-21 with no policy.')
ON CONFLICT (table_name) DO UPDATE
  SET keep_days = EXCLUDED.keep_days, ts_column = EXCLUDED.ts_column,
      enabled = EXCLUDED.enabled, notes = EXCLUDED.notes, updated_at = now();

INSERT INTO public.retention_policy
  (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes)
VALUES
  ('espn_news', 'first_seen_at', 7, false, 50000, 60, 100,
   'ESPN news — 7d (operator 2026-08-31), seeded DISABLED: writer dark since 2026-08-19, all 14,016 rows exceed 7d, so enabling now empties the table and blanks the ticker ESPN feed. Mirrors seatgeek_listings_snapshots / AUD-16. Enable with the ESPN news ingest fix.')
ON CONFLICT (table_name) DO UPDATE
  SET keep_days = EXCLUDED.keep_days, ts_column = EXCLUDED.ts_column,
      notes = EXCLUDED.notes, updated_at = now();

DO $cron_adjust$
DECLARE
  v_id bigint;
BEGIN
  SELECT jobid INTO v_id FROM cron.job WHERE jobname = 'sg_seller_process_30min';
  IF v_id IS NULL THEN RAISE EXCEPTION 'sg_seller_process_30min not found'; END IF;
  PERFORM cron.alter_job(job_id := v_id, schedule := '1-59/20 * * * *');

  FOR v_id IN SELECT jobid FROM cron.job
               WHERE jobname IN ('x_news_process_1min','x_news_queue_1min') AND active
  LOOP
    PERFORM cron.alter_job(job_id := v_id, active := false);
  END LOOP;

  SELECT jobid INTO v_id FROM cron.job WHERE jobname = 'retention_tick_hourly' AND NOT active;
  IF v_id IS NOT NULL THEN
    PERFORM cron.alter_job(job_id := v_id, active := true);
  END IF;
END
$cron_adjust$;
;
