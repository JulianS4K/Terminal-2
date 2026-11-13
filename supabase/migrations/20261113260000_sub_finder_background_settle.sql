-- Migration 20261113260000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_job,sub_finder_submit,sub_finder_bg_settle,sub_finder_settle_pending,sub_finder_job_json,sub_finder_order_read,sub_finder_results,cron:sub_finder_settle_15s · reads:sub_finder_job · pre:20261113220000
--
-- SUB FINDER: new lookups are settled by a background job, not by the CRM's read.
--
-- Found 2026-11-13 (system test + N2S dry run): a job only moved when it was read, and the
-- read did the matching. For a batch over several large events that first read ran past the
-- API role's statement timeout: 3 of 4 six-order batches answered 500 after about 9 seconds,
-- then succeeded on the next read. Mig 20261113220000 cut the match from 43 s to about the
-- limit, not safely under it.
--
--   sub_finder_settle_pending()   settles every job that is not done, one at a time (parallel
--                                 settles slowed each other), up to 25 a round. The queue is
--                                 fair: the job tried longest ago goes first
--                                 (sub_finder_job.settle_tried_at), so a job that stays open or
--                                 keeps failing cannot hold the head of the queue and starve
--                                 newer jobs or another key's. A job that fails is counted
--                                 (settle_fails) and, after 5 failures in a row, retried only
--                                 every 5 minutes.
--   sub_finder_submit             no longer settles inline when the listings are already fresh
--                                 (it did the same heavy match inside the POST); with the
--                                 switch on it leaves that to the background job too.
--   cron sub_finder_settle_15s    runs it every 15 seconds with a 120 s statement timeout.
--   sub_finder_config.bg_settle_enabled
--                                 when on, GET /jobs/{id}, GET /orders/{n} and the sync feed
--                                 no longer settle: they return the state as it stands, so a
--                                 read is always quick. An order reads `pending` until the
--                                 background job has answered it (about 20 to 40 seconds
--                                 after the listing pulls land). OFF by default: with it off
--                                 reads settle exactly as before, and the background job
--                                 only makes that settle rarer.
-- Nothing else changes: the same sub_finder_settle does the work either way, including the
-- TicketsData step and the automatic buy.
--
-- The three read functions and sub_finder_submit are patched in place; each patch fails loudly if its anchor is not
-- there exactly once, and does nothing on a second run.
--
-- rollback: UPDATE sub_finder_config SET bg_settle_enabled = false WHERE id = true;
--           SELECT cron.unschedule('sub_finder_settle_15s');
--           (full: re-apply the three read functions without the IF; DROP FUNCTION
--           public.sub_finder_settle_pending(), public.sub_finder_bg_settle();
--           ALTER TABLE public.sub_finder_config DROP COLUMN bg_settle_enabled.)

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS bg_settle_enabled boolean NOT NULL DEFAULT false;   -- reads no longer settle

ALTER TABLE public.sub_finder_job
  ADD COLUMN IF NOT EXISTS settle_tried_at timestamptz,                 -- last background attempt
  ADD COLUMN IF NOT EXISTS settle_fails    integer NOT NULL DEFAULT 0;  -- failures in a row

CREATE OR REPLACE FUNCTION public.sub_finder_bg_settle()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT coalesce((SELECT c.bg_settle_enabled FROM public.sub_finder_config c), false)
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_settle_pending()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.sub_finder_settle_pending(), public.sub_finder_bg_settle() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_settle_pending() TO service_role;

DO $patch$
DECLARE
  f     regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.sub_finder_job_json(bigint, uuid)'::regprocedure,
                           'public.sub_finder_order_read(bigint, uuid, text)'::regprocedure,
                           'public.sub_finder_results(bigint, timestamptz, integer, integer)'::regprocedure]
  LOOP
    v_def := pg_get_functiondef(f);
    IF position('sub_finder_bg_settle' IN v_def) > 0 THEN CONTINUE; END IF;   -- already patched
    IF f = 'public.sub_finder_results(bigint, timestamptz, integer, integer)'::regprocedure THEN
      v_old := $o$  FOR r IN SELECT job_id FROM public.sub_finder_job WHERE key_id = p_key_id AND status <> 'done' LOOP$o$;
      v_new := $n$  FOR r IN SELECT job_id FROM public.sub_finder_job
            WHERE key_id = p_key_id AND status <> 'done' AND NOT public.sub_finder_bg_settle() LOOP$n$;
    ELSE
      v_old := $o$  PERFORM public.sub_finder_settle(p_job_id);$o$;
      v_new := $n$  IF NOT public.sub_finder_bg_settle() THEN       -- else the background job settles it (20261113260000)
    PERFORM public.sub_finder_settle(p_job_id);
  END IF;$n$;
    END IF;
    IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
      RAISE EXCEPTION '%: the line to patch was not found exactly once', f;
    END IF;
    EXECUTE replace(v_def, v_old, v_new);
  END LOOP;
END
$patch$;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_submit(bigint, text, jsonb, text)'::regprocedure);
  v_old text := $o$    PERFORM public.sub_finder_settle(v_job);$o$;
  v_new text := $n$    IF NOT public.sub_finder_bg_settle() THEN     -- else the background job settles it (20261113260000)
      PERFORM public.sub_finder_settle(v_job);
    END IF;$n$;
BEGIN
  IF position('sub_finder_bg_settle' IN v_def) > 0 THEN RETURN; END IF;       -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_submit: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;

DO $cron$
BEGIN
  IF to_regclass('cron.job') IS NULL THEN RETURN; END IF;                     -- no pg_cron here (local / CI)
  EXECUTE $q$
    SELECT cron.schedule('sub_finder_settle_15s', '15 seconds',
                         $c$SET statement_timeout = '120s'; SELECT public.sub_finder_settle_pending();$c$)
     WHERE NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sub_finder_settle_15s')
  $q$;
END
$cron$;
