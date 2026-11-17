-- Migration 20260831182614 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "sweep_news_image_urls" (version 20260831182614) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

CREATE OR REPLACE FUNCTION public.sweep_news_image_urls(
  p_age_hours  int DEFAULT 24,
  p_batch_rows int DEFAULT 20000
) RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE n int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'sweep_news_image_urls: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  WITH victims AS (
    SELECT ctid
      FROM public.espn_news
     WHERE image_url IS NOT NULL
       AND first_seen_at < now() - make_interval(hours => p_age_hours)
     LIMIT p_batch_rows
  )
  UPDATE public.espn_news e
     SET image_url = NULL
    FROM victims v
   WHERE e.ctid = v.ctid;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END
$fn$;

REVOKE ALL ON FUNCTION public.sweep_news_image_urls(int,int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sweep_news_image_urls(int,int) TO service_role;

COMMENT ON FUNCTION public.sweep_news_image_urls(int,int) IS
  'Nulls espn_news.image_url older than p_age_hours (default 24). Row and text content are untouched; only the image URL is dropped. Service-only. Operator directive 2026-08-31.';

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, enabled, notes)
VALUES
  ('sweep_news_images_hourly', '{}', 60, 60, 24, true,
   'Ages espn_news.image_url out at 24h, hourly. Added 2026-08-31 per operator "sweep images out more often".')
ON CONFLICT (jobname) DO UPDATE
  SET peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = EXCLUDED.enabled,
      notes = EXCLUDED.notes,
      updated_at = now();

SELECT cron.unschedule('sweep_news_images_hourly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sweep_news_images_hourly');

SELECT cron.schedule('sweep_news_images_hourly', '33 * * * *', $sched$
DO $b$ BEGIN
  IF NOT public.cron_should_fire('sweep_news_images_hourly') THEN RETURN; END IF;
  PERFORM public.sweep_news_image_urls(24, 20000);
END $b$;
$sched$);
;
