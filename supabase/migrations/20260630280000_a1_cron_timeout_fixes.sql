-- ============================================================================
-- Migration 20260630280000 — cron statement-timeout fixes (post-redesign load)
--
-- Lane:     A1
-- Touches:  compute_alerts_tick() (read MV not live view), sweep_old_sg_listings() (tighter batching),
--           cron commands event_snapshot_{morning,midday,evening} (per-job statement_timeout).
-- Pre-reqs: mv_event_price_vol (refreshed by mv_event_price_vol_refresh, cols identical to v_event_price_vol),
--           idx_sg_listings_captured on seatgeek_listings_snapshots(captured_at).
--
-- WHY (operator 2026-06-30 "investigate + fix non-ok crons"): the TD sourcing redesign (6/29–6/30) grew
-- snapshot volume + DB load, pushing several aggregation/retention jobs past the 120s cron statement_timeout.
--   1. compute_alerts_tick (worst: ~68% fail today) builds a temp table from the LIVE v_event_price_vol,
--      which recomputes price-volatility over all snapshot history every 15min. mv_event_price_vol is the
--      already-maintained materialized form (refreshed 8-59/15, ~3min before this job) with IDENTICAL columns
--      — read it instead. ~no freshness change, large cost drop.
--   2. event_snapshot_{morning,midday,evening} (daily, feed price charts, 0% today): one big INSERT…SELECT
--      that now exceeds the default 120s. Raise per-job statement_timeout to 8min — daily jobs holding a
--      worker slot for a few minutes once/day is acceptable.
--   3. sweep_old_sg_listings: already batched but a single large batch could block; shrink batch
--      10k→3k, tighten the internal time budget 90s→45s (well under the 150s cron cap), and add a
--      per-batch lock_timeout so write-contention aborts a batch fast and the loop retries next tick
--      instead of blocking to the statement timeout.
--
-- DEFERRED (need a maintenance-window index build that exceeds the 60s MCP exec cap, filed for operator):
--   • sweep_old_section_metrics — section_metrics (57M rows) has NO standalone captured_at index (only
--     composites leading with event_id), so `WHERE captured_at < cutoff` seq-scans 57M rows. Needs
--     CREATE INDEX idx_section_metrics_captured ON section_metrics(captured_at) built off-MCP.
--   • listings_deltas_backfill_overnight — chronic (15/15 fail 5+ days, pre-redesign); its ranking scans
--     `WHERE prev_*_price IS NULL` over 15–18M-row tables need partial indexes (also a large build).
--
-- Idempotent (CREATE OR REPLACE + cron.alter_job by name). Re-apply is a no-op.
-- ============================================================================

