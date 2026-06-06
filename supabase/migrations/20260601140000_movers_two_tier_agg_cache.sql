-- ============================================================
-- Movers index: two-tier rebuild to fix the cron timeout for good.
-- Authored by D0/A1 2026-06-01. STATUS: NOT APPLIED at author time.
--
-- WHY: compute_event_movers_index_all() ran all 30 (6 sources × 5 windows)
-- aggregate computations in ONE cron statement under the role's 120s
-- statement_timeout. Each call re-scanned the TD listings firehose (~16s cold)
-- + event_metrics/seatgeek_event_metrics, so the batch crept 55s→95s→TIMEOUT
-- (stale since 2026-05-30). A function-local statement_timeout does NOT re-arm
-- the cron's already-running outer statement (verified), so raising it was
-- ineffective.
--
-- FIX (operator-directed two-tier split):
--   TIER 1 — refresh_event_movers_agg(window): compute the heavy, source-
--     INDEPENDENT aggregates ONCE per window (TD firehose scanned once per
--     window instead of 3× per platform-source) into a cache table
--     public.event_movers_agg. Measured ~15–18s per window. Run as separate
--     per-window statements, twice a day.
--   TIER 2 — compute_event_movers_index(source, window): unchanged signal /
--     category / ranking logic, but now reads the pre-computed cache instead of
--     re-scanning raw tables. Near-instant; the existing thrice-daily
--     compute_movers_index_post_snapshot cron (jobid 300) keeps driving it.
--
-- Output is equivalent to the prior inline compute by construction: the cache
-- holds the same aggregates (identical SQL), and Tier 2 applies the same
-- raw_signals→categorized→top25 logic to them.
-- ============================================================

-- ── Tier-1 cache ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.event_movers_agg (
  window_days   int         NOT NULL,
  event_id      bigint      NOT NULL,
  computed_at   timestamptz NOT NULL DEFAULT now(),
  days_to_event numeric,
  -- EVO (event_metrics)
  ev_price_recent numeric, ev_price_recent_n int, ev_price_prior numeric, ev_price_prior_n int,
  ev_owned_recent numeric, ev_owned_prior numeric, ev_cur_price numeric, ev_cur_owned numeric, ev_cur_tix numeric,
  -- SG (seatgeek_event_metrics)
  sg_price_recent numeric, sg_price_recent_n int, sg_price_prior numeric, sg_price_prior_n int,
  sg_fill_recent numeric, sg_fill_prior numeric, sg_cur_price numeric, sg_cur_tix numeric,
  -- TicketsData per platform (SH / GT / VD)
  sh_price_recent numeric, sh_price_recent_n int, sh_price_prior numeric, sh_price_prior_n int, sh_cur_price numeric, sh_cur_listings numeric,
  gt_price_recent numeric, gt_price_recent_n int, gt_price_prior numeric, gt_price_prior_n int, gt_cur_price numeric, gt_cur_listings numeric,
  vd_price_recent numeric, vd_price_recent_n int, vd_price_prior numeric, vd_price_prior_n int, vd_cur_price numeric, vd_cur_listings numeric,
  -- latest daily snapshot (window-independent; stored per row for join-free reads)
  ls_evo_retail_median numeric, ls_sg_all_median numeric, ls_td_sh_median numeric, ls_td_gt_median numeric, ls_td_vd_median numeric,
  PRIMARY KEY (window_days, event_id)
);
-- Internal cache: no anon/authenticated access (read only by SECDEF RPCs).
REVOKE ALL ON TABLE public.event_movers_agg FROM PUBLIC, anon, authenticated;

-- ── Tier 1: refresh one window's shared aggregates ──────────────────────────
CREATE OR REPLACE FUNCTION public.refresh_event_movers_agg(p_window_days int)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_now  timestamptz := now();
  v_half numeric     := p_window_days / 2.0;
  v_n    int;
