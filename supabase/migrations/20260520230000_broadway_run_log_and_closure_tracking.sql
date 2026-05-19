-- Migration 20260520230000 · level:standard · lane:broadway (D3) · pre:20260520220000
--
-- Adds run-level aggregation (P1 #6) and show-closure tracking (P2 #11).
-- Both designed to be called from the future broadway_collect edge
-- function — no cron schedules, no edge function deploy in this file.
--
-- Design: docs/broadway-scale-plan.md "Proposed fixes for remaining issues"
-- Depends on: 20260520220000_broadway_listings_pipeline.sql (broadway_shows)

-- ============================================================================
-- (1) broadway_shows — closure-tracking columns
-- ============================================================================

ALTER TABLE public.broadway_shows
  ADD COLUMN IF NOT EXISTS closed_at                       timestamptz,
  ADD COLUMN IF NOT EXISTS consecutive_discover_failures   integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS last_discover_failure_at        timestamptz,
  ADD COLUMN IF NOT EXISTS last_discover_failure_reason    text;

CREATE INDEX IF NOT EXISTS idx_broadway_shows_closed
  ON public.broadway_shows (closed_at)
  WHERE closed_at IS NOT NULL;

COMMENT ON COLUMN public.broadway_shows.closed_at IS
  'Marked when consecutive_discover_failures crosses 3. Operator can '
  'clear by setting NULL to reopen tracking (also resets counter).';
COMMENT ON COLUMN public.broadway_shows.consecutive_discover_failures IS
  'Bumped by increment_broadway_discover_failure(slug). Reset to 0 by '
  'reset_broadway_discover_failure(slug) on any successful discover. '
  'Crossing 3 -> closed_at = now() automatically.';

-- ============================================================================
-- (2) increment_broadway_discover_failure(slug)
--     Bumps counter. Sets closed_at = now() when crossing the 3-failure
--     threshold (idempotent — won't overwrite an existing closed_at).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.increment_broadway_discover_failure(
  p_slug   text,
  p_reason text DEFAULT NULL
) RETURNS public.broadway_shows
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.broadway_shows;
BEGIN
  UPDATE public.broadway_shows
     SET consecutive_discover_failures = consecutive_discover_failures + 1,
         last_discover_failure_at      = now(),
         last_discover_failure_reason  = p_reason,
         closed_at = CASE
           WHEN consecutive_discover_failures + 1 >= 3 AND closed_at IS NULL
             THEN now()
           ELSE closed_at
         END
   WHERE slug = p_slug
   RETURNING * INTO v_row;

  -- If the slug isn't in broadway_shows yet, that's an upstream bug
  -- (discover_shows should have seeded it). Surface loudly.
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'increment_broadway_discover_failure: slug % not in broadway_shows', p_slug;
  END IF;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.increment_broadway_discover_failure(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.increment_broadway_discover_failure(text, text) TO service_role;

COMMENT ON FUNCTION public.increment_broadway_discover_failure(text, text) IS
  'Called by broadway_collect on a discover_performances failure. '
  'Bumps consecutive_discover_failures. 3rd consecutive failure marks '
  'closed_at = now(). Returns the updated row for caller diagnostics.';

-- ============================================================================
-- (3) reset_broadway_discover_failure(slug)
--     Called on any successful discover. Resets counter; does NOT clear
--     closed_at automatically — operator must do that manually if a
--     close-marked show should be reopened.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reset_broadway_discover_failure(
  p_slug text
) RETURNS public.broadway_shows
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.broadway_shows;
BEGIN
  UPDATE public.broadway_shows
     SET consecutive_discover_failures = 0,
         last_discover_failure_at      = NULL,
         last_discover_failure_reason  = NULL,
         last_seen_at                  = now()
   WHERE slug = p_slug
   RETURNING * INTO v_row;
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'reset_broadway_discover_failure: slug % not in broadway_shows', p_slug;
  END IF;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.reset_broadway_discover_failure(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reset_broadway_discover_failure(text) TO service_role;

-- ============================================================================
-- (4) broadway_run_log — per-cron-invocation summary (P1 #6)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_run_log (
  id                bigserial   PRIMARY KEY,
  bucket            text        NOT NULL,        -- '0-72h' | '72h+' | 'shows-index'
  started_at        timestamptz NOT NULL,
  finished_at       timestamptz,
  duration_ms       integer GENERATED ALWAYS AS (
                      CASE WHEN finished_at IS NULL THEN NULL
                           ELSE EXTRACT(epoch FROM (finished_at - started_at))::integer * 1000
                      END) STORED,

  -- Counts
  events_attempted  integer NOT NULL DEFAULT 0,
  events_ok         integer NOT NULL DEFAULT 0,
  events_failed     integer NOT NULL DEFAULT 0,
  shows_attempted   integer NOT NULL DEFAULT 0,
  shows_failed      integer NOT NULL DEFAULT 0,

  -- Did we raise a bot_chat flag from this run?
  flag_raised       boolean NOT NULL DEFAULT false,

  -- Up to N sampled error messages from failing fetches/discovers.
  -- Bounded by the edge function (default 10) so this row stays small.
  error_samples     jsonb NOT NULL DEFAULT '[]'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_bwy_run_log_time
  ON public.broadway_run_log (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_bwy_run_log_bucket
  ON public.broadway_run_log (bucket, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_bwy_run_log_flagged
  ON public.broadway_run_log (started_at DESC)
  WHERE flag_raised = true;

COMMENT ON TABLE public.broadway_run_log IS
  'Per-cron-invocation run summary. One row per broadway-collect-* '
  'invocation. broadway_collect edge function inserts on start, updates '
  'on finish. >25% failure rate triggers a bot_chat_log flag (caller '
  'sets flag_raised=true). 90-day retention via sweep_old_broadway_runs.';

-- ============================================================================
-- (5) sweep_old_broadway_runs() — 90-day retention for run log
--     (separate from sweep_old_broadway_listings because run-log rows
--     are way smaller — we can keep them longer for analytics)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sweep_old_broadway_runs()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deleted integer;
BEGIN
  DELETE FROM public.broadway_run_log
   WHERE started_at < now() - interval '90 days';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.sweep_old_broadway_runs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sweep_old_broadway_runs() TO service_role;

-- ============================================================================
-- (6) v_broadway_runs_recent — convenience view of last 7 days
--     Replaces the need for the dashboard to know about indexes / time
--     calculations. Each row already carries duration + counts.
-- ============================================================================

CREATE OR REPLACE VIEW public.v_broadway_runs_recent
WITH (security_invoker = true)
AS
SELECT
  id,
  bucket,
  started_at,
  finished_at,
  duration_ms,
  events_attempted,
  events_ok,
  events_failed,
  CASE
    WHEN events_attempted > 0
      THEN round((events_failed::numeric / events_attempted) * 100, 1)
    ELSE 0
  END AS event_failure_pct,
  shows_attempted,
  shows_failed,
  flag_raised,
  error_samples
FROM public.broadway_run_log
WHERE started_at > now() - interval '7 days'
ORDER BY started_at DESC;

COMMENT ON VIEW public.v_broadway_runs_recent IS
  'Last 7 days of broadway_collect runs with computed event_failure_pct. '
  'D2 dashboard consumes this for the broadway coverage panel.';

-- ============================================================================
-- (7) RLS on the new table
-- ============================================================================

ALTER TABLE public.broadway_run_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS broadway_run_log_read ON public.broadway_run_log;
CREATE POLICY broadway_run_log_read ON public.broadway_run_log
  FOR SELECT TO authenticated USING (true);

-- ============================================================================
-- DONE.
-- ============================================================================