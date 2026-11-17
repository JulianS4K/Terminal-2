CREATE OR REPLACE PROCEDURE public.sub_finder_settle_each()
 LANGUAGE plpgsql
AS $procedure$
DECLARE
  v_ids  uuid[];
  v_id   uuid;
  v_t0   timestamptz := clock_timestamp();
  v_lock bigint := hashtext('cron_job:sub_finder_settle')::bigint;
BEGIN
  IF NOT coalesce((SELECT c.enabled FROM public.sub_finder_config c), false) THEN RETURN; END IF;
  IF NOT pg_try_advisory_lock(v_lock) THEN RETURN; END IF;          -- one round at a time (session lock)
  SELECT array_agg(q.job_id) INTO v_ids FROM (
    SELECT job_id FROM public.sub_finder_job
     WHERE status <> 'done'
       AND (settle_fails < 5 OR settle_tried_at IS NULL OR settle_tried_at < now() - interval '5 minutes')
     ORDER BY settle_tried_at NULLS FIRST, created_at, job_id LIMIT 25) q;
  FOREACH v_id IN ARRAY coalesce(v_ids, '{}'::uuid[]) LOOP
    EXIT WHEN clock_timestamp() - v_t0 > interval '100 seconds';
    -- record the attempt first, and commit it: if the settle below never returns, the job has
    -- still been counted and goes to the back of the queue
    UPDATE public.sub_finder_job SET settle_tried_at = clock_timestamp(), settle_fails = settle_fails + 1
     WHERE job_id = v_id;
    COMMIT;
    BEGIN
      PERFORM public.sub_finder_settle(v_id);
      UPDATE public.sub_finder_job SET settle_fails = 0 WHERE job_id = v_id;
    EXCEPTION WHEN OTHERS THEN
      NULL;                                        -- already counted above; tried again in its turn
    END;
    COMMIT;
  END LOOP;
  PERFORM pg_advisory_unlock(v_lock);
END
$procedure$

