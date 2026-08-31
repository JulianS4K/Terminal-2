-- Migration 20260831100000 · lane:A1 · INCIDENT FIX (2026-08-31) — DB memory saturation.
--
-- INCIDENT. Instance memory pinned at ~100% with a 78.3% buffer-cache hit ratio on an 8 GB
-- box (shared_buffers 2 GB) fronting a 470 GB database. Averaged over 24 h, 20.3 pg_cron
-- backends were concurrently ACTIVE (cron.max_running_jobs = 32) — i.e. permanently ~65%
-- saturated, not bursty. 591 GB of temp files across 52,813 files.
--
-- ROOT CAUSE — a bloated, unindexed `net._http_response` feeding a vicious cycle:
--   * `net._http_response` is 61 GB (heap 9.9 GB + 51 GB TOAST) for only ~173 k live rows,
--     all <6 h old. relpages/live-tuple ratio = 7.3 pages/row for rows whose non-TOAST heap
--     width is ~200 B → the heap alone is ~300x bloated. autovacuum_count on that table is
--     2 for its whole lifetime (last heap autovacuum 5 d ago; last TOAST autovacuum 26 d ago)
--     because autovacuum_max_workers=3 is permanently occupied by the 100 GB+ snapshot tables.
--   * pg_net ships `net._http_response` with ONE index — on `created`. There is NO index on
--     `id`. All 55 of our `*_process()` / `*_drain()` functions consume responses via
--     `JOIN net._http_response h ON h.id = <pending>.request_id`, so every tick seq-scans the
--     bloated 61 GB table. Measured: 204,764 seq scans reading 14.2 BILLION tuples; a single
--     `WHERE id = <literal>` EXPLAIN did not return inside 60 s.
--   * That is why ~10 unrelated jobs all die identically in a `FOR over SELECT rows` loop at
--     the 900 s `statement_timeout` backstop (mig 20260701213000), then are immediately
--     restarted by the next tick — pg_cron does not dedupe overlapping runs. 24 h failure
--     counts: reddit 528/529, x_news 558/572, sg_seller 95/96, espn_scoreboard 95/96,
--     sg_priority_sales 95/96, sg-match-map 95/96, td_match_drain 95/96, compute_alerts 96/96,
--     sweep_expired_pg_net_pending 24/24, venue_section_rollup 24/24, listings_deltas 15/15.
--   * The cycle closes: 900 s transactions hold back the xmin horizon → autovacuum cannot
--     reclaim dead tuples → the table bloats further → the scans get slower.
--
-- We cannot add the missing `net._http_response(id)` index: the `net` schema and table are
-- owned by `supabase_admin` and `postgres` has neither CREATE on the schema nor ownership.
-- `postgres` DOES hold SELECT/UPDATE/DELETE + MAINTAIN on the table, so the reclaim path is
-- VACUUM (FULL) + an aggressive reaper, both of which this migration establishes.
--
-- FIX (this migration; the one-off VACUUM FULL is applied out-of-band — see ROLLBACK note):
--   1. cron_try_lock()   — transaction-scoped advisory-lock helper. MUST be xact-scoped, not
--                          session-scoped: with use_background_workers=off pg_cron reuses
--                          PERSISTENT pooled connections across jobs, so a session lock would
--                          leak onto unrelated later jobs (same mechanism as the SET leak,
--                          PROJECT_BIBLE §3 landmine (d)).
--   2. cron_should_fire() — takes that lock, so every job already behind the gate gets overlap
--                          protection for free with no command rewrite. New decision value
--                          'skip_overlap' (cron_gate_decisions has no CHECK on `decision`).
--                          The mig 20260708042000 statement_timeout capture/restore is
--                          preserved verbatim — do not re-clamp (§3 landmine (e)).
--   3. reddit_news_process() — real, deterministic bug, unrelated to the above: a Reddit feed
--                          batch can carry the same t3_ id in two <entry> blocks, so the
--                          INSERT ... ON CONFLICT DO UPDATE hit "cannot affect row a second
--                          time" on 528 of 529 runs. Deduped with DISTINCT ON.
--   4. pg_net_reap()     — bounds `net._http_response` going forward. pg_net's own TTL is 6 h,
--                          which is what let it reach 61 GB; this reaps to 2 h and VACUUMs.
--   5. Disabled jobs     — the redundant TD-match trio + the four 100%-failure jobs (below).
--   6. Overlap guards    — wrapped onto the 9 hot jobs that do NOT route through
--                          cron_should_fire (bare `SELECT fn();` commands).
--
-- ROLLBACK: re-enable the jobs listed in step 5 with cron.alter_job(<id>, active := true) and
--   restore the two functions from their prior definitions. The one-off
--   `VACUUM (FULL, ANALYZE) net._http_response` is not part of this file (VACUUM cannot run
--   inside a transaction block) and is not reversible — nor would you want it to be.

