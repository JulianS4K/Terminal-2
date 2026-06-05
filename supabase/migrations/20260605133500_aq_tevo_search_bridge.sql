-- Migration 20260601120000 · level:2 · lane:D0
-- writes: aq_tevo_search_attempts (new table)
-- reads:  aq_event_map
--
-- Purpose: Stand up the server-side half of the AQ→TEvo cold-search bridge — the
--   non-SG analogue of sg_to_tevo_search_bridge. Today TM / Vivid / ScoreBig(SH)
--   rows in aq_event_map only acquire a canonical tevo_event_id *passively* (when
--   they happen to coincide with an SG match or an order sweep). ~1,250 upcoming,
--   non-parking, non-cancelled hub rows carry only TM/Vivid/SH ids and are never
--   actively searched against TEvo /v9/events.
--
--   This migration adds:
--     1. aq_tevo_search_attempts — per-hub-row attempt ledger (mirrors
--        sg_tevo_search_attempts, keyed on aq_event_map.id).
--     2. aq_tevo_search_candidates(p_limit, p_backoff_hours) — the candidate
--        selector the edge fn drains. It anti-joins the ledger and orders
--        NEVER-TRIED-FIRST, then stalest-attempt, then by event date.
--
--   DESIGN NOTE — why the selector lives in SQL, not the edge fn:
--     The SG bridge picks candidates client-side with
--     `.order(date asc).limit(N*6)` then filters out recently-tried rows. That
--     pins it to the nearest-dated front of the queue and starves the deeper
--     backlog (observed: 645 SG candidates never attempted; see KANBAN). Doing
--     the anti-join server-side with `(attempt is null) DESC` ordering guarantees
--     the window advances through the whole backlog and cannot starve.
--
--   Authored by D0 2026-06-01. Writes to aq_event_map.tevo_event_id are performed
--   by the edge fn (service role), gated min_score + venue-signal; dry_run validated first.
--
-- ## Already applied to prod  Applied via MCP 2026-06-01 (operator-authorized).
--   Edge fn `aq-to-tevo-search-bridge` deployed v2 (venue-signal guard). First live
--   run: 30 attempted / 13 matched / 0 errored, all 13 written to aq_event_map.
--   Cron `aq_to_tevo_search_bridge_13h` scheduled (see PART 3) — 13h cadence.
--
-- KEY ARCHITECTURE NOTE (do not re-discover):
--   aq_event_map is the canonical hub; tevo_event_id is the canonical link.
--   Source IDs are source-internal — never cross-join on raw IDs. The hub row is
--   self-describing (event_name/venue_name/event_date/city/state/performer/category),
--   which is enough to drive a TEvo /v9/events text+date search directly.
--   See D0_BIBLE.md §3 and PROJECT_BIBLE §5.

-- ── PART 1: attempt ledger ───────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.aq_tevo_search_attempts (
  aq_id        bigint PRIMARY KEY
                 REFERENCES public.aq_event_map(id) ON DELETE CASCADE,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  result       text NOT NULL
                 CHECK (result IN ('matched','no_results','low_score','errored')),
  meta         jsonb
);

COMMENT ON TABLE public.aq_tevo_search_attempts IS
  'Per-hub-row attempt ledger for the AQ→TEvo cold-search bridge (aq-to-tevo-search-bridge edge fn). Keyed on aq_event_map.id. Mirrors sg_tevo_search_attempts. no_results/low_score rows are retried after the backoff window; matched rows are terminal (the hub row leaves the candidate pool once tevo_event_id is set).';

CREATE INDEX IF NOT EXISTS idx_aqtsa_attempted_at
  ON public.aq_tevo_search_attempts (attempted_at);
CREATE INDEX IF NOT EXISTS idx_aqtsa_result
  ON public.aq_tevo_search_attempts (result);

-- ── PART 2: candidate selector (anti-join, never-tried-first) ────────────────
-- LANGUAGE sql body is validated at CREATE time → must be declared AFTER the
-- table above exists in this same migration (PROJECT_BIBLE §7 landmine).