BEGIN
  INSERT INTO public.event_movers_agg AS a (
    window_days, event_id, computed_at, days_to_event,
    ev_price_recent, ev_price_recent_n, ev_price_prior, ev_price_prior_n, ev_owned_recent, ev_owned_prior, ev_cur_price, ev_cur_owned, ev_cur_tix,
    sg_price_recent, sg_price_recent_n, sg_price_prior, sg_price_prior_n, sg_fill_recent, sg_fill_prior, sg_cur_price, sg_cur_tix,
    sh_price_recent, sh_price_recent_n, sh_price_prior, sh_price_prior_n, sh_cur_price, sh_cur_listings,
    gt_price_recent, gt_price_recent_n, gt_price_prior, gt_price_prior_n, gt_cur_price, gt_cur_listings,
    vd_price_recent, vd_price_recent_n, vd_price_prior, vd_price_prior_n, vd_cur_price, vd_cur_listings,
    ls_evo_retail_median, ls_sg_all_median, ls_td_sh_median, ls_td_gt_median, ls_td_vd_median)
  WITH
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
      AVG(em.retail_median) FILTER (WHERE em.captured_at > v_now - (v_half || ' days')::interval) AS price_recent,
      COUNT(*) FILTER (WHERE em.captured_at > v_now - (v_half || ' days')::interval AND em.retail_median IS NOT NULL) AS price_recent_n,
      AVG(em.retail_median) FILTER (WHERE em.captured_at BETWEEN v_now - (p_window_days || ' days')::interval AND v_now - (v_half || ' days')::interval) AS price_prior,
      COUNT(*) FILTER (WHERE em.captured_at BETWEEN v_now - (p_window_days || ' days')::interval AND v_now - (v_half || ' days')::interval AND em.retail_median IS NOT NULL) AS price_prior_n,
      AVG(em.owned_tickets_count) FILTER (WHERE em.captured_at > v_now - (v_half || ' days')::interval) AS owned_recent,
      AVG(em.owned_tickets_count) FILTER (WHERE em.captured_at BETWEEN v_now - (p_window_days || ' days')::interval AND v_now - (v_half || ' days')::interval) AS owned_prior,
      (ARRAY_AGG(em.retail_median ORDER BY em.captured_at DESC))[1] AS cur_price,
      (ARRAY_AGG(em.owned_tickets_count ORDER BY em.captured_at DESC))[1] AS cur_owned,
      (ARRAY_AGG(em.tickets_count ORDER BY em.captured_at DESC))[1] AS cur_tix
    FROM public.event_metrics em
    WHERE em.captured_at > v_now - (p_window_days || ' days')::interval
    GROUP BY em.event_id
  ),
  sg_agg AS (
    SELECT sgm.tevo_event_id AS event_id,
      AVG(sgm.listings_all_median) FILTER (WHERE sgm.captured_at > v_now - (v_half || ' days')::interval) AS price_recent,
      COUNT(*) FILTER (WHERE sgm.captured_at > v_now - (v_half || ' days')::interval AND sgm.listings_all_median IS NOT NULL) AS price_recent_n,
      AVG(sgm.listings_all_median) FILTER (WHERE sgm.captured_at BETWEEN v_now - (p_window_days || ' days')::interval AND v_now - (v_half || ' days')::interval) AS price_prior,
      COUNT(*) FILTER (WHERE sgm.captured_at BETWEEN v_now - (p_window_days || ' days')::interval AND v_now - (v_half || ' days')::interval AND sgm.listings_all_median IS NOT NULL) AS price_prior_n,
      AVG(sgm.fill_rate) FILTER (WHERE sgm.captured_at > v_now - (v_half || ' days')::interval) AS fill_recent,
      AVG(sgm.fill_rate) FILTER (WHERE sgm.captured_at BETWEEN v_now - (p_window_days || ' days')::interval AND v_now - (v_half || ' days')::interval) AS fill_prior,
      (ARRAY_AGG(sgm.listings_all_median ORDER BY sgm.captured_at DESC))[1] AS cur_price,
      (ARRAY_AGG(sgm.listings_all_count ORDER BY sgm.captured_at DESC))[1] AS cur_tix
    FROM public.seatgeek_event_metrics sgm
    WHERE sgm.captured_at > v_now - (p_window_days || ' days')::interval
    GROUP BY sgm.tevo_event_id
  ),
  td_daily AS (
    SELECT sgc.tevo_event_id AS event_id, tds.platform, date_trunc('day', tds.captured_at) AS snap_day,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tds.list_price) AS daily_median, COUNT(*) AS cnt
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
      AVG(td.daily_median) FILTER (WHERE td.snap_day > (v_now - (v_half || ' days')::interval)::date) AS price_recent,
      COUNT(*) FILTER (WHERE td.snap_day > (v_now - (v_half || ' days')::interval)::date) AS price_recent_n,
      AVG(td.daily_median) FILTER (WHERE td.snap_day BETWEEN (v_now - (p_window_days || ' days')::interval)::date AND (v_now - (v_half || ' days')::interval)::date) AS price_prior,
      COUNT(*) FILTER (WHERE td.snap_day BETWEEN (v_now - (p_window_days || ' days')::interval)::date AND (v_now - (v_half || ' days')::interval)::date) AS price_prior_n,
      (ARRAY_AGG(td.daily_median ORDER BY td.snap_day DESC))[1] AS cur_price,
      (ARRAY_AGG(td.cnt ORDER BY td.snap_day DESC))[1] AS cur_listings
    FROM td_daily td
    GROUP BY td.event_id, td.platform
  ),
  latest_snap AS (
    SELECT DISTINCT ON (s.event_id)
      s.event_id, s.evo_retail_median, s.sg_all_median, s.td_sh_median, s.td_gt_median, s.td_vd_median
    FROM public.event_listing_snapshot_daily s
    ORDER BY s.event_id, s.snapshot_date DESC,
      CASE s.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC
  )
  SELECT p_window_days, h.event_id, v_now, h.days_to_event,
    ea.price_recent, ea.price_recent_n, ea.price_prior, ea.price_prior_n, ea.owned_recent, ea.owned_prior, ea.cur_price, ea.cur_owned, ea.cur_tix,
    sa.price_recent, sa.price_recent_n, sa.price_prior, sa.price_prior_n, sa.fill_recent, sa.fill_prior, sa.cur_price, sa.cur_tix,
    tda.price_recent, tda.price_recent_n, tda.price_prior, tda.price_prior_n, tda.cur_price, tda.cur_listings,
    tdg.price_recent, tdg.price_recent_n, tdg.price_prior, tdg.price_prior_n, tdg.cur_price, tdg.cur_listings,
    tdv.price_recent, tdv.price_recent_n, tdv.price_prior, tdv.price_prior_n, tdv.cur_price, tdv.cur_listings,
    ls.evo_retail_median, ls.sg_all_median, ls.td_sh_median, ls.td_gt_median, ls.td_vd_median
  FROM horizon h
  LEFT JOIN evo_agg    ea  ON ea.event_id = h.event_id
  LEFT JOIN sg_agg     sa  ON sa.event_id = h.event_id
  LEFT JOIN td_agg     tda ON tda.event_id = h.event_id AND tda.platform = 'SH'
  LEFT JOIN td_agg     tdg ON tdg.event_id = h.event_id AND tdg.platform = 'GT'
  LEFT JOIN td_agg     tdv ON tdv.event_id = h.event_id AND tdv.platform = 'VD'
  LEFT JOIN latest_snap ls ON ls.event_id  = h.event_id
  ON CONFLICT (window_days, event_id) DO UPDATE SET
    computed_at = v_now, days_to_event = EXCLUDED.days_to_event,
    ev_price_recent=EXCLUDED.ev_price_recent, ev_price_recent_n=EXCLUDED.ev_price_recent_n, ev_price_prior=EXCLUDED.ev_price_prior, ev_price_prior_n=EXCLUDED.ev_price_prior_n,
    ev_owned_recent=EXCLUDED.ev_owned_recent, ev_owned_prior=EXCLUDED.ev_owned_prior, ev_cur_price=EXCLUDED.ev_cur_price, ev_cur_owned=EXCLUDED.ev_cur_owned, ev_cur_tix=EXCLUDED.ev_cur_tix,
    sg_price_recent=EXCLUDED.sg_price_recent, sg_price_recent_n=EXCLUDED.sg_price_recent_n, sg_price_prior=EXCLUDED.sg_price_prior, sg_price_prior_n=EXCLUDED.sg_price_prior_n,
    sg_fill_recent=EXCLUDED.sg_fill_recent, sg_fill_prior=EXCLUDED.sg_fill_prior, sg_cur_price=EXCLUDED.sg_cur_price, sg_cur_tix=EXCLUDED.sg_cur_tix,
    sh_price_recent=EXCLUDED.sh_price_recent, sh_price_recent_n=EXCLUDED.sh_price_recent_n, sh_price_prior=EXCLUDED.sh_price_prior, sh_price_prior_n=EXCLUDED.sh_price_prior_n, sh_cur_price=EXCLUDED.sh_cur_price, sh_cur_listings=EXCLUDED.sh_cur_listings,
    gt_price_recent=EXCLUDED.gt_price_recent, gt_price_recent_n=EXCLUDED.gt_price_recent_n, gt_price_prior=EXCLUDED.gt_price_prior, gt_price_prior_n=EXCLUDED.gt_price_prior_n, gt_cur_price=EXCLUDED.gt_cur_price, gt_cur_listings=EXCLUDED.gt_cur_listings,
    vd_price_recent=EXCLUDED.vd_price_recent, vd_price_recent_n=EXCLUDED.vd_price_recent_n, vd_price_prior=EXCLUDED.vd_price_prior, vd_price_prior_n=EXCLUDED.vd_price_prior_n, vd_cur_price=EXCLUDED.vd_cur_price, vd_cur_listings=EXCLUDED.vd_cur_listings,
    ls_evo_retail_median=EXCLUDED.ls_evo_retail_median, ls_sg_all_median=EXCLUDED.ls_sg_all_median, ls_td_sh_median=EXCLUDED.ls_td_sh_median, ls_td_gt_median=EXCLUDED.ls_td_gt_median, ls_td_vd_median=EXCLUDED.ls_td_vd_median;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  -- Evict rows for events that left this window's horizon since last refresh.
  DELETE FROM public.event_movers_agg WHERE window_days = p_window_days AND computed_at < v_now;
  RETURN v_n;
