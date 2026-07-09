-- Migration 20260709190000 · level:2 · lane:A1 (operator-directed 2026-07-09; D0 consumes)
-- writes: CREATE TABLE sg_owned_stall_chart; CREATE fn rebuild_sg_owned_stall_chart();
--         CREATE RPC get_sg_owned_stall_chart(int,int); cron_policy row +
--         cron.schedule('sg_owned_stall_chart_rebuild_daily'); one initial rebuild.
-- reads:  seatgeek_event_metrics (sold_*), sg_event_priority_state (map/names),
--         latest_event_metrics (owned_*), evo_orders, vivid_orders,
--         tickpick_orders, seatgeek_orders.
-- pre-reqs: 20260606120000 (sg_market_chart — the sibling chart + cron pattern),
--           20260708042000 (cron_should_fire timeout capture-and-restore).
--
-- ============================================================
-- "SG SELLING, WE'RE NOT — OWNED, NOT MOVING" — the OWNED-inventory companion
-- to the sg_market_chart Top-50 (which by construction only charts events we
-- hold ZERO inventory in). This chart answers the other half of the operator's
-- "SeatGeek is selling, we're not" question: events where we DO hold inventory,
-- the SG market is clearing tickets daily, and OUR own channels (EVO, Vivid,
-- TickPick, SG SellerDirect) recorded ZERO sales in the trailing 7 days.
--
-- Prototype on prod 2026-07-09 (read-only): 520 owned events had live SG sales
-- activity; 471 (91%) had no own-channel sale in 7d, averaging 157 market
-- sales/day. Headline offenders carry a +100–220% ask premium vs the price the
-- market is actually clearing at (ask_premium_pct is the "why" column).
--
-- ELIGIBILITY (a row charts when ALL hold):
--   * future event, mapped (sg_event_priority_state.tevo_event_id NOT NULL)
--   * we hold EVO/TEvo inventory NOW: latest_event_metrics.owned_tickets_count
--     > 0 (fresh, firehose-fed). The SG-side book/firehose has been dark since
--     2026-06-26 (listings crons off after chronic 429s), so SG-side ownership
--     is carried as last-known INFO columns (sg_owned_*) but never gates.
--   * real market tape: >= 2 days with SG sales in the trailing 7d
--   * our_sales_7d = 0 across all four own channels ("we're not" is literal;
--     an event we sold on this week drops off the chart)
--
-- SCORING (same two-axis percentile blend as the sibling chart, 0..2):
--   stall_score = percent_rank(ma7_volume)                        [market heat]
--               + percent_rank(owned_tickets * coalesce(ask, med)) [our $ stuck]
-- High market velocity AND a big pile of our money sitting still tops the
-- chart. Billboard mechanics (prev/peak/days_on_chart) mirror sg_market_chart.
--
-- OUR-SALES DEFINITION (per channel, "not-dead" orders, created in window):
--   evo:      seller_brokerage_id = 1768 (we are the seller) AND state NOT IN
--             ('rejected','canceled','canceled_post_acceptance')
--   vivid:    upper(status) NOT IN ('CANCELED','CANCELLED','REJECTED')
--   tickpick: upper(order_status) NOT IN ('REJECTED','CANCELED','CANCELLED')
--             (order_status carries CONFIRMED, absent from order_status_xref —
--             per-source predicates instead of the xref join on purpose)
--   seatgeek: lower(status) <> 'cancelled' (SellerDirect orders table is dark
--             since 2026-06 — included so the chart heals itself if relit;
--             ingest gaps tracked in KANBAN A1-OPS-30)
--   Strict is_sale_succeeded is deliberately NOT used: a real sale sits in
--   accepted/pending for days before fulfilment.
--
-- PENDING OPERATOR APPLY: prod application is gated (CLAUDE.md §1). The final
-- SELECT rebuild_sg_owned_stall_chart() seeds the table on apply so the panel
-- renders immediately. ROLLBACK: cron.unschedule('sg_owned_stall_chart_rebuild_daily');
-- DROP FUNCTION get_sg_owned_stall_chart(int,int), rebuild_sg_owned_stall_chart();
-- DROP TABLE sg_owned_stall_chart; DELETE FROM cron_policy WHERE jobname =
-- 'sg_owned_stall_chart_rebuild_daily'.
-- ============================================================

