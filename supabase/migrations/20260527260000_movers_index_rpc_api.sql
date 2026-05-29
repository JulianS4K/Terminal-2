-- 20260527260000_movers_index_rpc_api.sql
--
-- Movers Index v2 RPCs — reads from event_movers_index (seeded by mig 250000).
--
-- Two new functions:
--   get_event_movers_v2          — per-event rows from event_movers_index with
--                                  cross-source spread columns (evo/sg/td medians)
--   get_event_movers_index_summary — one row per (source, window_days, category):
--                                  size, 24h entry/exit turnover, avg signal score,
--                                  data coverage pct
--
-- app.py /api/broker/movers gets two new optional params:
--   source      (default "merged") — index source to query
--   window_days (default None)     — event horizon in days; if set, routes to v2 path
--   category    (default None)     — filter to one category; None = all categories
-- Existing window_hours / legacy path is UNCHANGED when window_days is not supplied.

-- ── 1. get_event_movers_v2 ──────────────────────────────────────────────────
--
-- Returns per-event index rows ordered by (category, rank).
-- Each row includes:
--   • Index metadata: source, window_days, category, rank, signal_score
--   • Event context: name, venue, occurs_at, days_to_event
--   • Entry/current/delta metrics: price, owned count, ticket count
--   • Cross-source medians from latest event_listing_snapshot_daily row
--   • Platform spread pcts: sh_vs_evo, gt_vs_sh, vd_vs_sh
--
-- When p_category IS NULL all categories are returned, up to p_limit total rows
-- (ordered by category, rank — so p_limit=200 safely covers 6 cat × 25 events).

CREATE OR REPLACE FUNCTION public.get_event_movers_v2(
  p_source      text DEFAULT 'merged',
  p_window_days int  DEFAULT 7,
  p_category    text DEFAULT NULL,    -- NULL → all categories
  p_limit       int  DEFAULT 25
) RETURNS TABLE (
  source            text,
  window_days       int,
  category          text,
  rank              int,
  event_id          bigint,
  event_name        text,
  venue_name        text,
  occurs_at         text,             -- ISO-8601 local (UTC) string
  days_to_event     int,
  entry_price       numeric,
  cur_price         numeric,
  price_delta_pct   numeric,
  cur_owned         int,
  owned_delta       numeric,
  cur_tix           int,
  tix_delta         numeric,
  signal_score      numeric,
  days_in_index     numeric,          -- decimal days since entered_at
  data_coverage_pct numeric,
  -- Cross-source medians from latest daily snapshot (NULL until snapshot accumulates)
  evo_median        numeric,
  sg_median         numeric,
  td_sh_median      numeric,
  td_gt_median      numeric,
  td_vd_median      numeric,
  -- Platform spread vs baseline (pct, NULL if either operand is NULL or zero)
  sh_vs_evo_spread  numeric,          -- (SH - EVO) / EVO × 100
  gt_vs_sh_spread   numeric,          -- (GT - SH)  / SH  × 100
  vd_vs_sh_spread   numeric           -- (VD - SH)  / SH  × 100
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
    GREATEST(0, FLOOR(
      EXTRACT(EPOCH FROM (sgc.sg_datetime_utc - now())) / 86400.0
    ))::int                                                     AS days_to_event,
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
    -- Cross-source medians: latest snapshot row per event (sub-ms LATERAL scan)
    sn.evo_retail_median  AS evo_median,
    sn.sg_all_median      AS sg_median,
    sn.td_sh_median,
    sn.td_gt_median,
    sn.td_vd_median,
    -- Spread: SH premium over EVO retail
    ROUND(
      (sn.td_sh_median - sn.evo_retail_median)
        / NULLIF(sn.evo_retail_median, 0) * 100,
      2
    )                                                           AS sh_vs_evo_spread,
    -- Spread: GT premium over SH (inter-platform arbitrage signal)
    ROUND(
      (sn.td_gt_median - sn.td_sh_median)
        / NULLIF(sn.td_sh_median, 0) * 100,
      2
    )                                                           AS gt_vs_sh_spread,
    -- Spread: VD premium over SH
    ROUND(
      (sn.td_vd_median - sn.td_sh_median)
        / NULLIF(sn.td_sh_median, 0) * 100,
      2
    )                                                           AS vd_vs_sh_spread
  FROM public.event_movers_index idx
  JOIN public.sg_events_canonical sgc
    ON sgc.tevo_event_id = idx.event_id
  LEFT JOIN LATERAL (
    -- Latest snapshot slot per event: evening > midday > morning, most recent date first
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
  'Added 2026-05-27 (mig 260000).';


-- ── 2. get_event_movers_index_summary ───────────────────────────────────────
--
-- Index health: one row per (source, window_days, category).
-- Useful for understanding index maturity (data_coverage_pct) and turnover
-- velocity (entries/exits in last 24h).
-- p_source / p_window_days = NULL returns all combinations.

CREATE OR REPLACE FUNCTION public.get_event_movers_index_summary(
  p_source      text DEFAULT NULL,    -- NULL → all sources
  p_window_days int  DEFAULT NULL     -- NULL → all window sizes
) RETURNS TABLE (
  source              text,
  window_days         int,
  category            text,
  index_size          bigint,
  avg_signal_score    numeric,
  avg_price_delta_pct numeric,
  avg_data_coverage   numeric,
  entries_24h         bigint,         -- events that entered this index in last 24h
  exits_24h           bigint,         -- events that exited this index in last 24h
  last_computed_at    timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT
    i.source,
    i.window_days,
    i.category,
    COUNT(*)::bigint                                            AS index_size,
    ROUND(AVG(i.signal_score),      4)                         AS avg_signal_score,
    ROUND(AVG(i.price_delta_pct),   2)                         AS avg_price_delta_pct,
    ROUND(AVG(i.data_coverage_pct), 1)                         AS avg_data_coverage,
    COALESCE((
      SELECT COUNT(*)::bigint
      FROM   public.event_movers_index_history h
      WHERE  h.source      = i.source
        AND  h.window_days = i.window_days
        AND  h.category    = i.category
        AND  h.action      = 'enter'
        AND  h.recorded_at > now() - interval '24 hours'
    ), 0)                                                       AS entries_24h,
    COALESCE((
      SELECT COUNT(*)::bigint
      FROM   public.event_movers_index_history h
      WHERE  h.source      = i.source
        AND  h.window_days = i.window_days
        AND  h.category    = i.category
        AND  h.action      = 'exit'
        AND  h.recorded_at > now() - interval '24 hours'
    ), 0)                                                       AS exits_24h,
    MAX(i.last_computed_at)                                     AS last_computed_at
  FROM public.event_movers_index i
  WHERE (p_source IS NULL OR i.source = p_source)
    AND (p_window_days IS NULL OR i.window_days = p_window_days)
  GROUP BY i.source, i.window_days, i.category
  ORDER BY i.source, i.window_days, i.category;
$$;

REVOKE ALL ON FUNCTION public.get_event_movers_index_summary(text,int) FROM anon, public;
COMMENT ON FUNCTION public.get_event_movers_index_summary IS
  'Index health summary: one row per (source, window_days, category). '
  'Tracks size, 24h entry/exit turnover, avg signal score and data coverage. '
  'data_coverage_pct < 100 means some events lacked enough history for full SMA. '
  'Added 2026-05-27 (mig 260000).';
