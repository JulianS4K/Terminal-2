CREATE OR REPLACE FUNCTION public.sub_finder_settle_pending()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r        record;
  v_done   integer := 0;
  v_open   integer := 0;
  v_failed integer := 0;
BEGIN
  IF NOT coalesce((SELECT c.enabled FROM public.sub_finder_config c), false) THEN
    RETURN jsonb_build_object('skipped', 'off');
  END IF;
  IF NOT public.cron_try_lock('sub_finder_settle') THEN RETURN jsonb_build_object('skipped', 'overlap'); END IF;
  -- Fair queue: least recently tried first, so no job (or key) can hold the head of it.
  -- A job that keeps failing is retried every 5 minutes instead of every round.
  FOR r IN SELECT job_id FROM public.sub_finder_job
            WHERE status <> 'done'
              AND (settle_fails < 5 OR settle_tried_at IS NULL OR settle_tried_at < now() - interval '5 minutes')
            ORDER BY settle_tried_at NULLS FIRST, created_at, job_id LIMIT 25
  LOOP
    BEGIN
      IF public.sub_finder_settle(r.job_id) = 'done' THEN v_done := v_done + 1; ELSE v_open := v_open + 1; END IF;
      UPDATE public.sub_finder_job SET settle_tried_at = clock_timestamp(), settle_fails = 0 WHERE job_id = r.job_id;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;                    -- one bad job never stops the rest
      UPDATE public.sub_finder_job SET settle_tried_at = clock_timestamp(), settle_fails = settle_fails + 1
       WHERE job_id = r.job_id;
    END;
  END LOOP;
  RETURN jsonb_build_object('done', v_done, 'open', v_open, 'failed', v_failed);
END
$function$