-- ---------- 1. Chart history table (one ranked set per UTC day) ----------
CREATE TABLE IF NOT EXISTS public.sg_owned_stall_chart (
  chart_date           date        NOT NULL,
  tevo_event_id        bigint      NOT NULL,
  sg_event_id          bigint,
  rank                 integer     NOT NULL,
  stall_score          numeric     NOT NULL,
  pct_volume           numeric,
  pct_exposure         numeric,
  ma7_volume           numeric,      -- SG market: 7d-MA daily sold tickets
  ma7_median           numeric,      -- SG market: 7d-MA median sold price
  ma7_gross            numeric,      -- SG market: 7d-MA daily sold gross
  days_with_sales      integer,
  owned_tickets        integer,      -- our EVO/TEvo inventory (fresh)
  owned_median_ask     numeric,      -- our median retail ask on those tickets
  owned_as_of          timestamptz,  -- latest_event_metrics.captured_at
  ask_premium_pct      numeric,      -- (our ask − market sold median) / median
  sg_owned_listings    integer,      -- last-known broker-owned SG listings (info)
  sg_owned_as_of       timestamptz,  -- when that was last observed (stale-badge)
  our_sales_30d        integer,      -- own-channel orders in trailing 30d
  our_last_sale_at     timestamptz,  -- most recent own-channel order, any time
  our_last_sale_source text,         -- evo | vivid | tickpick | seatgeek
  prev_rank            integer,      -- rank on the most recent prior chart_date
  peak_rank            integer,      -- best (lowest) rank ever achieved
  days_on_chart        integer,      -- consecutive daily appearances
  sg_event_name        text,
  sg_venue_name        text,
  sg_datetime_utc      timestamptz,
  PRIMARY KEY (chart_date, tevo_event_id)
);

CREATE INDEX IF NOT EXISTS sg_owned_stall_chart_date_rank_idx
  ON public.sg_owned_stall_chart (chart_date, rank);
CREATE INDEX IF NOT EXISTS sg_owned_stall_chart_event_idx
  ON public.sg_owned_stall_chart (tevo_event_id);

-- secure-by-default: only the SECDEF RPC (owner) reads it; no anon/auth surface
REVOKE ALL ON public.sg_owned_stall_chart FROM anon, authenticated;

-- ---------- 2. Daily rebuild function ----------
CREATE OR REPLACE FUNCTION public.rebuild_sg_owned_stall_chart()
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_today date := (now() AT TIME ZONE 'UTC')::date;
  v_prev  date;
  v_count int := 0;
