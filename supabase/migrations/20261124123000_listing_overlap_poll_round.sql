-- Migration 20261124123000 · level:data-collection · lane:A1 (data plane — cross-source listings) · writes:listing_overlap_config(+settle_evo_seconds,+settle_gt_seconds),listing_overlap_tick() fn (waits for the poll round) · reads:evo_listings_poll_state,gt_listings_poll_state,gotickets_event,event_metrics · pre:20261124120000
--
-- ============================================================================
-- Migration 20261124123000 — the overlap matcher matches a game once per poll round,
--   when both markets' responses are in
--
-- Lane:     A1 (data plane — cross-source listings)
-- Touches:  listing_overlap_config (W: two columns), listing_overlap_tick() (W: full definition),
--           evo_listings_poll_state (R), gt_listings_poll_state (R), gotickets_event (R), event_metrics (R)
-- Pre-reqs: 20261124120000 (applied 2026-11-24 04:03Z)
--
-- Operator 2026-11-17: "note response times and fix timer accordingly". Measured in production
-- in the first ten minutes after 20261124120000 went live (2026-11-24 04:03Z to 04:13Z):
--   * the first-time backlog (546 games polled in the last hour, 522,528 labels) cleared in
--     about six minutes;
--   * after that the tick still used its whole 20 s budget every 30 s. One match costs
--     0.25 s at the median and 1.0 s at the 95th percentile here, not the 0.07 s measured on
--     a laptop: the rows a poll has just written are read back from disk at about 5 ms a
--     page (67 pages, 330 ms for a 660-listing game; 9 ms once cached);
--   * and each poll round asked for TWO matches per game. The pinned poll fires both markets
--     in one tick; the EVO response is stored 18 s later (p95 64 s) and the GoTickets
--     response at second :01 to :08 of the next minute, so the game was matched when EVO
--     landed and again a minute later when GoTickets did. About 55 matches a minute were
--     wanted and about 54 fitted.
--
-- THE CHANGE. A game is matched when its poll round is complete: no EVO or GoTickets poll of
-- it is still on its way in. "On its way in" = fired after the capture we hold. It is waited
-- for until it is settle_evo_seconds (120) / settle_gt_seconds (150) old; after that it is
-- taken as lost (a failed request, a non-200) and the game is matched on what did land. So a
-- round costs one match, about 80 to 110 s after the poll fired, and the first match of the
-- two — which compared a fresh EVO book with the previous GoTickets book — no longer runs.
-- Nothing else in listing_overlap_tick() changes; this file carries its whole definition
-- (MIGRATION_CONVENTIONS section 6a).
--
-- rollback: re-apply listing_overlap_tick() from 20261124120000;
--           ALTER TABLE public.listing_overlap_config DROP COLUMN settle_evo_seconds, DROP COLUMN settle_gt_seconds;
-- ============================================================================

SET LOCAL lock_timeout = '10s';

ALTER TABLE public.listing_overlap_config
  ADD COLUMN IF NOT EXISTS settle_evo_seconds integer NOT NULL DEFAULT 120 CHECK (settle_evo_seconds BETWEEN 0 AND 600),
  ADD COLUMN IF NOT EXISTS settle_gt_seconds  integer NOT NULL DEFAULT 150 CHECK (settle_gt_seconds BETWEEN 0 AND 600);
COMMENT ON TABLE public.listing_overlap_config IS
  'One row. enabled = the kill switch for listing_overlap_tick(); price_center / price_band = the GoTickets all-in to EVO retail price ratio a pair must fall in (log scale); tick_* = work per 30-second tick; settle_*_seconds = how long a poll that has fired is waited for before the game is matched without it (migs 20261124120000, 20261124123000).';

