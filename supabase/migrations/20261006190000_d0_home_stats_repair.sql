-- Migration 20261006190000 · level:secondary-sales · lane:D0 · writes:get_owned_events_upcoming(),get_discovery_gaps(),evo_sg_discovery_gaps(),get_home_stats(),get_sg_market_chart() · reads:latest_event_metrics,events,event_movers_index,discovery_gap_alerts,sg_events_canonical,event_metrics,seatgeek_event_metrics,ticketsdata_listings_snapshots,ticketsdata_event_xref,aq_event_map,performer_espn_team_xref,sg_market_chart,event_listing_snapshot_daily,s4kcs_orders,order_status_xref · pre:20260620000000,20260620010000,20260927043400
--
-- ============================================================================
-- Migration 20261006190000 — terminal home: repair the stats behind each panel
--
-- Lane:     D0 (terminal home) · operator-directed 2026-10-06 ("do all four" →
--           "guard + label"; Top 50 "exclude events we sell")
-- Touches:  functions + grants only (no table DDL, no data writes here):
--           get_owned_events_upcoming (W, new), get_discovery_gaps (W, new),
--           evo_sg_discovery_gaps (W, replaced), get_home_stats (W, new),
--           get_sg_market_chart (W, replaced)
-- Pre-reqs: 20260620000000 / 20260620010000 (authored, never applied — this
--           migration supersedes both), 20260927043400 (listing polls paused)
--
-- Already applied to prod · via MCP 2026-10-06 ~18:20 UTC under operator
-- direction. Verified as an @s4kent.com JWT: home stats coverage 5,813 / 977 /
-- 256 / 25; owned events 943 (as of 2026-09-27 04:34, the poll pause); gaps read
-- path OK; chart 121 kept / 9 excluded for our CRM sales. evo_sg_discovery_gaps()
-- run once: 0 rows, no error (EVO stale → EVO types skipped). Non-s4kent JWT →
-- 42501. evo_sg_discovery_gaps EXECUTE now postgres + service_role only.
--
-- Found 2026-10-06 auditing how /terminal/ builds its numbers:
--
-- 1. S4K-OWNED EVENTS panel called get_owned_events_upcoming, and the movers
--    gap chips + Discovery gaps panel call get_discovery_gaps — both authored
--    2026-06-20 and NEVER applied, so the owned panel errors and the chips
--    never appear. Re-created here; owned-events gains the @s4kent.com email
--    gate (it exposes our owned counts/prices, like get_sg_market_chart) and a
--    metrics_as_of column, because TEvo listing polls are paused (2026-09-27,
--    mig 20260927043400) and latest_event_metrics is frozen at that point.
--
-- 2. discovery_gap_refresh (cron 301) has failed daily since 2026-09-22:
--    value_gap_large's signal (SG median vs EVO median, %) reached +36,952% on
--    two events — over numeric(8,4) — and the one INSERT aborted. Fixing only
--    that would be worse: with TEvo polls paused, event_metrics has no rows in
--    48 h, so every EVO-absence gap type (sg_no_evo, td_*_no_evo) would fire on
--    every event as a false "no EVO coverage". So evo_sg_discovery_gaps now
--    (a) skips EVO-dependent gap types while EVO metrics are stale (< 1,000
--    event_metrics rows in 48 h; normal is ~55k/day), (b) restricts
--    value_gap_large to EVO metrics from the last 48 h, and (c) clamps every
--    signal_score to the column's range. Signals that need only SeatGeek /
--    TicketsData keep running. Its EXECUTE grant to `authenticated` (any
--    signed-in client could trigger this SECURITY DEFINER upsert) is revoked —
--    only cron 301 calls it.
--
-- 3. COVERAGE band was counted in the browser from the movers result (capped
--    at 200, following the movers source/window toggle, frozen since the movers
--    index was paused 2026-07-02). get_home_stats() counts upcoming TEAM events
--    server-side (a performer is in performer_espn_team_xref; ET dates;
--    parking listings excluded) and returns each panel's data-as-of time so
--    the page can label frozen feeds instead of presenting them as live:
--    movers index, TEvo inventory, market chart, discovery gaps.
--    The movers cron itself stays paused (operator: guard + label) — with the
--    listing polls paused it would compute an empty/stale index.
--
-- 4. TOP 50 — MARKET SELLING, WE'RE NOT IN: "not in" only checked owned TEvo
--    and SeatGeek listings, so events we sell on StubHub / Gametime / Vivid /
--    TickPick / GoTickets (CRM book) could appear. get_sg_market_chart now
--    drops events with a non-cancelled CRM order (s4kcs_orders, matched on
--    tevo_event_id OR sg_event_id) purchased — or, for undated SeatGeek rows,
--    seen — in the last 30 days, then renumbers. `rank` = position in the
--    filtered list; `chart_rank` = the stored daily rank; prev/peak/rank_delta
--    stay on the stored ranks (movement in the underlying chart). New keys:
--    excluded_crm (how many were dropped). The sg_market_chart TABLE and its
--    other consumers (SeatData/TD enrollment, deadman) are untouched.
-- ============================================================================

