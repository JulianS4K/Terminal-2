-- ============================================================================
-- Migration 20260709221500 — Enroll TM/GT/TP from /match for NON-SeatGeek-anchored events
--
-- Lane:     A1 (data plane — TicketsData TM coverage)
-- Touches:  td_gt_tm_enroll_from_match() [CREATE OR REPLACE — key on COALESCE(sg,tevo), drop sg-only gate].
-- Reads/writes on run: td_match_results, aq_event_map (R); ticketsdata_event_xref (W — enroll TM/GT/TP).
-- Pre-reqs: 20260704160040 (introduced td_gt_tm_enroll_from_match; live had since added TP — codified here).
-- Auth:     operator directive 2026-07-09 (julian@s4kent.com — "most events are TM primary; check tm_url").
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- Test result (2026-07-09): /match DOES return a tm_url for **73%** of upcoming matched events
-- (341 of 467; zero extraction misses — the ticketmaster_us/_ca keys are read correctly). But the
-- enroller required `r.sg_event_id IS NOT NULL` and keyed ticketsdata_event_xref.event_id on sg_event_id,
-- so **~224 events that carry a tm_url but are NOT SeatGeek-anchored (sg_event_id NULL) were silently
-- dropped** — leaving TM at ~155 despite TM being primary. That sg-anchor gate, not /match, was the cap.
--
-- FIX: key enrollment on COALESCE(sg_event_id, tevo_event_id). tevo_event_id is present on 100% of the
-- dropped events (verified 223/223), and event_id is only a per-platform unique key — downstream (td_pull_
-- drain / td_tier_enqueue) links via aq_short_event_id, never via event_id's numeric identity — so a
-- tevo-keyed row behaves identically. Safeguards against double-enrolling one event under two keys:
--   * DISTINCT ON (aq_short_event_id, platform), ORDER BY … sg_event_id NULLS LAST → one row per event
--     per platform, preferring the sg key when any match row has it (existing sg-keyed rows stay stable).
--   * INSERT … WHERE NOT EXISTS a row for the same (aq_short_event_id, platform) under a DIFFERENT
--     event_id → never re-keys an already-enrolled event (no sg/tevo duplicate on later transitions).
-- Also codifies a live drift: the running function already enrolled TP (match_method 'gt_tm_tp_from_match')
-- vs the committed GT/TM-only shape in 20260704160040.
--
-- Impact: enrolls ~223 previously-dropped upcoming TM events now (TM ~155 → ~375), plus the GT/TP
-- equivalents, and keeps capturing them as new matches land (the hourly enroll cron already calls this).
-- Newly-enrolled events are then polled by the TM tier/peak crons — bounded by td_budget_ok() (≤225k/cycle).
--
-- Idempotent (CREATE OR REPLACE + ON CONFLICT upsert) -> apply-before-PR under operator direction.
-- Rollback: restore the sg_event_id-only body from 20260704160040 (extra tevo-keyed rows are inert if left).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.td_gt_tm_enroll_from_match()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'td_gt_tm_enroll_from_match: forbidden for %', current_user USING ERRCODE = '42501';
  END IF;

  WITH m AS (
    SELECT DISTINCT ON (COALESCE(r.sg_event_id, r.tevo_event_id), plat.platform)
           COALESCE(r.sg_event_id, r.tevo_event_id) AS event_id,
           r.aq_short_event_id, plat.platform, plat.url
    FROM public.td_match_results r
    JOIN public.aq_event_map a ON a.aq_short_event_id = r.aq_short_event_id
    JOIN LATERAL (VALUES ('GT', r.gametime_url), ('TM', r.tm_url), ('TP', r.tickpick_url)) AS plat(platform, url)
      ON plat.url IS NOT NULL
    WHERE COALESCE(r.sg_event_id, r.tevo_event_id) IS NOT NULL
      AND a.event_date > now()
      AND a.event_name NOT ILIKE '%parking%'
    ORDER BY COALESCE(r.sg_event_id, r.tevo_event_id), plat.platform, r.created_at DESC
  )
  INSERT INTO public.ticketsdata_event_xref
    (event_id, platform, aq_short_event_id, event_url, active, manual_opt_in, match_method, meta, updated_at)
  SELECT m.event_id, m.platform, m.aq_short_event_id, m.url, true, true, 'gt_tm_tp_from_match',
         jsonb_build_object('seed','gt_tm_tp_from_match','seeded_at', now()), now()
  FROM m
  WHERE NOT EXISTS (
    SELECT 1 FROM public.ticketsdata_event_xref x2
    WHERE x2.aq_short_event_id = m.aq_short_event_id
      AND x2.platform          = m.platform
      AND x2.event_id         <> m.event_id
  )
  ON CONFLICT (event_id, platform) DO UPDATE
    SET active = true, manual_opt_in = true,
        event_url = COALESCE(public.ticketsdata_event_xref.event_url, EXCLUDED.event_url),
        updated_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$function$;
REVOKE ALL ON FUNCTION public.td_gt_tm_enroll_from_match() FROM anon, public;
GRANT EXECUTE ON FUNCTION public.td_gt_tm_enroll_from_match() TO service_role;

-- Enroll the previously-dropped events now (the hourly cron will keep it current thereafter).
SELECT public.td_gt_tm_enroll_from_match();