BEGIN
  SELECT max(chart_date) INTO v_prev
  FROM public.sg_owned_stall_chart WHERE chart_date < v_today;

  DELETE FROM public.sg_owned_stall_chart WHERE chart_date = v_today;  -- idempotent re-run

  WITH daily AS (
    -- one row per (event, UTC day): latest hourly rollup; sold_* is trailing-24h
    SELECT DISTINCT ON (sg_event_id, (captured_at AT TIME ZONE 'UTC')::date)
      sg_event_id,
      sold_quantity, sold_price_median, sold_gross
    FROM public.seatgeek_event_metrics
    WHERE captured_at > now() - interval '7 days'
      AND coalesce(sold_quantity, 0) > 0
    ORDER BY sg_event_id, (captured_at AT TIME ZONE 'UTC')::date, captured_at DESC
  ),
  ma AS (
    SELECT sg_event_id,
      count(*)                        AS days_with_sales,
      avg(sold_quantity)::numeric     AS ma7_volume,
      avg(sold_price_median)::numeric AS ma7_median,
      avg(sold_gross)::numeric        AS ma7_gross
    FROM daily
    GROUP BY sg_event_id
  ),
  mapped AS (
    -- map to canonical tevo id + display fields; N SG events can share one
    -- tevo_event_id (§0 map-can-be-wrong) → keep the hottest per tevo id
    SELECT DISTINCT ON (p.tevo_event_id)
      m.sg_event_id, m.days_with_sales, m.ma7_volume, m.ma7_median, m.ma7_gross,
      p.tevo_event_id, p.sg_event_name, p.sg_venue_name, p.sg_datetime_utc
    FROM ma m
    JOIN public.sg_event_priority_state p ON p.sg_event_id = m.sg_event_id
    WHERE p.tevo_event_id IS NOT NULL
      AND p.sg_datetime_utc > now()
      AND m.days_with_sales >= 2
    ORDER BY p.tevo_event_id, m.ma7_volume DESC
  ),
  owned AS (
    SELECT event_id AS tevo_event_id,
           owned_tickets_count, owned_median_retail, captured_at AS owned_as_of
    FROM public.latest_event_metrics
    WHERE coalesce(owned_tickets_count, 0) > 0
  ),
  ours AS (
    -- our own orders, all channels, "not-dead" statuses (see header)
    SELECT o.tevo_event_id, o.evo_created_at AS created_at, 'evo'::text AS src
    FROM public.evo_orders o
    WHERE o.seller_brokerage_id = 1768
      AND o.state NOT IN ('rejected','canceled','canceled_post_acceptance')
      AND o.tevo_event_id IS NOT NULL
    UNION ALL
    SELECT v.tevo_event_id, v.ordered_at, 'vivid'
    FROM public.vivid_orders v
    WHERE upper(coalesce(v.status,'')) NOT IN ('CANCELED','CANCELLED','REJECTED')
      AND v.tevo_event_id IS NOT NULL
    UNION ALL
    SELECT t.tevo_event_id, t.ordered_at, 'tickpick'
    FROM public.tickpick_orders t
    WHERE upper(coalesce(t.order_status,'')) NOT IN ('REJECTED','CANCELED','CANCELLED')
      AND t.tevo_event_id IS NOT NULL
    UNION ALL
    SELECT s.tevo_event_id, s.created_at_sg, 'seatgeek'
    FROM public.seatgeek_orders s
    WHERE lower(coalesce(s.status,'')) <> 'cancelled'
      AND s.tevo_event_id IS NOT NULL
  ),
  our_agg AS (
    SELECT tevo_event_id,
      count(*) FILTER (WHERE created_at > now() - interval '7 days')  AS sales_7d,
      count(*) FILTER (WHERE created_at > now() - interval '30 days') AS sales_30d,
      max(created_at) AS last_sale_at
    FROM ours
    GROUP BY tevo_event_id
  ),
  our_last_src AS (
    SELECT DISTINCT ON (tevo_event_id) tevo_event_id, src AS last_source
    FROM ours
    ORDER BY tevo_event_id, created_at DESC
  ),
  elig AS (
    SELECT m.*,
      o.owned_tickets_count, o.owned_median_retail, o.owned_as_of,
      sgown.listings_owned_count AS sg_owned_listings,
      sgown.captured_at          AS sg_owned_as_of,
      coalesce(a.sales_30d, 0)   AS our_sales_30d,
      a.last_sale_at             AS our_last_sale_at,
      ls.last_source             AS our_last_sale_source
    FROM mapped m
    JOIN owned o USING (tevo_event_id)
    LEFT JOIN our_agg  a  USING (tevo_event_id)
    LEFT JOIN our_last_src ls USING (tevo_event_id)
    LEFT JOIN LATERAL (
      -- last-known SG-side broker-owned listings (info only; feed dark 06-26)
      SELECT sem.listings_owned_count, sem.captured_at
      FROM public.seatgeek_event_metrics sem
      WHERE sem.sg_event_id = m.sg_event_id
        AND coalesce(sem.listings_owned_count, 0) > 0
      ORDER BY sem.captured_at DESC
      LIMIT 1
    ) sgown ON true
    WHERE coalesce(a.sales_7d, 0) = 0            -- "we're not": no own sale in 7d
  ),
  scored AS (
    SELECT e.*,
      -- percent_rank() is double precision; cast to numeric so round() resolves
      (percent_rank() OVER (ORDER BY e.ma7_volume))::numeric AS pct_volume,
      (percent_rank() OVER (ORDER BY
         e.owned_tickets_count * coalesce(e.owned_median_retail, e.ma7_median, 0)
       ))::numeric AS pct_exposure
    FROM elig e
  ),
  ranked AS (
    SELECT s.*,
      (pct_volume + pct_exposure) AS stall_score,
      row_number() OVER (
        ORDER BY (pct_volume + pct_exposure) DESC, ma7_gross DESC NULLS LAST, ma7_volume DESC
      ) AS rnk
    FROM scored s
  )
  INSERT INTO public.sg_owned_stall_chart (
    chart_date, tevo_event_id, sg_event_id, rank, stall_score,
    pct_volume, pct_exposure, ma7_volume, ma7_median, ma7_gross, days_with_sales,
    owned_tickets, owned_median_ask, owned_as_of, ask_premium_pct,
    sg_owned_listings, sg_owned_as_of,
    our_sales_30d, our_last_sale_at, our_last_sale_source,
    prev_rank, peak_rank, days_on_chart,
    sg_event_name, sg_venue_name, sg_datetime_utc)
  SELECT
    v_today, r.tevo_event_id, r.sg_event_id, r.rnk::int, round(r.stall_score, 4),
    round(r.pct_volume, 4), round(r.pct_exposure, 4),
    round(r.ma7_volume, 1), round(r.ma7_median, 2), round(r.ma7_gross, 2), r.days_with_sales,
    r.owned_tickets_count, round(r.owned_median_retail, 2), r.owned_as_of,
    CASE WHEN r.ma7_median > 0 AND r.owned_median_retail IS NOT NULL
         THEN round(100 * (r.owned_median_retail - r.ma7_median) / r.ma7_median, 1)
    END,
    r.sg_owned_listings, r.sg_owned_as_of,
    r.our_sales_30d, r.our_last_sale_at, r.our_last_sale_source,
    prev.rank,
    LEAST(r.rnk::int,
          coalesce((SELECT min(h.rank) FROM public.sg_owned_stall_chart h
                    WHERE h.tevo_event_id = r.tevo_event_id), r.rnk::int)),
    CASE WHEN prev.rank IS NOT NULL THEN coalesce(prev.days_on_chart, 0) + 1 ELSE 1 END,
    r.sg_event_name, r.sg_venue_name, r.sg_datetime_utc
  FROM ranked r
  LEFT JOIN public.sg_owned_stall_chart prev
    ON prev.tevo_event_id = r.tevo_event_id AND prev.chart_date = v_prev;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- retention: keep 90 days of chart history
  DELETE FROM public.sg_owned_stall_chart WHERE chart_date < v_today - 90;

  RETURN v_count;
