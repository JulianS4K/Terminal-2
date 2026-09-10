-- ============================================================================
-- Migration 20260910420000 — the six-gate label cascade
--
-- Lane:     D7 · Level: data-collection · Pre-reqs: 20260910400000, n2s_zone_of
--
-- Operator 2026-09-10: "we are just data control and labeling, border patrol if
-- you will, get that right and job done."
--
-- THE CASCADE — first gate that matches wins, then cheapest within it:
--   1 Index                       exact section · row ==/better · profitable
--   2 S4KTrading                  exact section · row ==/better · <=200%
--   3 Index offer subs            same zone     · row ==/better · profitable
--   4 offer subs s4ktrading       same zone     · row ==/better · <=200%
--   5 Index Down offer subs       exact or zone · row up to +5  · profitable
--   6 Down offer subs S4KTrading  exact or zone · row up to +5  · <=200%
--   + suffix " repost single" whenever buy_qty > quantity (the spare gets
--     reposted as a single, so the buyer of THIS order is unaffected).
-- No gate = not sent. Anything above 200% therefore never ships, on any gate.
--
-- ── WHY "offer subs" IS IN THE NAME OF 3-6 ─────────────────────────────────
-- Operator: "for anything where we move or downgrade buyer we will offer subs
-- first, hence labeling." Gates 1-2 keep the buyer in the exact section they
-- bought, so they are actionable directly. Gates 3-6 move them — a different
-- section in the same zone, or up to five rows back — so the label itself
-- encodes that a human must offer it to the buyer BEFORE purchase. The label
-- is a workflow instruction, not a quality score.
--
-- ── ⚠ ROW DOWNGRADE IS DELIBERATELY *NOT* ZONE-CAPPED ──────────────────────
-- Operator, explicitly: "downgrade is not zone based for now."
-- The hazard this accepts, recorded so it is a decision and not a surprise:
-- 436 of 5,524 zone rules are row-bound, and they are PRICE TIERS inside one
-- section, not geography — sections 121-124 run Metro Gold/Plat (rows 1-6),
-- Metro Silver (7-12), Metro Bronze (13-22), Metro Box (23-35). So a +5 row
-- move can cross a tier: row 6 -> row 11 is Gold -> Silver, a product
-- downgrade wearing a row number. Measured at authoring time: 0 of 49 live
-- obligations would cross a named zone at +5, so this bites nothing today.
-- If it starts to, the fix is one predicate (require zone_of(sub) = zone_of
-- (order) on gates 5/6), not a redesign.
--
-- ── ⚠ ZONES ARE SECTION *AND* ROW SCOPED ───────────────────────────────────
-- n2s_zone_of() takes the row for exactly the reason above. Gates 3/4 get tier
-- safety for free: a Gold seat cannot match a Silver seat in the same section,
-- because they resolve to different zones. Do not "optimise" the row argument
-- away.
--
-- ── ⚠ AMBIGUOUS ZONES FALL THROUGH, THEY DO NOT GUESS ──────────────────────
-- n2s_zone_of() returns NULL when a section+row lands in two curated zones
-- (4 of 48 live lookups). match_performer_zone() would have broken the tie by
-- display_order, which carries no semantics. For a classifier whose product IS
-- the label, a confidently wrong zone is worse than no zone — so those cases
-- drop to gates 5/6 rather than shipping a wrong zone name.
--
-- ── THE 200% CEILING IS NOW THE GATES, NOT A SEPARATE FILTER ───────────────
-- 20260910400000 added a standalone `m` WHERE ceiling. It is REMOVED here and
-- folded into the gate CASE, so the cascade is the single authority on what
-- ships. Same behaviour, one place to read. The sold_ea <= 0 carve-out is
-- preserved: a zero-priced order has an uncomputable ceiling, so treat it as
-- within-cap and let the label carry it to a human rather than blanking the
-- obligation (PROJECT_BIBLE §3 records GoTickets CRM orders at price 0.00).
-- ============================================================================

DROP FUNCTION IF EXISTS public.n2s_cover_candidates(bigint[], interval, integer, text[]);