CREATE OR REPLACE FUNCTION public.aq_tevo_search_candidates(
  p_limit         int DEFAULT 30,
  p_backoff_hours int DEFAULT 24
)
RETURNS TABLE (
  aq_id       bigint,
  event_name  text,
  venue_name  text,
  city        text,
  state       text,
  performer   text,
  category    text,
  event_date  timestamp,
  src         text,
  last_result text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    m.id,
    m.event_name,
    m.venue_name,
    m.city,
    m.state,
    m.performer,
    m.category,
    m.event_date,
    CASE
      WHEN m.tm_event_id    IS NOT NULL THEN 'TM'
      WHEN m.vivid_event_id IS NOT NULL THEN 'VIVID'
      WHEN m.sh_event_id    IS NOT NULL THEN 'SH'
      ELSE 'OTHER'
    END                                 AS src,
    a.result                            AS last_result
  FROM public.aq_event_map m
  LEFT JOIN public.aq_tevo_search_attempts a ON a.aq_id = m.id
  WHERE m.tevo_event_id IS NULL
    AND m.sg_event_id   IS NULL                              -- SG rows are the SG bridge's job
    AND COALESCE(m.tm_event_id, m.vivid_event_id, m.sh_event_id) IS NOT NULL
    AND m.event_date >= now()::timestamp                     -- upcoming only
    AND NOT (m.category IN ('Parking','parking')
             OR m.venue_name ILIKE '%parking%'
             OR m.event_name ILIKE '%parking%')              -- TEvo folds parking in
    AND NOT (m.event_name ~* '(cancelled|if necessary|\(date tbd\))')
    AND (
      a.aq_id IS NULL                                        -- never tried
      OR a.attempted_at < now() - make_interval(hours => p_backoff_hours)
    )
  ORDER BY
    (a.aq_id IS NULL) DESC,                                  -- never-tried first
    a.attempted_at ASC NULLS FIRST,                          -- then stalest attempt
    m.event_date ASC                                         -- then soonest event
  LIMIT GREATEST(1, LEAST(200, p_limit));
$$;

COMMENT ON FUNCTION public.aq_tevo_search_candidates(int, int) IS
  'Next batch of unmapped non-SG hub rows for the AQ→TEvo cold-search bridge. Anti-joins aq_tevo_search_attempts and orders never-tried-first to drain the full backlog (avoids the date-LIMIT starvation the SG bridge suffers). Service-role only.';

-- Service-role only (edge fn calls with SUPABASE_SERVICE_ROLE_KEY).
REVOKE ALL ON FUNCTION public.aq_tevo_search_candidates(int, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aq_tevo_search_candidates(int, int) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.aq_tevo_search_candidates(int, int) TO service_role;

-- ── PART 3: cron wiring (applied 2026-06-01, AFTER the edge fn was deployed) ──
-- Ran as a separate gated step (cron.schedule + cron_policy + edge-fn deploy are
-- all gated per PROJECT_BIBLE §1, and the fn must exist before the cron fires).
--
-- Cadence: every 13 hours (operator directive 2026-06-01). Standard cron can't
-- express a strict 13h interval, so the schedule TRIGGERS hourly at :08 and the
-- cron_should_fire min-interval gate (780 min, all hours treated as "peak")
-- releases it only ~every 13h. "now" was seeded as the first fire so the first
-- automated run lands ~13h after deploy.
--
-- INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
--   offpeak_min_interval_min, work_check_sql, daily_max_fires, enabled, notes)
-- VALUES (
--   'aq_to_tevo_search_bridge_13h',
--   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
--   780, 780,
--   'SELECT EXISTS(SELECT 1 FROM public.aq_tevo_search_candidates(1, 24))',
--   NULL, true,
--   'Active TEvo /v9/events search bridge for non-SG (TM/Vivid/SH) hub rows. 13h cadence via min-interval gate. limit=30/run.'
-- )
-- ON CONFLICT (jobname) DO UPDATE SET ... ;
--
-- -- seed now as first fire so next automated run is ~13h out:
-- INSERT INTO public.cron_gate_decisions (jobname, decided_at, decision, hour_et)
-- VALUES ('aq_to_tevo_search_bridge_13h', now(), 'fire',
--         EXTRACT(hour FROM (now() AT TIME ZONE 'America/New_York'))::int);
--
-- SELECT cron.schedule(
--   'aq_to_tevo_search_bridge_13h',
--   '8 * * * *',
--   $cronbody$
--     DO $b$ BEGIN
--       IF NOT public.cron_should_fire('aq_to_tevo_search_bridge_13h') THEN RETURN; END IF;
--       PERFORM public._cron_invoke_edge_fn(
--         'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/aq-to-tevo-search-bridge?limit=30&min_score=50',
--         '{}'::jsonb
--       );
--     END $b$;
--   $cronbody$
-- );
