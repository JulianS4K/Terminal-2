-- Migration 20260911020000 · level:secondary-sales · lane:D7 · writes:gotickets_event,cron.job · reads:n2s_items,events,gotickets_event · pre:20260911010000
-- ============================================================================
-- Migration 20260911020000 — n2s_gt_map_by_name(): GoTickets name+venue fallback
--
-- Lane: D7 · Pre-reqs: 20260804230000 (gt_map_events), 20260910180000 (rule 5),
--                      20260910290000 (cron 598 = map, then pull)
--
-- ── THE GAP ────────────────────────────────────────────────────────────────
-- A1's gt_map_events() links a GoTickets event to a TEvo event by ONE test:
-- same minute AND similarity(gt.performer, events.primary_performer_name)
-- > 0.45. That is the right test for GT's catalogue at large, but it has a
-- blind spot the N2S book walked straight into on 2026-09-11:
--
--   GT  1531741  "$uicideboy$ with Shakewell, Destroy Lonely, …"  performer "$uicideboy$"
--   TEvo 3349548 "Suicideboys with Destroy Lonely, Shakewell, …"  primary_performer "Shakewell"
--
-- Same minute, same venue, event-name similarity 0.92 — and performer
-- similarity 0.00, because the TEvo catalogue lists the SUPPORT act as the
-- primary performer. gt_map_events cannot see past that field, so the GT
-- event stays unmapped, n2s_pull_events (which selects GT events by
-- tevo_event_id) never fires it, and two obligations on that show can never
-- be covered from GoTickets.
--
-- ── THE FIX ────────────────────────────────────────────────────────────────
-- A D7 second pass, scoped to the OPEN N2S BOOK only, run right after
-- n2s_map_events in cron 598. For each unmapped, scheduled, non-parking GT
-- event at the same minute as an open N2S event, map it when the EVENT NAME
-- and the VENUE both agree (trigram similarity ≥ 0.6 each), taking the best
-- name score per GT event and refusing a tie. Rows it maps carry
-- mapped_via = 'n2s_name_venue_minute', which gt_map_events leaves alone (it
-- only touches NULL / 'instant_performer' rows), so the two passes never
-- fight.
--
-- Measured before authoring, against the live book: exactly ONE candidate
-- (the one above) at name 0.92 / venue 1.00; the next-best same-minute
-- neighbours score 0.07–0.11 on name. 0.6 sits well clear of both.
--
-- ⚠ CROSS-LANE: gotickets_event is A1's GT data plane; cron 598 is D7's.
-- Operator-directed write (2026-09-11), scoped to open N2S events, never
-- overwriting an existing mapping. Flagged to A1 in bot_chat.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_gt_map_by_name(
  p_min_name  numeric DEFAULT 0.6,
  p_min_venue numeric DEFAULT 0.6
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  SET LOCAL statement_timeout = '30s';
  WITH ev AS (
    SELECT DISTINCT i.tevo_event_id
      FROM public.n2s_items i
     WHERE NOT i.is_terminal AND i.tevo_event_id IS NOT NULL
       AND i.event_dt::date >= current_date
  ),
  cand AS (
    SELECT g.gt_event_id, e.id AS tevo_id,
           similarity(lower(g.name), lower(e.name)) AS name_sim,
           row_number() OVER (PARTITION BY g.gt_event_id
                              ORDER BY similarity(lower(g.name), lower(e.name)) DESC) AS rn,
           count(*)     OVER (PARTITION BY g.gt_event_id) AS n_cands
      FROM ev
      JOIN public.events e ON e.id = ev.tevo_event_id
      JOIN public.gotickets_event g
        ON g.tevo_event_id IS NULL
       AND g.status = 'AS_SCHEDULED'
       AND g.name NOT ILIKE '%parking%'
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
       AND date_trunc('minute', g.event_time_utc) = date_trunc('minute', e.occurs_at_local::timestamptz)
       AND similarity(lower(g.name), lower(e.name)) >= p_min_name
       AND similarity(lower(g.venue_name), lower(e.venue_name)) >= p_min_venue
  )
  UPDATE public.gotickets_event g
     SET tevo_event_id = c.tevo_id,
         mapped_via    = 'n2s_name_venue_minute',
         map_score     = round(c.name_sim::numeric, 3),
         mapped_at     = now(),
         updated_at    = now()
    FROM cand c
   WHERE c.rn = 1 AND c.n_cands = 1          -- a tie is refused, not guessed
     AND g.gt_event_id = c.gt_event_id
     AND g.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

COMMENT ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric) IS
  'D7 second-pass GoTickets mapper, scoped to the OPEN N2S book. Maps an unmapped, scheduled, non-parking GT event to the open N2S event at the same minute when event-NAME and VENUE trigram similarity are both >= the thresholds (default 0.6), best name score per GT event, ties refused. Exists because gt_map_events() matches on performer only and the TEvo catalogue sometimes lists a support act as primary performer (Suicideboys/Shakewell, 2026-09-11). Marks rows mapped_via=n2s_name_venue_minute, which gt_map_events leaves alone. Never overwrites an existing mapping. Runs in cron 598 between n2s_map_events and n2s_pull_all_sources.';

REVOKE ALL ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric) TO service_role;

-- ── wire it into the map-then-pull cron, between the two existing steps ─────
-- cron.job is not directly writable (42501); alter_job is the sanctioned path.
-- Guarded so a re-run does not double the call.
DO $do$
DECLARE v_cmd text;
BEGIN
  SELECT command INTO v_cmd FROM cron.job WHERE jobid = 598;
  IF v_cmd IS NULL THEN
    RAISE EXCEPTION 'cron job 598 (n2s_map_events_5min) not found — re-derive this migration';
  END IF;
  IF position('n2s_gt_map_by_name' in v_cmd) > 0 THEN
    RAISE NOTICE 'cron 598 already calls n2s_gt_map_by_name; leaving it';
  ELSIF position('SELECT public.n2s_pull_all_sources();' in v_cmd) = 0 THEN
    RAISE EXCEPTION 'cron 598 command has drifted (no n2s_pull_all_sources call): %', v_cmd;
  ELSE
    PERFORM cron.alter_job(598, command := replace(v_cmd,
      'SELECT public.n2s_pull_all_sources();',
      'SELECT public.n2s_gt_map_by_name(); SELECT public.n2s_pull_all_sources();'));
  END IF;
END $do$;
