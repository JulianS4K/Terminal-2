-- ============================================================================
-- Migration 20260623120000 — AXS→TEvo cold-search bridge (map unmapped AXS box-office events)
--
-- Lane:     A1 (data plane — AQ mapper / TEvo ingest). Authored by D0 (terminal
--           surface) per operator directive 2026-06-23; APPLY + edge-fn deploy +
--           cron wiring stay A1-gated (PROJECT_BIBLE §1, §2.3).
-- Touches:  axs_tevo_search_attempts (W, new table),
--           axs_tevo_search_candidates (W, new fn),
--           axs_events (R), axs_event_snapshots (R)
-- Pre-reqs: 20260610020000 (axs_apply_aq / axs_aq_backfill / axs_aq_match),
--           20260605133500 (aq_tevo_search_bridge — pattern this mirrors),
--           cross_source_venue_resolve(text,text,text),
--           vault: TEVO_TOKEN/TEVO_SECRET, CRON_SECRET (edge fn, deployed separately)
--
-- WHY: The AXS registry carries ~172 events with no canonical tevo_event_id. The
--   AXS matcher (axs_aq_match, v3) only links to events that already exist in
--   public.events — but verified head-to-head, the unmapped AXS shows (Morgan
--   Wallen @ Clemson/Michigan Stadium, Journey/Zac Brown/Red Clay Strays @ Van
--   Andel, Geese club dates, Wilco @ Frederik Meijer, …) are simply ABSENT from
--   public.events (and where an aq_event_map seed row exists, its tevo_event_id is
--   NULL). axs_aq_backfill() therefore maps 0 — the blocker is upstream, not the
--   matcher. Nothing actively searches TEvo /v9/events on the AXS side, so these
--   stay permanently unmapped (= invisible to terminal views keyed on tevo id).
--
--   This is the non-SG / non-AQ analogue of sg-to-tevo-search-bridge +
--   aq-to-tevo-search-bridge, but ANCHORED ON AXS: for each unmapped AXS-primary
--   event it searches TEvo /v9/events (venue+date, then name+date), upserts the
--   matched canonical event into public.events, then calls axs_apply_aq() — which
--   re-runs the existing matcher (now finds the freshly-ingested event) and
--   propagates tevo_event_id across the AXS snapshot/section/seat/registry rows.
--   Reuses axs_apply_aq for the actual link so there is ONE matching code path.
--
-- This migration adds the SQL half only (ledger + candidate selector). The edge
-- fn (axs-to-tevo-search-bridge) + its cron + a recurring axs_aq_backfill cron are
-- gated steps documented in PART 3 (cron.schedule + edge-fn deploy are A1-gated).
-- ============================================================================

-- ── PART 1: attempt ledger ───────────────────────────────────────────────────
-- Keyed on axs_event_id (the AXS registry PK). Mirrors aq_tevo_search_attempts.
-- no_results/low_score/no_name_overlap rows are retried after the backoff window;
-- matched rows are terminal (the event leaves the pool once tevo_event_id is set).

CREATE TABLE IF NOT EXISTS public.axs_tevo_search_attempts (
  axs_event_id text PRIMARY KEY
                 REFERENCES public.axs_events(axs_event_id) ON DELETE CASCADE,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  result       text NOT NULL
                 CHECK (result IN ('matched','no_results','low_score','no_name_overlap','errored')),
  meta         jsonb
);

COMMENT ON TABLE public.axs_tevo_search_attempts IS
  'Per-AXS-event attempt ledger for the AXS→TEvo cold-search bridge (axs-to-tevo-search-bridge edge fn). Keyed on axs_events.axs_event_id. Mirrors aq_tevo_search_attempts. Non-matched results retry after backoff; matched rows are terminal (event leaves the candidate pool once axs_apply_aq sets tevo_event_id).';

CREATE INDEX IF NOT EXISTS idx_axstsa_attempted_at
  ON public.axs_tevo_search_attempts (attempted_at);
CREATE INDEX IF NOT EXISTS idx_axstsa_result
  ON public.axs_tevo_search_attempts (result);

ALTER TABLE public.axs_tevo_search_attempts ENABLE ROW LEVEL SECURITY;
-- No policies: service-role-only (matches the rest of the axs_* table family).

-- ── PART 2: candidate selector (anti-join, never-tried-first) ────────────────
-- Unmapped, active, AXS-primary events whose latest snapshot has a usable
-- name + venue + future date. Anti-joins the ledger and orders NEVER-TRIED-FIRST
-- then stalest, then soonest event — drains the whole backlog (no date-LIMIT
-- starvation, per the aq bridge design note).

