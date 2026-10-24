-- Migration 20260901160947 · level:admin · lane:A1 · operator-directed 2026-09-01
--   ("assume we pause AXS going forward"), scope confirmed this session.
--
--   writes: cron.job (4 jobs deactivated), retention_policy (2 NEW rows, DISABLED)
--   reads:  cron.job, axs_seat_snapshots, axs_event_snapshots
--
-- 1. PAUSE AXS COLLECTION
--
-- axs-probe-drain is the single largest consumer in the whole cron fleet:
-- measured over the live post-rollback window it ran every minute at ~34s
-- average, occupying 57.7% of wall-clock. Pausing it takes overall cron
-- concurrency from ~1.5 to ~0.9. The other three paused here are rounding
-- errors individually but are part of the same AXS pipeline.
--
-- DELIBERATELY LEFT ACTIVE — both are misfiled under the axs* name and are not
-- AXS work. Pattern-matching on the job name would have stopped unrelated
-- surfaces:
--   * axs-sg-url-anchor-backfill — body is UPDATE sg_events_canonical SET
--     sg_url = ..., i.e. pure SeatGeek URL backfill.
--   * axs-enroll-gt-tm — calls axs_enroll_gt_tm_from_match(), which enrolls
--     GoTickets/Ticketmaster into TicketsData. AXS-sourced but GT-serving, and
--     GoTickets is a current priority surface.
--
-- Nothing breaks. Pausing collection leaves the 8.9 GB of AXS data in place, so
-- every reader keeps working against data that simply stops advancing:
-- get_event_face (terminal event page), enrich_zone_price_observations,
-- rebuild_sg_market_chart, sg_match_map_tick, refresh_performer_primary_median,
-- record_source_freshness, match_to_aq_event_id.
--
-- 2. SEED AXS RETENTION, DISABLED
--
-- No retention_policy row has ever covered any AXS table, so both snapshot
-- tables have grown unbounded since 2026-06-09:
--   axs_seat_snapshots   6,091,321 rows / 4,532 MB  (~765 bytes/row)
--   axs_event_snapshots      5,752 rows / 4,375 MB  (~760 KB/row -- fat raw JSON)
--
-- Both rows are seeded enabled=false, following this project's established
-- handling for a table whose writer is dark (see the seatgeek_listings_snapshots
-- row and audit AUD-16): pausing the collector above makes these tables dark, and
-- switching on a TTL against a dark table is a one-way drain. Flip enabled=true
-- deliberately when you want the space back.
--
-- BATCH SIZING for axs_event_snapshots. At ~760 KB/row this table wants a batch
-- of a couple of hundred rows, but retention_policy_batch_rows_check enforces
-- batch_rows >= 1000, so 1000 is the floor available -- roughly 760 MB of churn
-- per batch. budget_seconds is therefore set to 30 (vs 90 for the seat table) so
-- the WALL-CLOCK budget, not the row count, is what bounds each tick. If that
-- still proves too coarse when enabled, the fix is a smaller keep_days or a
-- widened check constraint, not a larger budget.

DO $pause$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT jobid, jobname FROM cron.job
     WHERE jobname IN ('axs-probe-drain','axs-aq-backfill-6h',
                       'axs-performer-match','axs_to_tevo_search_bridge_13h')
       AND active
  LOOP
    PERFORM cron.alter_job(job_id := r.jobid, active := false);
    n := n + 1;
    RAISE NOTICE 'paused %', r.jobname;
  END LOOP;
  RAISE NOTICE 'paused % AXS collection job(s)', n;
END $pause$;

INSERT INTO public.retention_policy
  (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes)
VALUES
  ('axs_seat_snapshots', 'captured_at', 15, false, 50000, 90, 35,
   'AXS seat-level firehose - 15d, mirroring listings_snapshots / gotickets_listings_snapshots. '
   'Seeded DISABLED (mig 20260901160947): AXS collection was paused in the same migration, so this '
   'is a dark table and enabling a TTL now is a one-way drain (cf. seatgeek_listings_snapshots / AUD-16). '
   'At seed time 5,566,683 of 6,091,321 rows (91%) were older than 15d, ~4.1 GB reclaimable.'),
  ('axs_event_snapshots', 'captured_at', 30, false, 1000, 30, 36,
   'AXS event-level raw snapshots - 30d. Seeded DISABLED, same reasoning as axs_seat_snapshots. '
   'Rows average ~760 KB (fat raw JSON), so batch_rows sits at the schema floor of 1000 (~760 MB per '
   'batch) and budget_seconds is 30 so the wall-clock budget bounds each tick rather than the row count. '
   'At seed time 4,235 of 5,752 rows (74%) were older than 30d, ~3.2 GB reclaimable.')
ON CONFLICT (table_name) DO NOTHING;

DO $verify$
DECLARE v_still_active text; v_kept int; v_pol int;
BEGIN
  SELECT string_agg(jobname, ', ') INTO v_still_active
    FROM cron.job
   WHERE active AND jobname IN ('axs-probe-drain','axs-aq-backfill-6h',
                                'axs-performer-match','axs_to_tevo_search_bridge_13h');
  IF v_still_active IS NOT NULL THEN
    RAISE EXCEPTION 'AXS collection job(s) still active: %', v_still_active;
  END IF;

  SELECT count(*) INTO v_kept FROM cron.job
   WHERE active AND jobname IN ('axs-sg-url-anchor-backfill','axs-enroll-gt-tm');
  IF v_kept <> 2 THEN
    RAISE EXCEPTION 'the two deliberately-kept jobs are not both active (found %)', v_kept;
  END IF;

  SELECT count(*) INTO v_pol FROM public.retention_policy
   WHERE table_name IN ('axs_seat_snapshots','axs_event_snapshots') AND NOT enabled;
  IF v_pol <> 2 THEN
    RAISE EXCEPTION 'expected 2 disabled AXS retention rows, found %', v_pol;
  END IF;
END $verify$;
