-- ============================================================================
-- Migration 20260914223500 — N2S: rank TEvo asks at LANDED cost, not the bare ask
--
-- Lane:     D7 (n2s_* schema; reads A1's order_fee_schedule)
-- Touches:  W: n2s_landed_total() (new), n2s_cover_candidates() (replaced)
--           R: order_fee_schedule (source='tevo': buyer_fee_pct, fixed_fee_per_order)
-- Pre-reqs: 20260914223000 (n2s_event_live — this body carries that predicate),
-- Already applied to prod · via MCP 2026-09-14 22:38 UTC (PR #988); re-apply is a no-op
--           20260509370000 (order_fee_schedule)
--
-- ── The bug ─────────────────────────────────────────────────────────────────
-- The candidate pool prices three sources on three bases and ranks them as
-- one:  TEvo `retail_price` (a bare ask — the buyer fee is added at checkout),
-- GoTickets `all_in_price` and SeatGeek `retail_price_all_in` (what checkout
-- charges). So a TEvo listing wins every near-tie it should lose, and a TEvo
-- "profitable" cover can be a loss once the fee lands. 21 of the 37 in-window
-- hits since launch are TEvo.
--
-- ── The fix ─────────────────────────────────────────────────────────────────
-- Every place the matcher spends money — tier-3 admission, the profitable /
-- within-cap gates, the per-order ranking, sub_total and cover_cost — now uses
-- n2s_landed_total(src, ea, qty):
--     tevo    → ea * qty * (1 + buyer_fee_pct) + fixed_fee_per_order
--     others  → ea * qty                      (already all-in)
-- with the rates read from order_fee_schedule (source='tevo') at call time,
-- so the operator sets the fee with one UPDATE and never a redeploy.
--
-- ⚠ sub_ea is UNCHANGED: it stays the listing ask, because n2s_buy_intent_create
-- copies it into the TEvo `POST /orders` payload as price_per_ticket and
-- n2s_cover_verify compares it to the live ask. Only sub_total / cover_cost /
-- profit are landed. The column comment on n2s_cover_queue says so.
--
-- ⚠ The schedule row currently reads buyer_fee_pct = 0 ("placeholder; verify",
-- 2026-05-09). This migration changes NOTHING until the operator sets it:
--     UPDATE public.order_fee_schedule SET buyer_fee_pct = <rate>, notes = '...'
--      WHERE source = 'tevo';
-- Rates are fractions (0.06 = 6%), per the column's existing convention.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_landed_total(p_src text, p_ea numeric, p_qty integer)
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
           WHEN p_src = 'tevo' THEN
             p_ea * p_qty * (1 + COALESCE((SELECT f.buyer_fee_pct FROM public.order_fee_schedule f
                                            WHERE f.source = 'tevo' LIMIT 1), 0))
             + COALESCE((SELECT f.fixed_fee_per_order FROM public.order_fee_schedule f
                          WHERE f.source = 'tevo' LIMIT 1), 0)
           ELSE p_ea * p_qty
         END;
$function$;

COMMENT ON FUNCTION public.n2s_landed_total(text, numeric, integer) IS
  'What buying p_qty seats at ask p_ea from source p_src actually costs. TEvo asks are bare (buyer fee added at checkout) so they gain order_fee_schedule.buyer_fee_pct + fixed_fee_per_order for source=''tevo''; GoTickets all_in_price and SeatGeek retail_price_all_in are already landed and pass through. Rates are fractions (0.06 = 6%).';

REVOKE ALL ON FUNCTION public.n2s_landed_total(text, numeric, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_landed_total(text, numeric, integer) TO authenticated, service_role;

-- ── n2s_cover_candidates: body from 20260910650000 + n2s_event_live (20260914223000),
--    with every money expression routed through n2s_landed_total ─────────────
CREATE OR REPLACE FUNCTION public.n2s_cover_candidates(
  p_n2s_ids bigint[] DEFAULT NULL::bigint[],
  p_max_listing_age interval DEFAULT '01:00:00'::interval,
  p_per_order integer DEFAULT 3,
  p_sub_sources text[] DEFAULT NULL::text[])
RETURNS TABLE(n2s_id bigint, order_number text, s4k_source text, n2s_status text, fail_reason text, timer_expired boolean, event_name text, event_date date, venue text, tevo_event_id bigint, section text, order_row text, quantity integer, sold_ea numeric, sub_source text, sub_listing_id text, sub_section text, sub_row text, sub_qty integer, sub_avail integer, sub_ea numeric, sub_total numeric, cover_cost numeric, rows_closer integer, buy_url text, captured_at timestamp with time zone, cover_rank bigint, cover_gate integer, cover_label text, order_zone text, sub_zone text)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH o AS (
    SELECT i.n2s_id, i.order_number, i.s4k_source, i.status, i.fail_reason,
           i.timer_expired, i.event_name, i.event_dt::date AS event_date,
           i.venue, i.tevo_event_id, i.section, i."row" AS order_row,
           i.qty AS quantity, i.price_per_ticket AS sold_ea,
           public.seat_row_kind(i."row")    AS ord_kind,
           public.seat_row_rank(i."row")    AS ord_rank,
           public.seat_section_norm(i.section) AS sec_norm,
           e.venue_id,
           (SELECT z.performer_id FROM public.performer_zones z
             WHERE z.venue_id = e.venue_id AND z.performer_id = ANY(e.performer_ids)
               AND z.source = 'curated' LIMIT 1) AS zperf
      FROM public.n2s_items i
      JOIN public.events e ON e.id = i.tevo_event_id
     WHERE NOT i.is_terminal AND i.tevo_event_id IS NOT NULL
       AND public.n2s_event_live(i.event_dt, i.tevo_event_id)
       AND (p_n2s_ids IS NULL OR i.n2s_id = ANY(p_n2s_ids))
  ),
  oz AS (SELECT o.*, public.n2s_zone_of(o.zperf, o.venue_id, o.section, o.order_row) AS order_zone FROM o),
  ev AS (SELECT DISTINCT tevo_event_id AS eid FROM o),
  p_tevo AS (SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.listings_snapshots s
       WHERE s.event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x),
  p_gt AS (SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.gotickets_listings_snapshots s
       WHERE s.tevo_event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x),
  p_sg AS (SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.seatgeek_listings_snapshots s
       WHERE s.tevo_event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x),
  td_cur AS (
    SELECT DISTINCT ON (t.event_id, t.platform, t.td_listing_id)
           t.event_id AS eid, t.platform, t.td_listing_id, t.section, t."row",
           t.quantity, t.price_with_fees, t.list_price, t.is_parking, t.captured_at
      FROM public.ticketsdata_listings_snapshots t
     WHERE t.event_id IN (SELECT eid FROM ev) AND t.captured_at >= now() - p_max_listing_age
     ORDER BY t.event_id, t.platform, t.td_listing_id, t.captured_at DESC),
  l AS (
    SELECT 'tevo'::text AS src, t.tevo_ticket_group_id::text AS lid, t.event_id AS eid,
           t.section AS sec, t."row" AS rw, t.quantity AS q, t.retail_price AS ea,
           'https://core.ticketevolution.com/buy/event/' || t.event_id::text
             || '/tickets/' || t.tevo_ticket_group_id::text AS url,
           t.captured_at, t.splits
      FROM p_tevo p JOIN public.listings_snapshots t
        ON t.event_id = p.eid AND t.captured_at = p.captured_at
     WHERE NOT t.is_owned AND NOT t.is_ancillary
       AND (p_sub_sources IS NULL OR 'tevo' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'gotickets', g.gt_listing_id::text, g.tevo_event_id,
           g.section, g."row", g.quantity, g.all_in_price,
           'https://pro.gotickets.com/tickets/' || g.gt_event_id
             || '/?sortBy=price&sortDirection=asc&sections=' || g.section_id,
           g.captured_at, g.splits
      FROM p_gt p JOIN public.gotickets_listings_snapshots g
        ON g.tevo_event_id = p.eid AND g.captured_at = p.captured_at
     WHERE (p_sub_sources IS NULL OR 'gotickets' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'seatgeek', sg.sglid::text, sg.tevo_event_id,
           sg.section, sg."row", sg.quantity, sg.retail_price_all_in,
           CASE WHEN COALESCE(c.sg_url,'') <> '' AND COALESCE(sg.display_id,'') <> ''
                THEN c.sg_url || '#listing=' || sg.display_id ELSE NULL::text END,
           sg.captured_at,
           CASE WHEN jsonb_typeof(sg.splits) = 'array'
                THEN ARRAY(SELECT e::int FROM jsonb_array_elements_text(sg.splits) AS e
                            WHERE e ~ '^[0-9]+$')
                ELSE NULL::int[] END
      FROM p_sg p JOIN public.seatgeek_listings_snapshots sg
        ON sg.tevo_event_id = p.eid AND sg.captured_at = p.captured_at
      LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = sg.sg_event_id
     WHERE NOT sg.is_broker_owned
       AND (p_sub_sources IS NULL OR 'seatgeek' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'ticketsdata:' || td.platform, td.td_listing_id, td.eid,
           td.section, td."row", td.quantity,
           COALESCE(td.price_with_fees, td.list_price),
           NULL::text, td.captured_at, NULL::int[]
      FROM td_cur td
     WHERE NOT COALESCE(td.is_parking,false)
       AND COALESCE(td.price_with_fees, td.list_price) IS NOT NULL
       AND ('ticketsdata' = ANY(p_sub_sources))
  ),
  evz AS MATERIALIZED (SELECT DISTINCT tevo_event_id AS eid, zperf, venue_id
            FROM oz WHERE zperf IS NOT NULL AND order_zone IS NOT NULL),
  -- rule bounds normalised ONCE per rule
  zrule AS MATERIALIZED (
    SELECT evz.eid, z.name AS zone,
           public._sec_norm(r.section_from) AS sf_n, public._sec_norm(r.section_to) AS st_n,
           (r.section_from ~ '^[0-9]+$' AND r.section_to ~ '^[0-9]+$') AS sec_num,
           NULLIF(regexp_replace(r.section_from,'\D','','g'),'')::bigint AS sf_i,
           NULLIF(regexp_replace(r.section_to  ,'\D','','g'),'')::bigint AS st_i,
           public._sec_prefix(r.section_from) AS sf_p, public._sec_prefix(r.section_to) AS st_p,
           public._sec_suffix(r.section_from) AS sf_s, public._sec_suffix(r.section_to) AS st_s,
           r.row_from, r.row_to,
           (r.row_from ~ '^[0-9]+$' AND r.row_to ~ '^[0-9]+$') AS row_num,
           NULLIF(regexp_replace(coalesce(r.row_from,''),'\D','','g'),'')::bigint AS rf_i,
           NULLIF(regexp_replace(coalesce(r.row_to  ,''),'\D','','g'),'')::bigint AS rt_i,
           lower(coalesce(r.row_from,'')) AS rf_lc, lower(coalesce(r.row_to,'')) AS rt_lc
      FROM evz
      JOIN public.performer_zones z
        ON z.performer_id = evz.zperf AND z.venue_id = evz.venue_id
       AND z.source = 'curated' AND z.name NOT ILIKE '%fifa%'
      JOIN public.performer_zone_rules r ON r.zone_id = z.id
  ),
  lcoord0 AS MATERIALIZED (SELECT DISTINCT l.eid, l.sec, l.rw FROM l JOIN evz ON evz.eid = l.eid),
  -- coordinate normalised ONCE per coordinate (after the DISTINCT, not before)
  lcoord AS MATERIALIZED (
    SELECT eid, sec, rw,
           public._sec_norm(sec) AS c_n,
           (sec ~ '^[0-9]+$') AS c_num,
           NULLIF(regexp_replace(coalesce(sec,''),'\D','','g'),'')::bigint AS c_i,
           public._sec_prefix(sec) AS c_p, public._sec_suffix(sec) AS c_s,
           (rw ~ '^[0-9]+$') AS r_num,
           NULLIF(regexp_replace(coalesce(rw,''),'\D','','g'),'')::bigint AS r_i,
           lower(coalesce(rw,'')) AS r_lc
      FROM lcoord0
  ),
  lz AS (
    SELECT c.eid, c.sec, c.rw,
           CASE WHEN count(DISTINCT zr.zone) = 1 THEN min(zr.zone) END AS zone
      FROM lcoord c
      JOIN zrule zr ON zr.eid = c.eid
     WHERE ( (zr.sf_n = zr.st_n AND c.c_n = zr.sf_n)
          OR (zr.sec_num AND c.c_num AND c.c_i BETWEEN zr.sf_i AND zr.st_i)
          OR (zr.sf_p <> '' AND zr.sf_p = zr.st_p AND zr.sf_p = c.c_p
              AND zr.sf_s IS NOT NULL AND zr.st_s IS NOT NULL AND c.c_s IS NOT NULL
              AND c.c_s BETWEEN zr.sf_s AND zr.st_s) )
       AND ( (zr.row_from IS NULL AND zr.row_to IS NULL)
          OR (zr.rf_lc = zr.rt_lc AND c.r_lc = zr.rf_lc)
          OR (zr.row_num AND c.r_num AND c.r_i BETWEEN zr.rf_i AND zr.rt_i) )
     GROUP BY c.eid, c.sec, c.rw
  ),
  match_exact AS (
    SELECT oz.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at, l.splits,
           lz.zone AS sub_zone, true AS sec_exact
      FROM oz
      JOIN l ON l.eid = oz.tevo_event_id
            AND public.seat_section_norm(l.sec) = oz.sec_norm
            AND public.seat_row_kind(l.rw) = oz.ord_kind
      LEFT JOIN lz ON lz.eid = l.eid AND lz.sec IS NOT DISTINCT FROM l.sec
                                     AND lz.rw  IS NOT DISTINCT FROM l.rw
     WHERE public.seat_row_rank(l.rw) <= oz.ord_rank + 5
  ),
  match_zone AS (
    SELECT oz.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at, l.splits,
           lz.zone AS sub_zone, false AS sec_exact
      FROM oz
      JOIN lz ON lz.eid = oz.tevo_event_id AND lz.zone = oz.order_zone
      JOIN l  ON l.eid = lz.eid AND l.sec IS NOT DISTINCT FROM lz.sec
                                AND l.rw  IS NOT DISTINCT FROM lz.rw
     WHERE oz.order_zone IS NOT NULL
       AND public.seat_row_kind(l.rw) = oz.ord_kind
       AND public.seat_row_rank(l.rw) <= oz.ord_rank + 5
       AND public.seat_section_norm(l.sec) <> oz.sec_norm
  ),
  u AS (SELECT * FROM match_exact UNION ALL SELECT * FROM match_zone),
  mm AS (
    SELECT u.*,
           CASE WHEN u.q = u.quantity
                  OR (u.q > u.quantity AND u.quantity = ANY(u.splits)) THEN 1
                WHEN u.q = u.quantity + 1 THEN 2 ELSE 3 END AS tier,
           CASE WHEN u.q = u.quantity
                  OR (u.q > u.quantity AND u.quantity = ANY(u.splits)) THEN u.quantity
                WHEN u.q = u.quantity + 1 THEN u.q
                ELSE u.quantity + 1 END AS buy_qty
      FROM u
     WHERE ( (u.q = u.quantity AND (u.splits IS NULL OR u.q = ANY(u.splits)))
          OR (u.q > u.quantity AND u.quantity = ANY(u.splits))
          OR (u.q = u.quantity + 1 AND (u.splits IS NULL OR u.q = ANY(u.splits)))
          OR (u.q > u.quantity + 1 AND (u.quantity + 1) = ANY(u.splits)
              -- tier 3 is admitted only when the LANDED spare-seat buy still profits
              AND public.n2s_landed_total(u.src, u.ea, u.quantity + 1) <= u.sold_ea * u.quantity) )
  ),
  g AS (
    SELECT mm.*,
           public.n2s_landed_total(mm.src, mm.ea, mm.buy_qty)          AS landed,
           public.seat_row_rank(mm.rw) <= mm.ord_rank                  AS row_ok,
           public.n2s_landed_total(mm.src, mm.ea, mm.buy_qty)
             < mm.sold_ea * mm.quantity                                AS profitable,
           (mm.sold_ea IS NULL OR mm.sold_ea <= 0
             OR public.n2s_landed_total(mm.src, mm.ea, mm.buy_qty)
                <= 2 * mm.sold_ea * mm.quantity)                       AS within_cap,
           -- NOT DISTINCT FROM, so both-NULL (no curated zones at this
           -- venue) passes while a named zone vs NULL is refused.
           mm.sub_zone IS NOT DISTINCT FROM mm.order_zone              AS zone_ok
      FROM mm
  ),
  gg AS (
    SELECT g.*,
           CASE WHEN sec_exact AND row_ok AND profitable THEN 1
                WHEN sec_exact AND row_ok AND within_cap THEN 2
                WHEN NOT sec_exact AND row_ok AND profitable THEN 3
                WHEN NOT sec_exact AND row_ok AND within_cap THEN 4
                WHEN NOT row_ok AND zone_ok AND profitable THEN 5
                WHEN NOT row_ok AND zone_ok AND within_cap THEN 6
           END AS cover_gate
      FROM g
  ),
  ded AS (
    SELECT DISTINCT ON (n2s_id, src, lid) *
      FROM gg WHERE cover_gate IS NOT NULL
     ORDER BY n2s_id, src, lid, cover_gate
  ),
  m AS (
    SELECT ded.*,
           CASE ded.cover_gate WHEN 1 THEN 'Index'
                               WHEN 2 THEN 'S4KTrading'
                               WHEN 3 THEN 'Index offer subs'
                               WHEN 4 THEN 'offer subs s4ktrading'
                               WHEN 5 THEN 'Index Down offer subs'
                               WHEN 6 THEN 'Down offer subs S4KTrading' END
             || CASE WHEN ded.cover_gate >= 5 AND ded.order_zone IS NULL
                     THEN ' zone unverified' ELSE '' END
             || CASE WHEN ded.quantity = 1 THEN ' single ticket' ELSE '' END
             || CASE WHEN ded.buy_qty > ded.quantity THEN ' repost single' ELSE '' END
             AS cover_label,
           row_number() OVER (PARTITION BY ded.n2s_id
                              ORDER BY ded.cover_gate, ded.tier,
                                       ded.landed, (ded.q - ded.quantity)) AS rn
      FROM ded
  )
  SELECT n2s_id, order_number, s4k_source, status, fail_reason, timer_expired,
         event_name, event_date, venue, tevo_event_id, section, order_row,
         quantity, sold_ea, src, lid, sec, rw,
         buy_qty AS sub_qty, q AS sub_avail, ea,
         round(landed, 2) AS sub_total,
         round(landed - sold_ea * quantity, 2) AS cover_cost,
         (ord_rank - public.seat_row_rank(rw)) AS rows_closer,
         url, captured_at, rn, cover_gate, cover_label, order_zone, sub_zone
    FROM m
   WHERE rn <= p_per_order
   ORDER BY cover_gate, cover_cost, n2s_id;
$function$;

COMMENT ON FUNCTION public.n2s_cover_candidates(bigint[], interval, integer, text[]) IS
  'Ranked cover candidates per open N2S obligation (up to p_per_order each). Pools TEvo, GoTickets and SeatGeek listings, matches by exact section or curated zone, tiers by quantity, classifies into six gates, and ranks by gate, tier, LANDED cost. sub_ea is the listing ask (what checkout is quoted); sub_total and cover_cost are landed via n2s_landed_total(), so a TEvo ask carries order_fee_schedule.buyer_fee_pct + fixed_fee_per_order while GoTickets/SeatGeek all-in prices pass through. Event liveness is n2s_event_live() (local time), not the UTC date.';

COMMENT ON COLUMN public.n2s_cover_queue.sub_ea IS
  'Listing ask per seat, exactly as the source quotes it — the number to enter at checkout and the one n2s_cover_verify compares to the live ask. NOT landed: for TEvo the buyer fee is added at checkout. Use sub_total / cover_cost for what the cover costs.';
COMMENT ON COLUMN public.n2s_cover_queue.sub_total IS
  'Landed cost of the cover: n2s_landed_total(sub_source, sub_ea, sub_qty). For TEvo this includes order_fee_schedule.buyer_fee_pct and fixed_fee_per_order; GoTickets and SeatGeek prices are already all-in.';
COMMENT ON COLUMN public.n2s_cover_queue.cover_cost IS
  'sub_total minus the sold value (sold_ea × quantity). Negative = the cover is cheaper than what we sold for, i.e. profitable. Landed, see sub_total.';
