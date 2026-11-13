-- Migration 20261023055000 · level:feature · lane:D0 (MCP) + A1 (read RPC) · writes:mcp_auto_pricer_setup()(new) · reads:seatgeek_listings_snapshots,listings_snapshots,gotickets_listings_snapshots,event_metrics,seatgeek_event_metrics,sg_events_canonical,v_s4kcs_orders,events · pre:20261023053000
--
-- ============================================================================
-- Migration 20261023055000 — mcp_auto_pricer_setup: Auto Pricer inputs for one event,
--   SeatGeek anchor checked against EVO and GoTickets
--
-- Operator 2026-10-23: the Auto Pricer Field Guide (docs/auto_pricer_field_guide.md)
-- "should tell you how to use it … plug against other listing sources". Per seating level
-- (section hundreds: 100s, 200s, …; non-numeric sections = 'other'):
--   sources   per marketplace, OUR listings excluded from the market: listing count, the
--             quantity curve q2..q6p (cheapest listing with ≥ n tickets — SG2..SG6+ on
--             SeatGeek), p25 / median / p75, and our own count + median.
--   coverage  raw listings seen vs the source's full-book count (event_metrics /
--             seatgeek_event_metrics): EVO/GT/SG raw tables are delta-stored, so "seen in
--             the window" undercounts unchanged listings and can include a few sold ones.
--   row_surge pooled cross-source p25 per row bucket vs the back bucket → the guide's
--             Surge % = ((T ÷ B) − 1) × 100. Single-letter rows rank A=1, B=2, …
--   our_sales CRM sales in the last 7 days (v_s4kcs_orders, rejected/cancelled excluded).
--   suggest   engine (smart when SG5/SG6+ sits > 20 % over SG2, else dumb), the SG2 anchor,
--             a floor at the cheapest pair across sources, top of range from the EVO/GT
--             p75, and our median vs each market's median.
-- Prices: SeatGeek and GoTickets all-in; EVO retail_price (fee basis differs).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.mcp_auto_pricer_setup(p_event_id bigint, p_hours integer DEFAULT 48)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
SET statement_timeout = '25s'
AS $$
DECLARE
  v_since timestamptz := now() - make_interval(hours => LEAST(GREATEST(coalesce(p_hours, 48), 3), 168));
  v_sg    bigint;
  v_ev    record;
  v_out   jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: mcp_auto_pricer_setup is service-only' USING ERRCODE='42501';
  END IF;
  SELECT e.id, e.name, e.occurs_at_local, e.venue_name INTO v_ev FROM public.events e WHERE e.id = p_event_id;
  IF v_ev.id IS NULL THEN
    RETURN jsonb_build_object('error', format('event %s not found', p_event_id));
  END IF;
  SELECT min(c.sg_event_id) INTO v_sg FROM public.sg_events_canonical c WHERE c.tevo_event_id = p_event_id;

  WITH raw AS (
    SELECT * FROM (
      SELECT DISTINCT ON (s.sglid) 'sg'::text AS src, s.section, s.row, s.quantity AS q,
             coalesce(s.retail_price_all_in, s.broadcast_price) AS p, coalesce(s.is_broker_owned, false) AS ours
        FROM public.seatgeek_listings_snapshots s
       WHERE v_sg IS NOT NULL AND s.sg_event_id = v_sg AND s.captured_at > v_since
       ORDER BY s.sglid, s.captured_at DESC) a
    UNION ALL
    SELECT * FROM (
      SELECT DISTINCT ON (l.tevo_ticket_group_id) 'evo', l.section, l.row, l.quantity,
             l.retail_price, coalesce(l.is_owned, false)
        FROM public.listings_snapshots l
       WHERE l.event_id = p_event_id AND l.captured_at > v_since AND NOT coalesce(l.is_ancillary, false)
       ORDER BY l.tevo_ticket_group_id, l.captured_at DESC) b
    UNION ALL
    SELECT * FROM (
      SELECT DISTINCT ON (g.gt_listing_id) 'gt', g.section, g.row, g.quantity, g.all_in_price, false
        FROM public.gotickets_listings_snapshots g
       WHERE g.tevo_event_id = p_event_id AND g.captured_at > v_since
       ORDER BY g.gt_listing_id, g.captured_at DESC) c
  ),
  l AS (
    SELECT src, q, p, ours,
           CASE WHEN sec ~ '^\d+$' AND sec::int >= 100 THEN (sec::int / 100 * 100)::text || 's' ELSE 'other' END AS lvl,
           CASE WHEN row ~ '^\d+$' THEN row::int
                WHEN upper(row) ~ '^[A-Z]$' THEN ascii(upper(row)) - 64 END AS r
      FROM (SELECT src, q, p, ours, row,
                   btrim(regexp_replace(coalesce(section, ''), '^(section|sec)\s*', '', 'i')) AS sec
              FROM raw) x
     WHERE p > 0 AND q > 0
  ),
  src AS (
    SELECT lvl, src,
           jsonb_build_object(
             'market_listings', count(*) FILTER (WHERE NOT ours),
             'q2',  min(p) FILTER (WHERE q >= 2 AND NOT ours), 'q3', min(p) FILTER (WHERE q >= 3 AND NOT ours),
             'q4',  min(p) FILTER (WHERE q >= 4 AND NOT ours), 'q5', min(p) FILTER (WHERE q >= 5 AND NOT ours),
             'q6p', min(p) FILTER (WHERE q >= 6 AND NOT ours),
             'p25', round((percentile_cont(0.25) WITHIN GROUP (ORDER BY p) FILTER (WHERE NOT ours))::numeric, 2),
             'median', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY p) FILTER (WHERE NOT ours))::numeric, 2),
             'p75', round((percentile_cont(0.75) WITHIN GROUP (ORDER BY p) FILTER (WHERE NOT ours))::numeric, 2),
             'our_listings', count(*) FILTER (WHERE ours),
             'our_median', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY p) FILTER (WHERE ours))::numeric, 2)
           ) AS j,
           min(p) FILTER (WHERE q >= 2 AND NOT ours) AS q2,
           coalesce(min(p) FILTER (WHERE q >= 6 AND NOT ours), min(p) FILTER (WHERE q >= 5 AND NOT ours)) AS q5p,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY p) FILTER (WHERE NOT ours) AS med,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY p) FILTER (WHERE NOT ours) AS p75,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY p) FILTER (WHERE ours) AS our_med
      FROM l GROUP BY lvl, src
  ),
  rows_b AS (
    SELECT lvl, CASE WHEN r <= 3 THEN 1 WHEN r <= 7 THEN 2 WHEN r <= 12 THEN 3 WHEN r <= 18 THEN 4 ELSE 5 END AS b,
           count(*) AS n, percentile_cont(0.25) WITHIN GROUP (ORDER BY p) AS p25
      FROM l WHERE NOT ours AND r IS NOT NULL
     GROUP BY 1, 2 HAVING count(*) >= 5
  ),
  surge AS (
    SELECT rb.lvl,
           jsonb_agg(jsonb_build_object(
             'rows', (ARRAY['1-3','4-7','8-12','13-18','19+'])[rb.b], 'listings', rb.n,
             'p25', round(rb.p25::numeric, 2),
             'surge_pct', round(((rb.p25 / nullif(bk.p25, 0)) - 1)::numeric * 100, 0)) ORDER BY rb.b) AS j
      FROM rows_b rb
      JOIN LATERAL (SELECT x.p25 FROM rows_b x WHERE x.lvl = rb.lvl ORDER BY x.b DESC LIMIT 1) bk ON true
     GROUP BY rb.lvl
  ),
  sales AS (
    SELECT CASE WHEN sec ~ '^\d+$' AND sec::int >= 100 THEN (sec::int / 100 * 100)::text || 's' ELSE 'other' END AS lvl,
           sum(quantity) AS tix, round(sum(price_per_ticket * quantity) / nullif(sum(quantity), 0), 2) AS avg_per_ticket
      FROM (SELECT o.quantity, o.price_per_ticket,
                   btrim(regexp_replace(coalesce(o.section, ''), '^(section|sec)\s*', '', 'i')) AS sec
              FROM public.v_s4kcs_orders o
             WHERE o.s4k_order_id IN (SELECT s.s4k_order_id FROM public.s4kcs_orders s WHERE s.tevo_event_id = p_event_id)
               AND o.tevo_event_id = p_event_id
               AND o.order_status !~* '(reject|cancel)'
               AND o.purchase_date >= current_date - 7
               AND o.price_per_ticket > 0) o
     GROUP BY 1
  ),
  lv AS (
    SELECT s.lvl,
           max(s.q2) FILTER (WHERE s.src = 'sg') AS sg2,
           max(s.q5p) FILTER (WHERE s.src = 'sg') AS sg5p,
           min(s.q2) AS floor_q2,
           (array_agg(s.src ORDER BY s.q2) FILTER (WHERE s.q2 IS NOT NULL))[1] AS floor_src,
           max(s.p75) FILTER (WHERE s.src IN ('evo', 'gt')) AS top_p75,
           jsonb_object_agg(s.src, s.j) AS sources,
           jsonb_object_agg(s.src, round(((s.our_med / nullif(s.med, 0)) - 1)::numeric * 100, 0))
             FILTER (WHERE s.our_med IS NOT NULL) AS ours_vs_market_pct
      FROM src s GROUP BY s.lvl
  )
  SELECT jsonb_build_object(
    'event', jsonb_build_object('event_id', v_ev.id, 'name', v_ev.name, 'occurs_at_local', v_ev.occurs_at_local,
                                'venue', v_ev.venue_name, 'sg_event_id', v_sg,
                                'days_out', left(v_ev.occurs_at_local, 10)::date - current_date),
    'window_hours', extract(epoch FROM now() - v_since) / 3600,
    'coverage', jsonb_build_object(
       'evo', jsonb_build_object('seen', (SELECT count(*) FROM raw WHERE src = 'evo'),
                                 'full_book', (SELECT m.groups_count FROM public.event_metrics m
                                                WHERE m.event_id = p_event_id ORDER BY m.captured_at DESC LIMIT 1)),
       'sg',  jsonb_build_object('seen', (SELECT count(*) FROM raw WHERE src = 'sg'),
                                 'full_book', (SELECT m.listings_all_count FROM public.seatgeek_event_metrics m
                                                WHERE m.tevo_event_id = p_event_id ORDER BY m.captured_at DESC LIMIT 1)),
       'gt',  jsonb_build_object('seen', (SELECT count(*) FROM raw WHERE src = 'gt'))),
    'levels', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'level', lv.lvl,
        'sources', lv.sources,
        'row_surge', coalesce(su.j, '[]'::jsonb),
        'our_sales_7d', CASE WHEN sa.tix IS NULL THEN NULL
                             ELSE jsonb_build_object('tickets', sa.tix, 'avg_per_ticket', sa.avg_per_ticket) END,
        'suggest', jsonb_build_object(
           'engine', CASE WHEN lv.sg2 IS NULL OR lv.sg5p IS NULL THEN 'dumb'
                          WHEN lv.sg5p > lv.sg2 * 1.2 THEN 'smart' ELSE 'dumb' END,
           'pack_premium_pct', round(((lv.sg5p / nullif(lv.sg2, 0)) - 1)::numeric * 100, 0),
           'anchor_sg2', lv.sg2,
           'floor', lv.floor_q2, 'floor_source', lv.floor_src,
           'floor_vs_sg2_pct', round(((lv.floor_q2 / nullif(lv.sg2, 0)) - 1)::numeric * 100, 0),
           'top_of_range_pct', round(((lv.top_p75 / nullif(coalesce(lv.sg2, lv.floor_q2), 0)) - 1)::numeric * 100, 0),
           'ours_vs_market_median_pct', lv.ours_vs_market_pct)
      ) ORDER BY lv.lvl), '[]'::jsonb)
      FROM lv LEFT JOIN surge su ON su.lvl = lv.lvl LEFT JOIN sales sa ON sa.lvl = lv.lvl),
    'notes', jsonb_build_array(
      'Market numbers exclude our own listings (EVO is_owned, SeatGeek is_broker_owned).',
      'SeatGeek and GoTickets prices are all-in; EVO is retail_price — compare floors with the fee basis in mind.',
      'Raw listings are delta-stored: "seen" is listings observed in the window, not a live book — check coverage.',
      'engine/floor/top_of_range are starting points for a Preview Pricing test (guide §13), not live settings.'),
    'generated_at', now()
  ) INTO v_out;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.mcp_auto_pricer_setup(bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mcp_auto_pricer_setup(bigint, integer) TO service_role;

-- VERIFY: SELECT jsonb_pretty(public.mcp_auto_pricer_setup(3465614));
