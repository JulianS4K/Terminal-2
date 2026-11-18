-- Undervalued-asset grade: the operator's own buy rule, scored per deal.
--
-- The scanner finds statistical outliers (modified z <= -3.5 inside a curated zone) and then
-- ranks them by realized-sale win probability. That is a different question from "is this thing
-- worth owning", which the operator states as eight conditions. This migration encodes those
-- eight verbatim and grades every live feed row against them, recording WHICH ones failed —
-- the fail codes are the point. A rule that silently drops 90% of the feed is only useful if
-- you can see that it was criterion 5 (no sale history) and not criterion 1 (not cheap enough)
-- doing the dropping.
--
-- The grade LAYERS on the existing feed, it does not replace the win-probability gate: the feed
-- keeps every row it would have had, and uv_pass marks the subset that clears the buy rule.
--
--   1 zone_discount     price <= zone median - 30%
--   2 single            quantity >= 2
--   3 view_or_parking   no obstructed/limited/partial view note, no parking
--   4 dte               event is 7+ days out
--   5 sales_median      pooled realized median for the EVENT (all sale sources) > price per seat
--     sales_n           ...and enough sales to mean anything
--   6 price_pctile      in the cheapest p_price_pctile of its zone's book
--     row_below_median  ...but seated better than the zone's median row (don't flag row 50)
--     row_unknown       ...row we cannot rank at all
--   7 ma_negative       15-day moving average of the event's listing median is rising
--     ma_history        ...with enough daily history to compute it
--
-- Criterion 3 also plugs a real hole: the EVO leg drops parking via type/is_ancillary, the
-- GoTickets leg had nothing — GT parking inventory reached the scanner as ordinary listings.

