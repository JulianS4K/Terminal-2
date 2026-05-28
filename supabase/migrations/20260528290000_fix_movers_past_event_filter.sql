-- 20260528290000_fix_movers_past_event_filter.sql
--
-- Bug: movers tab shows past events (days_to_event = 0) because:
--   1. get_event_movers_v2 used GREATEST(0,...) clipping negatives to 0 instead
--      of filtering past events out entirely.
--   2. compute_event_movers_index_all() had no global purge for past events;
--      stale rows survive between cron fires (up to 8h) or after compute exceptions.
--
-- Fix:
--   A. Recreate get_event_movers_v2 with sg_datetime_utc > now() filter.
--   B. Recreate compute_event_movers_index_all() with a global past-event purge
--      at the top (runs once per all-combo cycle, covers all source×window slices).

-- ── A. get_event_movers_v2 — add future-event filter ────────────────────────

CREATE OR REPLACE FUNCTION public.get_event_movers_v2(
  p_source      text DEFAULT 'merged',
  p_window_days int  DEFAULT 7,
  p_category    text DEFAULT NULL,
  p_limit       int  DEFAULT 25
) RETURNS TABLE (
  source            text,
  window_days       int,
  category          text,
  rank              int,
  event_id          bigint,
  event_name        text,
  venue_name        text,
  occurs_at         text,
  days_to_event     int,
  entry_price       numeric,
  cur_price         numeric,
  price_delta_pct   numeric,
  cur_owned         int,
  owned_delta       numeric,
  cur_tix           int,
  tix_delta         numeric,
  signal_score      numeric,
  days_in_index     numeric,
  data_coverage_pct numeric,
  evo_median        numeric,
  sg_median         numeric,
  td_sh_median      numeric,
  td_gt_median      numeric,
  td_vd_median      numeric,
  sh_vs_evo_spread  numeric,
  gt_vs_sh_spread   numeric,
  vd_vs_sh_spread   numeric
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT
    idx.source,
    idx.window_days,
    idx.category,
    idx.rank,
    idx.event_id,
    sgc.sg_event_name                                           AS event_name,
    sgc.sg_venue_name                                           AS venue_name,
    to_char(sgc.sg_datetime_utc, 'YYYY-MM-DD"T"HH24:MI:SS')    AS occurs_at,
    -- Use FLOOR not GREATEST: negative means past event — these are now excluded below,
    -- but FLOOR keeps the value accurate for events occurring today (0 is valid for today).
    FLOOR(
      EXTRACT(EPOCH FROM (sgc.sg_datetime_utc - now())) / 86400.0
    )::int                                                      AS days_to_event,
    idx.entry_price,
    idx.cur_price,
    idx.price_delta_pct,
    idx.cur_owned,
    idx.owned_delta,
    idx.cur_tix,
    idx.tix_delta,
    idx.signal_score,
    ROUND(
      EXTRACT(EPOCH FROM (now() - idx.entered_at)) / 86400.0, 2
    )                                                           AS days_in_index,
    idx.data_coverage_pct,
    sn.evo_retail_median  AS evo_median,
    sn.sg_all_median      AS sg_median,
    sn.td_sh_median,
    sn.td_gt_median,
    sn.td_vd_median,
    ROUND(
      (sn.td_sh_median - sn.evo_retail_median)
        / NULLIF(sn.evo_retail_median, 0) * 100,
      2
    )                                                           AS sh_vs_evo_spread,
    ROUND(
      (sn.td_gt_median - sn.td_sh_median)
        / NULLIF(sn.td_sh_median, 0) * 100,
      2
    )                                                           AS gt_vs_sh_spread,
    ROUND(
      (sn.td_vd_median - sn.td_sh_median)
        / NULLIF(sn.td_sh_median, 0) * 100,
      2
    )                                                           AS vd_vs_sh_spread
  FROM public.event_movers_index idx
  JOIN public.sg_events_canonical sgc
    ON sgc.tevo_event_id = idx.event_id
   AND sgc.sg_datetime_utc > now()          -- FILTER: exclude past events entirely
  LEFT JOIN LATERAL (
    SELECT s.evo_retail_median,
           s.sg_all_median,
           s.td_sh_median,
           s.td_gt_median,
           s.td_vd_median
    FROM   public.event_listing_snapshot_daily s
    WHERE  s.event_id = idx.event_id
    ORDER BY s.snapshot_date DESC,
             CASE s.snapshot_slot
               WHEN 'evening' THEN 3
               WHEN 'midday'  THEN 2
               ELSE 1
             END DESC
    LIMIT 1
  ) sn ON true
  WHERE idx.source      = p_source
    AND idx.window_days = p_window_days
    AND (p_category IS NULL OR idx.category = p_category)
  ORDER BY idx.category, idx.rank
  LIMIT p_limit;
$$;

REVOKE ALL ON FUNCTION public.get_event_movers_v2(text,int,text,int) FROM anon, public;
COMMENT ON FUNCTION public.get_event_movers_v2 IS
  'v2 movers RPC: per-event rows from event_movers_index with cross-source spread '
  'columns. p_source + p_window_days are required; p_category=NULL returns all '
  'categories up to p_limit rows (ordered category, rank). '
  'FIXED 2026-05-28 (mig 290000): added sg_datetime_utc > now() to exclude past events; '
  'replaced GREATEST(0,...) with plain FLOOR so days_to_event is accurate for today events.';


-- ── B. compute_event_movers_index_all — add global past-event purge ──────────
--
-- Added before the source×window loop:
--   DELETE FROM event_movers_index WHERE event_id maps to an event that already occurred.
-- This handles:
--   - Events that fell out of a window since the last successful compute (up to 8h gap).
--   - Residual rows from failed compute runs (exception handler swallowed the EXIT DELETE).
--   - Any seeding-time events that have since passed.

CREATE OR REPLACE FUNCTION public.compute_event_movers_index_all()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_source   text;
  v_window   int;
  v_n        int;
  v_purged   int;
BEGIN
  -- ── Global past-event purge ─────────────────────────────────────────────────
  -- Remove all index rows for events that have already occurred.
  -- Runs once per full cycle (before any source×window compute).
  -- Belt-and-suspenders: the per-(source,window) EXIT DELETE handles normal
  -- compute-cycle exits; this handles gaps from partial failures and cron lag.
  DELETE FROM public.event_movers_index idx
  WHERE idx.event_id IN (
    SELECT sgc.tevo_event_id
    FROM public.sg_events_canonical sgc
    WHERE sgc.sg_datetime_utc < now()
      AND sgc.tevo_event_id IS NOT NULL
  );
  GET DIAGNOSTICS v_purged = ROW_COUNT;
  IF v_purged > 0 THEN
    PERFORM public.bot_chat_log(
      'data-collection', 'D0', 'status',
      format('movers: purged %s past-event rows from index', v_purged)
    );
  END IF;

  -- ── Per-source × per-window compute ────────────────────────────────────────
  FOREACH v_source IN ARRAY ARRAY['evo','sg','td_sh','td_gt','td_vd','merged'] LOOP
    FOREACH v_window IN ARRAY ARRAY[7,15,30,180,365] LOOP
      BEGIN
        v_n := public.compute_event_movers_index(v_source, v_window);
        PERFORM public.bot_chat_log(
          'data-collection', 'D0', 'status',
          format('movers(%s, %sd): %s events upserted', v_source, v_window, v_n)
        );
      EXCEPTION WHEN OTHERS THEN
        PERFORM public.bot_chat_log(
          'data-collection', 'D0', 'flag',
          format('movers(%s, %sd) ERROR: %s', v_source, v_window, SQLERRM)
        );
      END;
    END LOOP;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.compute_event_movers_index_all() FROM anon, public;
COMMENT ON FUNCTION public.compute_event_movers_index_all() IS
  'Run all 30 source×window combos (6 sources × 5 windows). '
  'FIXED 2026-05-28 (mig 290000): global past-event purge runs before the loop to '
  'clear stale rows from failed compute runs and inter-cron-fire gaps. '
  'Each combo wrapped in BEGIN/EXCEPTION so one failure does not abort all.';
