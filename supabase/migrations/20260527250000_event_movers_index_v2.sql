-- 20260527250000_event_movers_index_v2.sql
--
-- Movers Index v2 + EVO/SG Discovery Redesign
--
-- Architecture:
--   source × window_days × category = one independent index (top 25 events)
--   window_days = EVENT HORIZON (events occurring in next N days), NOT historical lookback
--   source = 'evo' | 'sg' | 'td_sh' | 'td_gt' | 'td_vd' | 'merged'
--   Signal = half-window SMA vs prior-half SMA for trend detection
--   score = ABS(signal_pct) * LOG(1 + days_to_event)
--
-- Data depth (2026-05-27):
--   EVO  (event_metrics):          34 days → 7d/15d/30d clean; 180d/365d = capped proxy
--   SG   (seatgeek_event_metrics): 18 days → 7d/15d clean
--   TD*  (ticketsdata_listings):   1 day → sparse, grows daily
--   merged: event_listing_snapshot_daily (1d) + event_metrics fallback

-- ── Part A: Add TD columns to event_listing_snapshot_daily ───────────────────

ALTER TABLE public.event_listing_snapshot_daily
  ADD COLUMN IF NOT EXISTS td_sh_listings    int,
  ADD COLUMN IF NOT EXISTS td_sh_median      numeric(10,2),
  ADD COLUMN IF NOT EXISTS td_gt_listings    int,
  ADD COLUMN IF NOT EXISTS td_gt_median      numeric(10,2),
  ADD COLUMN IF NOT EXISTS td_vd_listings    int,
  ADD COLUMN IF NOT EXISTS td_vd_median      numeric(10,2),
  ADD COLUMN IF NOT EXISTS td_combined_median numeric(10,2);

COMMENT ON COLUMN public.event_listing_snapshot_daily.td_sh_listings    IS 'StubHub listing count at snapshot time';
COMMENT ON COLUMN public.event_listing_snapshot_daily.td_sh_median      IS 'StubHub median list_price (excl. parking)';
COMMENT ON COLUMN public.event_listing_snapshot_daily.td_gt_listings    IS 'GameTime listing count';
COMMENT ON COLUMN public.event_listing_snapshot_daily.td_gt_median      IS 'GameTime median list_price';
COMMENT ON COLUMN public.event_listing_snapshot_daily.td_vd_listings    IS 'VividSeats listing count';
COMMENT ON COLUMN public.event_listing_snapshot_daily.td_vd_median      IS 'VividSeats median list_price';
COMMENT ON COLUMN public.event_listing_snapshot_daily.td_combined_median IS 'LEAST(sh,gt,vd) median — most competitive TD price';

-- ── Part B: Index tables ─────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.event_movers_index (
  source           text        NOT NULL,  -- 'evo'|'sg'|'td_sh'|'td_gt'|'td_vd'|'merged'
  window_days      int         NOT NULL,  -- event horizon: 7|15|30|180|365
  category         text        NOT NULL,  -- 'price_up'|'price_down'|'selling_fast'|'accumulating'|'value_gap'|'cross_gap'
  event_id         bigint      NOT NULL,  -- tevo_event_id
  rank             int         NOT NULL,  -- 1–25 within (source, window_days, category)
  entered_at       timestamptz NOT NULL DEFAULT now(),
  last_computed_at timestamptz NOT NULL DEFAULT now(),
  entry_price      numeric(10,2),
  entry_owned      int,
  entry_tix        int,
  cur_price        numeric(10,2),
  cur_owned        int,
  cur_tix          int,
  price_delta_pct  numeric(8,4),
  owned_delta      numeric(8,2),
  tix_delta        numeric(8,2),
  signal_score     numeric(10,4),
  data_coverage_pct numeric(5,2),
  PRIMARY KEY (source, window_days, category, event_id)
);
CREATE INDEX IF NOT EXISTS idx_emi_rank  ON public.event_movers_index (source, window_days, category, rank);
CREATE INDEX IF NOT EXISTS idx_emi_event ON public.event_movers_index (event_id);

COMMENT ON TABLE public.event_movers_index IS
  'Top-25 movers per (source × window_days × category). '
  'window_days = event horizon (events in next N days). '
  'Signal = half-window SMA vs prior-half SMA. '
  'Updated 3x/day by compute_movers_index_post_snapshot cron (7:35/13:35/19:35 UTC).';