-- ---------------------------------------------------------------------------
-- 1. Parking exclusion (criterion 3, GoTickets leg)
-- ---------------------------------------------------------------------------
-- Tokens are word-bounded on purpose: '\mparking\M' must not fire on "Ballpark Box" or
-- "Park Terrace 12", which are seats.
CREATE OR REPLACE FUNCTION public.deal_listing_excluded(
  p_notes text, p_row text, p_section text,
  p_wheelchair boolean DEFAULT false, p_view_type text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $fn$
  SELECT coalesce(p_wheelchair, false)
      OR concat_ws(' ', p_notes, p_view_type) ~* '(obstruct|limited view|limited or|partial view|partially|restricted view|side view|rear stage|rear view|behind (the )?stage|no view|overhang|\mpole\M|pillar|standing room|\msro\M|not an event ticket|wheelchair|\mada\M|accessible|handicap)'
      OR coalesce(p_row, '')     ~* '(\mwc\M|\mwc[0-9a-z-]|wheelchair|accessible|\mada\M|handicap)'
      OR coalesce(p_section, '') ~* '(\mwc\M|wheelchair|accessible|\mada\M|handicap)'
      OR concat_ws(' ', p_section, p_notes) ~* '(\mparking\M|\mparking pass\M|\mpark(ing)? lot\M|\mrv lot\M|\mtailgate\M|\mshuttle\M)'
$fn$;

COMMENT ON FUNCTION public.deal_listing_excluded(text,text,text,boolean,text) IS
  'True when a listing must never be scored as a deal: obstructed/limited/partial view, standing room, wheelchair/ADA, or parking. Word-bounded parking tokens so "Ballpark"/"Park Terrace" stay seats.';

-- ---------------------------------------------------------------------------
-- 2. Feed columns carrying the grade + its evidence
-- ---------------------------------------------------------------------------
ALTER TABLE public.gotickets_deals_feed
  ADD COLUMN IF NOT EXISTS uv_pass           boolean,
  ADD COLUMN IF NOT EXISTS uv_fail_codes     text[],
  ADD COLUMN IF NOT EXISTS uv_graded_at      timestamptz,
  ADD COLUMN IF NOT EXISTS uv_price_pctile   numeric,
  ADD COLUMN IF NOT EXISTS uv_row_rank       int,
  ADD COLUMN IF NOT EXISTS uv_zone_row_median numeric,
  ADD COLUMN IF NOT EXISTS uv_sale_median    numeric,
  ADD COLUMN IF NOT EXISTS uv_sale_n         int,
  ADD COLUMN IF NOT EXISTS uv_ma15_now       numeric,
  ADD COLUMN IF NOT EXISTS uv_ma15_prev      numeric;

COMMENT ON COLUMN public.gotickets_deals_feed.uv_pass IS
  'Clears every condition of the operator buy rule. NULL = not graded yet.';
COMMENT ON COLUMN public.gotickets_deals_feed.uv_fail_codes IS
  'Which conditions it failed, empty array when uv_pass. Read the histogram of these before loosening any threshold.';
COMMENT ON COLUMN public.gotickets_deals_feed.uv_price_pctile IS
  'percent_rank of this listing price inside its curated zone at gt_captured_at; 0 = cheapest in the zone.';
COMMENT ON COLUMN public.gotickets_deals_feed.uv_sale_median IS
  'Median realized per-seat sale price for the whole event across SeatGeek broker + SeatData + GoTickets, over the grading window. GoTickets contributes payout-basis prices, so this pool is mildly conservative.';

CREATE INDEX IF NOT EXISTS gotickets_deals_feed_uv_pass_idx
  ON public.gotickets_deals_feed (uv_pass, last_seen_at DESC)
  WHERE gone_at IS NULL;

-- ---------------------------------------------------------------------------
-- 3. The grader
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.grade_undervalued_assets(
  p_events            bigint[] DEFAULT NULL,
  p_max_events        int      DEFAULT 200,
  p_min_discount_pct  numeric  DEFAULT 30,
  p_min_qty           int      DEFAULT 2,
  p_min_dte           int      DEFAULT 7,
  p_min_sale_n        int      DEFAULT 5,
  p_price_pctile      numeric  DEFAULT 0.25,
  p_ma_days           int      DEFAULT 15,
  p_sale_window_days  int      DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $fn$
DECLARE
  v_graded int := 0; v_pass int := 0; v_events int := 0;
  v_ma  int := GREATEST(coalesce(p_ma_days, 15), 3);
  v_win int := GREATEST(coalesce(p_sale_window_days, 30), 1);
  v_pct numeric := LEAST(GREATEST(coalesce(p_price_pctile, 0.25), 0), 1);
  v_mix jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '45000', true);

  DROP TABLE IF EXISTS pg_temp._uv_rows, pg_temp._uv_book, pg_temp._uv_sect, pg_temp._uv_zone,
                       pg_temp._uv_sales, pg_temp._uv_ma, pg_temp._uv_grade;

  -- The rows to grade, and the (event, capture) pairs whose listing book we must reconstruct.
  CREATE TEMP TABLE _uv_rows ON COMMIT DROP AS
  WITH ev AS (
    SELECT DISTINCT f.tevo_event_id AS ev
    FROM public.gotickets_deals_feed f
    WHERE f.gone_at IS NULL
      AND (p_events IS NULL OR f.tevo_event_id = ANY (p_events))
    ORDER BY 1
    LIMIT GREATEST(coalesce(p_max_events, 200), 1)
  )
  SELECT f.tevo_event_id AS ev, f.gt_event_id, f.gt_listing_id AS lid, f.source,
         f.gt_captured_at AS cap, f.quantity, f.gt_price AS price, f.vs_zone_pct,
         f.dte_now, f."row" AS row_label, f.section,
         public.seat_row_rank(f."row") AS row_rank
  FROM public.gotickets_deals_feed f
  JOIN ev ON ev.ev = f.tevo_event_id
  WHERE f.gone_at IS NULL;

  SELECT count(*), count(DISTINCT ev) INTO v_graded, v_events FROM _uv_rows;
  IF v_graded = 0 THEN
    RETURN jsonb_build_object('graded', 0, 'passed', 0, 'events', 0, 'at', now());
  END IF;

  -- The book as the scanner saw it: every sellable listing on that capture.
  CREATE TEMP TABLE _uv_book ON COMMIT DROP AS
  WITH pairs AS (SELECT DISTINCT ev, gt_event_id, source, cap FROM _uv_rows)
    SELECT p.ev, p.source, g.gt_listing_id AS listing_id, btrim(g.section) AS section,
           g.all_in_price::numeric AS price, public.seat_row_rank(g."row") AS row_rank
    FROM pairs p
    JOIN public.gotickets_listings_snapshots g
      ON g.gt_event_id = p.gt_event_id AND g.captured_at = p.cap
    WHERE p.source = 'gotickets'
      AND g.all_in_price > 0 AND g.section IS NOT NULL
      AND coalesce(g.general_admission, false) = false
      AND NOT public.deal_listing_excluded(g.notes, g."row", g.section, false, NULL)
    UNION ALL
    SELECT p.ev, p.source, -l.tevo_ticket_group_id AS listing_id, btrim(l.section) AS section,
           l.wholesale_price::numeric AS price, public.seat_row_rank(l."row") AS row_rank
    FROM pairs p
    JOIN public.listings_snapshots l
      ON l.event_id = p.ev AND l.captured_at = p.cap
    WHERE p.source = 'evo'
      AND l.wholesale_price > 0 AND l.section IS NOT NULL
      AND NOT coalesce(l.is_owned, false) AND NOT coalesce(l.is_ancillary, false)
      AND coalesce(l.type, 'event') = 'event'
      AND NOT public.deal_listing_excluded(l.public_notes, l."row", l.section,
                                           coalesce(l.wheelchair,false), l.view_type);

  -- Zone lookup once per distinct section, not once per listing. gt_curated_zone_id() is a
  -- two-table join with a function in its predicate (procost 100); calling it per listing put
  -- a 120-event batch over the statement timeout while 60 events finished fine.
  CREATE TEMP TABLE _uv_sect ON COMMIT DROP AS
  SELECT s.ev, s.source, s.section,
         public.gt_curated_zone_id(e.primary_performer_id, e.venue_id, s.section) AS zid
  FROM (SELECT DISTINCT ev, source, section FROM _uv_book) s
  JOIN public.events e ON e.id = s.ev;
  CREATE INDEX ON _uv_sect (ev, source, section);

  -- Price standing inside the zone, and the zone's median row.
  -- LEFT JOIN, not JOIN: a zone whose rows are all unparseable still has a price standing, and
  -- that row should fail row_unknown alone rather than also reading as "not cheap enough".
  -- DISTINCT ON guards the known landmine where one TEvo event carries two gotickets_event rows.
  CREATE TEMP TABLE _uv_zone ON COMMIT DROP AS
  SELECT DISTINCT ON (ev, source, listing_id) *
  FROM (
    SELECT b.ev, b.source, b.listing_id,
           percent_rank() OVER (PARTITION BY b.ev, b.source, k.zid ORDER BY b.price) AS price_pctile,
           z.row_median
    FROM _uv_book b
    JOIN _uv_sect k ON k.ev = b.ev AND k.source = b.source AND k.section = b.section
    LEFT JOIN (
      SELECT b2.ev, b2.source, k2.zid,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY b2.row_rank)::numeric AS row_median
      FROM _uv_book b2
      JOIN _uv_sect k2 ON k2.ev = b2.ev AND k2.source = b2.source AND k2.section = b2.section
      WHERE b2.row_rank IS NOT NULL AND k2.zid IS NOT NULL
      GROUP BY b2.ev, b2.source, k2.zid
    ) z ON z.ev = b.ev AND z.source = b.source AND z.zid = k.zid
    WHERE k.zid IS NOT NULL
  ) q
  ORDER BY ev, source, listing_id, price_pctile;
  CREATE INDEX ON _uv_zone (ev, source, listing_id);

  -- Criterion 5: what the EVENT actually sells for, per seat, pooled across every sale feed
  -- we collect. Event-level on purpose — the operator's test is the event's median, not the
  -- zone's, so a cheap upper-deck seat is compared against the whole building.
  CREATE TEMP TABLE _uv_sales ON COMMIT DROP AS
  WITH ev AS (SELECT DISTINCT ev FROM _uv_rows),
  pool AS (
    SELECT ev.ev, s.broadcast_price::numeric AS px
    FROM ev JOIN public.seatgeek_sales_snapshots s ON s.tevo_event_id = ev.ev
    WHERE s.broadcast_price > 0 AND s.sale_at_utc > now() - make_interval(days => v_win)
    UNION ALL
    SELECT ev.ev, d.price::numeric
    FROM ev JOIN public.seatdata_sales_snapshots d ON d.tevo_event_id = ev.ev
    WHERE d.price > 0 AND d.sale_timestamp > now() - make_interval(days => v_win)
    UNION ALL
    SELECT ev.ev, g.unit_cost::numeric
    FROM ev
    JOIN public.gotickets_event ge ON ge.tevo_event_id = ev.ev
    JOIN public.gotickets_sales g ON g.gt_event_id = ge.gt_event_id
    WHERE g.unit_cost > 0 AND g.create_time > now() - make_interval(days => v_win)
  )
  SELECT ev, count(*)::int AS sale_n,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY px)::numeric AS sale_median
  FROM pool GROUP BY ev;

  -- Criterion 7: is the event's own listing median trending up over the last v_ma days.
  CREATE TEMP TABLE _uv_ma ON COMMIT DROP AS
  WITH ev AS (SELECT DISTINCT ev FROM _uv_rows),
  daily AS (
    SELECT d.event_id AS ev, d.snapshot_date, avg(d.amalgam_median) AS med
    FROM ev JOIN public.event_listing_snapshot_daily d ON d.event_id = ev.ev
    WHERE d.amalgam_median IS NOT NULL
    GROUP BY d.event_id, d.snapshot_date
  ),
  ranked AS (
    SELECT ev, med, row_number() OVER (PARTITION BY ev ORDER BY snapshot_date DESC) AS rn FROM daily
  )
  SELECT ev,
         avg(med) FILTER (WHERE rn <= v_ma)                       AS ma_now,
         avg(med) FILTER (WHERE rn BETWEEN v_ma+1 AND 2*v_ma)     AS ma_prev,
         count(*) FILTER (WHERE rn <= v_ma)                       AS n_now,
         count(*) FILTER (WHERE rn BETWEEN v_ma+1 AND 2*v_ma)     AS n_prev
  FROM ranked GROUP BY ev;

  -- Assemble. A row that is not in its own book at all (capture rolled over mid-scan) fails
  -- the zone-standing tests rather than passing them by default.
  CREATE TEMP TABLE _uv_grade ON COMMIT DROP AS
  SELECT r.ev, r.lid, r.source,
         z.price_pctile, r.row_rank, z.row_median, s.sale_n, s.sale_median, m.ma_now, m.ma_prev,
         (ARRAY[]::text[]
          || CASE WHEN r.vs_zone_pct IS NULL OR r.vs_zone_pct > -p_min_discount_pct
                  THEN ARRAY['zone_discount'] ELSE ARRAY[]::text[] END
          || CASE WHEN coalesce(r.quantity, 1) < p_min_qty
                  THEN ARRAY['single'] ELSE ARRAY[]::text[] END
          || CASE WHEN coalesce(r.dte_now, 0) < p_min_dte
                  THEN ARRAY['dte'] ELSE ARRAY[]::text[] END
          || CASE WHEN s.sale_n IS NULL OR s.sale_n < p_min_sale_n
                  THEN ARRAY['sales_n'] ELSE ARRAY[]::text[] END
          || CASE WHEN s.sale_n >= p_min_sale_n AND s.sale_median <= r.price
                  THEN ARRAY['sales_median'] ELSE ARRAY[]::text[] END
          || CASE WHEN z.price_pctile IS NULL OR z.price_pctile > v_pct
                  THEN ARRAY['price_pctile'] ELSE ARRAY[]::text[] END
          || CASE WHEN r.row_rank IS NULL OR z.row_median IS NULL
                  THEN ARRAY['row_unknown']
                  WHEN r.row_rank >= z.row_median
                  THEN ARRAY['row_below_median'] ELSE ARRAY[]::text[] END
          || CASE WHEN m.n_now IS NULL OR m.n_now < (v_ma*2)/3 OR m.n_prev < v_ma/2 OR coalesce(m.ma_prev,0) <= 0
                  THEN ARRAY['ma_history']
                  WHEN m.ma_now <= m.ma_prev
                  THEN ARRAY['ma_negative'] ELSE ARRAY[]::text[] END
         ) AS codes
  FROM _uv_rows r
  LEFT JOIN _uv_zone  z ON z.ev = r.ev AND z.source = r.source AND z.listing_id = r.lid
  LEFT JOIN _uv_sales s ON s.ev = r.ev
  LEFT JOIN _uv_ma    m ON m.ev = r.ev;

  UPDATE public.gotickets_deals_feed f
     SET uv_pass            = (cardinality(g.codes) = 0),
         uv_fail_codes      = g.codes,
         uv_graded_at       = now(),
         -- percent_rank() and avg(amalgam_median) come back double precision; round(double, int)
         -- does not exist in Postgres, so every one of these needs the cast.
         uv_price_pctile    = round(g.price_pctile::numeric, 4),
         uv_row_rank        = g.row_rank,
         uv_zone_row_median = round(g.row_median::numeric, 1),
         uv_sale_median     = round(g.sale_median::numeric, 2),
         uv_sale_n          = g.sale_n,
         uv_ma15_now        = round(g.ma_now::numeric, 2),
         uv_ma15_prev       = round(g.ma_prev::numeric, 2)
    FROM _uv_grade g
   WHERE f.tevo_event_id = g.ev AND f.gt_listing_id = g.lid AND f.gone_at IS NULL;

  SELECT count(*) FILTER (WHERE cardinality(codes) = 0) INTO v_pass FROM _uv_grade;
  SELECT coalesce(jsonb_object_agg(code, n), '{}'::jsonb) INTO v_mix
  FROM (SELECT unnest(codes) AS code, count(*) AS n FROM _uv_grade GROUP BY 1) q;

  RETURN jsonb_build_object(
    'graded', v_graded, 'passed', v_pass, 'events', v_events,
    'fail_mix', v_mix,
    'thresholds', jsonb_build_object(
      'min_discount_pct', p_min_discount_pct, 'min_qty', p_min_qty, 'min_dte', p_min_dte,
      'min_sale_n', p_min_sale_n, 'price_pctile', v_pct, 'ma_days', v_ma,
      'sale_window_days', v_win),
    'at', now());