END $func$;

REVOKE ALL ON FUNCTION public.rebuild_sg_owned_stall_chart() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_sg_owned_stall_chart() TO service_role;

COMMENT ON FUNCTION public.rebuild_sg_owned_stall_chart() IS
  'Rebuilds today''s sg_owned_stall_chart: future events we hold EVO inventory in '
  'where the SG market sold on >=2 of the trailing 7 days but our own channels '
  '(evo/vivid/tickpick/sg) sold NOTHING in 7d. stall_score = percent_rank(7d-MA '
  'market volume) + percent_rank(our $ exposure). Billboard prev/peak/days_on '
  'mechanics mirror sg_market_chart. Daily cron @ 11:20 UTC.';

-- ---------- 3. Read RPC (email-gated, paged: top 50 + the rest) ----------
CREATE OR REPLACE FUNCTION public.get_sg_owned_stall_chart(
  p_offset integer DEFAULT 0,
  p_limit  integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_email text;
  v_date  date;
  v_total int;
  v_rows  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT max(chart_date) INTO v_date FROM public.sg_owned_stall_chart;
  IF v_date IS NULL THEN
    RETURN jsonb_build_object('chart_date', NULL, 'total', 0, 'rows', '[]'::jsonb);
  END IF;

  SELECT count(*) INTO v_total FROM public.sg_owned_stall_chart WHERE chart_date = v_date;

  SELECT coalesce(jsonb_agg(r.obj ORDER BY (r.obj->>'rank')::int), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'rank',                 m.rank,
      'prev_rank',            m.prev_rank,
      'rank_delta',           CASE WHEN m.prev_rank IS NULL THEN NULL ELSE m.prev_rank - m.rank END,
      'is_new',               (m.prev_rank IS NULL),
      'peak_rank',            m.peak_rank,
      'days_on_chart',        m.days_on_chart,
      'tevo_event_id',        m.tevo_event_id,
      'sg_event_id',          m.sg_event_id,
      'sg_event_name',        m.sg_event_name,
      'sg_venue_name',        m.sg_venue_name,
      'sg_datetime_utc',      to_char(m.sg_datetime_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'ma7_volume',           m.ma7_volume,
      'ma7_median',           m.ma7_median,
      'ma7_gross',            m.ma7_gross,
      'days_with_sales',      m.days_with_sales,
      'owned_tickets',        m.owned_tickets,
      'owned_median_ask',     m.owned_median_ask,
      'owned_as_of',          to_char(m.owned_as_of AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'ask_premium_pct',      m.ask_premium_pct,
      'sg_owned_listings',    m.sg_owned_listings,
      'sg_owned_as_of',       to_char(m.sg_owned_as_of AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'our_sales_30d',        m.our_sales_30d,
      'our_last_sale_at',     to_char(m.our_last_sale_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'our_last_sale_source', m.our_last_sale_source,
      'pct_volume',           m.pct_volume,
      'pct_exposure',         m.pct_exposure,
      'stall_score',          m.stall_score
    ) AS obj
    FROM public.sg_owned_stall_chart m
    WHERE m.chart_date = v_date
    ORDER BY m.rank
    OFFSET greatest(coalesce(p_offset, 0), 0)
    LIMIT  least(coalesce(p_limit, 50), 500)
  ) r;

  RETURN jsonb_build_object('chart_date', v_date, 'total', v_total, 'rows', v_rows);
END $func$;

REVOKE ALL ON FUNCTION public.get_sg_owned_stall_chart(integer, integer) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sg_owned_stall_chart(integer, integer) TO authenticated;

COMMENT ON FUNCTION public.get_sg_owned_stall_chart(integer, integer) IS
  'Returns {chart_date,total,rows[]} for the latest sg_owned_stall_chart day, paged '
  'by rank (offset/limit, cap 500). Powers the terminal home "SG SELLING, WE''RE NOT '
  '— OWNED, NOT MOVING" panel: tab 1 = offset 0/limit 50, tab 2 = the rest. '
  'Email-gated @s4kent.com.';

-- ---------- 4. Daily rebuild cron (gated) ----------
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_owned_stall_chart_rebuild_daily',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   720, 720, 2, true,
   'Daily rebuild of sg_owned_stall_chart (owned-and-stalled companion to the Top-50 non-owned chart; home panel). Fires once @ 11:20 UTC, 15 min after sg_market_chart_rebuild_daily so the two never contend; 720-min gate guards double-fire.')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et = EXCLUDED.peak_hours_et,
      peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = true,
      notes = EXCLUDED.notes,
      updated_at = now();

SELECT cron.schedule('sg_owned_stall_chart_rebuild_daily', '20 11 * * *', $cron$
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_owned_stall_chart_rebuild_daily') THEN RETURN; END IF;
    SET LOCAL statement_timeout = '300s';
    PERFORM public.rebuild_sg_owned_stall_chart();
  END $body$;
$cron$);

-- ---------- 5. Seed today's chart so the panel renders immediately on apply ----------
SELECT public.rebuild_sg_owned_stall_chart();