CREATE TABLE IF NOT EXISTS public.event_movers_index_history (
  id              bigserial   PRIMARY KEY,
  source          text        NOT NULL,
  window_days     int         NOT NULL,
  category        text        NOT NULL,
  event_id        bigint      NOT NULL,
  action          text        NOT NULL CHECK (action IN ('enter','exit','rank_change')),
  rank_before     int,
  rank_after      int,
  price_at_action numeric(10,2),
  signal_score_at numeric(10,4),
  recorded_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_emih_lookup ON public.event_movers_index_history
  (source, window_days, category, event_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_emih_time ON public.event_movers_index_history (recorded_at DESC);

COMMENT ON TABLE public.event_movers_index_history IS
  'Composition changes for event_movers_index: enter/exit/rank_change. '
  'When did an event join the index and at what price?';

-- ── Part C: Discovery gap alerts ─────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.discovery_gap_alerts (
  id           bigserial   PRIMARY KEY,
  event_id     bigint      NOT NULL,
  gap_type     text        NOT NULL,
  detail       text,
  signal_score numeric(8,4),
  detected_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at  timestamptz,
  UNIQUE (event_id, gap_type)
);
CREATE INDEX IF NOT EXISTS idx_dga_event  ON public.discovery_gap_alerts (event_id);
CREATE INDEX IF NOT EXISTS idx_dga_type   ON public.discovery_gap_alerts (gap_type, resolved_at);
CREATE INDEX IF NOT EXISTS idx_dga_active ON public.discovery_gap_alerts (detected_at DESC) WHERE resolved_at IS NULL;

COMMENT ON TABLE public.discovery_gap_alerts IS
  'Active market coverage and opportunity gaps from evo_sg_discovery_gaps(). '
  'gap_types: sg_no_evo | td_sh/gt/vd_no_evo | td_sh_no_gt | td_gt/vd_premium | '
  'evo_no_sg | value_gap_large | fill_rate_spike';

-- ── Part D: Update compute_event_listing_snapshot() with TD columns ──────────

CREATE OR REPLACE FUNCTION public.compute_event_listing_snapshot(
  p_slot text DEFAULT 'morning'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_count int := 0;
  v_jobname text;
BEGIN
  v_jobname := 'event_snapshot_' || p_slot;
  IF p_slot NOT IN ('morning','midday','evening') THEN
    v_jobname := 'event_snapshot_morning';
  END IF;

  IF NOT public.cron_should_fire(v_jobname) THEN RETURN 0; END IF;

  INSERT INTO public.event_listing_snapshot_daily (
    event_id, snapshot_slot, snapshot_date,
    evo_tickets_count, evo_owned_tickets, evo_owned_median,
    evo_retail_getin, evo_retail_median, evo_retail_mean,
    evo_retail_min, evo_retail_max,
    sg_all_listings, sg_all_tickets, sg_owned_tickets,
    sg_owned_median, sg_all_median, sg_all_getin, sg_all_mean,
    td_sh_listings, td_sh_median,
    td_gt_listings, td_gt_median,
    td_vd_listings, td_vd_median,
    td_combined_median,
    captured_at
  )
  SELECT
    em.event_id,
    p_slot,
    CURRENT_DATE,
    em.tickets_count,
    em.owned_tickets_count,
    em.owned_median_retail,
    em.getin_price,
    em.retail_median,
    em.retail_mean,
    em.retail_min,
    em.retail_max,
    sgm.listings_all_count,
    sgm.listings_all_tickets,
    sgm.listings_owned_tickets,
    sgm.listings_owned_median,
    sgm.listings_all_median,
    sgm.listings_all_min,
    sgm.listings_all_mean,
    td.sh_listings,   td.sh_median,
    td.gt_listings,   td.gt_median,
    td.vd_listings,   td.vd_median,
    LEAST(NULLIF(td.sh_median, 0), NULLIF(td.gt_median, 0), NULLIF(td.vd_median, 0)),
    now()
  FROM (
    SELECT DISTINCT ON (event_id)
      event_id, tickets_count, owned_tickets_count, owned_median_retail,
      getin_price, retail_median, retail_mean, retail_min, retail_max
    FROM public.event_metrics
    ORDER BY event_id, captured_at DESC
  ) em
  LEFT JOIN (
    SELECT DISTINCT ON (tevo_event_id)
      tevo_event_id, listings_all_count, listings_all_tickets,
      listings_owned_tickets, listings_owned_median,
      listings_all_median, listings_all_min, listings_all_mean
    FROM public.seatgeek_event_metrics
    ORDER BY tevo_event_id, captured_at DESC
  ) sgm ON sgm.tevo_event_id = em.event_id
  LEFT JOIN (
    SELECT
      sgc.tevo_event_id,
      COUNT(*) FILTER (WHERE tds.platform = 'SH')          AS sh_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tds.list_price)
        FILTER (WHERE tds.platform = 'SH')                 AS sh_median,
      COUNT(*) FILTER (WHERE tds.platform = 'GT')          AS gt_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tds.list_price)
        FILTER (WHERE tds.platform = 'GT')                 AS gt_median,
      COUNT(*) FILTER (WHERE tds.platform = 'VD')          AS vd_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tds.list_price)
        FILTER (WHERE tds.platform = 'VD')                 AS vd_median
    FROM public.ticketsdata_listings_snapshots tds
    JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = tds.event_id AND tdx.active = true
    JOIN public.aq_event_map aem           ON aem.aq_short_event_id = tdx.aq_short_event_id
    JOIN public.sg_events_canonical sgc    ON sgc.sg_event_id = aem.sg_event_id
    WHERE tds.captured_at > now() - interval '12 hours'
      AND tds.is_parking = false
      AND tds.list_price > 0
    GROUP BY sgc.tevo_event_id
  ) td ON td.tevo_event_id = em.event_id
  ON CONFLICT (event_id, snapshot_date, snapshot_slot) DO UPDATE SET
    evo_tickets_count  = EXCLUDED.evo_tickets_count,
    evo_owned_tickets  = EXCLUDED.evo_owned_tickets,
    evo_owned_median   = EXCLUDED.evo_owned_median,
    evo_retail_getin   = EXCLUDED.evo_retail_getin,
    evo_retail_median  = EXCLUDED.evo_retail_median,
    evo_retail_mean    = EXCLUDED.evo_retail_mean,
    evo_retail_min     = EXCLUDED.evo_retail_min,
    evo_retail_max     = EXCLUDED.evo_retail_max,
    sg_all_listings    = EXCLUDED.sg_all_listings,
    sg_all_tickets     = EXCLUDED.sg_all_tickets,
    sg_owned_tickets   = EXCLUDED.sg_owned_tickets,
    sg_owned_median    = EXCLUDED.sg_owned_median,
    sg_all_median      = EXCLUDED.sg_all_median,
    sg_all_getin       = EXCLUDED.sg_all_getin,
    sg_all_mean        = EXCLUDED.sg_all_mean,
    td_sh_listings     = EXCLUDED.td_sh_listings,
    td_sh_median       = EXCLUDED.td_sh_median,
    td_gt_listings     = EXCLUDED.td_gt_listings,
    td_gt_median       = EXCLUDED.td_gt_median,
    td_vd_listings     = EXCLUDED.td_vd_listings,
    td_vd_median       = EXCLUDED.td_vd_median,
    td_combined_median = EXCLUDED.td_combined_median,
    captured_at        = EXCLUDED.captured_at;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.compute_event_listing_snapshot(text) FROM anon, public;
