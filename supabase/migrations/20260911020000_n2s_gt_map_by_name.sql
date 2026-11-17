-- Migration 20260911020000 · level:secondary-sales · lane:D7 · writes:gotickets_event,cron.job · reads:n2s_items,events,gotickets_event · pre:20260911010000
--
-- Already applied to prod · via MCP 2026-09-11 under operator direction.
-- ============================================================================
-- Migration 20260911020000 — n2s_gt_map_by_name(): GoTickets second-pass mapper
--
-- Lane: D7 · Pre-reqs: 20260804230000 (gt_map_events), 20260910180000 (rule 5),
--                      20260910290000 (cron 598 = map, then pull)
--
-- ── THE GAP ────────────────────────────────────────────────────────────────
-- A1's gt_map_events() links a GoTickets event to a TEvo event by ONE test:
-- same minute AND similarity(gt.performer, events.primary_performer_name)
-- > 0.45. Right for GT's catalogue at large; blind in two ways the N2S book
-- walked into on 2026-09-11:
--
--   1. The TEvo catalogue can list the SUPPORT act as primary performer.
--      GT 1531741 "$uicideboy$ with Shakewell, Destroy Lonely, …" performer
--      "$uicideboy$" vs TEvo 3349548 "Suicideboys with Destroy Lonely,
--      Shakewell, …" primary_performer "Shakewell": performer sim 0.00,
--      event-name sim 0.92, venue sim 1.00, same minute, same venue.
--   2. The exact-minute join needs a real instant. 5 of 61 open N2S events
--      carry a TEvo time with NO offset ("2026-09-12T18:30:00", college
--      football) or a midnight PLACEHOLDER ("2026-10-03T00:00:00", time
--      TBD). Cast to timestamptz those land wherever the session timezone
--      puts them, so the minute test can never be true for them.
--
-- GoTickets only POLLS mapped events (4,096 GT events polled in the 24h
-- before this, 0 unmapped), so an unmapped event has no path to the matcher
-- at all: 1531741's last GT snapshot is 2026-08-31 and none of its 5,729 rows
-- carries a tevo_event_id.
--
-- ── THE FIX: A D7 SECOND PASS, SCOPED TO THE OPEN N2S BOOK, WITH EXPLICIT
-- ── CONDITIONS PER TIME-KIND ("if conditions", operator 2026-09-11) ─────────
-- Runs right after n2s_map_events in cron 598. Every open N2S event is
-- classified by the SHAPE of its TEvo time, and each shape gets its own
-- candidate window and its own acceptance rule, strictest where the time
-- evidence is weakest:
--
--   time_kind = 'offset'  ("…T18:30:00-04:00")  → candidates at the SAME MINUTE
--     rule A  name_sim ≥ 0.60 AND venue_sim ≥ 0.60            → minute_name_venue
--     rule B  venue_sim ≥ 0.80 AND name_sim ≥ 0.40
--             AND (perf_sim ≥ 0.45 OR TEvo's primary performer
--                  appears inside the GT event name)             → minute_venue_performer
--   time_kind = 'naive'   ("…T18:30:00", no offset) → candidates on the same
--   time_kind = 'tbd'     ("…T00:00:00", placeholder)  local DATE ±1 day
--     rule C  name_sim ≥ 0.80 AND venue_sim ≥ 0.80            → date_name_venue_strict
--
-- Hard exclusions before any rule: GT rows already mapped; not AS_SCHEDULED;
-- names containing "parking" / "season ticket" / starting "cancelled:".
-- Per GT event the best (name, venue) candidate wins and a TIE IS REFUSED —
-- a GT event with two plausible TEvo events is left for a human. Several GT
-- rows may map to one TEvo event (GT carries duplicate listings of a show).
--
-- Rows it maps carry mapped_via = 'n2s_<rule>', which gt_map_events leaves
-- alone (it only touches NULL / 'instant_performer' rows), so the two passes
-- never fight; an existing mapping is never overwritten.
--
-- Measured before authoring against the live book (19,619 candidate pairs
-- across all three time kinds): exactly ONE row passes any rule — the one
-- above, via rule A at 0.92 / 1.00. Nothing passes B or C today; the
-- next-best same-minute neighbours score 0.07–0.11 on name.
--
-- ⚠ CROSS-LANE: gotickets_event is A1's GT data plane; cron 598 is D7's.
-- Operator-directed write (2026-09-11), scoped to open N2S events, never
-- overwriting an existing mapping. Flagged to A1 in bot_chat 3638.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_gt_map_by_name(
  p_min_name         numeric DEFAULT 0.60,   -- rule A
  p_min_venue        numeric DEFAULT 0.60,   -- rule A
  p_min_name_perf    numeric DEFAULT 0.40,   -- rule B (venue ≥ 0.80 fixed)
  p_min_name_date    numeric DEFAULT 0.80,   -- rule C (venue ≥ 0.80 fixed)
  p_date_slop_days   integer DEFAULT 1       -- rule C window either side
)
RETURNS TABLE(mapped integer, refused_ties integer, by_rule jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_mapped int := 0; v_ties int := 0; v_rules jsonb := '{}'::jsonb;
BEGIN
  SET LOCAL statement_timeout = '30s';

  CREATE TEMP TABLE _n2s_gt_cand ON COMMIT DROP AS
  WITH ev AS (
    SELECT DISTINCT i.tevo_event_id
      FROM public.n2s_items i
     WHERE NOT i.is_terminal AND i.tevo_event_id IS NOT NULL
       AND i.event_dt::date >= current_date
  ),
  tevo AS (
    SELECT e.id, e.name, e.venue_name, e.primary_performer_name,
           CASE WHEN e.occurs_at_local ~ '[+-]\d\d:\d\d$' THEN 'offset'
                WHEN e.occurs_at_local ~ 'T00:00:00'      THEN 'tbd'
                ELSE 'naive' END                                   AS time_kind,
           left(e.occurs_at_local, 10)::date                       AS local_date,
           CASE WHEN e.occurs_at_local ~ '[+-]\d\d:\d\d$'
                THEN e.occurs_at_local::timestamptz END              AS at_utc
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
        ON g.tevo_event_id IS NULL
       AND g.status = 'AS_SCHEDULED'
       AND g.name NOT ILIKE '%parking%'
       AND g.name NOT ILIKE 'cancelled:%'
       AND g.name NOT ILIKE '%season ticket%'
       AND CASE WHEN t.time_kind = 'offset'
                THEN date_trunc('minute', g.event_time_utc) = date_trunc('minute', t.at_utc)
                ELSE (g.event_time_utc AT TIME ZONE 'UTC')::date
                     BETWEEN t.local_date - p_date_slop_days AND t.local_date + p_date_slop_days
           END
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

COMMENT ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric, numeric, numeric, integer) IS
  'D7 second-pass GoTickets mapper, scoped to the OPEN N2S book. Classifies each open TEvo event by the shape of its time — offset (real instant), naive (no offset), tbd (midnight placeholder) — and applies a rule per shape: A) same minute + name ≥ 0.6 + venue ≥ 0.6; B) same minute + venue ≥ 0.8 + name ≥ 0.4 + performer agrees (sim ≥ 0.45 or TEvo primary performer appears in the GT name); C) no usable instant → same local date ±1 day + name ≥ 0.8 + venue ≥ 0.8. Excludes parking / cancelled / season-ticket rows and anything already mapped; best candidate per GT event, ties refused. Exists because gt_map_events() matches on performer only and needs a real instant (Suicideboys/Shakewell 2026-09-11; 5 of 61 open events had no usable instant). Marks rows mapped_via=n2s_<rule>, which gt_map_events leaves alone. Never overwrites an existing mapping. Returns (mapped, refused_ties, by_rule). Runs in cron 598 between n2s_map_events and n2s_pull_all_sources.';

REVOKE ALL ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric, numeric, numeric, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n2s_gt_map_by_name(numeric, numeric, numeric, numeric, integer) TO service_role;

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
