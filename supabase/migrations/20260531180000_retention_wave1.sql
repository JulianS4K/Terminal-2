-- ============================================================
-- Retention Wave 1 — operator-set ladder (raw 30d · event_metrics 120d ·
-- section_metrics 60d · rollup indefinite) + cap the previously-unbounded firehoses.
-- A1 2026-05-31 (cadence/retention plan Part C, Wave 1).
--
-- NOTE: VACUUM FULL net._http_response / evo_orders is DEFERRED to a quiet window —
-- it takes ACCESS EXCLUSIVE on net._http_response which the new high-cadence pollers
-- are actively using. Run separately off-peak.
-- ============================================================

-- ---- event_metrics TTL 7d -> 120d (keep listings_snapshots arm at 30d) ----
CREATE OR REPLACE FUNCTION public.sweep_old_listings(p_days integer DEFAULT 30)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_start timestamptz := clock_timestamp(); v_ls_count int := 0; v_em_count int; v_batch int;
  v_cutoff timestamptz := now() - make_interval(days => p_days);
BEGIN
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '80 seconds';
    WITH to_delete AS (
      SELECT id FROM public.listings_snapshots WHERE captured_at < v_cutoff ORDER BY captured_at LIMIT 50000
    )
    DELETE FROM public.listings_snapshots WHERE id IN (SELECT id FROM to_delete);
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_ls_count := v_ls_count + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  DELETE FROM public.event_metrics WHERE captured_at < now() - interval '120 days';  -- operator-set 120d
  GET DIAGNOSTICS v_em_count = ROW_COUNT;
  RETURN v_ls_count + v_em_count;
END $function$;

-- ---- td listings: re-batch (was single DELETE) so 30d stays safe ----
CREATE OR REPLACE FUNCTION public.sweep_old_td_listings(p_days integer DEFAULT 30)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_start timestamptz := clock_timestamp(); v_total int := 0; v_batch int;
  v_cutoff timestamptz := now() - make_interval(days => p_days);
BEGIN
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '60 seconds';
    DELETE FROM public.ticketsdata_listings_snapshots
    WHERE ctid IN (SELECT ctid FROM public.ticketsdata_listings_snapshots WHERE captured_at < v_cutoff LIMIT 20000);
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_total := v_total + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  RETURN v_total;
END $function$;

-- ---- NEW: cap section_metrics (per-section firehose) at 60d ----
CREATE OR REPLACE FUNCTION public.sweep_old_section_metrics(p_days integer DEFAULT 60)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_start timestamptz := clock_timestamp(); v_total int := 0; v_batch int;
  v_cutoff timestamptz := now() - make_interval(days => p_days);
BEGIN
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '80 seconds';
    DELETE FROM public.section_metrics
    WHERE ctid IN (SELECT ctid FROM public.section_metrics WHERE captured_at < v_cutoff LIMIT 50000);
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_total := v_total + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  RETURN v_total;
END $function$;
REVOKE ALL ON FUNCTION public.sweep_old_section_metrics(int) FROM anon, PUBLIC;

-- ---- NEW: cap event_section_row_snapshots at 30d ----
CREATE OR REPLACE FUNCTION public.sweep_old_event_section_rows(p_days integer DEFAULT 30)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_start timestamptz := clock_timestamp(); v_total int := 0; v_batch int;
  v_cutoff timestamptz := now() - make_interval(days => p_days);
BEGIN
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '80 seconds';
    DELETE FROM public.event_section_row_snapshots
    WHERE ctid IN (SELECT ctid FROM public.event_section_row_snapshots WHERE captured_at < v_cutoff LIMIT 50000);
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_total := v_total + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  RETURN v_total;
END $function$;
REVOKE ALL ON FUNCTION public.sweep_old_event_section_rows(int) FROM anon, PUBLIC;

-- ---- NEW: cap espn_injuries_snapshots at 90d (small) ----
CREATE OR REPLACE FUNCTION public.sweep_old_espn_injuries(p_days integer DEFAULT 90)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_count int;
BEGIN
  DELETE FROM public.espn_injuries_snapshots WHERE captured_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $function$;
REVOKE ALL ON FUNCTION public.sweep_old_espn_injuries(int) FROM anon, PUBLIC;

-- ---- Autovacuum tuning for high-churn snapshot tables ----
ALTER TABLE public.listings_snapshots          SET (autovacuum_vacuum_scale_factor=0.02, autovacuum_vacuum_insert_scale_factor=0.05, autovacuum_analyze_scale_factor=0.02);
ALTER TABLE public.seatgeek_listings_snapshots SET (autovacuum_vacuum_scale_factor=0.02, autovacuum_vacuum_insert_scale_factor=0.05, autovacuum_analyze_scale_factor=0.02);
ALTER TABLE public.seatgeek_sales_snapshots    SET (autovacuum_vacuum_scale_factor=0.02, autovacuum_vacuum_insert_scale_factor=0.05, autovacuum_analyze_scale_factor=0.02);
ALTER TABLE public.section_metrics             SET (autovacuum_vacuum_scale_factor=0.02, autovacuum_vacuum_insert_scale_factor=0.05, autovacuum_analyze_scale_factor=0.02);
ALTER TABLE public.espn_injuries_snapshots     SET (autovacuum_vacuum_scale_factor=0.05, autovacuum_vacuum_threshold=50);
ALTER TABLE public.evo_orders                  SET (autovacuum_vacuum_scale_factor=0.05, autovacuum_vacuum_threshold=50);

-- ---- Retarget existing sweep crons + schedule the new ones (gated) ----
SELECT cron.schedule('sweep-old-sg-listings','15 3,9,15,21 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sweep-old-sg-listings') THEN RETURN; END IF; PERFORM public.sweep_old_sg_listings(720); END $b$;$cron$);   -- 30d
SELECT cron.schedule('sweep-old-td-listings','30 3 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sweep-old-td-listings') THEN RETURN; END IF; PERFORM public.sweep_old_td_listings(30); END $b$;$cron$);
SELECT cron.schedule('sweep-old-section-metrics','25 3,9,15,21 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sweep-old-section-metrics') THEN RETURN; END IF; PERFORM public.sweep_old_section_metrics(60); END $b$;$cron$);
SELECT cron.schedule('sweep-old-event-section-rows','35 3 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sweep-old-event-section-rows') THEN RETURN; END IF; PERFORM public.sweep_old_event_section_rows(30); END $b$;$cron$);
SELECT cron.schedule('sweep-old-espn-injuries','40 3 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sweep-old-espn-injuries') THEN RETURN; END IF; PERFORM public.sweep_old_espn_injuries(90); END $b$;$cron$);