END;
$fn$;

REVOKE ALL ON FUNCTION public.grade_undervalued_assets(bigint[],int,numeric,int,int,int,numeric,int,int) FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.grade_undervalued_assets(bigint[],int,numeric,int,int,int,numeric,int,int) IS
  'Grades live deal-feed rows against the operator undervalued-asset rule and records which conditions each row failed. Called at the end of every scan for the events just scanned; safe to re-run standalone.';

-- ---------------------------------------------------------------------------
-- 4. Read surface
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_undervalued_assets AS
SELECT f.source, f.tevo_event_id, f.gt_listing_id, f.event_name, f.event_date, f.dte_now,
       f.zone, f.section, f."row", f.quantity, f.gt_price,
       f.zone_median, f.vs_zone_pct, f.uv_price_pctile, f.uv_row_rank, f.uv_zone_row_median,
       f.uv_sale_median, f.uv_sale_n,
       f.uv_ma15_now, f.uv_ma15_prev,
       CASE WHEN f.uv_ma15_prev > 0
            THEN round((f.uv_ma15_now / f.uv_ma15_prev - 1) * 100, 1) END AS uv_ma15_pct,
       f.realized_median, f.realized_n, f.resale_basis, f.win_prob, f.net_profit_pct,
       f.pred_final_price, f.pred_roi_pct, f.pred_p15, f.confidence, f.regime,
       f.first_seen_at, f.last_seen_at, f.uv_graded_at
