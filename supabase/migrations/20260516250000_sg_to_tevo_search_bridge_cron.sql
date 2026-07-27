-- ============================================================================
-- sg-to-tevo-search-bridge cron + tracking table
--
-- Companion to migration 20260516240000 (matcher v3). Where matcher v3 handles
-- the local-data path (zero API cost), this migration wires up the ACTIVE
-- TEvo /v9/events search-based autotrack for events that aren't yet in our
-- local `events` table.
--
-- Architecture:
--   1. Edge fn `sg-to-tevo-search-bridge` (deployed separately, code in
--      supabase/functions/sg-to-tevo-search-bridge/) calls TEvo /v9/events
--      with venue_id + date range (or name + date range fallback), scores
--      candidates, upserts winners into events + seatgeek_event_xref.
--   2. This migration creates:
--        a. sg_tevo_search_attempts (PK sg_event_id) — 24h retry suppression
--        b. cron sg_to_tevo_search_bridge_30min @ :23,:53 (off-cycle)
--        c. cron_policy entry — 30 fires/day cap (= 1,200 attempts/day)
--   3. Operator directive 2026-05-16 — "auto-track any event we're tracking
--      on SG on evo and vice versa. use evo search to find events directly."
--
-- Expected outcome: drains the ~1,900 unmatched-future-SG backlog in 2-3 days
-- at ~75% hit rate (observed first-batch live run 2026-05-16).
-- ============================================================================

-- 1. Attempts tracking table (already applied via MCP, codified here)
CREATE TABLE IF NOT EXISTS public.sg_tevo_search_attempts (
  sg_event_id   bigint PRIMARY KEY,
  attempted_at  timestamptz NOT NULL DEFAULT now(),
  result        text NOT NULL,   -- 'matched' | 'no_results' | 'low_score' | 'error'
  meta          jsonb,
  retries       int NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_sg_tevo_search_attempts_attempted_at
  ON public.sg_tevo_search_attempts(attempted_at);
CREATE INDEX IF NOT EXISTS idx_sg_tevo_search_attempts_result
  ON public.sg_tevo_search_attempts(result);

COMMENT ON TABLE public.sg_tevo_search_attempts IS
  'Tracks TEvo search-bridge attempts per sg_event_id to avoid burning API on repeat queries within 24h.';

-- 2. Update cross_source_match_tick to call matcher v3 alongside v2
CREATE OR REPLACE FUNCTION public.cross_source_match_tick()
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_sg jsonb; v_evo record; v_sd record; v_v3 record;
BEGIN
  v_sg  := sg_canonical_auto_match_tick();
  SELECT * INTO v_v3 FROM auto_match_sg_canonical_v3();
  SELECT * INTO v_evo FROM evo_orphan_event_resolve();
  SELECT * INTO v_sd  FROM sd_xref_resolve();
  RETURN jsonb_build_object(
    'sg', v_sg,
    'v3_attempted', v_v3.attempted,
    'v3_newly_matched', v_v3.newly_matched,
    'v3_parking_skipped', v_v3.parking_skipped,
    'v3_needs_tevo_search', v_v3.needs_tevo_search,
    'evo', jsonb_build_object('orphans_seen', v_evo.orphans_seen, 'attempts_logged', v_evo.attempts_logged),
    'sd', jsonb_build_object('orphan_xref_rows', v_sd.orphan_xref_rows, 'sd_pulls_logged', v_sd.sd_pulls_logged),
    'ran_at', now()
  );
END;
$function$;

-- 3. Cron schedule @ :23,:53 (off-cycle from matcher v3 @ :09,:39)
DO $body$
DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sg_to_tevo_search_bridge_30min';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'sg_to_tevo_search_bridge_30min',
    '23,53 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_to_tevo_search_bridge_30min') THEN RETURN; END IF;
      PERFORM public._cron_invoke_edge_fn(
        'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/sg-to-tevo-search-bridge?limit=40&min_score=50',
        '{}'::jsonb
      );
    END $cronbody$;$cron$
  );
END $body$;

INSERT INTO public.cron_policy (
  jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, enabled, notes
) VALUES (
  'sg_to_tevo_search_bridge_30min',
  '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
  30, 60, 30, true,
  'Active TEvo /v9/events search bridge for SG events with no local TEvo row. 40/run × 30 fires/day = 1,200 attempts/day. Drains 1,800 backlog in ~4 days at 75% hit rate.'
) ON CONFLICT (jobname) DO UPDATE SET
  notes = EXCLUDED.notes, enabled = EXCLUDED.enabled, updated_at = now();