-- 1. compute_alerts_tick: read the materialized mv_event_price_vol instead of the live view.
CREATE OR REPLACE FUNCTION public.compute_alerts_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_fired jsonb := '{}'::jsonb; v_n int;
BEGIN
  CREATE TEMP TABLE _vol ON COMMIT DROP AS SELECT * FROM public.mv_event_price_vol;

  CREATE TEMP TABLE _sig ON COMMIT DROP AS
    SELECT 'getin_zscore_move'::text AS rule_key, v.tevo_event_id,
      (v.days_n>=7 AND v.sigma_daily_pct>0 AND abs(v.move_z_24h)>=2.5 AND abs(v.getin_d24h_pct)>=4) AS fire,
      (abs(v.move_z_24h) < 1.0) AS clr,
      (CASE WHEN abs(v.move_z_24h)>=4 THEN 'critical' WHEN abs(v.move_z_24h)>=3 THEN 'warn' ELSE 'info' END)::text AS severity,
      format('Get-in %s %s%% in 24h = %s sigma move (typical %s%%/day) -> $%s',
        CASE WHEN v.getin_d24h_pct>=0 THEN 'UP' ELSE 'DOWN' END,
        round(v.getin_d24h_pct,1), v.move_z_24h, v.sigma_daily_pct, v.getin_now::int) AS message,
      jsonb_build_object('move_pct',v.getin_d24h_pct,'z',v.move_z_24h,'sigma_pct',v.sigma_daily_pct,'getin',v.getin_now) AS payload
    FROM _vol v
    UNION ALL
    SELECT 'getin_breakout', v.tevo_event_id,
      (v.days_n>=7 AND (v.breakout_up OR v.breakout_down)),
      (NOT v.breakout_up AND NOT v.breakout_down),
      'info',
      format('Get-in broke 14d %s: $%s (prior %s $%s)',
        CASE WHEN v.breakout_up THEN 'HIGH' ELSE 'LOW' END, v.getin_now::int,
        CASE WHEN v.breakout_up THEN 'high' ELSE 'low' END,
        CASE WHEN v.breakout_up THEN v.peak_prior ELSE v.low_prior END::int),
      jsonb_build_object('getin',v.getin_now,'peak_prior',v.peak_prior,'low_prior',v.low_prior,
        'dir',CASE WHEN v.breakout_up THEN 'up' ELSE 'down' END)
    FROM _vol v
    UNION ALL
    SELECT 'getin_trailing_drawdown', v.tevo_event_id,
      (v.days_n>=7 AND v.drawdown_from_peak_pct >= greatest(12, 2.5*v.sigma_daily_pct)),
      (v.drawdown_from_peak_pct < greatest(8, 1.5*v.sigma_daily_pct)),
      'warn',
      format('Get-in down %s%% from 14d peak $%s -> $%s (trailing stop)',
        v.drawdown_from_peak_pct, v.peak_14d::int, v.getin_now::int),
      jsonb_build_object('drawdown_pct',v.drawdown_from_peak_pct,'peak',v.peak_14d,'getin',v.getin_now)
    FROM _vol v
    UNION ALL
    SELECT 'competing_event_added', ecs.tevo_event_id,
      (ecs.competitors_count >= 5),
      (ecs.competitors_count < 3),
      'info',
      format('Crowded market: %s competing events within +/-24h x 20mi', ecs.competitors_count),
      jsonb_build_object('competitors_count', ecs.competitors_count, 'competitors', ecs.competitors)
    FROM public.event_competitors_snapshot ecs
    UNION ALL
    SELECT 'cross_source_mispricing', arb.tevo_event_id,
      (arb.tevo_retail_median>0 AND arb.sg_all_median>0 AND arb.tevo_listings_count>=3 AND arb.sg_listings_count>=3
        AND abs(arb.sg_all_median - arb.tevo_retail_median)/arb.tevo_retail_median >= 0.30),
      (coalesce(abs(arb.sg_all_median - arb.tevo_retail_median)/NULLIF(arb.tevo_retail_median,0), 0) < 0.20),
      (CASE WHEN arb.tevo_retail_median>0 AND abs(arb.sg_all_median-arb.tevo_retail_median)/arb.tevo_retail_median>=0.40 THEN 'warn' ELSE 'info' END),
      format('Cross-source gap %s%%: SG median $%s vs TEvo $%s (%s cheaper)',
        round(abs(arb.sg_all_median-arb.tevo_retail_median)/NULLIF(arb.tevo_retail_median,0)*100),
        arb.sg_all_median::int, arb.tevo_retail_median::int,
        CASE WHEN arb.sg_all_median < arb.tevo_retail_median THEN 'SG' ELSE 'TEvo' END),
      jsonb_build_object('tevo_median',arb.tevo_retail_median,'sg_median',arb.sg_all_median,
        'gap_pct', round(abs(arb.sg_all_median-arb.tevo_retail_median)/NULLIF(arb.tevo_retail_median,0)*100,1),
        'cheaper', CASE WHEN arb.sg_all_median < arb.tevo_retail_median THEN 'sg' ELSE 'tevo' END)
    FROM public.v_event_price_arbitrage arb;

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT s.rule_key, s.tevo_event_id, s.severity, s.message, s.payload
  FROM _sig s
  LEFT JOIN public.alert_state st ON st.rule_key=s.rule_key AND st.tevo_event_id=s.tevo_event_id
  WHERE s.fire AND coalesce(st.is_active,false)=false
    AND _alert_dedupe_ok(s.rule_key, s.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('hysteresis_rules_fired', v_n);

  INSERT INTO public.alert_state(rule_key, tevo_event_id, is_active, last_fired_at, updated_at)
  SELECT s.rule_key, s.tevo_event_id, true, now(), now()
  FROM _sig s
  LEFT JOIN public.alert_state st ON st.rule_key=s.rule_key AND st.tevo_event_id=s.tevo_event_id
  WHERE s.fire AND coalesce(st.is_active,false)=false
  ON CONFLICT (rule_key, tevo_event_id) DO UPDATE SET is_active=true, last_fired_at=now(), updated_at=now();

  UPDATE public.alert_state st SET is_active=false, updated_at=now()
  FROM _sig s
  WHERE st.rule_key=s.rule_key AND st.tevo_event_id=s.tevo_event_id AND st.is_active AND s.clr;

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'tevo_inventory_low_48h', e.id, 'warn',
    format('Inventory low: %s tickets, event in %s hours',
      lem.tickets_count, round(extract(epoch from (e.occurs_at_local::timestamptz - now()))/3600)),
    jsonb_build_object('tickets', lem.tickets_count, 'occurs_at', e.occurs_at_local)
  FROM events e JOIN latest_event_metrics lem ON lem.event_id = e.id
  WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '48 hours'
    AND lem.tickets_count < 25 AND lem.tickets_count > 0
    AND _alert_dedupe_ok('tevo_inventory_low_48h', e.id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_inventory_low_48h', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'espn_status_change', x.tevo_event_id, 'critical',
    format('ESPN status: %s', ee.status_short),
    jsonb_build_object('espn_status', ee.status_short, 'state', ee.state, 'captured_at', ee.captured_at)
  FROM event_xref x
  JOIN LATERAL (SELECT * FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1) ee ON true
  WHERE lower(ee.status_short) IN ('postponed','delayed','canceled','cancelled','suspended')
    AND _alert_dedupe_ok('espn_status_change', x.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('espn_status_change', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'line_movement_24h', lm.tevo_event_id, 'info',
    format('Line moved: home win-prob %s -> %s (%s pts)',
      round(lm.home_winp_24h_ago::numeric, 3), round(lm.home_winp_now::numeric, 3),
      round((lm.home_winp_now - lm.home_winp_24h_ago)::numeric, 3)),
    jsonb_build_object('home_winp_now', lm.home_winp_now, 'home_winp_24h_ago', lm.home_winp_24h_ago,
      'spread_now', lm.spread_now, 'spread_24h_ago', lm.spread_24h_ago)
  FROM v_event_line_movement lm
  WHERE lm.home_winp_24h_ago IS NOT NULL AND lm.home_winp_now IS NOT NULL
    AND abs(lm.home_winp_now - lm.home_winp_24h_ago) >= 0.10
    AND _alert_dedupe_ok('line_movement_24h', lm.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('line_movement_24h', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'primary_flip_opportunity', pv.tevo_event_id, 'info',
    format('Flip vs face: secondary get-in $%s is %s%% over AXS face $%s (%s)',
      pv.best_secondary_getin::int, pv.flip_margin_pct, pv.axs_primary_getin::int, pv.event_name),
    jsonb_build_object('axs_face', pv.axs_primary_getin, 'secondary_getin', pv.best_secondary_getin,
      'flip_margin', pv.flip_margin, 'flip_margin_pct', pv.flip_margin_pct)
  FROM v_event_primary_vs_secondary pv
  WHERE pv.signal = 'secondary_premium' AND pv.flip_margin_pct >= 25
    AND _alert_dedupe_ok('primary_flip_opportunity', pv.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('primary_flip_opportunity', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'secondary_below_face', pv.tevo_event_id, 'warn',
    format('Secondary $%s is %s%% BELOW AXS face $%s (%s) - dump risk',
      pv.best_secondary_getin::int, pv.flip_margin_pct, pv.axs_primary_getin::int, pv.event_name),
    jsonb_build_object('axs_face', pv.axs_primary_getin, 'secondary_getin', pv.best_secondary_getin,
      'flip_margin', pv.flip_margin, 'flip_margin_pct', pv.flip_margin_pct)
  FROM v_event_primary_vs_secondary pv
  WHERE pv.signal = 'below_face' AND pv.flip_margin_pct <= -10
    AND _alert_dedupe_ok('secondary_below_face', pv.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('secondary_below_face', v_n);

  RETURN jsonb_build_object('fired_counts', v_fired, 'ran_at', now());
END; $function$;

-- 2. sweep_old_sg_listings: smaller batch + tighter budget + per-batch lock_timeout (graceful retry).
CREATE OR REPLACE FUNCTION public.sweep_old_sg_listings(p_hours integer DEFAULT 48)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start  timestamptz := clock_timestamp();
  v_total  integer     := 0;
  v_batch  integer;
  v_locked boolean;
  v_cutoff timestamptz := now() - make_interval(hours => p_hours);
BEGIN
  SET LOCAL lock_timeout = '3s';
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '45 seconds';
    v_batch := 0; v_locked := false;
    BEGIN
      WITH to_delete AS (
        SELECT id FROM public.seatgeek_listings_snapshots
        WHERE captured_at < v_cutoff
        ORDER BY captured_at
        LIMIT 3000
      )
      DELETE FROM public.seatgeek_listings_snapshots
      WHERE id IN (SELECT id FROM to_delete);
      GET DIAGNOSTICS v_batch = ROW_COUNT;
    EXCEPTION WHEN lock_not_available THEN
      v_locked := true;            -- couldn't grab the lock this round; retry next iteration
    END;
    v_total := v_total + v_batch;
    EXIT WHEN (NOT v_locked AND v_batch = 0);   -- exit only when a clean batch found nothing to delete
  END LOOP;
  RETURN v_total;
END;
$function$;

-- 3. event_snapshot_{morning,midday,evening}: raise per-job statement_timeout to 8min (daily jobs).
DO $do$
DECLARE
  rec RECORD;
  slot text;
BEGIN
  FOR rec IN SELECT jobid, jobname FROM cron.job
             WHERE jobname IN ('event_snapshot_morning','event_snapshot_midday','event_snapshot_evening')
  LOOP
    slot := replace(rec.jobname, 'event_snapshot_', '');
    PERFORM cron.alter_job(
      job_id  := rec.jobid,
      command := format($cmd$DO $b$ BEGIN
      IF NOT public.cron_should_fire(%L) THEN RETURN; END IF;
      SET LOCAL statement_timeout = '8min';
      PERFORM public.compute_event_listing_snapshot(%L);
    END $b$;$cmd$, rec.jobname, slot)
    );
  END LOOP;
END $do$;