CREATE OR REPLACE FUNCTION public.axs_tevo_search_candidates(
  p_limit         int DEFAULT 30,
  p_backoff_hours int DEFAULT 24
)
RETURNS TABLE (
  axs_event_id    text,
  event_name      text,
  venue_name      text,
  tevo_venue_id   bigint,
  occurs_at_local text,
  last_result     text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH latest AS (
    SELECT DISTINCT ON (s.axs_event_id)
           s.axs_event_id, s.event_name, s.venue_name, s.tevo_venue_id, s.occurs_at_local
    FROM public.axs_event_snapshots s
    WHERE s.event_name IS NOT NULL
      AND s.venue_name IS NOT NULL
      AND s.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'          -- guard the text->ts cast
    ORDER BY s.axs_event_id, s.captured_at DESC
  )
  SELECT l.axs_event_id, l.event_name, l.venue_name, l.tevo_venue_id,
         l.occurs_at_local, a.result AS last_result
  FROM public.axs_events e
  JOIN latest l ON l.axs_event_id = e.axs_event_id
  LEFT JOIN public.axs_tevo_search_attempts a ON a.axs_event_id = e.axs_event_id
  WHERE e.tevo_event_id IS NULL
    AND e.active
    AND COALESCE(e.is_axs_primary, true)                     -- skip probed not_axs (resale/no-inventory)
    AND l.occurs_at_local::timestamptz >= now()              -- upcoming only
    AND NOT (l.event_name ~* '(cancelled|if necessary|\(date tbd\))')
    AND (
      a.axs_event_id IS NULL                                 -- never tried
      OR a.attempted_at < now() - make_interval(hours => p_backoff_hours)
    )
  ORDER BY
    (a.axs_event_id IS NULL) DESC,                           -- never-tried first
    a.attempted_at ASC NULLS FIRST,                          -- then stalest attempt
    l.occurs_at_local::timestamptz ASC                       -- then soonest event
  LIMIT GREATEST(1, LEAST(200, p_limit));
$$;

COMMENT ON FUNCTION public.axs_tevo_search_candidates(int, int) IS
  'Next batch of unmapped, active, AXS-primary events (latest snapshot has name+venue+future date) for the AXS→TEvo cold-search bridge. Anti-joins axs_tevo_search_attempts, never-tried-first. Service-role only.';

REVOKE ALL ON FUNCTION public.axs_tevo_search_candidates(int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.axs_tevo_search_candidates(int, int) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_tevo_search_candidates(int, int) TO service_role;

-- ── PART 3: gated wiring (A1 applies AFTER deploying the edge fn) ─────────────
-- cron.schedule + edge-fn deploy are gated (PROJECT_BIBLE §1). Run these as
-- separate operator-authorized steps once supabase/functions/axs-to-tevo-search-bridge
-- is deployed. The bridge upserts into public.events + calls axs_apply_aq() itself;
-- the recurring backfill below is a belt-and-suspenders re-map so AXS rows also
-- pick up TEvo events ingested by ANY other path (SG/AQ bridges, order sweeps).
--
-- (a) AXS→TEvo cold-search bridge — every 13h via the min-interval gate, mirroring
--     aq_to_tevo_search_bridge_13h. Validate with ?dry_run=true first.
--
-- INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
--   offpeak_min_interval_min, work_check_sql, daily_max_fires, enabled, notes)
-- VALUES (
--   'axs_to_tevo_search_bridge_13h',
--   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
--   780, 780,
--   'SELECT EXISTS(SELECT 1 FROM public.axs_tevo_search_candidates(1, 24))',
--   NULL, true,
--   'AXS→TEvo cold-search bridge for unmapped AXS-primary events. 13h cadence via min-interval gate. limit=30/run.'
-- ) ON CONFLICT (jobname) DO UPDATE SET enabled = EXCLUDED.enabled, notes = EXCLUDED.notes;
--
-- SELECT cron.schedule(
--   'axs_to_tevo_search_bridge_13h', '18 * * * *',
--   $cronbody$
--     DO $b$ BEGIN
--       IF NOT public.cron_should_fire('axs_to_tevo_search_bridge_13h') THEN RETURN; END IF;
--       PERFORM public._cron_invoke_edge_fn(
--         'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/axs-to-tevo-search-bridge?limit=30&min_score=50',
--         '{}'::jsonb
--       );
--     END $b$;
--   $cronbody$
-- );
--
-- (b) Recurring re-map so newly-ingested TEvo events retro-link AXS rows even
--     outside the bridge (there is no axs_aq_backfill cron today — mapping only
--     fires at ingest). Cheap, idempotent, no upstream calls.
--
-- SELECT cron.schedule('axs-aq-backfill-6h', '40 */6 * * *',
--   $$ SELECT public.axs_aq_backfill(1000); $$);
