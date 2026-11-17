-- Migration 20261113070000 · level:secondary-sales · lane:D0 · writes:evo_venue_tax,evo_venue_tax_refresh,cron:evo_venue_tax_refresh_hourly,sub_finder_config,sub_finder_evo_tax_pct,sub_finder_match · reads:evo_orders,evo_order_items,events · pre:20261113010000
--
-- SUB FINDER: expected EVO sales tax, per venue, in every cost / profit / gate calculation.
--
-- Operator 2026-11-13: "Track venues and their tax percent and add that to calculation when
-- computing." EVO charges sales tax on some purchases, on top of the listed price (3 of our
-- first 19 manual sub buys: 5.5%, 5.5%, 9.31%), which a listing does not show beforehand.
--
--   evo_venue_tax   one row per venue: the tax percent to expect on an EVO buy there.
--                   'observed' rows are learned from our own EVO purchases (evo_orders where
--                   we are the buyer and tax > 0: the HIGHEST tax / subtotal seen at the venue)
--                   and refreshed hourly. A 'manual' row is the operator's and is never
--                   overwritten. A venue with no row uses sub_finder_config.evo_tax_default_pct (0).
--   sub_finder_match now prices an EVO cover as listed price x (1 + tax%): `total`, `profit`,
--                   the gate and the 200% rule all use it, so the automatic buy (breakeven or
--                   better) is breakeven AFTER the expected tax. The cover also shows
--                   `subtotal`, `tax_pct` and `tax_est`. `price_ea` stays the listed price (it is
--                   the ceiling the buy path re-checks). Other markets are priced as listed.
--
-- The tax is not charged on every order at a venue (same game, some taxed, some not — it seems
-- to depend on the seller), so this assumes the tax applies: a cover may cost less than shown,
-- not more, unless a higher rate turns up. Only venues where we have been taxed are known:
-- the table starts small and grows with our purchases, or with manual rows.
--
-- rollback: re-apply sub_finder_match from 20261113010000; SELECT cron.unschedule('evo_venue_tax_refresh_hourly');
--           DROP FUNCTION public.sub_finder_evo_tax_pct(text, bigint), public.evo_venue_tax_refresh();
--           DROP TABLE public.evo_venue_tax; ALTER TABLE public.sub_finder_config DROP COLUMN evo_tax_default_pct;