END;
$fn$;

-- ── Tier 2: build movers index from the cache (signal logic unchanged) ──────
CREATE OR REPLACE FUNCTION public.compute_event_movers_index(p_source text DEFAULT 'merged'::text, p_window_days integer DEFAULT 7)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now   timestamptz := now();
  v_count int := 0;
BEGIN
  -- Safety: if the Tier-1 cache for this window is missing or stale, do NOT run
  -- (an empty cache would wipe the index via the exit-DELETE below). Keep the
  -- existing index until the next refresh. Tier-1 cadence is 2x/day; 18h = margin.
  IF NOT EXISTS (SELECT 1 FROM public.event_movers_agg WHERE window_days = p_window_days AND computed_at > now() - interval '18 hours') THEN
    RETURN 0;
  END IF;
  WITH
  raw_signals AS (
    SELECT
      a.event_id,
      a.days_to_event,
      CASE
        WHEN p_source = 'evo'    AND a.ev_price_recent_n >= 3 AND a.ev_price_prior_n >= 3 THEN (a.ev_price_recent - a.ev_price_prior) / NULLIF(a.ev_price_prior, 0) * 100
        WHEN p_source = 'sg'     AND a.sg_price_recent_n >= 3 AND a.sg_price_prior_n >= 3 THEN (a.sg_price_recent - a.sg_price_prior) / NULLIF(a.sg_price_prior, 0) * 100
        WHEN p_source = 'td_sh'  AND a.sh_price_recent_n >= 1 AND a.sh_price_prior_n >= 1 THEN (a.sh_price_recent - a.sh_price_prior) / NULLIF(a.sh_price_prior, 0) * 100
        WHEN p_source = 'td_gt'  AND a.gt_price_recent_n >= 1 AND a.gt_price_prior_n >= 1 THEN (a.gt_price_recent - a.gt_price_prior) / NULLIF(a.gt_price_prior, 0) * 100
        WHEN p_source = 'td_vd'  AND a.vd_price_recent_n >= 1 AND a.vd_price_prior_n >= 1 THEN (a.vd_price_recent - a.vd_price_prior) / NULLIF(a.vd_price_prior, 0) * 100
        WHEN p_source = 'merged' AND a.ev_price_recent_n >= 3 AND a.ev_price_prior_n >= 3 THEN (a.ev_price_recent - a.ev_price_prior) / NULLIF(a.ev_price_prior, 0) * 100
      END AS price_delta_pct,
      CASE WHEN p_source IN ('sg','merged') AND a.sg_fill_prior IS NOT NULL THEN (a.sg_fill_recent - a.sg_fill_prior) * 100 END AS fill_delta_pp,
      CASE WHEN p_source IN ('evo','merged') AND a.ev_owned_prior IS NOT NULL THEN a.ev_owned_recent - a.ev_owned_prior END AS owned_delta,
      CASE WHEN a.ls_sg_all_median IS NOT NULL AND NULLIF(a.ls_evo_retail_median, 0) IS NOT NULL THEN (a.ls_sg_all_median - a.ls_evo_retail_median) / a.ls_evo_retail_median * 100 END AS sg_vs_evo_pct,
      CASE
        WHEN p_source = 'td_gt' AND NULLIF(a.ls_td_sh_median, 0) IS NOT NULL AND a.ls_td_gt_median IS NOT NULL THEN (a.ls_td_gt_median - a.ls_td_sh_median) / a.ls_td_sh_median * 100
        WHEN p_source = 'td_vd' AND NULLIF(a.ls_td_sh_median, 0) IS NOT NULL AND a.ls_td_vd_median IS NOT NULL THEN (a.ls_td_vd_median - a.ls_td_sh_median) / a.ls_td_sh_median * 100
        WHEN p_source = 'td_sh' AND NULLIF(a.ls_evo_retail_median, 0) IS NOT NULL AND a.ls_td_sh_median IS NOT NULL THEN (a.ls_td_sh_median - a.ls_evo_retail_median) / a.ls_evo_retail_median * 100
      END AS cross_gap_pct,
      CASE
        WHEN p_source IN ('evo','merged') THEN a.ev_cur_price
        WHEN p_source = 'sg'    THEN a.sg_cur_price
        WHEN p_source = 'td_sh' THEN a.sh_cur_price
        WHEN p_source = 'td_gt' THEN a.gt_cur_price
        WHEN p_source = 'td_vd' THEN a.vd_cur_price
      END AS cur_price,
      CASE WHEN p_source IN ('evo','merged') THEN a.ev_cur_owned END AS cur_owned,
      CASE
        WHEN p_source IN ('evo','merged') THEN a.ev_cur_tix
        WHEN p_source = 'sg'    THEN a.sg_cur_tix
        WHEN p_source = 'td_sh' THEN a.sh_cur_listings
        WHEN p_source = 'td_gt' THEN a.gt_cur_listings
        WHEN p_source = 'td_vd' THEN a.vd_cur_listings
      END AS cur_tix
    FROM public.event_movers_agg a
    WHERE a.window_days = p_window_days
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
        ABS(COALESCE(price_delta_pct, 0)), ABS(COALESCE(fill_delta_pp, 0)),
        ABS(COALESCE(owned_delta, 0)) * 5, ABS(COALESCE(sg_vs_evo_pct, 0)), ABS(COALESCE(cross_gap_pct, 0))
      ) * LOG(1.0 + GREATEST(days_to_event, 0.01)) AS signal_score
    FROM raw_signals
    WHERE price_delta_pct IS NOT NULL OR fill_delta_pp IS NOT NULL OR owned_delta IS NOT NULL OR sg_vs_evo_pct IS NOT NULL OR cross_gap_pct IS NOT NULL
  ),
  top25 AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY category ORDER BY signal_score DESC) AS rank
    FROM categorized WHERE category IS NOT NULL AND signal_score > 0
  ),
  upserted AS (
    INSERT INTO public.event_movers_index AS idx
      (source, window_days, category, event_id, rank, entered_at, last_computed_at, entry_price, entry_owned, entry_tix, cur_price, cur_owned, cur_tix, price_delta_pct, owned_delta, signal_score)
    SELECT p_source, p_window_days, t.category, t.event_id, t.rank, v_now, v_now, t.cur_price, t.cur_owned::int, t.cur_tix::int, t.cur_price, t.cur_owned::int, t.cur_tix::int, t.price_delta_pct, t.owned_delta, t.signal_score
    FROM top25 t WHERE t.rank <= 25
    ON CONFLICT (source, window_days, category, event_id) DO UPDATE SET
      rank=EXCLUDED.rank, last_computed_at=v_now, cur_price=EXCLUDED.cur_price, cur_owned=EXCLUDED.cur_owned, cur_tix=EXCLUDED.cur_tix,
      price_delta_pct=EXCLUDED.price_delta_pct, owned_delta=EXCLUDED.owned_delta, signal_score=EXCLUDED.signal_score
    RETURNING source, window_days, category, event_id, (xmax = 0) AS is_new_entry, rank, cur_price, signal_score
  )
  INSERT INTO public.event_movers_index_history (source, window_days, category, event_id, action, rank_after, price_at_action, signal_score_at)
  SELECT source, window_days, category, event_id, 'enter', rank, cur_price, signal_score FROM upserted WHERE is_new_entry = true;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  WITH exits AS (
    DELETE FROM public.event_movers_index idx
    WHERE idx.source = p_source AND idx.window_days = p_window_days AND idx.last_computed_at < v_now
    RETURNING source, window_days, category, event_id, rank, cur_price, signal_score
  )
  INSERT INTO public.event_movers_index_history (source, window_days, category, event_id, action, rank_before, price_at_action, signal_score_at)
  SELECT source, window_days, category, event_id, 'exit', rank, cur_price, signal_score FROM exits;

  RETURN v_count;