FROM public.gotickets_deals_feed f
WHERE f.gone_at IS NULL AND f.uv_pass;

COMMENT ON VIEW public.v_undervalued_assets IS
  'Live deals that clear every condition of the operator undervalued-asset rule. See grade_undervalued_assets().';

CREATE OR REPLACE FUNCTION public.get_undervalued_assets(
  p_limit int DEFAULT 100, p_source text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $fn$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email', '');
  v_src text := nullif(btrim(coalesce(p_source, '')), '');
  v_out jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '10000', true);

  SELECT jsonb_build_object(
    'generated_at', now(),
    'graded_at', (SELECT max(uv_graded_at) FROM public.gotickets_deals_feed WHERE gone_at IS NULL),
    'live_graded', (SELECT count(*) FROM public.gotickets_deals_feed WHERE gone_at IS NULL AND uv_pass IS NOT NULL),
    'passing', (SELECT count(*) FROM public.gotickets_deals_feed WHERE gone_at IS NULL AND uv_pass),
    -- The fail histogram is the operating instrument: it says which condition is actually
    -- binding before anyone argues about moving a threshold.
    'fail_mix', (SELECT coalesce(jsonb_object_agg(code, n), '{}'::jsonb) FROM (
                   SELECT unnest(uv_fail_codes) AS code, count(*) AS n
                   FROM public.gotickets_deals_feed
                   WHERE gone_at IS NULL AND uv_pass = false
                   GROUP BY 1) q),
    'assets', (SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.pred_roi_pct DESC NULLS LAST), '[]'::jsonb)
               FROM (SELECT * FROM public.v_undervalued_assets
                      WHERE (v_src IS NULL OR source = v_src)
                      ORDER BY pred_roi_pct DESC NULLS LAST
                      LIMIT GREATEST(coalesce(p_limit, 100), 1)) a)
  ) INTO v_out;
  RETURN v_out;
