-- Migration 20260926031431 · level:secondary-sales · lane:D7 · writes:gotickets_event(via fn),cron.job · reads:n2s_items,events,gotickets_event · pre:20260926014415
--
-- Already applied to prod · via MCP 2026-09-26 under operator direction, after a
-- full rolled-back dry run (scoped 1.91 s, full 7.42 s, tick edit + cron + ACL verified).
--
-- ============================================================================
-- Migration 20260926031431 — the GoTickets name matcher: fast, back in the
-- tick every tick; a 30-minute full pass as the safety net
--
-- Lane: D7 · Pre-reqs: 20260911020000 (n2s_gt_map_by_name), 20260926014415
--
-- ── WHAT WENT WRONG IN 20260926014415 ──────────────────────────────────────
-- Moving the matcher to its own every-minute job made it compete with the tick
-- for the database: it ran 1 min 56 s – 4 min 20 s (vs 45 s typical in the
-- tick), finished 2 of 12 runs, made 0 links, and DOUBLED the tick (typical
-- 34 s → 68 s) — worse for the 10-minute CRM-alert-to-subs window than before.
-- The operator needs the matcher as a priority, the TEvo/GoTickets pollers,
-- and the feed to the CRM, all inside that window. So the matcher has to be
-- cheap, not moved.
--
-- ── WHY IT WAS SLOW (EXPLAIN ANALYZE, 2026-09-26) ────────────────────────────
-- The date predicate was a CASE over expressions of g.event_time_utc, which no
-- index can serve: a sequential scan of all 186,074 unlinked GoTickets events,
-- ~4.8 M join-filter evaluations, 35.7 s even for 26 events. And it rescanned
-- every live mapped event (132), although 106 already had a GoTickets link.
--
-- ── THE FIX ────────────────────────────────────────────────────────────────
--   1. The time predicate becomes a half-open RANGE per TEvo event, which uses
--      idx_gt_event_time. Exactly equivalent:
--        offset : date_trunc('minute', g.t) = date_trunc('minute', at)
--                 ⇔ g.t ∈ [trunc(at), trunc(at) + 1 min)
--        other  : (g.t AT TIME ZONE 'UTC')::date BETWEEN d - s AND d + s
--                 ⇔ g.t ∈ [(d - s) 00:00 UTC, (d + s + 1) 00:00 UTC)
--      Verified on prod before applying: old vs new join, 34,415 pairs each,
--      EXCEPT both ways = 0, across all three time kinds.
--   2. New p_only_unlinked (default false): restrict to live events with no
--      GoTickets link yet. Measured 1.9 s (vs 7.9 s for all 130, vs 45 s+ old).
--   3. The tick runs it EVERY tick with p_only_unlinked => true, right after
--      the mapper and BEFORE n2s_pull_all_sources, so a new link is polled in
--      the same tick. (It previously ran every 5th minute only.)
--   4. The scoped pass skips events that already have one GoTickets link, so
--      a second GT listing for the same show is only found by a full pass:
--      job 661 is replaced by `n2s_gt_map_by_name_full_30min` (13,43 past the
--      hour), a full pass — ~8 s now.
--
-- Rules, thresholds, tie refusal and "never overwrite a mapping" are unchanged.
--
-- ── SECURITY ───────────────────────────────────────────────────────────────
-- The old function (SECURITY DEFINER, writes gotickets_event) was EXECUTE-able
-- by anon and authenticated, i.e. callable through the API with the publishable
-- key. Recreated with REVOKE … FROM PUBLIC, anon, authenticated + GRANT
-- service_role (PROJECT_BIBLE §2.8).
--
-- Drift guards: both live bodies md5-asserted. Rollback at the bottom.
-- ============================================================================

DO $$
BEGIN
  IF md5(pg_get_functiondef('public.n2s_gt_map_by_name'::regproc)) <> '0190cdf3e1c33fae3db6a22eed089440' THEN
    RAISE EXCEPTION 'n2s_gt_map_by_name drifted from the reviewed body — refusing';
  END IF;
  IF md5(pg_get_functiondef('public.n2s_pipeline_tick'::regproc)) <> '2fef89d2ee43be2258a38bb61a18747b' THEN
    RAISE EXCEPTION 'n2s_pipeline_tick drifted from the reviewed body — refusing';
  END IF;
END $$;

DROP FUNCTION public.n2s_gt_map_by_name(numeric, numeric, numeric, numeric, integer);