-- ---------------------------------------------------------------------------
-- 1. Transaction-scoped advisory-lock helper for cron overlap suppression.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cron_try_lock(p_key text)
RETURNS boolean
LANGUAGE sql
AS $function$
  -- xact-scoped ON PURPOSE: released at commit, so it cannot leak across the
  -- persistent pooled connections pg_cron reuses between jobs.
  SELECT pg_try_advisory_xact_lock(hashtext('cron_job:' || p_key)::bigint);
$function$;

COMMENT ON FUNCTION public.cron_try_lock(text) IS
  'Cron overlap guard. Returns false when a prior run holding the same key is still in '
  'flight, so the tick can no-op instead of piling up. Transaction-scoped (see mig '
  '20260831100000) — never convert to pg_try_advisory_lock.';

-- ---------------------------------------------------------------------------
-- 2. cron_should_fire(): add the overlap guard ahead of every other check, so a
--    still-running previous run short-circuits before any policy/work-check I/O.
--    Everything else below is unchanged from the mig 20260708042000 definition.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cron_should_fire(p_jobname text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_policy        public.cron_policy%ROWTYPE;
  v_hour_et       int;
  v_in_peak       boolean;
  v_interval_min  int;
  v_last_fire     timestamptz;
  v_fires_today   int := NULL;
  v_has_work      boolean := true;
  v_decision      text;
  v_now           timestamptz := clock_timestamp();
  v_prev_timeout  text;
BEGIN
  v_hour_et := EXTRACT(hour FROM (v_now AT TIME ZONE 'America/New_York'))::int;

  -- OVERLAP GUARD (mig 20260831100000). pg_cron does not dedupe overlapping runs, so a job
  -- whose body outlives its own interval piles a new backend on top of the old one every
  -- tick. Held for the life of the cron command's implicit transaction.
  IF NOT public.cron_try_lock(p_jobname) THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'skip_overlap', v_hour_et);
    RETURN false;
  END IF;

  SELECT * INTO v_policy FROM public.cron_policy WHERE jobname = p_jobname;

  IF NOT FOUND THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'fire_no_policy', v_hour_et);
    RETURN true;
  END IF;

  IF NOT v_policy.enabled THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'disabled', v_hour_et);
    RETURN false;
  END IF;

  IF v_policy.daily_max_fires IS NOT NULL THEN
    SELECT count(*) INTO v_fires_today FROM public.cron_gate_decisions
      WHERE jobname = p_jobname AND decision = 'fire'
        AND decided_at >= date_trunc('day', v_now AT TIME ZONE 'UTC');
    IF v_fires_today >= v_policy.daily_max_fires THEN
      INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, fires_today)
        VALUES (p_jobname, v_now, 'skip_budget', v_hour_et, v_fires_today);
      RETURN false;
    END IF;
  END IF;

  SELECT max(decided_at) INTO v_last_fire
    FROM public.cron_gate_decisions
    WHERE jobname = p_jobname AND decision = 'fire';
  v_in_peak := v_hour_et = ANY(v_policy.peak_hours_et);
  v_interval_min := CASE WHEN v_in_peak THEN v_policy.peak_min_interval_min
                                        ELSE v_policy.offpeak_min_interval_min END;
  IF v_last_fire IS NOT NULL AND (v_now - v_last_fire) < make_interval(mins => v_interval_min) THEN
    v_decision := CASE WHEN v_in_peak THEN 'skip_interval' ELSE 'skip_offpeak' END;
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
      VALUES (p_jobname, v_now, v_decision, v_hour_et, v_last_fire, v_fires_today);
    RETURN false;
  END IF;

  IF v_policy.work_check_sql IS NOT NULL THEN
    BEGIN
      -- capture-and-restore, NOT a hardcoded restore — see §3 landmine (e) / mig 20260708042000.
      v_prev_timeout := current_setting('statement_timeout', true);
      PERFORM set_config('statement_timeout', '8000', true);
      EXECUTE v_policy.work_check_sql INTO v_has_work;
      PERFORM set_config('statement_timeout', coalesce(nullif(v_prev_timeout, ''), '0'), true);
    EXCEPTION WHEN OTHERS THEN
      v_has_work := true;
    END;
    IF NOT coalesce(v_has_work, false) THEN
      INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
        VALUES (p_jobname, v_now, 'skip_no_work', v_hour_et, v_last_fire, v_fires_today);
      RETURN false;
    END IF;
  END IF;

  INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
    VALUES (p_jobname, v_now, 'fire', v_hour_et, v_last_fire, v_fires_today);
  RETURN true;