END;
$fn$;

REVOKE ALL ON FUNCTION public.get_undervalued_assets(int,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_undervalued_assets(int,text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Call the grader from the scanner, for the events it just scanned
-- ---------------------------------------------------------------------------
-- Assert-and-replace: scan_listing_deals is 25KB of SQL that no migration should restate.
-- Every anchor below must match exactly once or this migration aborts, and the signature is
-- read back from the catalog rather than retyped -- a hardcoded arg list here once came within
-- one failed assertion of silently reverting prod thresholds to their development defaults.
DO $do$
DECLARE
  v_src  text;
  v_args text;
  v_cfg  text[];
  v_set  text := '';
  v_kv   text;
  v_a    text;
  v_b    text;
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid), p.proconfig INTO v_src, v_args, v_cfg
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'scan_listing_deals';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'scan_listing_deals not found';
  END IF;
  IF position('grade_undervalued_assets' in v_src) > 0 THEN
    RETURN;   -- already spliced; the anchors below are one-shot by construction
  END IF;

  -- Carry the function's existing SET clauses across verbatim. Retyping search_path here is
  -- how a CREATE OR REPLACE quietly changes which schema a helper resolves from.
  FOREACH v_kv IN ARRAY coalesce(v_cfg, ARRAY[]::text[]) LOOP
    v_set := v_set || format(' SET %I TO %s', split_part(v_kv, '=', 1),
                             substr(v_kv, strpos(v_kv, '=') + 1));
  END LOOP;

  -- (a) a variable to hold the grader's summary
  v_a := '  v_new int := 0; v_gone int := 0; v_events int := 0; v_dl int := 0; v_xr int := 0;';
  IF (length(v_src) - length(replace(v_src, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'anchor (a) did not match exactly once';
  END IF;
  v_src := replace(v_src, v_a, v_a || E'\n  v_uv jsonb := ''{}''::jsonb;');

  -- (b) grade the rows we just wrote, before returning
  v_b := E'  RETURN jsonb_build_object(\n    ''source'', p_source, ''scanned_events'', v_events,';
  IF (length(v_src) - length(replace(v_src, v_b, ''))) / length(v_b) <> 1 THEN
    RAISE EXCEPTION 'anchor (b) did not match exactly once';
  END IF;
  v_src := replace(v_src, v_b,
    E'  -- Grade this batch against the operator undervalued-asset rule (mig 20260914240000).\n  -- Scoped to the events this call touched, so it stays a few hundred ms; re-runnable standalone.\n  v_uv := public.grade_undervalued_assets(ARRAY(SELECT ev FROM _cand), GREATEST(p_max_events,1) * 2);\n\n'
    || v_b);

  -- (c) surface it in the scan result
  v_a := E'                               ''raw_pass'', v_raw_pass, ''adj_pass'', v_adj_pass, ''dumping_in_adj_pass'', v_dumping, ''gated'', v_gated),\n    ''at'', now());';
  IF (length(v_src) - length(replace(v_src, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'anchor (c) did not match exactly once';
  END IF;
  v_src := replace(v_src, v_a,
    E'                               ''raw_pass'', v_raw_pass, ''adj_pass'', v_adj_pass, ''dumping_in_adj_pass'', v_dumping, ''gated'', v_gated),\n    ''undervalued'', v_uv,\n    ''at'', now());');

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.scan_listing_deals(%s) RETURNS jsonb '
    'LANGUAGE plpgsql SECURITY DEFINER%s AS %s',
    v_args, v_set, quote_literal(v_src));
END
$do$;