CREATE FUNCTION public.n2s_cover_candidates(
  p_n2s_ids          bigint[] DEFAULT NULL::bigint[],
  p_max_listing_age  interval DEFAULT '01:00:00'::interval,
  p_per_order        integer  DEFAULT 3,
  p_sub_sources      text[]   DEFAULT NULL::text[])
 RETURNS TABLE(n2s_id bigint, order_number text, s4k_source text, n2s_status text,
               fail_reason text, timer_expired boolean, event_name text,
               event_date date, venue text, tevo_event_id bigint, section text,
               order_row text, quantity integer, sold_ea numeric, sub_source text,
               sub_listing_id text, sub_section text, sub_row text, sub_qty integer,
               sub_avail integer, sub_ea numeric, sub_total numeric,
               cover_cost numeric, rows_closer integer, buy_url text,
               captured_at timestamp with time zone, cover_rank bigint,
               cover_gate integer, cover_label text,
               order_zone text, sub_zone text)
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
           -- the ONE performer that owns curated zones at this venue; verified
           -- unique across all 66 live zoned obligations, so no precedence rule.
           (SELECT z.performer_id FROM public.performer_zones z
             WHERE z.venue_id = e.venue_id AND z.performer_id = ANY(e.performer_ids)
               AND z.source = 'curated' LIMIT 1) AS zperf
      FROM public.n2s_items i
      JOIN public.events e ON e.id = i.tevo_event_id
     WHERE NOT i.is_terminal
       AND i.tevo_event_id IS NOT NULL
       AND i.event_dt::date >= current_date
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
       AND (p_sub_sources IS NULL OR 'ticketsdata' = ANY(p_sub_sources))
  ),
  -- Zone is resolved ONCE per distinct listing coordinate at events that
  -- actually have a zoned performer, not once per listing. 26k+ listings
  -- collapse to a few thousand (event, section, row) triples; this runs inside
  -- a 1-minute cron, so the difference matters.
  evz AS MATERIALIZED (SELECT DISTINCT tevo_event_id AS eid, zperf, venue_id
            FROM oz WHERE zperf IS NOT NULL AND order_zone IS NOT NULL),
  -- ⚠ AS MATERIALIZED IS LOAD-BEARING ON zrule/lcoord0/lcoord.
  -- Postgres 12+ inlines a CTE referenced only once. Without it these
  -- normalisers (_sec_norm/_sec_prefix/_sec_suffix) get pushed into the join
  -- predicate and evaluated PER COMPARISON — 12,097 coordinates x 1,965 rules,
  -- ~24M string-function calls — which timed out at 60s. Precomputing them into
  -- CTE columns achieves nothing on its own because inlining undoes it. Removing
  -- MATERIALIZED fails as a TIMEOUT, not a wrong answer, so it looks like an
  -- infrastructure fault rather than a query-shape one. Do not "tidy" it away.
  zrule AS MATERIALIZED (   -- rule bounds normalised ONCE per rule
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
  lcoord AS MATERIALIZED (  -- coordinate normalised ONCE, AFTER the DISTINCT
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
  lz AS (   -- ambiguity refused: count(DISTINCT zone) = 1 or NULL
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
              AND u.ea * (u.quantity + 1) <= u.sold_ea * u.quantity) )
  ),
  g AS (
    SELECT mm.*,
           public.seat_row_rank(mm.rw) <= mm.ord_rank                AS row_ok,
           mm.ea * mm.buy_qty < mm.sold_ea * mm.quantity             AS profitable,
           -- sold_ea <= 0 makes the ceiling uncomputable; treat as within-cap so
           -- the obligation is LABELLED rather than silently blanked.
           (mm.sold_ea IS NULL OR mm.sold_ea <= 0
             OR mm.ea * mm.buy_qty <= 2 * mm.sold_ea * mm.quantity)  AS within_cap
      FROM mm
  ),
  gg AS (
    SELECT g.*,
           CASE WHEN sec_exact AND row_ok AND profitable THEN 1
                WHEN sec_exact AND row_ok AND within_cap THEN 2
                WHEN NOT sec_exact AND row_ok AND profitable THEN 3
                WHEN NOT sec_exact AND row_ok AND within_cap THEN 4
                WHEN NOT row_ok AND profitable THEN 5
                WHEN NOT row_ok AND within_cap THEN 6
           END AS cover_gate
      FROM g
  ),
  ded AS (  -- a listing reachable both exactly and by zone keeps its BEST gate
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
             || CASE WHEN ded.buy_qty > ded.quantity THEN ' repost single' ELSE '' END
             AS cover_label,
           row_number() OVER (PARTITION BY ded.n2s_id
                              ORDER BY ded.cover_gate, ded.tier,
                                       ded.ea * ded.buy_qty, (ded.q - ded.quantity)) AS rn
      FROM ded
  )
  SELECT n2s_id, order_number, s4k_source, status, fail_reason, timer_expired,
         event_name, event_date, venue, tevo_event_id, section, order_row,
         quantity, sold_ea, src, lid, sec, rw,
         buy_qty AS sub_qty, q AS sub_avail, ea,
         round(ea * buy_qty, 2) AS sub_total,
         round(ea * buy_qty - sold_ea * quantity, 2) AS cover_cost,
         (ord_rank - public.seat_row_rank(rw)) AS rows_closer,
         url, captured_at, rn, cover_gate, cover_label, order_zone, sub_zone
    FROM m
   WHERE rn <= p_per_order
   ORDER BY cover_gate, cover_cost, n2s_id;
$function$;

COMMENT ON FUNCTION public.n2s_cover_candidates(bigint[], interval, integer, text[]) IS
  'Ranked, LABELLED cover candidates. Six gates, first match wins: 1 Index / 2 S4KTrading (exact section) · 3 Index offer subs / 4 offer subs s4ktrading (same curated zone) · 5 Index Down offer subs / 6 Down offer subs S4KTrading (up to 5 rows back). Odd gates are profitable, even gates are within a 200% cost ceiling; no gate = not sent, so nothing above 200% ever ships. Suffix " repost single" marks a qty+1 buy. "offer subs" in a label means the buyer is being MOVED and a human must offer it first. Zones come from n2s_zone_of(), which refuses ambiguity rather than guessing. Row downgrade is deliberately NOT zone-capped (operator 2026-09-10) — it can cross a row-based price tier; 0 live cases today.';