END;
$function$;

-- ── Tier-1 cron: refresh the cache twice a day, per-window (each its own
--    statement → own 120s budget), 15 min before the 07:35/19:35 compute. ────
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, enabled, notes)
VALUES ('refresh_movers_agg', ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
        600, 600, 'SELECT true', 2, true,
        'Tier-1: refresh public.event_movers_agg shared aggregates (6 source feeds × 5 windows, TD firehose scanned once/window). Per-window ~15-18s. Feeds Tier-2 compute_event_movers_index (jobid 300). 2x/day at 07:20/19:20 UTC.')
ON CONFLICT (jobname) DO UPDATE SET enabled = EXCLUDED.enabled, notes = EXCLUDED.notes, updated_at = now();

-- One gated statement looping the 5 windows (each window ~15-18s; ~68s total,
-- vs the old 30-iteration batch that blew past 120s). The gate must wrap the
-- work in a single DO (a `RETURN` only exits its own block), so the loop lives
-- inside it rather than as separate statements.
SELECT cron.schedule('refresh_movers_agg', '20 7,19 * * *', $cron$
  DO $g$
  DECLARE w int;
  BEGIN
    IF NOT public.cron_should_fire('refresh_movers_agg') THEN RETURN; END IF;
    FOREACH w IN ARRAY ARRAY[7,15,30,180,365] LOOP
      PERFORM public.refresh_event_movers_agg(w);
    END LOOP;
  END $g$;
$cron$);

-- ── Manual verification (run AFTER apply) ───────────────────────────────────
--   SELECT public.refresh_event_movers_agg(w) FROM unnest(ARRAY[7,15,30,180,365]) w;  -- bootstrap cache
--   SELECT public.compute_event_movers_index_all();                                   -- fast now
--   SELECT max(last_computed_at) FROM public.event_movers_index;                      -- ~now()
--   SELECT status, return_message FROM cron.job_run_details WHERE jobid=300 ORDER BY start_time DESC LIMIT 2;
