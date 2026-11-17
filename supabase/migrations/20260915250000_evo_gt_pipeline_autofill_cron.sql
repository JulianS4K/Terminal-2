-- Migration 20260915250000 · level:data-collection · lane:A1 · writes:evo_gt_pipeline_run_log,cron_policy,cron.job,evo_gt_venue_link,evo_gt_event_pair,gotickets_event · reads:v_evo_us_ca_event,v_gt_us_ca_event,tevo_event_pull_state · pre:20260915240000
-- ⚠ NOT YET APPLIED TO PROD. Written while the Supabase connector was unauthorised, so none of
-- this has been executed or verified. Apply and verify before trusting it; the "VERIFIED ON APPLY"
-- block at the bottom is deliberately empty until that happens.
--
-- Operator: "just auto fill everything going forward and improve mapper as we go."
--
-- Until now the pipeline has only ever run because I ran it by hand. That is fine for a build-out
-- and useless as a steady state: cron 653 pulls fresh TEvo events every morning, and without this
-- they simply accumulate unmapped until somebody notices.
--
-- ============================================================================================
-- WHY IT RUNS AFTER THE INGEST, NOT ON ITS OWN CLOCK
-- ============================================================================================
-- The mapper's input is the mirror. Running it before cron 653's daily delta pass has finished
-- maps yesterday's catalogue and then sits idle for 24 hours while today's arrivals wait. So the
-- work_check requires that EVERY country has completed its delta pass TODAY, and the schedule sits
-- at 12:20 UTC — after 653's 06:00–11:59 window closes. If the ingest is late or stalled, this
-- does not fire at all rather than mapping a half-updated mirror.
--
-- 08:20 ET is deliberately outside the selling day. peak_hours_et names noon ET onward so that a
-- future reschedule cannot quietly drag a multi-minute table rebuild into the evening book, and
-- daily_max_fires caps it at two even if something re-triggers it.
--
-- ============================================================================================
-- WHY BOTH STEPS, IN THAT ORDER, EVERY TIME
-- ============================================================================================
-- The venue map is not static. Every new venue the ingest discovers is a venue the mapper cannot
-- use until evo_gt_venue_link_build runs again, and today proved the cost of a stale venue map is
-- not marginal: one bad crosswalk row left Crypto.com Arena, Intuit Dome, SoFi Stadium, Petco Park
-- and Hard Rock Stadium unlinked, and with them every event at those buildings.
--
-- Both functions rebuild their whole table (DELETE + INSERT) inside one transaction, so a reader
-- either sees the previous map or the new one, never a partial one.
--
-- The writer still only fills NULLs and still refuses a TEvo event another GoTickets row already
-- claims. Running daily does not relax that: an automated mapper that overwrites is how a wrong
-- mapping becomes permanent and unattributable.
--
-- ============================================================================================
-- THE RUN LOG IS THE "IMPROVE AS WE GO" HALF
-- ============================================================================================
-- Each tick stores both functions' full JSONB results. That turns the rejection buckets into a
-- time series: if `not_mutual_best` or `ambiguous_sibling` starts climbing, the mapper is losing
-- ground on a shape it used to handle, and the pair table still holds the losers to read. Without
-- this, the only record of a daily run is that it did not error.
--
-- Today's baseline, for the first comparison: accepted 26,612 · different_local_day 22,793 ·
-- not_mutual_best 6,237 · ambiguous_sibling 1,613 · below_threshold 605 · guard_subtitle 500 ·
-- guard_ordinals 230 · venue links 3,460.
--
-- Failures are NOT in the run log and cannot be. The whole tick is one transaction, so an
-- exception rolls the log insert back along with everything else -- a column for the error text
-- would never hold one. cron.job_run_details is where a failed tick is recorded.
--
-- ============================================================================================
-- THE COLLAPSE GUARD -- what changes when nobody is watching
-- ============================================================================================
-- evo_gt_venue_link_build DELETEs the entire venue map and rebuilds it. Every time I ran it today
-- I read the returned count before doing anything else, so a collapse could not have gone
-- unnoticed. On a schedule there is no such reader.
--
-- Anything that transiently empties an input -- a view returning nothing, a half-applied
-- migration, an ingest that truncated the mirror -- would wipe the map and, through it, every
-- mapping the matcher could have made that day. It would do so silently, and then again tomorrow.
--
-- So the tick counts the links before and after, and RAISES if the map lost more than a fifth of
-- itself. Because the whole tick is one transaction, raising rolls the DELETE back: the previous
-- map survives and the failure is loud. A growing map never trips it, and the guard is skipped
-- entirely below 100 links so a first run on an empty table is not blocked.

CREATE TABLE IF NOT EXISTS public.evo_gt_pipeline_run_log (
  id            bigserial PRIMARY KEY,
  ran_at        timestamptz NOT NULL DEFAULT now(),
  duration_ms   int,
  venue_result  jsonb,
  match_result  jsonb
);