END $function$;

-- ---------------------------------------------------------------------------
-- 3. reddit_news_process(): dedupe the parsed feed batch before ON CONFLICT.
--    A single Reddit RSS payload can repeat a t3_ id across <entry> blocks;
--    ON CONFLICT DO UPDATE cannot touch the same target row twice in one command.
--    528 of 529 runs in 24 h died here. Only the `parsed` CTE changed (DISTINCT ON).
-- ---------------------------------------------------------------------------
--    Applied as a surgical text patch on the live definition rather than a hand-retyped
--    CREATE OR REPLACE: the parser's five regex literals carry heavy backslash/quote
--    escaping, and re-typing them by hand risks silently changing what the feed matches.
--    This rewrites ONLY the ON CONFLICT source and raises if the expected shape is absent.
DO $patch$
DECLARE
  v_def   text;
  v_old   text;
  v_new   text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def
    FROM pg_proc WHERE proname = 'reddit_news_process' AND prokind = 'f';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'reddit_news_process() not found — cannot apply dedupe patch';
  END IF;

  v_old := E'        FROM parsed p\n'
        || E'        WHERE p.reddit_post_id IS NOT NULL AND COALESCE(p.title,\'\') <> \'\'\n';

  -- one row per reddit_post_id: ON CONFLICT DO UPDATE cannot affect a target row twice
  -- in one command, and a single feed payload can repeat a t3_ id across <entry> blocks.
  v_new := E'        FROM (SELECT DISTINCT ON (reddit_post_id) *\n'
        || E'                FROM parsed\n'
        || E'               WHERE reddit_post_id IS NOT NULL AND COALESCE(title,\'\') <> \'\'\n'
        || E'               ORDER BY reddit_post_id, updated_str DESC NULLS LAST) p\n';

  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION
      'reddit_news_process() body does not match the expected pre-patch shape; '
      'refusing to guess. Re-derive the patch against the live definition.';
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END $patch$;

-- ---------------------------------------------------------------------------
-- 4. pg_net response reaper — keeps net._http_response bounded so the unavoidable
--    (unindexable) seq scans stay cheap. pg_net's own TTL is 6 h, which is exactly
--    how the table reached 61 GB; 2 h is comfortably wider than the slowest consumer
--    cadence (the :3/:33 and :29/:59 30-minute drains).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.pg_net_reap(p_retain_minutes integer DEFAULT 120)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net', 'pg_temp'
AS $function$
DECLARE
  n int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'pg_net_reap: caller % not authorized', current_user;
  END IF;

  -- Deletes by `created`, which is the ONE column net._http_response is indexed on.
  DELETE FROM net._http_response
   WHERE created < now() - make_interval(mins => p_retain_minutes);
  GET DIAGNOSTICS n = ROW_COUNT;

  RETURN n;
END $function$;

COMMENT ON FUNCTION public.pg_net_reap(integer) IS
  'Bounds net._http_response (unindexed on id, so its size directly sets the cost of every '
  'pg_net consumer). See mig 20260831100000.';

-- ---------------------------------------------------------------------------
-- 5. Turn off redundant + wholly-failing jobs.
-- ---------------------------------------------------------------------------