-- 1a. S4K-owned events, next p_days -------------------------------------------
CREATE OR REPLACE FUNCTION public.get_owned_events_upcoming(
  p_days int DEFAULT 30
) RETURNS TABLE (
  event_id            bigint,
  event_name          text,
  venue_name          text,
  occurs_at_local     text,
  days_to_event       int,
  owned_tickets_count int,
  owned_groups_count  int,
  getin_price         numeric,
  retail_median       numeric,
  owned_median_retail numeric,
  category            text,
  price_delta_pct     numeric,
  metrics_as_of       timestamptz   -- when this event's TEvo metrics were captured
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT
    m.event_id,
    e.name,
    COALESCE(e.venue_name, e.venue_location),
    e.occurs_at_local,
    FLOOR(EXTRACT(EPOCH FROM ((e.occurs_at_local)::timestamptz - now())) / 86400.0)::int,
    m.owned_tickets_count,
    m.owned_groups_count,
    m.getin_price,
    m.retail_median,
    m.owned_median_retail,
    mi.category,
    mi.price_delta_pct,
    m.captured_at
  FROM public.latest_event_metrics m
  JOIN public.events e ON e.id = m.event_id
  LEFT JOIN LATERAL (
    SELECT i.category, i.price_delta_pct
    FROM   public.event_movers_index i
    WHERE  i.source = 'merged' AND i.event_id = m.event_id
    ORDER BY i.signal_score DESC
    LIMIT 1
  ) mi ON true
  WHERE m.owned_tickets_count > 0
    AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
    AND (e.occurs_at_local)::timestamptz >= now() - interval '1 day'
    AND (e.occurs_at_local)::timestamptz <= now() + make_interval(days => GREATEST(p_days, 1))
  ORDER BY (e.occurs_at_local)::timestamptz ASC;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_owned_events_upcoming(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_owned_events_upcoming(int) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_owned_events_upcoming(int) IS
  'Terminal home S4K-OWNED panel: owned events within p_days from latest_event_metrics + events, independent of the movers index; metrics_as_of = TEvo capture time (frozen while listing polls are paused). @s4kent.com only. Mig 20261006190000 (supersedes unapplied 20260620000000).';

-- 1b. Discovery gaps read path (unchanged from the unapplied 20260620010000) ----
CREATE OR REPLACE FUNCTION public.get_discovery_gaps(
  p_gap_type  text     DEFAULT NULL,
  p_limit     int      DEFAULT 200,
  p_event_ids bigint[] DEFAULT NULL
) RETURNS TABLE (
  id           bigint,
  event_id     bigint,
  gap_type     text,
  detail       text,
  signal_score numeric,
  detected_at  timestamptz,
  event_name   text,
  occurs_at    text
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT
    g.id, g.event_id, g.gap_type, g.detail, g.signal_score, g.detected_at,
    COALESCE(sgc.sg_event_name, e.name),
    COALESCE(to_char(sgc.sg_datetime_utc, 'YYYY-MM-DD"T"HH24:MI:SS'), e.occurs_at_local)
  FROM public.discovery_gap_alerts g
  LEFT JOIN LATERAL (
    SELECT s.sg_event_name, s.sg_datetime_utc
    FROM   public.sg_events_canonical s
    WHERE  s.tevo_event_id = g.event_id
    ORDER BY s.sg_datetime_utc DESC NULLS LAST
    LIMIT 1
  ) sgc ON true
  LEFT JOIN public.events e ON e.id = g.event_id
  WHERE g.resolved_at IS NULL
    AND (p_gap_type  IS NULL OR g.gap_type = p_gap_type)
    AND (p_event_ids IS NULL OR g.event_id = ANY(p_event_ids))
  ORDER BY g.signal_score DESC NULLS LAST
  LIMIT GREATEST(p_limit, 1);
END;
$function$;
REVOKE ALL ON FUNCTION public.get_discovery_gaps(text, int, bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_discovery_gaps(text, int, bigint[]) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_discovery_gaps(text, int, bigint[]) IS
  'Terminal Discovery gaps panel + home movers gap chips: active discovery_gap_alerts enriched with event name/date. @s4kent.com only. Mig 20261006190000 (supersedes unapplied 20260620010000).';

-- 2. Gap detector: stale-EVO guard + signal clamp ----------------------------
CREATE OR REPLACE FUNCTION public.evo_sg_discovery_gaps()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count     int := 0;
  -- EVO absence only means something while EVO is being collected (~55k
  -- event_metrics rows/day normally; 31/day while listing polls are paused).
  v_evo_fresh boolean := (SELECT count(*) FROM (
                            SELECT 1 FROM public.event_metrics
                            WHERE captured_at > now() - interval '48 hours'
                            LIMIT 1000) x) >= 1000;
BEGIN
  INSERT INTO public.discovery_gap_alerts (event_id, gap_type, detail, signal_score)

  -- sg_no_evo: SG tracking event (fill > 20%) but no EVO coverage
  SELECT * FROM (
    SELECT DISTINCT ON (sgm.tevo_event_id)
           sgm.tevo_event_id                                                                  AS event_id,
           'sg_no_evo'::text                                                                  AS gap_type,
           'SG fill_rate=' || round((sgm.fill_rate*100)::numeric, 1) || '%, no EVO coverage'  AS detail,
           least(sgm.fill_rate * 100, 9999.9999)::numeric(8,4)                                AS signal_score
    FROM public.seatgeek_event_metrics sgm
    WHERE v_evo_fresh
      AND sgm.captured_at > now() - interval '48 hours'
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

  -- td_sh_no_evo: SH listings but no EVO
  SELECT DISTINCT sgc.tevo_event_id, 'td_sh_no_evo'::text,
         'SH has listings, no EVO coverage'::text, 10.0::numeric(8,4)
  FROM public.ticketsdata_listings_snapshots tds
  JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = tds.event_id
  JOIN public.aq_event_map aem           ON aem.aq_short_event_id = tdx.aq_short_event_id
  JOIN public.sg_events_canonical sgc    ON sgc.sg_event_id = aem.sg_event_id
  WHERE v_evo_fresh
    AND tds.platform = 'SH'
    AND tds.captured_at > now() - interval '48 hours'
    AND sgc.tevo_event_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.event_metrics em
      WHERE em.event_id = sgc.tevo_event_id
        AND em.captured_at > now() - interval '48 hours'
    )

  UNION ALL

  -- td_gt_no_evo: GT listings but no EVO
  SELECT DISTINCT sgc.tevo_event_id, 'td_gt_no_evo'::text,
         'GT has listings, no EVO coverage'::text, 10.0::numeric(8,4)
  FROM public.ticketsdata_listings_snapshots tds
  JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = tds.event_id
  JOIN public.aq_event_map aem           ON aem.aq_short_event_id = tdx.aq_short_event_id
  JOIN public.sg_events_canonical sgc    ON sgc.sg_event_id = aem.sg_event_id
  WHERE v_evo_fresh
    AND tds.platform = 'GT'
    AND tds.captured_at > now() - interval '48 hours'
    AND sgc.tevo_event_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.event_metrics em
      WHERE em.event_id = sgc.tevo_event_id
        AND em.captured_at > now() - interval '48 hours'
    )

  UNION ALL

  -- td_sh_no_gt: SH covered, no GT (TicketsData only — no EVO dependency)
  SELECT DISTINCT sh_e.tevo_event_id, 'td_sh_no_gt'::text,
         'SH has listings but no GT coverage'::text, 5.0::numeric(8,4)
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

  -- evo_no_sg: we own tickets (fresh EVO), SG not tracking
  SELECT * FROM (
    SELECT DISTINCT ON (em.event_id)
           em.event_id, 'evo_no_sg'::text,
           'EVO owned_tickets=' || em.owned_tickets_count || ', SG not tracking',
           least(em.owned_tickets_count, 9999)::numeric(8,4)
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

  -- value_gap_large: SG market > fresh EVO price * 1.20 (signal clamped:
  -- +36,952% seen 2026-10 on a $1 EVO median — an artifact, not a bigger gap)
  SELECT em.event_id, 'value_gap_large'::text,
         'SG median $' || round(sgm.listings_all_median, 0)
           || ' vs EVO $' || round(em.retail_median, 0)
           || ' (+' || round((sgm.listings_all_median - em.retail_median) / em.retail_median * 100, 0) || '%%)',
         least((sgm.listings_all_median - em.retail_median) / em.retail_median * 100, 9999.9999)::numeric(8,4)
  FROM (
    SELECT DISTINCT ON (event_id) event_id, retail_median
    FROM public.event_metrics
    WHERE captured_at > now() - interval '48 hours'
    ORDER BY event_id, captured_at DESC
  ) em
  JOIN (
    SELECT DISTINCT ON (tevo_event_id) tevo_event_id, listings_all_median
    FROM public.seatgeek_event_metrics ORDER BY tevo_event_id, captured_at DESC
  ) sgm ON sgm.tevo_event_id = em.event_id
  WHERE v_evo_fresh
    AND em.retail_median > 0
    AND sgm.listings_all_median > em.retail_median * 1.20

  UNION ALL

  -- fill_rate_spike: SG fill rate jumped > 15pp over last 12h, event has owned tickets
  SELECT fs.tevo_event_id, 'fill_rate_spike'::text,
         'SG fill_rate jumped ' || round(((fs.fill_recent - fs.fill_prior)*100)::numeric, 1)
           || 'pp (prior: ' || round((fs.fill_prior*100)::numeric, 0)
           || '%% -> recent: ' || round((fs.fill_recent*100)::numeric, 0) || '%%)',
         least((fs.fill_recent - fs.fill_prior) * 100, 9999.9999)::numeric(8,4)
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
    format('evo_sg_discovery_gaps: %s gap rows upserted%s', v_count,
           CASE WHEN v_evo_fresh THEN '' ELSE ' (EVO metrics stale — EVO-dependent gap types skipped)' END));
  RETURN v_count;
END;
$function$;

-- Only cron 301 (runs as postgres) calls this SECURITY DEFINER writer; it was
-- also executable by `authenticated`, i.e. any signed-in client could trigger
-- the upsert. No FE/server caller exists (grep 2026-10-06), so close it.
REVOKE ALL ON FUNCTION public.evo_sg_discovery_gaps() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_sg_discovery_gaps() TO service_role;

-- 3. Home stats: coverage band + data-as-of for each panel -------------------
CREATE OR REPLACE FUNCTION public.get_home_stats()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_email text;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_cov jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Upcoming TEAM events (a performer is an ESPN-mapped team), ET dates.
  SELECT jsonb_build_object(
           'total', count(*),
           'd30',   count(*) FILTER (WHERE f.ed <= v_today + 30),
           'd7',    count(*) FILTER (WHERE f.ed <= v_today + 7),
           'today', count(*) FILTER (WHERE f.ed = v_today))
    INTO v_cov
  FROM (
    SELECT left(e.occurs_at_local, 10)::date AS ed
    FROM public.events e
    WHERE left(e.occurs_at_local, 10) ~ '^\d{4}-\d{2}-\d{2}$'
      AND left(e.occurs_at_local, 10) >= to_char(v_today, 'YYYY-MM-DD')
      AND coalesce(e.name, '') !~* '\m(parking|garage)\M'
      AND EXISTS (SELECT 1 FROM public.performer_espn_team_xref p
                  WHERE p.tevo_performer_id = ANY (e.performer_ids))
  ) f;

  RETURN jsonb_build_object(
    'coverage', v_cov,
    'as_of', jsonb_build_object(
      'movers_index',   (SELECT max(last_computed_at) FROM public.event_movers_index),
      'tevo_inventory', (SELECT max(captured_at) FROM public.latest_event_metrics WHERE owned_tickets_count > 0),
      'market_chart',   (SELECT max(chart_date) FROM public.sg_market_chart),
      'discovery_gaps', (SELECT max(detected_at) FROM public.discovery_gap_alerts)
    ),
    'generated_at', now()
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.get_home_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_home_stats() TO authenticated, service_role;
COMMENT ON FUNCTION public.get_home_stats() IS
  'Terminal home: COVERAGE band counts (upcoming team events, ET) + data-as-of per panel (movers index, TEvo inventory, market chart, discovery gaps) so frozen feeds are labelled. @s4kent.com only. Mig 20261006190000.';

-- 4. Top 50 — market selling, we're not in: also exclude events we sell -------
CREATE OR REPLACE FUNCTION public.get_sg_market_chart(p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_email text; v_date date; v_out jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT max(chart_date) INTO v_date FROM public.sg_market_chart;
  IF v_date IS NULL THEN
    RETURN jsonb_build_object('chart_date', NULL, 'total', 0, 'excluded_crm', 0, 'rows', '[]'::jsonb);
  END IF;

  WITH chart AS (
    SELECT m.* FROM public.sg_market_chart m WHERE m.chart_date = v_date
  ),
  -- "We're in" = a non-cancelled CRM order on the event in the last 30 days
  -- (SeatGeek CRM rows carry no purchase_date -> last seen instead). Two
  -- EXISTS probes (tevo id, sg id) so each uses its s4kcs_orders index.
  sold AS (
    SELECT c.sg_event_id
    FROM chart c
    WHERE EXISTS (
            SELECT 1 FROM public.s4kcs_orders o
            LEFT JOIN public.order_status_xref x ON x.source = 's4kcs' AND x.source_status = o.order_status
            WHERE c.tevo_event_id IS NOT NULL AND o.tevo_event_id = c.tevo_event_id
              AND coalesce(o.purchase_date::timestamptz, o.last_seen_at) >= now() - interval '30 days'
              AND coalesce(x.canonical_status, 'accepted') NOT IN ('cancelled', 'rejected'))
       OR EXISTS (
            SELECT 1 FROM public.s4kcs_orders o
            LEFT JOIN public.order_status_xref x ON x.source = 's4kcs' AND x.source_status = o.order_status
            WHERE o.sg_event_id = c.sg_event_id
              AND coalesce(o.purchase_date::timestamptz, o.last_seen_at) >= now() - interval '30 days'
              AND coalesce(x.canonical_status, 'accepted') NOT IN ('cancelled', 'rejected'))
  ),
  kept AS (
    SELECT c.*, row_number() OVER (ORDER BY c.rank)::int AS new_rank
    FROM chart c
    WHERE NOT EXISTS (SELECT 1 FROM sold s WHERE s.sg_event_id = c.sg_event_id)
  ),
  page AS (
    SELECT * FROM kept
    ORDER BY new_rank
    OFFSET greatest(coalesce(p_offset, 0), 0)
    LIMIT least(coalesce(p_limit, 50), 500)
  )
  SELECT jsonb_build_object(
    'chart_date',   v_date,
    'total',        (SELECT count(*) FROM kept),
    'excluded_crm', (SELECT count(*) FROM sold),
    'rows', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'rank', m.new_rank, 'chart_rank', m.rank, 'prev_rank', m.prev_rank,
        'rank_delta', CASE WHEN m.prev_rank IS NULL THEN NULL ELSE m.prev_rank - m.rank END,
        'is_new', (m.prev_rank IS NULL), 'peak_rank', m.peak_rank, 'days_on_chart', m.days_on_chart,
        'sg_event_id', m.sg_event_id, 'tevo_event_id', m.tevo_event_id,
        'sg_event_name', m.sg_event_name, 'sg_venue_name', m.sg_venue_name,
        'sg_datetime_utc', to_char(m.sg_datetime_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'ma7_volume', m.ma7_volume, 'ma7_median', m.ma7_median, 'ma7_gross', m.ma7_gross,
        'sd_ma7_gross', m.sd_ma7_gross, 'sd_sales_7d', m.sd_sales_7d,
        'sd_ma7_volume', m.sd_ma7_volume, 'sd_ma7_median', m.sd_ma7_median,
        'ma7_volume_blended', m.ma7_volume_blended, 'ma7_median_blended', m.ma7_median_blended,
        'ma7_gross_blended', m.ma7_gross_blended,
        'pct_volume', m.pct_volume, 'pct_median', m.pct_median,
        'chart_score', m.chart_score, 'blended_score', m.blended_score, 'score_basis', m.score_basis,
        'platform_breadth', m.platform_breadth, 'market_median_all', m.market_median_all,
        'primary_sources', m.primary_sources, 'days_with_sales', m.days_with_sales,
        'evo_getin', lem.getin_price, 'evo_median', lem.retail_median, 'evo_tickets', lem.tickets_count,
        'sh_median', shs.td_sh_median, 'sh_listings', shs.td_sh_listings
      ) ORDER BY m.new_rank)
      FROM page m
      LEFT JOIN public.latest_event_metrics lem ON lem.event_id = m.tevo_event_id
      LEFT JOIN LATERAL (
        SELECT s.td_sh_median, s.td_sh_listings
        FROM public.event_listing_snapshot_daily s
        WHERE s.event_id = m.tevo_event_id AND s.td_sh_median IS NOT NULL
        ORDER BY s.snapshot_date DESC,
                 CASE s.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC
        LIMIT 1
      ) shs ON true
    ), '[]'::jsonb)
  ) INTO v_out;

  RETURN v_out;
END $function$;
REVOKE ALL ON FUNCTION public.get_sg_market_chart(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_sg_market_chart(integer, integer) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_sg_market_chart(integer, integer) IS
  'Terminal home TOP 50 — MARKET SELLING, WE''RE NOT IN: latest sg_market_chart minus events with our CRM orders (s4kcs_orders, tevo or sg id) in the last 30 days, renumbered (rank) with the stored rank as chart_rank; excluded_crm = how many were dropped. @s4kent.com only. Mig 20261006190000.';