COMMENT ON FUNCTION public.compute_event_listing_snapshot(text) IS
  'UPDATED 2026-05-27: added TD platform columns (td_sh/gt/vd listings + medians). '
  'Aggregates ticketsdata_listings_snapshots (last 12h) per event per platform. '
  'td_combined_median = LEAST(sh, gt, vd) excl. NULLs. '
  'Runs at 7:30/13:30/19:30 UTC via event_snapshot_morning/midday/evening crons.';

-- ── Part E: compute_event_movers_index() ────────────────────────────────────
-- Uses half-window SMA vs prior-half SMA for trend detection.
-- score = ABS(strongest_signal_pct) * LOG(1 + days_to_event)
-- Each event maps to one category (highest-scoring signal).
-- Upserts into event_movers_index + writes history for enters and exits.

CREATE OR REPLACE FUNCTION public.compute_event_movers_index(
  p_source      text DEFAULT 'merged',
  p_window_days int  DEFAULT 7
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  -- Use now() (transaction start time), NOT clock_timestamp().
  -- The UPSERT sets last_computed_at = v_now; the EXIT DELETE checks last_computed_at < v_now.
  -- If v_now were clock_timestamp() (wall time captured BEFORE the UPSERT), the UPSERT's
  -- now() (transaction start) would be EARLIER than v_now, so every row we just inserted
  -- would immediately satisfy last_computed_at < v_now and get deleted.
  v_now   timestamptz := now();
  v_half  numeric     := p_window_days / 2.0;
  v_count int         := 0;
BEGIN
  WITH
  horizon AS (
    SELECT sgc.tevo_event_id AS event_id,
           EXTRACT(EPOCH FROM (sgc.sg_datetime_utc - v_now)) / 86400.0 AS days_to_event
    FROM public.sg_events_canonical sgc
    WHERE sgc.sg_datetime_utc BETWEEN v_now AND v_now + (p_window_days || ' days')::interval
      AND sgc.tevo_event_id IS NOT NULL
  ),
  evo_agg AS (
    SELECT em.event_id,
      AVG(em.retail_median) FILTER (
        WHERE em.captured_at > v_now - (v_half || ' days')::interval)       AS price_recent,
      COUNT(*)              FILTER (
        WHERE em.captured_at > v_now - (v_half || ' days')::interval
          AND em.retail_median IS NOT NULL)                                   AS price_recent_n,
      AVG(em.retail_median) FILTER (
        WHERE em.captured_at BETWEEN v_now - (p_window_days || ' days')::interval
                                 AND v_now - (v_half || ' days')::interval)   AS price_prior,
      COUNT(*)              FILTER (
        WHERE em.captured_at BETWEEN v_now - (p_window_days || ' days')::interval
                                 AND v_now - (v_half || ' days')::interval
          AND em.retail_median IS NOT NULL)                                    AS price_prior_n,
      AVG(em.owned_tickets_count) FILTER (
        WHERE em.captured_at > v_now - (v_half || ' days')::interval)         AS owned_recent,
      AVG(em.owned_tickets_count) FILTER (
        WHERE em.captured_at BETWEEN v_now - (p_window_days || ' days')::interval
                                 AND v_now - (v_half || ' days')::interval)   AS owned_prior,
      (ARRAY_AGG(em.retail_median      ORDER BY em.captured_at DESC))[1]      AS cur_price,
      (ARRAY_AGG(em.owned_tickets_count ORDER BY em.captured_at DESC))[1]     AS cur_owned,
      (ARRAY_AGG(em.tickets_count       ORDER BY em.captured_at DESC))[1]     AS cur_tix
    FROM public.event_metrics em
    WHERE em.captured_at > v_now - (p_window_days || ' days')::interval
    GROUP BY em.event_id
  ),
  sg_agg AS (
    SELECT sgm.tevo_event_id AS event_id,
      AVG(sgm.listings_all_median) FILTER (
        WHERE sgm.captured_at > v_now - (v_half || ' days')::interval)        AS price_recent,
      COUNT(*)                     FILTER (
        WHERE sgm.captured_at > v_now - (v_half || ' days')::interval
          AND sgm.listings_all_median IS NOT NULL)                             AS price_recent_n,
      AVG(sgm.listings_all_median) FILTER (
        WHERE sgm.captured_at BETWEEN v_now - (p_window_days || ' days')::interval
                                  AND v_now - (v_half || ' days')::interval)  AS price_prior,
      COUNT(*)                     FILTER (
        WHERE sgm.captured_at BETWEEN v_now - (p_window_days || ' days')::interval
                                  AND v_now - (v_half || ' days')::interval
          AND sgm.listings_all_median IS NOT NULL)                             AS price_prior_n,
      AVG(sgm.fill_rate) FILTER (
        WHERE sgm.captured_at > v_now - (v_half || ' days')::interval)        AS fill_recent,
      AVG(sgm.fill_rate) FILTER (
        WHERE sgm.captured_at BETWEEN v_now - (p_window_days || ' days')::interval
                                  AND v_now - (v_half || ' days')::interval)  AS fill_prior,
      (ARRAY_AGG(sgm.listings_all_median ORDER BY sgm.captured_at DESC))[1]   AS cur_price,
      (ARRAY_AGG(sgm.listings_all_count  ORDER BY sgm.captured_at DESC))[1]   AS cur_tix
    FROM public.seatgeek_event_metrics sgm
    WHERE sgm.captured_at > v_now - (p_window_days || ' days')::interval
    GROUP BY sgm.tevo_event_id
  ),
  td_daily AS (
    SELECT sgc.tevo_event_id AS event_id,
           tds.platform,
           date_trunc('day', tds.captured_at) AS snap_day,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tds.list_price) AS daily_median,
           COUNT(*) AS cnt
    FROM public.ticketsdata_listings_snapshots tds
    JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = tds.event_id AND tdx.active = true
    JOIN public.aq_event_map aem           ON aem.aq_short_event_id = tdx.aq_short_event_id
    JOIN public.sg_events_canonical sgc    ON sgc.sg_event_id = aem.sg_event_id
    WHERE tds.captured_at > v_now - (p_window_days || ' days')::interval
      AND tds.is_parking = false AND tds.list_price > 0
    GROUP BY sgc.tevo_event_id, tds.platform, date_trunc('day', tds.captured_at)
  ),
  td_agg AS (
    SELECT td.event_id, td.platform,
      AVG(td.daily_median) FILTER (
        WHERE td.snap_day > (v_now - (v_half || ' days')::interval)::date)       AS price_recent,
      COUNT(*)             FILTER (
        WHERE td.snap_day > (v_now - (v_half || ' days')::interval)::date)       AS price_recent_n,
      AVG(td.daily_median) FILTER (
        WHERE td.snap_day BETWEEN (v_now - (p_window_days || ' days')::interval)::date
                              AND (v_now - (v_half || ' days')::interval)::date) AS price_prior,
      COUNT(*)             FILTER (
        WHERE td.snap_day BETWEEN (v_now - (p_window_days || ' days')::interval)::date
                              AND (v_now - (v_half || ' days')::interval)::date) AS price_prior_n,
      (ARRAY_AGG(td.daily_median ORDER BY td.snap_day DESC))[1]                  AS cur_price,
      (ARRAY_AGG(td.cnt          ORDER BY td.snap_day DESC))[1]                  AS cur_listings
    FROM td_daily td
    GROUP BY td.event_id, td.platform
  ),
  latest_snap AS (
    SELECT DISTINCT ON (s.event_id)
      s.event_id, s.evo_retail_median, s.sg_all_median,
      s.td_sh_median, s.td_gt_median, s.td_vd_median, s.evo_owned_tickets
    FROM public.event_listing_snapshot_daily s
    ORDER BY s.event_id, s.snapshot_date DESC,
      CASE s.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC
  ),
  raw_signals AS (
    SELECT
      h.event_id,
      h.days_to_event,
      -- Price delta (SMA-based) — computed per source
      CASE
        WHEN p_source = 'evo' AND ea.price_recent_n >= 3 AND ea.price_prior_n >= 3
             THEN (ea.price_recent - ea.price_prior) / NULLIF(ea.price_prior, 0) * 100
        WHEN p_source = 'sg' AND sa.price_recent_n >= 3 AND sa.price_prior_n >= 3
             THEN (sa.price_recent - sa.price_prior) / NULLIF(sa.price_prior, 0) * 100
        WHEN p_source = 'td_sh' AND tda.price_recent_n >= 1 AND tda.price_prior_n >= 1
             THEN (tda.price_recent - tda.price_prior) / NULLIF(tda.price_prior, 0) * 100
        WHEN p_source = 'td_gt' AND tdg.price_recent_n >= 1 AND tdg.price_prior_n >= 1
             THEN (tdg.price_recent - tdg.price_prior) / NULLIF(tdg.price_prior, 0) * 100
        WHEN p_source = 'td_vd' AND tdv.price_recent_n >= 1 AND tdv.price_prior_n >= 1
             THEN (tdv.price_recent - tdv.price_prior) / NULLIF(tdv.price_prior, 0) * 100
        WHEN p_source = 'merged' AND ea.price_recent_n >= 3 AND ea.price_prior_n >= 3
             THEN (ea.price_recent - ea.price_prior) / NULLIF(ea.price_prior, 0) * 100
      END AS price_delta_pct,
      -- Fill rate delta (SG / merged)
      CASE
        WHEN p_source IN ('sg','merged') AND sa.fill_prior IS NOT NULL
             THEN (sa.fill_recent - sa.fill_prior) * 100
      END AS fill_delta_pp,
      -- Owned delta (EVO / merged)
      CASE
        WHEN p_source IN ('evo','merged') AND ea.owned_prior IS NOT NULL
             THEN ea.owned_recent - ea.owned_prior
      END AS owned_delta,
      -- Value gap: SG market vs EVO (point-in-time)
      CASE
        WHEN ls.sg_all_median IS NOT NULL AND NULLIF(ls.evo_retail_median, 0) IS NOT NULL
             THEN (ls.sg_all_median - ls.evo_retail_median) / ls.evo_retail_median * 100
      END AS sg_vs_evo_pct,
      -- Cross gap: this TD platform vs SH (or SH vs EVO for td_sh source)
      CASE
        WHEN p_source = 'td_gt' AND NULLIF(ls.td_sh_median, 0) IS NOT NULL AND ls.td_gt_median IS NOT NULL
             THEN (ls.td_gt_median - ls.td_sh_median) / ls.td_sh_median * 100
        WHEN p_source = 'td_vd' AND NULLIF(ls.td_sh_median, 0) IS NOT NULL AND ls.td_vd_median IS NOT NULL
             THEN (ls.td_vd_median - ls.td_sh_median) / ls.td_sh_median * 100
        WHEN p_source = 'td_sh' AND NULLIF(ls.evo_retail_median, 0) IS NOT NULL AND ls.td_sh_median IS NOT NULL
             THEN (ls.td_sh_median - ls.evo_retail_median) / ls.evo_retail_median * 100
      END AS cross_gap_pct,
      -- Current metrics
      CASE
        WHEN p_source IN ('evo','merged') THEN ea.cur_price
        WHEN p_source = 'sg'             THEN sa.cur_price
        WHEN p_source = 'td_sh'          THEN tda.cur_price
        WHEN p_source = 'td_gt'          THEN tdg.cur_price
        WHEN p_source = 'td_vd'          THEN tdv.cur_price
      END AS cur_price,
      CASE WHEN p_source IN ('evo','merged') THEN ea.cur_owned END AS cur_owned,
      CASE
        WHEN p_source IN ('evo','merged') THEN ea.cur_tix
        WHEN p_source = 'sg'             THEN sa.cur_tix
        WHEN p_source = 'td_sh'          THEN tda.cur_listings
        WHEN p_source = 'td_gt'          THEN tdg.cur_listings
        WHEN p_source = 'td_vd'          THEN tdv.cur_listings
      END AS cur_tix
    FROM horizon h
    LEFT JOIN evo_agg    ea  ON ea.event_id = h.event_id
    LEFT JOIN sg_agg     sa  ON sa.event_id = h.event_id
    LEFT JOIN td_agg     tda ON tda.event_id = h.event_id AND tda.platform = 'SH'
    LEFT JOIN td_agg     tdg ON tdg.event_id = h.event_id AND tdg.platform = 'GT'
    LEFT JOIN td_agg     tdv ON tdv.event_id = h.event_id AND tdv.platform = 'VD'
    LEFT JOIN latest_snap ls ON ls.event_id  = h.event_id
  ),
  categorized AS (
    SELECT *,
      CASE
        WHEN price_delta_pct >= 3   THEN 'price_up'
        WHEN price_delta_pct <= -3  THEN 'price_down'
        WHEN fill_delta_pp  >= 5    THEN 'selling_fast'
        WHEN owned_delta    >= 2    THEN 'accumulating'
        WHEN sg_vs_evo_pct  >= 20   THEN 'value_gap'
        WHEN cross_gap_pct  >= 10   THEN 'cross_gap'
      END AS category,
      GREATEST(
        ABS(COALESCE(price_delta_pct, 0)),
        ABS(COALESCE(fill_delta_pp,   0)),
        ABS(COALESCE(owned_delta,     0)) * 5,
        ABS(COALESCE(sg_vs_evo_pct,   0)),
        ABS(COALESCE(cross_gap_pct,   0))
      ) * LOG(1.0 + GREATEST(days_to_event, 0.01)) AS signal_score
    FROM raw_signals
    WHERE price_delta_pct IS NOT NULL
       OR fill_delta_pp   IS NOT NULL
       OR owned_delta     IS NOT NULL
       OR sg_vs_evo_pct   IS NOT NULL
       OR cross_gap_pct   IS NOT NULL
  ),
  top25 AS (
    SELECT *,
      ROW_NUMBER() OVER (
        PARTITION BY category
        ORDER BY signal_score DESC
      ) AS rank
    FROM categorized
    WHERE category IS NOT NULL AND signal_score > 0
  ),
  upserted AS (
    INSERT INTO public.event_movers_index AS idx
      (source, window_days, category, event_id, rank,
       entered_at, last_computed_at,
       entry_price, entry_owned, entry_tix,
       cur_price, cur_owned, cur_tix,
       price_delta_pct, owned_delta, signal_score)
    SELECT
      p_source, p_window_days, t.category, t.event_id, t.rank,
      v_now, v_now,
      t.cur_price, t.cur_owned::int, t.cur_tix::int,
      t.cur_price, t.cur_owned::int, t.cur_tix::int,
      t.price_delta_pct, t.owned_delta,
      t.signal_score
    FROM top25 t
    WHERE t.rank <= 25
    ON CONFLICT (source, window_days, category, event_id) DO UPDATE SET
      rank             = EXCLUDED.rank,
      last_computed_at = v_now,
      cur_price        = EXCLUDED.cur_price,
      cur_owned        = EXCLUDED.cur_owned,
      cur_tix          = EXCLUDED.cur_tix,
      price_delta_pct  = EXCLUDED.price_delta_pct,
      owned_delta      = EXCLUDED.owned_delta,
      signal_score     = EXCLUDED.signal_score
    RETURNING
      source, window_days, category, event_id,
      (xmax = 0) AS is_new_entry,  -- xmax=0 means it was an INSERT (not UPDATE)
      rank, cur_price, signal_score
  )
  -- Write enter history for new index entries
  INSERT INTO public.event_movers_index_history
    (source, window_days, category, event_id, action, rank_after, price_at_action, signal_score_at)
  SELECT source, window_days, category, event_id, 'enter', rank, cur_price, signal_score
  FROM upserted
  WHERE is_new_entry = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- ── Step 2: Remove events that dropped out of top-25, write exit history ──
  WITH exits AS (
    DELETE FROM public.event_movers_index idx
    WHERE idx.source = p_source
      AND idx.window_days = p_window_days
      AND idx.last_computed_at < v_now  -- not updated in this compute run = dropped out
    RETURNING source, window_days, category, event_id, rank, cur_price, signal_score
  )
  INSERT INTO public.event_movers_index_history
    (source, window_days, category, event_id, action, rank_before, price_at_action, signal_score_at)
  SELECT source, window_days, category, event_id, 'exit', rank, cur_price, signal_score
  FROM exits;

  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.compute_event_movers_index(text, int) FROM anon, public;