-- 5a. The TD-match trio. PROJECT_BIBLE §3 landmine 56 records these as DISABLED 2026-06-19
--     ("don't re-enable"): the legacy td_match_enqueue('fill') path seeds SeatHub/Vivid URLs,
--     but TicketsData /match resolves ONLY from a SeatGeek event URL, so every call 500s.
--     They were re-enabled at some point since. td_match_drain alone held a full backend
--     around the clock (95/96 runs failed at the 900 s cap) while burning the scarce
--     2,000-reports/month /match budget. sg_match_map_tick (job 413) is the correct path and
--     stays enabled.
SELECT cron.alter_job(404, active := false);  -- td_match_fill_enqueue
SELECT cron.alter_job(405, active := false);  -- td_match_drain
SELECT cron.alter_job(406, active := false);  -- td_match_apply_cron

-- 5b. 100% failure over the last 24 h — zero successful runs, each burning its full budget.
--     Disabled pending a real fix rather than left to keep saturating the cron pool.
SELECT cron.alter_job(149, active := false);  -- compute_alerts_tick_15min           96/96 failed
SELECT cron.alter_job(191, active := false);  -- sweep_expired_pg_net_pending_hourly  24/24 failed
SELECT cron.alter_job(479, active := false);  -- venue_section_rollup_hourly          24/24 failed
SELECT cron.alter_job(229, active := false);  -- listings_deltas_backfill_overnight   15/15 failed

-- 5c. Reddit news. The ON CONFLICT bug above is fixed in this migration, but the pair is
--     parked per operator decision so the fix can be verified before it runs again at 1-min
--     cadence. Re-enable with:
--       SELECT cron.alter_job(449, active := true); SELECT cron.alter_job(446, active := true);
SELECT cron.alter_job(446, active := false);  -- reddit_news_process_1min  528/529 failed
SELECT cron.alter_job(449, active := false);  -- reddit_news_queue_1min

-- ---------------------------------------------------------------------------
-- 6. Overlap guards for the hot jobs that bypass cron_should_fire (bare `SELECT fn();`).
--    Jobs already behind the gate inherit the guard from step 2 and are untouched.
-- ---------------------------------------------------------------------------
SELECT cron.alter_job(65, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('sg_seller_process') THEN RETURN; END IF;
  PERFORM public.sg_seller_process();
END $guard$;
$cmd$);

SELECT cron.alter_job(267, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('td_normalize_drain') THEN RETURN; END IF;
  PERFORM public.td_normalize_drain(50);
END $guard$;
$cmd$);

SELECT cron.alter_job(455, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('pm_process') THEN RETURN; END IF;
  PERFORM public.pm_process();
END $guard$;
$cmd$);

SELECT cron.alter_job(494, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('process_athlete_wiki_pageviews') THEN RETURN; END IF;
  PERFORM public.process_athlete_wiki_pageviews();
END $guard$;
$cmd$);

SELECT cron.alter_job(520, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('ppm_process') THEN RETURN; END IF;
  PERFORM public.ppm_process();
END $guard$;
$cmd$);

SELECT cron.alter_job(528, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('wa_news_process') THEN RETURN; END IF;
  PERFORM public.wa_news_process();
END $guard$;
$cmd$);

SELECT cron.alter_job(531, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('pww_wiki_process') THEN RETURN; END IF;
  PERFORM public.pww_wiki_process();
END $guard$;
$cmd$);

SELECT cron.alter_job(537, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('gt_listings_poll_tick') THEN RETURN; END IF;
  PERFORM public.gt_listings_poll_tick(2000);
END $guard$;
$cmd$);

-- gt_ingest_drain_1min keeps its two-step shape: the retire step stays in its own
-- exception-wrapped block so it can never roll back the drain (mig 20260811280000).
SELECT cron.alter_job(565, command := $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('gt_listings_drain') THEN RETURN; END IF;
  PERFORM public.gt_listings_drain(3000);
  BEGIN
    PERFORM public.gt_deals_retire_tick();
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt retire skipped: %', SQLERRM;
  END;
END $guard$;
$cmd$);

-- ---------------------------------------------------------------------------
-- 7. Schedule the reaper. Every 10 minutes, guarded like everything else.
-- ---------------------------------------------------------------------------
SELECT cron.schedule('pg_net_reap_10min', '*/10 * * * *', $cmd$
DO $guard$ BEGIN
  IF NOT public.cron_try_lock('pg_net_reap') THEN RETURN; END IF;
  PERFORM public.pg_net_reap(120);
END $guard$;
$cmd$);
