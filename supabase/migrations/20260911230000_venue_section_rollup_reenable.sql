-- Already applied to prod · via MCP 2026-09-11 under operator direction.
-- Migration 20260911230000 · level:cron · lane:A1 · writes:cron.job(venue_section_rollup_hourly),cron_policy · reads:venue_section_rollup_state,venue_section_price_daily · pre:20260705153500,20260705153000
--
-- ============================================================================
-- Migration 20260911230000 — restart the venue-section daily rollup
--
-- Lane:     A1 (data plane — crons)
-- Touches:  cron.job (venue_section_rollup_hourly → active=true),
--           cron_policy (W: min-interval 60→55 for that job + notes)
-- Pre-reqs: 20260705153500 (the rollup + catchup + aggs), 20260705153000 (cron_policy gate)
--
-- ── WHAT WAS TRUE BEFORE ───────────────────────────────────────────────────
-- Measured on prod 2026-09-11 20:30 UTC:
--   cron.job.active            = false  (jobid 479)
--   last successful fire       = 2026-07-29 23:52 UTC
--   venue_section_price_daily  = stops dead at snapshot_date 2026-07-29
--   venue_section_rollup_state = last sealed day 2026-07-29
-- The job was turned off OUT OF BAND — no migration in the tree references it,
-- which is precisely the failure mode mig 20260705153000 was written to end for
-- the retention sweeps ("the ENABLED FLAG IS THE KILL SWITCH … no more per-job
-- cron.alter_job toggles with no migration trail"). The command body was never
-- touched: only `active` was flipped, so re-activating restores exact prior
-- behaviour, nothing is re-authored here.
--
-- The deadman DID see it — health_check_history has been logging
-- check_name='venue_section_rollup_hourly' status='off' every ~5 min for 44 days
-- — but 'off' is not an alerting state in record_cron_deadman(), so it never
-- escalated. (Making 'off' escalate is a separate A1 call, deliberately NOT
-- bundled here.)
--
-- ── WHY THIS IS TIME-CRITICAL ──────────────────────────────────────────────
-- venue_section_price_daily is INDEFINITE-retention (RESOURCES_BIBLE §2.14) and
-- is built FROM section_metrics, which retention_policy deletes at 60 days.
-- Every unrolled day is recoverable only until its raw ages out:
--   first unrolled day        2026-07-30
--   its section_metrics dies  2026-09-28  (07-30 + 60d)
-- After that one permanent day of venue-section history is lost per day. The
-- catchup window is trailing-70d (today-70 = 2026-07-03), so the whole 43-day
-- backlog is still inside BOTH windows today.
--
-- Restart cost is unchanged from when it last ran: section_metrics is 5× bigger
-- than in July (44 GB vs 8.1 GB) purely from 60d accumulation — per-DAY volume
-- is flat (2026-07-30: 3,260,617 rows; 2026-09-10: 3,366,085), and the rollup
-- reads one day at a time through idx_section_metrics_captured.
--
-- ── THE MIN-INTERVAL FIX (why 55, not 60) ──────────────────────────────────
-- cron_should_fire() skips when now() - (last decision='fire') < min_interval,
-- strictly. With min_interval == the schedule period, a few hundred ms of start
-- jitter puts the gap at 59.7-60.0 min and the fire is dropped, so an hourly job
-- runs every OTHER hour. Measured on retention_tick_hourly over 7 days: 103
-- fires / 65 skips, every skip gap between 59.70 and 60.00 min.
-- This job carried the same 60/60 policy, so re-enabling it at 60 would drain
-- the backlog at half rate and then hold today's rollup to every-2-hours
-- forever. 55 gives the gate 5 minutes of jitter headroom while still blocking
-- a genuine double-fire. Scoped to THIS job only — the same bug affects ~12
-- others (incl. three weekly price-coefficient jobs now firing biweekly); that
-- sweep is a separate operator call, not smuggled in here.
--
-- Backlog drain is NOT done by this migration: catchup does today + up to 2
-- missing days per fire, bounded by a 300s wall clock. Draining 43 days is a
-- supervised operator step (venue_section_rollup_catchup with a wider p_max_days)
-- run after this lands.
--
-- Reversible: cron.alter_job(479, active := false) + restore min-interval 60.
-- Idempotent: re-apply is a no-op. No data is written or deleted here.
-- ============================================================================

-- ── 1. Turn it back on (by name — jobid 479 today, don't hard-code) ────────
DO $do$
DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'venue_section_rollup_hourly';
  IF v_jobid IS NULL THEN
    RAISE EXCEPTION 'venue_section_rollup_hourly is not scheduled — re-run mig 20260705153500 §6 first';
  END IF;
  PERFORM cron.alter_job(v_jobid, active := true);
END $do$;

-- ── 2. Give the gate jitter headroom so "hourly" is actually hourly ────────
UPDATE public.cron_policy
   SET peak_min_interval_min    = 55,
       offpeak_min_interval_min = 55,
       enabled                  = true,
       notes = 'Venue-section daily median rollup (today refresh + <=2 backfill days per fire, 300s budget). '
            || 'RESTARTED 2026-09-11 (mig 20260911230000) after 44 days off (out-of-band cron.alter_job on 2026-07-29; '
            || 'venue_section_price_daily froze at snapshot_date 2026-07-29). '
            || 'min-interval is 55 NOT 60 on purpose: cron_should_fire compares against the last fire strictly, so a '
            || '60-minute floor on a 60-minute schedule drops every other fire to start-time jitter (59.70-60.00 min gaps). '
            || 'Do NOT raise it back to 60.',
       updated_at = now()
 WHERE jobname = 'venue_section_rollup_hourly';

-- ── 3. Self-check: it is on, gated sanely, and the backlog is still rollable ─
DO $do$
DECLARE
  v_active     boolean;
  v_interval   int;
  v_last_day   date;
  v_oldest_raw timestamptz;
  v_backlog    int;
BEGIN
  SELECT active INTO v_active FROM cron.job WHERE jobname = 'venue_section_rollup_hourly';
  IF NOT coalesce(v_active, false) THEN
    RAISE EXCEPTION 'venue_section_rollup_hourly is still inactive';
  END IF;

  SELECT least(peak_min_interval_min, offpeak_min_interval_min) INTO v_interval
    FROM public.cron_policy WHERE jobname = 'venue_section_rollup_hourly';
  IF v_interval IS NULL OR v_interval >= 60 THEN
    RAISE EXCEPTION 'min-interval % would re-introduce the every-other-hour skip', v_interval;
  END IF;

  -- The backlog must still be inside BOTH the 70d catchup window and the raw TTL,
  -- otherwise turning the job on would start sealing empty days as if they held data.
  SELECT max(snapshot_date) INTO v_last_day FROM public.venue_section_rollup_state;
  SELECT min(captured_at)   INTO v_oldest_raw FROM public.section_metrics;
  v_backlog := ((now() AT TIME ZONE 'utc')::date - v_last_day) - 1;

  IF v_last_day + 1 < v_oldest_raw::date THEN
    RAISE EXCEPTION
      'raw for the first unrolled day (%) has already aged out of section_metrics (oldest %) — rolling it now would seal an EMPTY day; escalate before enabling',
      v_last_day + 1, v_oldest_raw::date;
  END IF;
  IF v_last_day < (now() AT TIME ZONE 'utc')::date - 70 THEN
    RAISE EXCEPTION 'backlog starts % which is outside the trailing-70d catchup window', v_last_day + 1;
  END IF;

  RAISE NOTICE 'venue_section_rollup_hourly ON · backlog % days (% .. %) · raw available from %',
    v_backlog, v_last_day + 1, (now() AT TIME ZONE 'utc')::date - 1, v_oldest_raw::date;
END $do$;