COMMENT ON FUNCTION public.compute_event_movers_index(text, int) IS
  'Compute movers index for one (source × window_days) combination. '
  'window_days = event horizon (events in next N days). '
  'Signal = half-window SMA vs prior-half SMA. '
  'score = ABS(signal_pct) * LOG(1 + days_to_event). '
  'Upserts event_movers_index + writes enter/exit to history. '
  'sources: evo | sg | td_sh | td_gt | td_vd | merged.';

-- ── Part F: compute_event_movers_index_all() ────────────────────────────────

CREATE OR REPLACE FUNCTION public.compute_event_movers_index_all()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_source text;
  v_window int;
  v_n      int;
BEGIN
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
  'Called by compute_movers_index_post_snapshot cron (7:35/13:35/19:35 UTC). '
  'Each combo wrapped in BEGIN/EXCEPTION so one failure does not abort all.';

-- ── Part G: evo_sg_discovery_gaps() ─────────────────────────────────────────
-- Notes on fixes applied post-initial-draft:
--   1. DISTINCT ON+ORDER BY wrapped in subqueries (can't be direct UNION member)
--   2. sgc.tevo_event_id IS NOT NULL guards on all TD branches (some SG events unmapped)
--   3. Postgres format() only supports %s/%I/%L; use || + round() for floats

CREATE OR REPLACE FUNCTION public.evo_sg_discovery_gaps()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_count int := 0;
BEGIN
  INSERT INTO public.discovery_gap_alerts (event_id, gap_type, detail, signal_score)

  -- sg_no_evo: SG tracking event (fill > 20%) but no EVO coverage
  SELECT * FROM (
    SELECT DISTINCT ON (sgm.tevo_event_id)
           sgm.tevo_event_id                                                                  AS event_id,
           'sg_no_evo'::text                                                                  AS gap_type,
           'SG fill_rate=' || round((sgm.fill_rate*100)::numeric, 1) || '%, no EVO coverage' AS detail,
           (sgm.fill_rate * 100)::numeric(8,4)                                                AS signal_score
    FROM public.seatgeek_event_metrics sgm
    WHERE sgm.captured_at > now() - interval '48 hours'
      AND sgm.fill_rate > 0.20
      AND sgm.tevo_event_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.event_metrics em
        WHERE em.event_id = sgm.tevo_event_id
          AND em.captured_at > now() - interval '48 hours'
      )
    ORDER BY sgm.tevo_event_id, sgm.captured_at DESC
  ) q_sg_no_evo

  UNION ALL

  -- td_sh_no_evo: SH listings but no EVO (only mapped events)
  SELECT DISTINCT
         sgc.tevo_event_id,
         'td_sh_no_evo'::text,
         'SH has listings, no EVO coverage'::text,
         10.0::numeric(8,4)
  FROM public.ticketsdata_listings_snapshots tds
  JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = tds.event_id
  JOIN public.aq_event_map aem           ON aem.aq_short_event_id = tdx.aq_short_event_id
  JOIN public.sg_events_canonical sgc    ON sgc.sg_event_id = aem.sg_event_id
  WHERE tds.platform = 'SH'
    AND tds.captured_at > now() - interval '48 hours'
    AND sgc.tevo_event_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.event_metrics em
      WHERE em.event_id = sgc.tevo_event_id
        AND em.captured_at > now() - interval '48 hours'
    )

  UNION ALL

  -- td_gt_no_evo: GT listings but no EVO
  SELECT DISTINCT
         sgc.tevo_event_id,
         'td_gt_no_evo'::text,
         'GT has listings, no EVO coverage'::text,
         10.0::numeric(8,4)
  FROM public.ticketsdata_listings_snapshots tds
  JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = tds.event_id
  JOIN public.aq_event_map aem           ON aem.aq_short_event_id = tdx.aq_short_event_id
  JOIN public.sg_events_canonical sgc    ON sgc.sg_event_id = aem.sg_event_id
  WHERE tds.platform = 'GT'
    AND tds.captured_at > now() - interval '48 hours'
    AND sgc.tevo_event_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.event_metrics em
      WHERE em.event_id = sgc.tevo_event_id
        AND em.captured_at > now() - interval '48 hours'
    )

  UNION ALL

  -- td_sh_no_gt: SH covered, no GT
  SELECT DISTINCT sh_e.tevo_event_id,
         'td_sh_no_gt'::text,
         'SH has listings but no GT coverage'::text,
         5.0::numeric(8,4)
  FROM (
    SELECT DISTINCT sgc.tevo_event_id
    FROM public.ticketsdata_listings_snapshots tds
    JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = tds.event_id
    JOIN public.aq_event_map aem           ON aem.aq_short_event_id = tdx.aq_short_event_id
    JOIN public.sg_events_canonical sgc    ON sgc.sg_event_id = aem.sg_event_id
    WHERE tds.platform = 'SH'
      AND tds.captured_at > now() - interval '48 hours'
      AND sgc.tevo_event_id IS NOT NULL
  ) sh_e
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.ticketsdata_listings_snapshots tds2
    JOIN public.ticketsdata_event_xref tdx2 ON tdx2.event_id = tds2.event_id
    JOIN public.aq_event_map aem2           ON aem2.aq_short_event_id = tdx2.aq_short_event_id
    JOIN public.sg_events_canonical sgc2    ON sgc2.sg_event_id = aem2.sg_event_id
    WHERE tds2.platform = 'GT'
      AND tds2.captured_at > now() - interval '48 hours'
      AND sgc2.tevo_event_id = sh_e.tevo_event_id
  )

  UNION ALL

  -- evo_no_sg: we own tickets, SG not tracking
  SELECT * FROM (
    SELECT DISTINCT ON (em.event_id)
           em.event_id,
           'evo_no_sg'::text,
           'EVO owned_tickets=' || em.owned_tickets_count || ', SG not tracking',
           em.owned_tickets_count::numeric(8,4)
    FROM public.event_metrics em
    WHERE em.captured_at > now() - interval '48 hours'
      AND em.owned_tickets_count > 0
      AND NOT EXISTS (
        SELECT 1 FROM public.seatgeek_event_metrics sgm
        WHERE sgm.tevo_event_id = em.event_id
          AND sgm.captured_at > now() - interval '48 hours'
      )
    ORDER BY em.event_id, em.captured_at DESC
  ) q_evo_no_sg

  UNION ALL

  -- value_gap_large: SG market > EVO price * 1.20
  SELECT em.event_id,
         'value_gap_large'::text,
         'SG median $' || round(sgm.listings_all_median, 0)
           || ' vs EVO $' || round(em.retail_median, 0)
           || ' (+' || round((sgm.listings_all_median - em.retail_median) / em.retail_median * 100, 0) || '%)',
         ((sgm.listings_all_median - em.retail_median) / em.retail_median * 100)::numeric(8,4)
  FROM (
    SELECT DISTINCT ON (event_id) event_id, retail_median
    FROM public.event_metrics ORDER BY event_id, captured_at DESC
  ) em
  JOIN (
    SELECT DISTINCT ON (tevo_event_id) tevo_event_id, listings_all_median
    FROM public.seatgeek_event_metrics ORDER BY tevo_event_id, captured_at DESC
  ) sgm ON sgm.tevo_event_id = em.event_id
  WHERE em.retail_median > 0
    AND sgm.listings_all_median > em.retail_median * 1.20

  UNION ALL

  -- fill_rate_spike: SG fill rate jumped > 15pp over 12h half-window, event has owned tickets
  SELECT fs.tevo_event_id,
         'fill_rate_spike'::text,
         'SG fill_rate jumped ' || round(((fs.fill_recent - fs.fill_prior)*100)::numeric, 1)
           || 'pp (prior: ' || round((fs.fill_prior*100)::numeric, 0)
           || '% -> recent: ' || round((fs.fill_recent*100)::numeric, 0) || '%)',
         ((fs.fill_recent - fs.fill_prior) * 100)::numeric(8,4)
  FROM (
    SELECT tevo_event_id,
           AVG(fill_rate) FILTER (WHERE captured_at > now() - interval '12 hours')       AS fill_recent,
           AVG(fill_rate) FILTER (WHERE captured_at BETWEEN now() - interval '24 hours'
                                                        AND now() - interval '12 hours') AS fill_prior
    FROM public.seatgeek_event_metrics
    WHERE captured_at > now() - interval '24 hours'
    GROUP BY tevo_event_id
  ) fs
  WHERE fs.fill_prior IS NOT NULL
    AND (fs.fill_recent - fs.fill_prior) > 0.15
    AND EXISTS (
      SELECT 1 FROM public.event_metrics em
      WHERE em.event_id = fs.tevo_event_id
        AND em.owned_tickets_count > 0
        AND em.captured_at > now() - interval '48 hours'
    )

  ON CONFLICT (event_id, gap_type) DO UPDATE SET
    detail       = EXCLUDED.detail,
    signal_score = EXCLUDED.signal_score,
    detected_at  = now(),
    resolved_at  = NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  PERFORM public.bot_chat_log('data-collection', 'D0', 'status',
    format('evo_sg_discovery_gaps: %s gap rows upserted', v_count));
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.evo_sg_discovery_gaps() FROM anon, public;
COMMENT ON FUNCTION public.evo_sg_discovery_gaps() IS
  'Detect EVO/SG/TD market coverage and opportunity gaps. '
  'gap_types: sg_no_evo | td_sh/gt_no_evo | td_sh_no_gt | evo_no_sg | value_gap_large | fill_rate_spike. '
  'Upserts discovery_gap_alerts. Runs daily 9am UTC via discovery_gap_refresh cron.';