CREATE FUNCTION public.n2s_gt_map_by_name(
  p_min_name        numeric DEFAULT 0.60,
  p_min_venue       numeric DEFAULT 0.60,
  p_min_name_perf   numeric DEFAULT 0.40,
  p_min_name_date   numeric DEFAULT 0.80,
  p_date_slop_days  integer DEFAULT 1,
  p_only_unlinked   boolean DEFAULT false)
 RETURNS TABLE(mapped integer, refused_ties integer, by_rule jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_mapped int := 0; v_ties int := 0; v_rules jsonb := '{}'::jsonb;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'n2s_gt_map_by_name: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  SET LOCAL statement_timeout = '30s';

  -- ON COMMIT DROP only fires at commit: a second call in the same transaction
  -- would otherwise fail with "relation already exists".
  DROP TABLE IF EXISTS _n2s_gt_cand;
  CREATE TEMP TABLE _n2s_gt_cand ON COMMIT DROP AS
  WITH ev AS (
    SELECT DISTINCT i.tevo_event_id
      FROM public.n2s_items i
     WHERE NOT i.is_terminal AND i.tevo_event_id IS NOT NULL
       AND public.n2s_event_live(i.event_dt, i.tevo_event_id)
       AND (NOT p_only_unlinked
            OR NOT EXISTS (SELECT 1 FROM public.gotickets_event g0
                            WHERE g0.tevo_event_id = i.tevo_event_id))
  ),
  tevo AS (
    SELECT e.id, e.name, e.venue_name, e.primary_performer_name,
           CASE WHEN e.occurs_at_local ~ '[+-]\d\d:\d\d$' THEN 'offset'
                WHEN e.occurs_at_local ~ 'T00:00:00'      THEN 'tbd'
                ELSE 'naive' END                                   AS time_kind,
           -- the matching window as a half-open range, so idx_gt_event_time serves it
           CASE WHEN e.occurs_at_local ~ '[+-]\d\d:\d\d$'
                THEN date_trunc('minute', e.occurs_at_local::timestamptz)
                ELSE ((left(e.occurs_at_local, 10)::date - p_date_slop_days)::timestamp AT TIME ZONE 'UTC')
           END                                                     AS win_lo,
           CASE WHEN e.occurs_at_local ~ '[+-]\d\d:\d\d$'
                THEN date_trunc('minute', e.occurs_at_local::timestamptz) + interval '1 minute'
                ELSE ((left(e.occurs_at_local, 10)::date + p_date_slop_days + 1)::timestamp AT TIME ZONE 'UTC')
           END                                                     AS win_hi
      FROM ev JOIN public.events e ON e.id = ev.tevo_event_id
     WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
  ),
  cand AS (
    SELECT g.gt_event_id, t.id AS tevo_id, t.time_kind,
           similarity(lower(g.name),       lower(t.name))       AS name_sim,
           similarity(lower(g.venue_name), lower(t.venue_name)) AS venue_sim,
           COALESCE(similarity(lower(g.performer), lower(t.primary_performer_name)), 0) AS perf_sim,
           (t.primary_performer_name IS NOT NULL
            AND lower(g.name) LIKE '%' || lower(t.primary_performer_name) || '%')       AS perf_in_gt_name
      FROM tevo t
      JOIN public.gotickets_event g
        ON g.event_time_utc >= t.win_lo
       AND g.event_time_utc <  t.win_hi
       AND g.tevo_event_id IS NULL
       AND g.status = 'AS_SCHEDULED'
       AND g.name NOT ILIKE '%parking%'
       AND g.name NOT ILIKE 'cancelled:%'
       AND g.name NOT ILIKE '%season ticket%'
  ),
  scored AS (
    SELECT *,
           CASE
             -- rule A: a real instant, and the show reads the same on both sides
             WHEN time_kind = 'offset' AND name_sim >= p_min_name AND venue_sim >= p_min_venue
               THEN 'minute_name_venue'
             -- rule B: a real instant at the same venue, and the performer agrees
             --         even though the names diverge (support act listed first, etc.)
             WHEN time_kind = 'offset' AND venue_sim >= 0.80 AND name_sim >= p_min_name_perf
                  AND (perf_sim >= 0.45 OR perf_in_gt_name)
               THEN 'minute_venue_performer'
             -- rule C: no usable instant, so the date window is wide and the
             --         text evidence must be near-exact on BOTH name and venue
             WHEN time_kind <> 'offset' AND name_sim >= p_min_name_date AND venue_sim >= 0.80
               THEN 'date_name_venue_strict'
           END AS rule
      FROM cand
  )
  SELECT s.*,
         row_number() OVER (PARTITION BY s.gt_event_id ORDER BY s.name_sim DESC, s.venue_sim DESC) AS rn,
         count(*)     OVER (PARTITION BY s.gt_event_id) AS n_cands
    FROM scored s
   WHERE s.rule IS NOT NULL;

  SELECT count(DISTINCT gt_event_id) INTO v_ties FROM _n2s_gt_cand WHERE n_cands > 1;

  UPDATE public.gotickets_event g
     SET tevo_event_id = c.tevo_id,
         mapped_via    = 'n2s_' || c.rule,
         map_score     = round(c.name_sim::numeric, 3),
         mapped_at     = now(),
         updated_at    = now()
    FROM _n2s_gt_cand c
   WHERE c.rn = 1 AND c.n_cands = 1          -- a tie is refused, not guessed
     AND g.gt_event_id = c.gt_event_id
     AND g.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_mapped = ROW_COUNT;

  SELECT COALESCE(jsonb_object_agg(rule, n), '{}'::jsonb) INTO v_rules
    FROM (SELECT rule, count(*) AS n FROM _n2s_gt_cand WHERE rn = 1 AND n_cands = 1 GROUP BY rule) x;

  RETURN QUERY SELECT v_mapped, v_ties, v_rules;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric, numeric, numeric, integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric, numeric, numeric, integer, boolean) TO service_role;

