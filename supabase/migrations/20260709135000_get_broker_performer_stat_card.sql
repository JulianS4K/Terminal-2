-- Migration 20260709135000 · lane:D0 (author) → A1 (apply) · writes:get_broker_performer_stat_card · reads:performer_metrics_daily · pre:performer_metrics_daily must exist (mig 20260605151100) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates a SECDEF read RPC; no DML, no cron)
--
-- D0 — performer "Statistics" stat-card metric block.
--
-- The Yahoo-Finance-"Statistics"-panel analog for a ticketing performer: one
-- compact label/value block of ~16 measures, in three groups:
--   MARKET   — current-slate snapshot (get-in, median, ceiling, spread, float)
--   POSITION — our owned book (tix, notional, share)
--   TREND    — trailing 7d / 30d deltas + home/away split (sports)
--
-- Pure rollup over the persisted performer_metrics_daily timeseries (split='all',
-- refreshed every 4h by entity-metrics-daily-refresh) — no live upstream calls,
-- so it is cheap and always answers from stored data. The live PORTFOLIO ROLLUP
-- (/api/portfolio) stays the request-time owned-position source; this RPC is the
-- persisted snapshot + deltas the stat card renders. Blind-spot detail keeps its
-- own tab (get_broker_performer_page); this block only carries the count-free
-- metrics_daily-derived measures.
--
-- Canonical SECDEF v3: @s4kent.com email gate, REVOKE PUBLIC + GRANT anon/auth.
-- Deltas are computed server-side (nearest on-or-before row at L-7 / L-30) so the
-- client renders raw values. Ratios guard div-by-zero with nullif.

CREATE OR REPLACE FUNCTION public.get_broker_performer_stat_card(p_performer_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_result jsonb;
  v_latest date;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Anchor on the performer's most-recent stored 'all'-split day.
  SELECT max(snapshot_date) INTO v_latest
  FROM public.performer_metrics_daily
  WHERE performer_id = p_performer_id AND split = 'all';

  IF v_latest IS NULL THEN
    RETURN jsonb_build_object('performer_id', p_performer_id, 'as_of', NULL, 'measures', NULL);
  END IF;

  WITH cur AS (
    SELECT * FROM public.performer_metrics_daily
    WHERE performer_id = p_performer_id AND split = 'all' AND snapshot_date = v_latest
    LIMIT 1
  ),
  -- nearest stored row on-or-before the trailing anchors (gaps tolerated)
  w7 AS (
    SELECT * FROM public.performer_metrics_daily
    WHERE performer_id = p_performer_id AND split = 'all' AND snapshot_date <= v_latest - 7
    ORDER BY snapshot_date DESC LIMIT 1
  ),
  w30 AS (
    SELECT * FROM public.performer_metrics_daily
    WHERE performer_id = p_performer_id AND split = 'all' AND snapshot_date <= v_latest - 30
    ORDER BY snapshot_date DESC LIMIT 1
  ),
  home AS (
    SELECT price_median FROM public.performer_metrics_daily
    WHERE performer_id = p_performer_id AND split = 'home' AND snapshot_date = v_latest LIMIT 1
  ),
  away AS (
    SELECT price_median FROM public.performer_metrics_daily
    WHERE performer_id = p_performer_id AND split = 'away' AND snapshot_date = v_latest LIMIT 1
  ),
  pct AS (  -- signed % change vs a trailing base (NULL when base is 0/absent)
    SELECT
      round(((c.price_median - w7.price_median) / nullif(w7.price_median,0)) * 100, 1) AS price_d7_pct,
      round(((c.price_median - w30.price_median) / nullif(w30.price_median,0)) * 100, 1) AS price_d30_pct,
      round(((c.getin_median - w7.getin_median) / nullif(w7.getin_median,0)) * 100, 1) AS getin_d7_pct
    FROM cur c LEFT JOIN w7 ON true LEFT JOIN w30 ON true
  )
  SELECT jsonb_build_object(
    'performer_id',   c.performer_id,
    'performer_name', c.performer_name,
    'as_of',          v_latest,
    'is_sports',      (c.what_event_type = 'game'),
    -- MARKET (current slate)
    'event_count',        c.event_count,
    'getin_min',          c.getin_min,
    'getin_median',       c.getin_median,
    'price_median',       c.price_median,
    'price_p90',          c.price_p90,
    'spread_ratio',       round(c.price_p90 / nullif(c.getin_median,0), 2),   -- ceiling ÷ get-in
    'market_tickets',     coalesce(c.evo_tickets_total,0) + coalesce(c.sg_all_tickets_total,0),
    -- POSITION (our owned book)
    'owned_tickets',      coalesce(c.evo_owned_tickets_total,0) + coalesce(c.sg_owned_tickets_total,0),
    'owned_book_notional', c.owned_book_notional,
    'owned_share',        round(
                            coalesce(c.evo_owned_tickets_total,0)::numeric
                            / nullif(coalesce(c.evo_tickets_total,0),0), 4),   -- owned ÷ EVO float
    -- TREND (trailing deltas + split)
    'price_median_7d',    (SELECT price_median FROM w7),
    'price_median_30d',   (SELECT price_median FROM w30),
    'price_d7_pct',       p.price_d7_pct,
    'price_d30_pct',      p.price_d30_pct,
    'getin_d7_pct',       p.getin_d7_pct,
    'owned_tickets_d30',  coalesce(c.evo_owned_tickets_total,0)
                            - coalesce((SELECT evo_owned_tickets_total FROM w30),0),
    'home_price_median',  (SELECT price_median FROM home),
    'away_price_median',  (SELECT price_median FROM away)
  )
  INTO v_result
  FROM cur c CROSS JOIN pct p;

  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_broker_performer_stat_card(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_performer_stat_card(bigint) TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_performer_stat_card(bigint) IS
  'D0 performer Statistics stat-card: MARKET/POSITION/TREND metric block over performer_metrics_daily (split=all) + 7d/30d deltas + home/away split. @s4kent.com-gated SECDEF read.';
