-- Fix: compute_event_movers_index ON CONFLICT error for td_sh (all 5 windows)
-- Root cause: 22 tevo_event_ids appear 2–3× in sg_events_canonical.
--   horizon CTE does SELECT sgc.tevo_event_id ... without DISTINCT.
--   Duplicate event_ids propagate through all CTEs → top25 produces duplicate
--   (source, window_days, category, event_id) rows → INSERT ON CONFLICT hits the
--   same PK twice in one statement → "ON CONFLICT DO UPDATE command cannot affect
--   row a second time" (Postgres prohibits updating the same row twice in one query).
--
-- Affected: td_sh all 5 windows (7/15/30/180/365d). Other sources may be masked
--   because they have fewer qualifying events; td_sh has more events in horizon
--   that expose the duplicates.
--
-- Fix: DISTINCT ON (tevo_event_id) in horizon CTE, ordered by sg_datetime_utc DESC
--   so the most-recent SG canonical row wins (matches what latest_snap already does).
--
-- Also: re-seed affected source×window combos immediately after apply.
-- Authored by D0 2026-05-28. A1 to review + apply.

-- How many duplicates exist right now (for post-apply verification):
-- SELECT COUNT(*) FROM sg_events_canonical WHERE tevo_event_id IN (
--   SELECT tevo_event_id FROM sg_events_canonical WHERE tevo_event_id IS NOT NULL
--   GROUP BY tevo_event_id HAVING COUNT(*) > 1);
-- Expected: 45 rows across 22 event_ids.

DROP FUNCTION IF EXISTS public.compute_event_movers_index(text, integer);

CREATE OR REPLACE FUNCTION public.compute_event_movers_index(
  p_source      text    DEFAULT 'merged',
  p_window_days integer DEFAULT 7
)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_now   timestamptz := now();
  v_half  numeric     := p_window_days / 2.0;
  v_count int         := 0;
BEGIN
  WITH
  -- FIX: DISTINCT ON eliminates duplicate tevo_event_ids from sg_events_canonical.
  -- Without this, 22 event_ids appear 2–3× and produce duplicate PK rows in the
  -- final INSERT, triggering "ON CONFLICT DO UPDATE cannot affect row a second time".
  horizon AS (
    SELECT DISTINCT ON (sgc.tevo_event_id)
           sgc.tevo_event_id AS event_id,
           EXTRACT(EPOCH FROM (sgc.sg_datetime_utc - v_now)) / 86400.0 AS days_to_event
    FROM public.sg_events_canonical sgc
    WHERE sgc.sg_datetime_utc BETWEEN v_now AND v_now + (p_window_days || ' days')::interval
      AND sgc.tevo_event_id IS NOT NULL
    ORDER BY sgc.tevo_event_id, sgc.sg_datetime_utc DESC
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
      CASE
        WHEN p_source IN ('sg','merged') AND sa.fill_prior IS NOT NULL
             THEN (sa.fill_recent - sa.fill_prior) * 100
      END AS fill_delta_pp,
      CASE
        WHEN p_source IN ('evo','merged') AND ea.owned_prior IS NOT NULL
             THEN ea.owned_recent - ea.owned_prior
      END AS owned_delta,
      CASE
        WHEN ls.sg_all_median IS NOT NULL AND NULLIF(ls.evo_retail_median, 0) IS NOT NULL
             THEN (ls.sg_all_median - ls.evo_retail_median) / ls.evo_retail_median * 100
      END AS sg_vs_evo_pct,
      CASE
        WHEN p_source = 'td_gt' AND NULLIF(ls.td_sh_median, 0) IS NOT NULL AND ls.td_gt_median IS NOT NULL
             THEN (ls.td_gt_median - ls.td_sh_median) / ls.td_sh_median * 100
        WHEN p_source = 'td_vd' AND NULLIF(ls.td_sh_median, 0) IS NOT NULL AND ls.td_vd_median IS NOT NULL
             THEN (ls.td_vd_median - ls.td_sh_median) / ls.td_sh_median * 100
        WHEN p_source = 'td_sh' AND NULLIF(ls.evo_retail_median, 0) IS NOT NULL AND ls.td_sh_median IS NOT NULL
             THEN (ls.td_sh_median - ls.evo_retail_median) / ls.evo_retail_median * 100
      END AS cross_gap_pct,
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
      (xmax = 0) AS is_new_entry,
      rank, cur_price, signal_score
  )
  INSERT INTO public.event_movers_index_history
    (source, window_days, category, event_id, action, rank_after, price_at_action, signal_score_at)
  SELECT source, window_days, category, event_id, 'enter', rank, cur_price, signal_score
  FROM upserted
  WHERE is_new_entry = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Remove events that dropped out of top-25 (not updated in this run)
  WITH exits AS (
    DELETE FROM public.event_movers_index idx
    WHERE idx.source = p_source
      AND idx.window_days = p_window_days
      AND idx.last_computed_at < v_now
    RETURNING source, window_days, category, event_id, rank, cur_price, signal_score
  )
  INSERT INTO public.event_movers_index_history
    (source, window_days, category, event_id, action, rank_before, price_at_action, signal_score_at)
  SELECT source, window_days, category, event_id, 'exit', rank, cur_price, signal_score
  FROM exits;

  RETURN v_count;
END;
$$;

-- Re-seed all td_sh windows immediately after apply (they were all failing)
SELECT public.compute_event_movers_index('td_sh', 7);
SELECT public.compute_event_movers_index('td_sh', 15);
SELECT public.compute_event_movers_index('td_sh', 30);
SELECT public.compute_event_movers_index('td_sh', 180);
SELECT public.compute_event_movers_index('td_sh', 365);

-- Verify: should return rows with no error
SELECT source, window_days, category, COUNT(*) AS events
FROM public.event_movers_index
WHERE source = 'td_sh'
GROUP BY 1,2,3 ORDER BY 1,2,3;