COMMENT ON TABLE public.evo_gt_pipeline_run_log IS
  'One row per SUCCESSFUL automated EVO->GoTickets pipeline tick, storing both stages'' full JSONB results so the rejection buckets become a time series. A daily mapper whose only record is "did not error" cannot be improved -- you need to see which bucket is growing. Failures are NOT here and cannot be: the whole tick is one transaction, so an exception rolls this insert back with everything else. Read cron.job_run_details for those (mig 20260915250000).';

CREATE INDEX IF NOT EXISTS evo_gt_pipeline_run_log_ran_at_idx
  ON public.evo_gt_pipeline_run_log (ran_at DESC);

CREATE OR REPLACE FUNCTION public.evo_gt_pipeline_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_t0 timestamptz := clock_timestamp();
  v_venue jsonb; v_match jsonb;
  v_links_before int; v_links_after int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'evo_gt_pipeline_tick: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '900000', true);

  -- Venue map first, always. A new venue is invisible to the matcher until the link exists.
  SELECT count(*) INTO v_links_before FROM public.evo_gt_venue_link;
  v_venue := public.evo_gt_venue_link_build(true);
  SELECT count(*) INTO v_links_after FROM public.evo_gt_venue_link;

  -- COLLAPSE GUARD. evo_gt_venue_link_build DELETEs the whole table and rebuilds it. Run by hand
  -- that is safe, because a human reads the returned count before moving on. Run unattended it is
  -- not: anything that transiently empties an input -- a view returning nothing, a half-applied
  -- migration, an ingest that truncated the mirror -- would wipe the venue map, and with it every
  -- mapping the matcher could have made that day, silently and on a schedule.
  --
  -- Raising here rolls the DELETE back, because the whole tick is one transaction. A shrinking
  -- map is a real signal worth failing loudly on; a growing one never trips this.
  IF v_links_before > 100 AND v_links_after < (v_links_before * 0.8)::int THEN
    RAISE EXCEPTION
      'evo_gt_pipeline_tick: venue map collapsed % -> % (< 80%%), refusing to publish; nothing written',
      v_links_before, v_links_after;
  END IF;

  v_match := public.evo_gt_pipeline_match(true);

  INSERT INTO public.evo_gt_pipeline_run_log (duration_ms, venue_result, match_result)
  VALUES ((extract(epoch FROM (clock_timestamp() - v_t0)) * 1000)::int, v_venue, v_match);

  RETURN jsonb_build_object('venue', v_venue, 'match', v_match);
END $fn$;

REVOKE ALL ON FUNCTION public.evo_gt_pipeline_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_pipeline_tick() TO service_role;

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES (
  'evo_gt_pipeline_tick',
  ARRAY[12,13,14,15,16,17,18,19,20,21,22,23,0],
  1440, 60,
  -- Both conditions matter. The first refuses to map a mirror that today's ingest has not
  -- finished updating; the second stops a daily rebuild of two whole tables when there is nothing
  -- left to bind. Base table, not the view, so the check stays sub-millisecond.
  $wc$SELECT NOT EXISTS (SELECT 1 FROM public.tevo_event_pull_state
                          WHERE daily_done_at IS NULL OR daily_done_at::date < current_date)
         AND EXISTS (SELECT 1 FROM public.gotickets_event
                      WHERE tevo_event_id IS NULL AND event_time_utc >= now() LIMIT 1)$wc$,
  2,
  true,
  'Daily EVO->GoTickets auto-fill: rebuilds the 1-1 venue map, then re-runs the +/-24h window and name match, writing only into GoTickets rows that have no TEvo event yet. Gated on today''s TEvo delta pass having completed for every country (mig 20260915250000).',
  now())
ON CONFLICT (jobname) DO UPDATE SET
  peak_hours_et = EXCLUDED.peak_hours_et,
  peak_min_interval_min = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql = EXCLUDED.work_check_sql,
  daily_max_fires = EXCLUDED.daily_max_fires,
  enabled = EXCLUDED.enabled,
  notes = EXCLUDED.notes,
  updated_at = now();

-- 12:20 UTC = 08:20 ET, after cron 653's 06:00-11:59 UTC ingest window closes.
-- Minute 20 avoids the saturated :02 / :05 / :07 marks.
SELECT cron.schedule(
  'evo_gt_pipeline_tick',
  '20 12 * * *',
  $cron$
DO $b$ BEGIN
  IF NOT public.cron_should_fire('evo_gt_pipeline_tick') THEN RETURN; END IF;
  PERFORM public.evo_gt_pipeline_tick();
END $b$;
$cron$);

-- VERIFIED ON APPLY: (pending -- not yet applied)
