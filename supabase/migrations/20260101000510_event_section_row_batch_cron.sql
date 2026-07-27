-- Migration 20260518030000 · lane:A1 · writes:rollup_event_section_row_batch+cron+cron_policy · reads:listings_snapshots,event_section_row_snapshots · pre:20260518020000 · auth:operator-approved 2026-05-18
--
-- A1 PR-3 — wire the existing rollup_event_section_row (single-event, mig 20260512100150)
-- into a batch wrapper + hourly cron. Table currently empty despite 6 months of schema.
-- Reads listings_snapshots, groups by _sec_norm(section)+row, computes min/median/max
-- price + listings_count + owned_quantity per cell.

CREATE OR REPLACE FUNCTION public.rollup_event_section_row_batch(
  p_max_events integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE r RECORD; v_total int := 0; v_n int;
BEGIN
  -- Pick events with fresh listings_snapshots in the last 2 hours that don't have
  -- a section_row rollup yet for that capture timestamp. Use MAX(captured_at) per
  -- event to dedupe in case multiple captures landed.
  FOR r IN
    SELECT ls.event_id, MAX(ls.captured_at) AS captured_at
    FROM public.listings_snapshots ls
    WHERE ls.captured_at > now() - interval '2 hours'
      AND ls.event_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.event_section_row_snapshots esrs
        WHERE esrs.event_id = ls.event_id
          AND esrs.source = 'tevo'
          AND esrs.captured_at > now() - interval '2 hours'
      )
    GROUP BY ls.event_id
    LIMIT p_max_events
  LOOP
    v_n := public.rollup_event_section_row(r.event_id, r.captured_at);
    v_total := v_total + COALESCE(v_n, 0);
  END LOOP;
  RETURN v_total;
END $func$;

REVOKE ALL ON FUNCTION public.rollup_event_section_row_batch(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rollup_event_section_row_batch(integer) TO service_role;

COMMENT ON FUNCTION public.rollup_event_section_row_batch(integer) IS
  'A1 2026-05-18 — batch wrapper around rollup_event_section_row (single-event, mig 20260512100150). Picks events with fresh listings_snapshots in last 2h lacking a recent section rollup, processes up to p_max_events. Hourly cron @ :03. Writes source=tevo only; SG mirror pending future PR.';

DO $body$ DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'event_section_row_rollup_hourly';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'event_section_row_rollup_hourly',
    '3 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('event_section_row_rollup_hourly') THEN RETURN; END IF;
      PERFORM public.rollup_event_section_row_batch(100);
    END $cronbody$;$cron$
  );
END $body$;

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES (
  'event_section_row_rollup_hourly',
  '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
  60, 60, 24, true,
  'Per-section rollup from listings_snapshots (source=tevo). SG-side rollup (source=seatgeek) pending future PR.'
) ON CONFLICT (jobname) DO UPDATE SET enabled = true, updated_at = now();