-- ── Part H: Crons ────────────────────────────────────────────────────────────

DO $sched$ BEGIN
  -- Movers index: 5 min after each event_listing_snapshot (7:30/13:30/19:30 UTC)
  PERFORM cron.schedule(
    'compute_movers_index_post_snapshot',
    '35 7,13,19 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('compute_movers_index_post_snapshot') THEN RETURN; END IF;
      PERFORM public.compute_event_movers_index_all();
    END $b$;$cron$
  );

  -- Discovery gap refresh: daily 9am UTC
  PERFORM cron.schedule(
    'discovery_gap_refresh',
    '0 9 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('discovery_gap_refresh') THEN RETURN; END IF;
      PERFORM public.evo_sg_discovery_gaps();
    END $b$;$cron$
  );
END $sched$;

-- ── Part I: cron_policy entries ──────────────────────────────────────────────

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, work_check_sql, enabled, notes)
VALUES
  ('compute_movers_index_post_snapshot',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23]::int[],
   360, 360, 3,
   'SELECT true', true,
   'Compute all 30 source×window movers indices (6 sources × 5 windows). '
   'Fires 5 min after each event_listing_snapshot at 7:35/13:35/19:35 UTC. '
   'Signal = half-window SMA. score = ABS(pct) * LOG(1 + days_to_event). '
   'sources: evo|sg|td_sh|td_gt|td_vd|merged. windows: 7|15|30|180|365d.'),

  ('discovery_gap_refresh',
   ARRAY[]::int[], 1440, 1440, 1,
   'SELECT true', true,
   'EVO/SG/TD coverage gap detection. '
   'Daily 9am UTC = 5am ET. '
   'Upserts discovery_gap_alerts with: sg_no_evo, td_sh/gt_no_evo, td_sh_no_gt, '
   'evo_no_sg, value_gap_large, fill_rate_spike.')

ON CONFLICT (jobname) DO UPDATE
  SET notes = EXCLUDED.notes, enabled = true, updated_at = now();