CREATE OR REPLACE FUNCTION public.listing_overlap_tick(p_max integer DEFAULT NULL, p_budget_seconds integer DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start   timestamptz := clock_timestamp();
  v_cfg     public.listing_overlap_config%ROWTYPE;
  v_max     integer;
  v_budget  integer;
  r         record;
  v_done    integer := 0;
  v_err     integer := 0;
  v_stale   integer := 0;
  v_out     boolean := false;
BEGIN
  SELECT * INTO v_cfg FROM public.listing_overlap_config;
  IF NOT FOUND OR NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('enabled', false);
  END IF;
  v_max    := coalesce(p_max, v_cfg.tick_max_events);
  v_budget := coalesce(p_budget_seconds, v_cfg.tick_budget_seconds);

  FOR r IN
    WITH due AS (
      -- a poll fired after the capture last matched (cheap: the two poll clocks)
      SELECT ps.event_id AS eid
        FROM public.evo_listings_poll_state ps
        LEFT JOIN public.listing_overlap_event st ON st.tevo_event_id = ps.event_id
       WHERE ps.last_polled_listings_at > now() - interval '60 minutes'
         AND (st.evo_cap IS NULL OR ps.last_polled_listings_at > st.evo_cap)
      UNION
      SELECT ge.tevo_event_id
        FROM public.gt_listings_poll_state ps
        JOIN public.gotickets_event ge ON ge.gt_event_id = ps.gt_event_id
        LEFT JOIN public.listing_overlap_event st ON st.tevo_event_id = ge.tevo_event_id
       WHERE ps.last_polled_listings_at > now() - interval '60 minutes'
         AND ge.tevo_event_id IS NOT NULL
         AND (st.gt_cap IS NULL OR ps.last_polled_listings_at > st.gt_cap)),
    -- An EVO-polled game with no GoTickets event stays in "due" for the hour after each poll
    -- and never gets a row; it is dropped here on one small index probe, before the firehoses.
    gt AS MATERIALIZED (
      SELECT d.eid, public.listing_overlap_gt_cap(d.eid) AS cap
        FROM due d
       WHERE EXISTS (SELECT 1 FROM public.gotickets_event ge
                      WHERE ge.tevo_event_id = d.eid AND ge.status = 'AS_SCHEDULED'))
    SELECT g.eid
      FROM gt g
      LEFT JOIN public.listing_overlap_event st ON st.tevo_event_id = g.eid
      CROSS JOIN LATERAL (SELECT max(m.captured_at) AS cap FROM public.event_metrics m
                           WHERE m.event_id = g.eid AND m.captured_at > now() - interval '3 days') ec
     WHERE g.cap IS NOT NULL AND ec.cap IS NOT NULL
       -- … and that poll has landed: a capture differs from the one matched
       AND (st.tevo_event_id IS NULL OR ec.cap IS DISTINCT FROM st.evo_cap OR g.cap IS DISTINCT FROM st.gt_cap)
       -- … and the round is complete: no poll of this game is still on its way in. A poll that
       -- fired after the capture we hold has not been stored yet; it is waited for until it is
       -- settle_*_seconds old, then taken as lost and the game is matched on what did land.
       AND NOT EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                        WHERE ps.event_id = g.eid
                          AND ps.last_polled_listings_at > ec.cap
                          AND ps.last_polled_listings_at > now() - make_interval(secs => v_cfg.settle_evo_seconds))
       AND NOT EXISTS (SELECT 1 FROM public.gotickets_event ge
                         JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = ge.gt_event_id
                        WHERE ge.tevo_event_id = g.eid AND ge.status = 'AS_SCHEDULED'
                          AND ps.last_polled_listings_at > g.cap
                          AND ps.last_polled_listings_at > now() - make_interval(secs => v_cfg.settle_gt_seconds))
     ORDER BY st.matched_at NULLS FIRST, g.eid
     LIMIT v_max
  LOOP
    IF clock_timestamp() - v_start > make_interval(secs => v_budget) THEN
      v_out := true;
      EXIT;
    END IF;
    BEGIN
      PERFORM public.listing_overlap_match_event(r.eid);
      v_done := v_done + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      RAISE WARNING 'listing_overlap_tick: event % failed: %', r.eid, SQLERRM;
    END;
  END LOOP;

  -- Labels nobody has refreshed for 50 hours (both polls stopped: the game is over, or the
  -- event left the pins) describe a book that no longer exists. Bounded per tick.
  IF NOT v_out THEN
    FOR r IN
      SELECT st.tevo_event_id
        FROM public.listing_overlap_event st
       WHERE st.status = 'ok' AND st.matched_at < now() - interval '50 hours'
       ORDER BY st.matched_at
       LIMIT 50
    LOOP
      EXIT WHEN clock_timestamp() - v_start > make_interval(secs => v_budget);
      DELETE FROM public.listing_overlap_label WHERE tevo_event_id = r.tevo_event_id;
      UPDATE public.listing_overlap_event
         SET status = CASE WHEN evo_cap <= gt_cap THEN 'stale_evo' ELSE 'stale_gt' END,
             evo_listings = NULL, gt_listings = NULL, both_pairs = NULL, evo_only = NULL, gt_only = NULL,
             evo_unclear = NULL, gt_unclear = NULL, updated_at = now()
       WHERE tevo_event_id = r.tevo_event_id;
      v_stale := v_stale + 1;
    END LOOP;
    DELETE FROM public.listing_overlap_event WHERE matched_at < now() - interval '30 days';
  END IF;

  RETURN jsonb_build_object('enabled', true, 'matched', v_done, 'errors', v_err, 'expired', v_stale,
                            'out_of_time', v_out,
                            'ms', (extract(epoch FROM clock_timestamp() - v_start) * 1000)::integer);
END
$function$;
COMMENT ON FUNCTION public.listing_overlap_tick(integer, integer) IS
  'Scan-on-arrival for the EVO / GoTickets overlap labels: matches every event with an EVO or GoTickets listings capture newer than the one last matched, once its poll round is complete (no poll of it fired after the capture held and younger than listing_overlap_config.settle_*_seconds). Least recently matched first, at most p_max events, inside p_budget_seconds (both default to listing_overlap_config); then expires labels untouched for 50 hours. Does nothing when listing_overlap_config.enabled is false. Cron listing_overlap_tick_30s.';

REVOKE EXECUTE ON FUNCTION public.listing_overlap_tick(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.listing_overlap_tick(integer, integer) TO service_role;