CREATE TABLE IF NOT EXISTS public.evo_venue_tax (
  venue_id       bigint PRIMARY KEY,                 -- TEvo venue id (events.venue_id)
  venue_name     text,
  tax_pct        numeric NOT NULL CHECK (tax_pct >= 0 AND tax_pct <= 30),
  source         text    NOT NULL DEFAULT 'observed' CHECK (source IN ('observed', 'manual')),
  orders_seen    integer NOT NULL DEFAULT 0,         -- our EVO purchases at this venue
  orders_taxed   integer NOT NULL DEFAULT 0,
  last_taxed_at  timestamptz,
  note           text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.evo_venue_tax ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.evo_venue_tax FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.evo_venue_tax IS
  'Sales tax percent to expect on an EVO purchase at a venue (20261113070000). observed = highest tax/subtotal '
  'on our own EVO purchases there, refreshed hourly; manual = operator-set, never overwritten.';

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS evo_tax_default_pct numeric NOT NULL DEFAULT 0;   -- for a venue with no row

-- Learn / update the observed rows from our own EVO purchases. Returns rows written.
CREATE OR REPLACE FUNCTION public.evo_venue_tax_refresh()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  v_n integer;
BEGIN
  INSERT INTO public.evo_venue_tax AS t (venue_id, venue_name, tax_pct, source, orders_seen, orders_taxed, last_taxed_at)
  SELECT p.venue_id, max(p.venue_name),
         max(round(100.0 * p.tax / p.subtotal, 2)) FILTER (WHERE p.tax > 0),
         'observed', count(*), count(*) FILTER (WHERE p.tax > 0),
         max(p.evo_created_at) FILTER (WHERE p.tax > 0)
  FROM (SELECT o.tax, o.subtotal, o.evo_created_at, i.venue_id, i.venue_name
        FROM public.evo_orders o
        JOIN LATERAL (SELECT x.venue_id, x.venue_name FROM public.evo_order_items x
                       WHERE x.evo_order_id = o.evo_order_id AND x.venue_id IS NOT NULL LIMIT 1) i ON true
        WHERE o.buyer_brokerage_id = 1768 AND o.seller_brokerage_id IS DISTINCT FROM 1768   -- our purchases
          AND o.subtotal > 0 AND o.tax >= 0 AND o.tax <= 0.3 * o.subtotal) p
  GROUP BY p.venue_id
  HAVING count(*) FILTER (WHERE p.tax > 0) > 0
  ON CONFLICT (venue_id) DO UPDATE
    SET venue_name = excluded.venue_name, tax_pct = excluded.tax_pct, orders_seen = excluded.orders_seen,
        orders_taxed = excluded.orders_taxed, last_taxed_at = excluded.last_taxed_at, updated_at = now()
  WHERE t.source = 'observed'
    AND (t.tax_pct, t.orders_seen, t.orders_taxed) IS DISTINCT FROM (excluded.tax_pct, excluded.orders_seen, excluded.orders_taxed);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$$;

-- The tax percent to add to a cover: the venue's rate for an EVO listing, 0 on any other market.
CREATE OR REPLACE FUNCTION public.sub_finder_evo_tax_pct(p_market text, p_venue_id bigint)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN p_market = 'evo'
              THEN coalesce((SELECT t.tax_pct FROM public.evo_venue_tax t WHERE t.venue_id = p_venue_id),
                            (SELECT c.evo_tax_default_pct FROM public.sub_finder_config c), 0)
              ELSE 0 END;
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_match(p_job_id uuid, p_td_answered boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  v_back integer := (SELECT rows_back FROM public.sub_finder_config);
  v_n    integer;
BEGIN
  WITH o AS (
    SELECT so.*, e.primary_performer_id AS perf, e.venue_id AS ven
    FROM public.sub_finder_order so
    LEFT JOIN public.events e ON e.id = so.tevo_event_id
    WHERE so.job_id = p_job_id
      AND ((so.state = 'pending' AND (NOT p_td_answered OR so.td_state IN ('searched', 'failed')))
           OR (so.rematch AND so.state IN ('cover', 'no_cover')))
  ), same_sec AS (
    -- the order's own section: same or better row, or up to rows_back behind
    SELECT o.job_id, o.idx, o.qty, o.sold_ea, o.perf, o.ven, o.section AS o_section, o.seat_row AS o_row,
           l.*, false AS moved,
           CASE WHEN o.qty = ANY (l.sp) OR l.quantity = o.qty THEN o.qty
                WHEN l.quantity = o.qty + 1 THEN o.qty + 1 END AS buy_qty,
           public.seat_row_rank(l.seat_row) - public.seat_row_rank(o.seat_row) AS row_delta
    FROM o JOIN _sf_l l ON l.eid = o.tevo_event_id
     AND public.seat_section_norm(l.section) = public.seat_section_norm(o.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(o.seat_row)
     AND public.seat_row_rank(l.seat_row) <= public.seat_row_rank(o.seat_row) + v_back
    WHERE l.px > 0 AND l.quantity > 0
  ), strict_ok AS (
    -- orders that HAVE "a buy in that same section, same row or better" (gate 1 or 2)
    SELECT DISTINCT s.job_id, s.idx FROM same_sec s
    WHERE s.buy_qty IS NOT NULL AND s.row_delta <= 0
      AND (s.sold_ea IS NULL
           OR s.buy_qty * s.px * (1 + public.sub_finder_evo_tax_pct(s.market, s.ven) / 100.0) <= 2 * s.sold_ea * s.qty)
  ), need AS (
    -- the rest: only these are widened to the zone rules
    SELECT o.* FROM o WHERE NOT EXISTS (SELECT 1 FROM strict_ok k WHERE k.job_id = o.job_id AND k.idx = o.idx)
  ), oz AS (
    SELECT n.job_id, n.idx, public.n2s_zone_of(n.perf, n.ven, n.section, n.seat_row) AS z FROM need n
  ), lz AS (
    -- the zone of each distinct listing seat, for the events of the orders being widened
    SELECT d.eid, d.section, d.seat_row, public.n2s_zone_of(e.primary_performer_id, e.venue_id, d.section, d.seat_row) AS z
    FROM (SELECT DISTINCT l.eid, l.section, l.seat_row FROM _sf_l l
          WHERE l.eid IN (SELECT tevo_event_id FROM need)) d
    JOIN public.events e ON e.id = d.eid
  ), zone_sec AS (
    -- another section in the SAME curated zone
    SELECT n.job_id, n.idx, n.qty, n.sold_ea, n.perf, n.ven, n.section AS o_section, n.seat_row AS o_row,
           l.*, true AS moved,
           CASE WHEN n.qty = ANY (l.sp) OR l.quantity = n.qty THEN n.qty
                WHEN l.quantity = n.qty + 1 THEN n.qty + 1 END AS buy_qty,
           public.seat_row_rank(l.seat_row) - public.seat_row_rank(n.seat_row) AS row_delta
    FROM need n
    JOIN oz ON oz.job_id = n.job_id AND oz.idx = n.idx AND oz.z IS NOT NULL
    JOIN lz ON lz.eid = n.tevo_event_id AND lz.z = oz.z
    JOIN _sf_l l ON l.eid = lz.eid AND l.section = lz.section AND l.seat_row = lz.seat_row
     AND public.seat_section_norm(l.section) <> public.seat_section_norm(n.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(n.seat_row)
     AND public.seat_row_rank(l.seat_row) <= public.seat_row_rank(n.seat_row) + v_back
    WHERE l.px > 0 AND l.quantity > 0
  ), cand AS (
    SELECT * FROM same_sec UNION ALL SELECT * FROM zone_sec
  ), taxed AS (
    -- what the buy is expected to cost: the listed price plus the sales tax EVO has charged us
    -- at this venue before (evo_venue_tax). Other markets: as listed.
    SELECT c.*, public.sub_finder_evo_tax_pct(c.market, c.ven) AS tax_pct,
           round(c.buy_qty * c.px * (1 + public.sub_finder_evo_tax_pct(c.market, c.ven) / 100.0), 2) AS total
    FROM cand c WHERE c.buy_qty IS NOT NULL
  ), priced AS (
    SELECT c.*,
           CASE WHEN c.sold_ea IS NOT NULL THEN round(c.sold_ea * c.qty - c.total, 2) END AS profit,
           (c.sold_ea IS NOT NULL AND c.sold_ea * c.qty - c.total > 0) AS profitable,
           (c.sold_ea IS NULL OR c.total <= 2 * c.sold_ea * c.qty) AS within_200,
           EXISTS (SELECT 1 FROM strict_ok k WHERE k.job_id = c.job_id AND k.idx = c.idx) AS has_strict,
           (SELECT oz.z FROM oz WHERE oz.job_id = c.job_id AND oz.idx = c.idx) AS o_zone,
           (SELECT lz.z FROM lz WHERE lz.eid = c.eid AND lz.section = c.section AND lz.seat_row = c.seat_row) AS l_zone
    FROM taxed c
  ), gated AS (
    SELECT p.*,
           CASE
             WHEN NOT p.within_200 THEN NULL
             WHEN NOT p.moved AND p.row_delta <= 0 THEN CASE WHEN p.profitable THEN 1 ELSE 2 END
             WHEN p.has_strict THEN NULL                      -- not widened: gates 3-6 do not apply
             WHEN p.moved AND p.row_delta <= 0 THEN CASE WHEN p.profitable THEN 3 ELSE 4 END
             -- rows back: the same zone, or no zone on either side (then it is flagged)
             WHEN p.row_delta > 0 AND (p.moved OR p.o_zone IS NOT DISTINCT FROM p.l_zone)
               THEN CASE WHEN p.profitable THEN 5 ELSE 6 END
           END AS gate
    FROM priced p
  ), kept_rows AS (
    -- what is shown: any gated cover, plus a same-section same-or-better cover above 200%
    SELECT g.* FROM gated g
    WHERE g.gate IS NOT NULL OR (NOT g.moved AND g.row_delta <= 0)
  ), ranked AS (
    SELECT k.*, row_number() OVER (PARTITION BY k.job_id, k.idx, k.market
                                   ORDER BY k.gate NULLS LAST, k.total, k.lid) AS rn
    FROM kept_rows k
  ), fresh AS (
    SELECT job_id, idx, jsonb_build_object(
             'market', market, 'source', via, 'listing_id', lid, 'section', section, 'row', seat_row,
             'listing_qty', quantity, 'buy_qty', buy_qty, 'spare', buy_qty - qty,
             'price_ea', px, 'subtotal', round(buy_qty * px, 2), 'tax_pct', tax_pct,
             'tax_est', round(total - buy_qty * px, 2), 'total', round(total, 2),   -- total includes the expected tax
             'profit', profit, 'price_note', price_note,
             'row_relation', CASE WHEN row_delta < 0 THEN 'better' WHEN row_delta = 0 THEN 'same' ELSE 'back' END,
             'gate', gate,
             'label', CASE gate WHEN 1 THEN 'Index' WHEN 2 THEN 'S4KTrading' WHEN 3 THEN 'Index offer subs'
                                WHEN 4 THEN 'offer subs s4ktrading' WHEN 5 THEN 'Index Down offer subs'
                                WHEN 6 THEN 'Down offer subs S4KTrading' ELSE 'over 200% of sale' END
                      || CASE WHEN gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL THEN ' zone unverified' ELSE '' END
                      || CASE WHEN view_note = 'obstructed' THEN ' obstructed view' ELSE '' END
                      || CASE WHEN qty = 1 THEN ' single ticket' ELSE '' END
                      || CASE WHEN buy_qty > qty THEN ' repost single' ELSE '' END
                      || CASE WHEN sold_ea IS NULL AND gate IS NOT NULL THEN ' no sale price' ELSE '' END,
             'needs_buyer_ok', coalesce(gate >= 3, false),
             'zone', l_zone, 'view', view_note,
             'link', link, 'buyable', market = 'evo', 'listing_seen_at', pulled_at) AS cover
    FROM ranked WHERE rn <= 3
  ), kept AS (
    -- rematch only: what a market found before, when that market has nothing in _sf_l now
    SELECT o.job_id, o.idx, x AS cover
    FROM o, jsonb_array_elements(o.covers) x
    WHERE o.rematch AND o.state IN ('cover', 'no_cover')
      AND NOT EXISTS (SELECT 1 FROM _sf_l l WHERE l.eid = o.tevo_event_id AND l.market = x->>'market')
  ), per_order AS (
    SELECT job_id, idx,
           jsonb_agg(cover ORDER BY (cover->>'gate')::int NULLS LAST, (cover->>'total')::numeric,
                                    cover->>'listing_id') AS covers
    FROM (SELECT * FROM fresh UNION ALL SELECT * FROM kept) u GROUP BY job_id, idx
  )
  UPDATE public.sub_finder_order t
     SET covers = coalesce(p.covers, '[]'::jsonb),
         best   = p.covers -> 0,                    -- lowest gate first, then cheapest
         state  = CASE WHEN p.covers IS NULL THEN 'no_cover' ELSE 'cover' END,
         action = CASE
                    WHEN t.buy_id IS NOT NULL THEN t.action
                    WHEN p.covers IS NULL THEN 'none'
                    WHEN (p.covers -> 0 ->> 'gate')::int IN (1, 2) THEN 'buy_manually'
                    WHEN (p.covers -> 0 ->> 'gate')::int >= 3 THEN 'offer'
                    ELSE 'review' END,
         updated_at = CASE WHEN o.state = 'pending'
                             OR public.sub_finder_covers_key(p.covers) IS DISTINCT FROM public.sub_finder_covers_key(o.covers)
                           THEN now() ELSE t.updated_at END,
         refreshed_at  = CASE WHEN o.state = 'pending' THEN t.refreshed_at ELSE now() END,
         refresh_count = t.refresh_count + CASE WHEN o.state = 'pending' THEN 0 ELSE 1 END,
         rematch = false
    FROM o LEFT JOIN per_order p ON p.job_id = o.job_id AND p.idx = o.idx
   WHERE t.job_id = o.job_id AND t.idx = o.idx;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM public.sub_finder_autobuy(p_job_id);
  RETURN v_n;
END
$$;

REVOKE ALL ON FUNCTION public.evo_venue_tax_refresh() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_evo_tax_pct(text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_venue_tax_refresh() TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_evo_tax_pct(text, bigint) TO service_role;

SELECT public.evo_venue_tax_refresh();
SELECT cron.schedule('evo_venue_tax_refresh_hourly', '17 * * * *', $cron$SELECT public.evo_venue_tax_refresh();$cron$);
