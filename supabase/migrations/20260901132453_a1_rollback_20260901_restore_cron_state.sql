-- ROLLBACK STEP 2/3 (operator-directed full rollback to the 2026-08-29 state).
--
-- Restores cron.job to exactly the fleet that was active before
-- 20260831120000_pause_all_crons.sql, the first migration of the branch:
--   * every job in public.rollback_20260901_manifest  -> active
--   * every other pre-existing job                    -> inactive
--   * the 5 jobs the branch CREATED                   -> unscheduled
--   * sg_seller_process_30min schedule                -> '1-59/4 * * * *'
--     (20260831160000 changed it to '1-59/20'; that migration records the
--      prior value in its own comment, which is the source used here)
--
-- Post-condition asserts the resulting active set equals the manifest exactly.

DO $rollback$
DECLARE
  r record;
  v_id bigint;
  n_on int := 0; n_off int := 0; n_unsched int := 0;
  v_active int; v_expected int; v_extra text;
BEGIN
  -- 1. Unschedule the jobs this branch created. None of them appear in the
  --    manifest, so on 2026-08-29 they did not exist at all.
  FOR r IN
    SELECT jobid, jobname FROM cron.job
     WHERE jobname IN ('event_mapping_queue_tick',
                       'sweep_news_images_hourly',
                       'evo_map_gotickets_daily',
                       's4k_orders_drain_10min',
                       's4k_orders_queue_hourly')
  LOOP
    PERFORM cron.unschedule(r.jobid);
    n_unsched := n_unsched + 1;
    RAISE NOTICE 'unscheduled branch-created job %', r.jobname;
  END LOOP;

  -- 2. Everything the manifest lists goes back on.
  FOR r IN
    SELECT j.jobid, j.jobname FROM cron.job j
     JOIN public.rollback_20260901_manifest m ON m.jobname = j.jobname
    WHERE NOT j.active
  LOOP
    PERFORM cron.alter_job(job_id := r.jobid, active := true);
    n_on := n_on + 1;
  END LOOP;

  -- 3. Everything else goes off.
  FOR r IN
    SELECT j.jobid, j.jobname FROM cron.job j
     WHERE j.active
       AND NOT EXISTS (SELECT 1 FROM public.rollback_20260901_manifest m
                        WHERE m.jobname = j.jobname)
  LOOP
    PERFORM cron.alter_job(job_id := r.jobid, active := false);
    n_off := n_off + 1;
    RAISE NOTICE 'deactivated non-manifest job %', r.jobname;
  END LOOP;

  -- 4. Restore the one schedule the branch rewrote.
  SELECT jobid INTO v_id FROM cron.job WHERE jobname = 'sg_seller_process_30min';
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'sg_seller_process_30min not found';
  END IF;
  PERFORM cron.alter_job(job_id := v_id, schedule := '1-59/4 * * * *');

  RAISE NOTICE 'rollback: % activated, % deactivated, % unscheduled', n_on, n_off, n_unsched;

  -- 5. Post-condition: active set == manifest, exactly.
  SELECT count(*) INTO v_active   FROM cron.job WHERE active;
  SELECT count(*) INTO v_expected FROM public.rollback_20260901_manifest;
  IF v_active <> v_expected THEN
    RAISE EXCEPTION 'post-condition failed: % active jobs, manifest has %', v_active, v_expected;
  END IF;

  SELECT string_agg(jobname, ', ') INTO v_extra
    FROM (
      SELECT j.jobname FROM cron.job j
       WHERE j.active AND NOT EXISTS (SELECT 1 FROM public.rollback_20260901_manifest m WHERE m.jobname = j.jobname)
      UNION ALL
      SELECT m.jobname FROM public.rollback_20260901_manifest m
       WHERE NOT EXISTS (SELECT 1 FROM cron.job j WHERE j.jobname = m.jobname AND j.active)
    ) s;
  IF v_extra IS NOT NULL THEN
    RAISE EXCEPTION 'post-condition failed: active set differs from manifest: %', v_extra;
  END IF;

  -- 6. The PROJECT_BIBLE §3 don't-re-enable list must remain off. None of these
  --    are in the manifest, so step 3 already turned them off; assert it.
  IF EXISTS (SELECT 1 FROM cron.job
              WHERE active
                AND jobname IN ('td_match_fill_enqueue','td_match_drain',
                                'td_match_apply_cron','auto_match_sg_canonical_v3_hourly'))
  THEN
    RAISE EXCEPTION 'post-condition failed: a PROJECT_BIBLE §3 prohibited job is active';
  END IF;
END
$rollback$;
