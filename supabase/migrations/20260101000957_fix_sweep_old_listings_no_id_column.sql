-- ============================================================================
-- Migration 20260617000000 — fix sweep_old_listings (column "id" does not exist)
--
-- Lane:     xref+macro (audit lane — listings_snapshots TEvo cron owner)
-- Touches:  sweep_old_listings() (W, function replace), listings_snapshots (W, scoped DELETE), event_metrics (W, scoped DELETE)
-- Pre-reqs: none
--
-- BUG: sweep_old_listings() deletes via `SELECT id ... WHERE id IN (...)`, but
-- public.listings_snapshots has NO `id` column (its key is event_id+captured_at).
-- Every run of cron job `sweep-old-listings` (309, daily `0 3 * * *`) has been
-- failing 100% with `ERROR: column "id" does not exist`, so the 15-day retention
-- has never been enforced. The table has grown to ~45 GB / ~121M rows (half the
-- whole DB) and is the dominant driver of the low (~81%) cache-hit ratio and of
-- statement-timeout failures on jobs that scan it.
--
-- FIX: delete by captured_at directly, batched via ctid — the same pattern
-- already used by sweep-old-section-metrics. Behaviour is otherwise identical
-- (80s self-cap, 50k batch, 120-day event_metrics retention).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sweep_old_listings(p_days integer DEFAULT 15)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start timestamptz := clock_timestamp(); v_ls_count int := 0; v_em_count int; v_batch int;
  v_cutoff timestamptz := now() - make_interval(days => p_days);
BEGIN
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '80 seconds';
    WITH to_delete AS (
      SELECT ctid FROM public.listings_snapshots
      WHERE captured_at < v_cutoff
      ORDER BY captured_at
      LIMIT 50000
    )
    DELETE FROM public.listings_snapshots WHERE ctid IN (SELECT ctid FROM to_delete);
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_ls_count := v_ls_count + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  -- metrics we generate keep their NORMAL retention (unchanged): 120 days
  DELETE FROM public.event_metrics WHERE captured_at < now() - interval '120 days';
  GET DIAGNOSTICS v_em_count = ROW_COUNT;
  RETURN v_ls_count + v_em_count;
END $function$;