COMMENT ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric, numeric, numeric, integer, boolean) IS
  'D7 second-pass GoTickets mapper, scoped to the OPEN N2S book. Classifies each open TEvo event by the shape of its time — offset (real instant), naive (no offset), tbd (midnight placeholder) — and applies a rule per shape: A) same minute + name ≥ 0.6 + venue ≥ 0.6; B) same minute + venue ≥ 0.8 + name ≥ 0.4 + performer agrees (sim ≥ 0.45 or TEvo primary performer appears in the GT name); C) no usable instant → same local date ±1 day + name ≥ 0.8 + venue ≥ 0.8. Excludes parking / cancelled / season-ticket rows and anything already mapped; best candidate per GT event, ties refused. Marks rows mapped_via=n2s_<rule>, which gt_map_events leaves alone. Never overwrites an existing mapping. Returns (mapped, refused_ties, by_rule). The time window is a half-open range on event_time_utc so idx_gt_event_time serves it (20260926031431). p_only_unlinked => true restricts to live events with no GoTickets link yet (~2 s): run EVERY tick by n2s_pipeline_tick before n2s_pull_all_sources; the full pass runs every 30 min in cron n2s_gt_map_by_name_full_30min.';

-- ── back into the tick, every tick, before the poller ──────────────────────
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_pipeline_tick'::regproc);
  v_pat text := '-- GoTickets name matcher runs as its own job, n2s_gt_map_by_name_1min \(20260926014415\)\.[ \t]*\n?[ \t]*';
  v_hits int;
BEGIN
  SELECT count(*) INTO v_hits FROM regexp_matches(v_def, v_pat, 'g');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick: expected the 20260926014415 marker once, found %', v_hits;
  END IF;
  v_def := regexp_replace(v_def, v_pat,
    '-- GoTickets name matcher, EVERY tick, scoped to events with no GoTickets link' || E'\n  ' ||
    '-- (~2 s; 20260926031431). Before the poller so a new link is polled this tick.' || E'\n  ' ||
    'v_stage := ''gt_map_by_name'';' || E'\n  ' ||
    'IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN' || E'\n    ' ||
    'BEGIN' || E'\n      ' ||
    'PERFORM * FROM public.n2s_gt_map_by_name(p_only_unlinked => true);' || E'\n    ' ||
    'EXCEPTION WHEN OTHERS THEN' || E'\n      ' ||
    'v_errors := v_errors || jsonb_build_object(''stage'', v_stage, ''err'', SQLERRM);' || E'\n    ' ||
    'END;' || E'\n  ' ||
    'END IF;' || E'\n\n  ');
  EXECUTE v_def;
  IF position('n2s_gt_map_by_name(p_only_unlinked => true)' in pg_get_functiondef('public.n2s_pipeline_tick'::regproc)) = 0 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick: scoped matcher call did not land';
  END IF;
END $$;

-- ── the every-minute job becomes a 30-minute full pass ─────────────────────
SELECT cron.unschedule('n2s_gt_map_by_name_1min');
SELECT cron.schedule(
  'n2s_gt_map_by_name_full_30min',
  '13,43 * * * *',
  $cmd$
  SET statement_timeout = '60s';
  DO $b$ BEGIN
    IF NOT public.cron_should_fire('n2s_gt_map_by_name_full_30min') THEN RETURN; END IF;
    PERFORM * FROM public.n2s_gt_map_by_name();
  END $b$;
  $cmd$
);

-- ── rollback ───────────────────────────────────────────────────────────────
-- SELECT cron.unschedule('n2s_gt_map_by_name_full_30min');
-- In n2s_pipeline_tick, replace the "GoTickets name matcher, EVERY tick" block
-- with the pre-20260926014415 5th-minute block (quoted verbatim in
-- 20260926014415's rollback section).
-- The function rewrite is behaviour-identical (see WHY/FIX above) and may stay.
