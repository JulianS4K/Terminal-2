-- Migration 20261113450000 · level:secondary-sales · lane:D0 · writes:sub_finder_row_is_wheelchair,sub_finder_row_letters_differ,sub_finder_match,sub_finder_cover_flags · reads:sub_finder_order,sub_finder_config,events,performer_zones,performer_zone_rules · pre:20261113440000
--
-- SUB FINDER: two more things a person reviews before anything is bought.
--
-- Operator 2026-11-13: "Yes add those 2 for CRM to review before autobuying, wc row and
-- single-double letter and vice versa".
--
-- Until now the matcher ranked a double-letter row behind Z (AA = 27) and read "WC" as an
-- ordinary two-letter row. So an order sold in row AA, or in row WC, took any single-letter
-- row of its section as "same or better" and could be bought automatically; and an order sold
-- in row H was never shown a row AA at all. Venues disagree on whether AA sits in front of A
-- or behind Z, which is why the N2S auto-buyer already skips these pairs (20261104170000).
--
--   * `row_letter_mismatch` (label suffix " row letters differ"): the sold row and the cover's
--     row are both letters and one is a single letter while the other is a double. Shown
--     EITHER way round (sold AA / cover H, and sold H / cover AA, which was hidden before), as
--     a same-section cover (gate 1 / 2) or, in another section of the zone, gate 3 / 4.
--   * `wheelchair_row` (label suffix " wheelchair row"): exactly one of the two rows is a
--     wheelchair row (WC, wheelchair, accessible, ADA, handicap). Which pairs match is not
--     changed, so a wheelchair listing is still not offered for an ordinary order.
--   * Both set `confirm_needed`, and the cover's `row_relation` reads `unknown`. A flagged
--     cover is never bought automatically (sub_finder_autobuy already requires no flags); the
--     order's `auto_buy_note` reads `needs_crm_confirm`, and the CRM buys it with
--     "confirm": true (or `sub_confirm: true` in its feed), as for the other flags.
--
-- Functions are shipped whole (MIGRATION_CONVENTIONS 6a). Covers already stored pick the flags
-- up at their next re-match (every round for a watched order).
--
-- rollback: re-apply sub_finder_match and sub_finder_cover_flags from 20261113440000's result.

CREATE OR REPLACE FUNCTION public.sub_finder_row_is_wheelchair(p_row text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $$
  SELECT coalesce(p_row ~* '(^|[^a-z])(wc|ada)([^a-z]|$)' OR p_row ~* '(wheelchair|accessible|handicap)', false)
$$;

-- one row a single letter, the other a double letter (never a wheelchair row: that has its own flag)
CREATE OR REPLACE FUNCTION public.sub_finder_row_letters_differ(p_sold text, p_sub text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $$
  SELECT coalesce(btrim(p_sold) ~ '^[A-Za-z]{1,2}$' AND btrim(p_sub) ~ '^[A-Za-z]{1,2}$'
                  AND length(btrim(p_sold)) <> length(btrim(p_sub))
                  AND NOT public.sub_finder_row_is_wheelchair(p_sold)
                  AND NOT public.sub_finder_row_is_wheelchair(p_sub), false)
$$;

REVOKE ALL ON FUNCTION public.sub_finder_row_is_wheelchair(text), public.sub_finder_row_letters_differ(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_row_is_wheelchair(text), public.sub_finder_row_letters_differ(text, text)
  TO service_role;

CREATE OR REPLACE FUNCTION public.sub_finder_match(p_job_id uuid, p_td_answered boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_back integer := (SELECT rows_back FROM public.sub_finder_config);
  v_n    integer;
BEGIN
  ANALYZE _sf_l;                                   -- a fresh temp table has no statistics (20261113220000)
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
           public.seat_row_rank(l.seat_row) - public.seat_row_rank(o.seat_row) AS row_delta,
           -- 20261113450000: rows whose order cannot be trusted. A person reviews these.
           public.sub_finder_row_letters_differ(o.seat_row, l.seat_row) AS letters_differ,
           public.sub_finder_row_is_wheelchair(o.seat_row) <> public.sub_finder_row_is_wheelchair(l.seat_row) AS wc_differs
    FROM o JOIN _sf_l l ON l.eid = o.tevo_event_id
     AND public.seat_section_norm(l.section) = public.seat_section_norm(o.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(o.seat_row)
     -- a single-letter row against a double-letter one is shown either way round: venues
     -- disagree on whether AA sits in front of A or behind Z
     AND (public.seat_row_rank(l.seat_row) <= public.seat_row_rank(o.seat_row) + v_back
          OR public.sub_finder_row_letters_differ(o.seat_row, l.seat_row))
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
    WITH zev AS (
    -- zones of every listed (section, row) at the events concerned, set-based (20261113220000):
    -- the same rule as n2s_zone_of, without one function call per listing row
    SELECT e.id AS eid, e.primary_performer_id AS perf, e.venue_id AS ven
    FROM public.events e WHERE e.id IN (SELECT tevo_event_id FROM need)
  ), zrule AS (
    SELECT v.eid, z.name, r.row_from, r.row_to,
           public._sec_norm(r.section_from) AS nf, public._sec_norm(r.section_to) AS nt,
           CASE WHEN r.section_from ~ '^[0-9]{1,9}$' AND r.section_to ~ '^[0-9]{1,9}$' THEN r.section_from::int END AS i_from,
           CASE WHEN r.section_from ~ '^[0-9]{1,9}$' AND r.section_to ~ '^[0-9]{1,9}$' THEN r.section_to::int END AS i_to,
           public._sec_prefix(r.section_from) AS pf, public._sec_prefix(r.section_to) AS pt,
           public._sec_suffix(r.section_from) AS sf, public._sec_suffix(r.section_to) AS st,
           CASE WHEN r.row_from ~ '^[0-9]{1,9}$' AND r.row_to ~ '^[0-9]{1,9}$' THEN r.row_from::int END AS r_from,
           CASE WHEN r.row_from ~ '^[0-9]{1,9}$' AND r.row_to ~ '^[0-9]{1,9}$' THEN r.row_to::int END AS r_to
    FROM zev v
    JOIN public.performer_zones z ON z.performer_id = v.perf AND z.venue_id = v.ven
                                 AND z.source = 'curated' AND z.name NOT ILIKE '%fifa%'
    JOIN public.performer_zone_rules r ON r.zone_id = z.id
  ), zdist AS (
    SELECT DISTINCT l.eid, l.section, l.seat_row FROM _sf_l l WHERE l.eid IN (SELECT eid FROM zev)
  ), zsec AS (
    SELECT s.eid, s.section, public._sec_norm(s.section) AS ns,
           CASE WHEN s.section ~ '^[0-9]{1,9}$' THEN s.section::int END AS i_s,
           public._sec_prefix(s.section) AS ps, public._sec_suffix(s.section) AS ss
    FROM (SELECT DISTINCT eid, section FROM zdist) s
  ), zmatch AS (
    SELECT s.eid, s.section, r.name, r.row_from, r.row_to, r.r_from, r.r_to
    FROM zsec s JOIN zrule r ON r.eid = s.eid
     AND ( (r.nf = r.nt AND s.ns = r.nf)
        OR (r.i_from IS NOT NULL AND s.i_s IS NOT NULL AND s.i_s BETWEEN r.i_from AND r.i_to)
        OR (r.pf <> '' AND r.pf = r.pt AND r.pf = s.ps
            AND r.sf IS NOT NULL AND r.st IS NOT NULL AND s.ss IS NOT NULL AND s.ss BETWEEN r.sf AND r.st) )
  )
    SELECT d.eid, d.section, d.seat_row,
           CASE WHEN count(DISTINCT m.name) = 1 THEN min(m.name) END AS z
    FROM zdist d
    LEFT JOIN zmatch m ON m.eid = d.eid AND m.section = d.section
     AND ( (m.row_from IS NULL AND m.row_to IS NULL)
        OR (lower(coalesce(m.row_from, '')) = lower(coalesce(m.row_to, ''))
            AND lower(coalesce(d.seat_row, '')) = lower(coalesce(m.row_from, '')))
        OR (m.r_from IS NOT NULL
            AND (CASE WHEN d.seat_row ~ '^[0-9]{1,9}$' THEN d.seat_row::int END) BETWEEN m.r_from AND m.r_to) )
    GROUP BY d.eid, d.section, d.seat_row
  ), zone_sec AS (
    -- another section in the SAME curated zone
    SELECT n.job_id, n.idx, n.qty, n.sold_ea, n.perf, n.ven, n.section AS o_section, n.seat_row AS o_row,
           l.*, true AS moved,
           CASE WHEN n.qty = ANY (l.sp) OR l.quantity = n.qty THEN n.qty
                WHEN l.quantity = n.qty + 1 THEN n.qty + 1 END AS buy_qty,
           public.seat_row_rank(l.seat_row) - public.seat_row_rank(n.seat_row) AS row_delta,
           public.sub_finder_row_letters_differ(n.seat_row, l.seat_row) AS letters_differ,
           public.sub_finder_row_is_wheelchair(n.seat_row) <> public.sub_finder_row_is_wheelchair(l.seat_row) AS wc_differs
    FROM need n
    JOIN oz ON oz.job_id = n.job_id AND oz.idx = n.idx AND oz.z IS NOT NULL
    JOIN lz ON lz.eid = n.tevo_event_id AND lz.z = oz.z
    JOIN _sf_l l ON l.eid = lz.eid AND l.section = lz.section AND l.seat_row = lz.seat_row
     AND public.seat_section_norm(l.section) <> public.seat_section_norm(n.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(n.seat_row)
     AND (public.seat_row_rank(l.seat_row) <= public.seat_row_rank(n.seat_row) + v_back
          OR public.sub_finder_row_letters_differ(n.seat_row, l.seat_row))
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
             -- letters_differ: which row is in front is not known, so it is not called rows back
             WHEN NOT p.moved AND (p.row_delta <= 0 OR p.letters_differ) THEN CASE WHEN p.profitable THEN 1 ELSE 2 END
             WHEN p.has_strict THEN NULL                      -- not widened: gates 3-6 do not apply
             WHEN p.moved AND (p.row_delta <= 0 OR p.letters_differ) THEN CASE WHEN p.profitable THEN 3 ELSE 4 END
             -- rows back: the same zone, or no zone on either side (then it is flagged)
             WHEN p.row_delta > 0 AND (p.moved OR p.o_zone IS NOT DISTINCT FROM p.l_zone)
               THEN CASE WHEN p.profitable THEN 5 ELSE 6 END
           END AS gate
    FROM priced p
  ), kept_rows AS (
    -- what is shown: any gated cover, plus a same-section same-or-better cover above 200%
    SELECT g.* FROM gated g
    WHERE g.gate IS NOT NULL OR (NOT g.moved AND (g.row_delta <= 0 OR g.letters_differ))
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
             'row_relation', CASE WHEN letters_differ OR wc_differs THEN 'unknown'
                                  WHEN row_delta < 0 THEN 'better' WHEN row_delta = 0 THEN 'same' ELSE 'back' END,
             'gate', gate,
             'label', CASE gate WHEN 1 THEN 'Index' WHEN 2 THEN 'S4KTrading' WHEN 3 THEN 'Index offer subs'
                                WHEN 4 THEN 'offer subs s4ktrading' WHEN 5 THEN 'Index Down offer subs'
                                WHEN 6 THEN 'Down offer subs S4KTrading' ELSE 'over 200% of sale' END
                      || CASE WHEN gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL THEN ' zone unverified' ELSE '' END
                      || CASE WHEN view_note = 'obstructed' THEN ' obstructed view' ELSE '' END
                      || CASE WHEN wc_differs THEN ' wheelchair row' ELSE '' END
                      || CASE WHEN letters_differ THEN ' row letters differ' ELSE '' END
                      || CASE WHEN qty = 1 THEN ' single ticket' ELSE '' END
                      || CASE WHEN buy_qty > qty THEN ' repost single' ELSE '' END
                      || CASE WHEN sold_ea IS NULL AND gate IS NOT NULL THEN ' no sale price' ELSE '' END,
             'needs_buyer_ok', coalesce(gate >= 3, false) OR (qty = 1 AND row_delta <> 0),
             -- a one-ticket order moved to another row of its own section: offer it, or buy it
             -- anyway with "confirm": true
             'offer_bypass', coalesce(gate IN (1, 2), false) AND qty = 1 AND row_delta <> 0,
             'flags', to_jsonb(array_remove(ARRAY[
                        CASE WHEN gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL THEN 'zone_unverified' END,
                        CASE WHEN view_note = 'obstructed' THEN 'obstructed_view' END,
                        CASE WHEN wc_differs THEN 'wheelchair_row' END,
                        CASE WHEN letters_differ THEN 'row_letter_mismatch' END,
                        CASE WHEN qty = 1 AND row_delta <> 0 THEN 'single_ticket_row_differs' END,
                        CASE WHEN buy_qty > qty THEN 'repost_single' END,
                        CASE WHEN sold_ea IS NULL AND gate IS NOT NULL THEN 'no_sale_price' END], NULL)),
             'confirm_needed', (gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL)
                               OR view_note IS NOT DISTINCT FROM 'obstructed' OR (qty = 1 AND row_delta <> 0)
                               OR wc_differs OR letters_differ
                               OR buy_qty > qty OR (sold_ea IS NULL AND gate IS NOT NULL),
             'zone', l_zone, 'view', view_note,
             'link', link, 'buyable', public.sub_finder_market_buyable(market), 'listing_seen_at', pulled_at) AS cover
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
                    WHEN (p.covers -> 0 ->> 'gate')::int IN (1, 2)
                         AND (p.covers -> 0 -> 'flags') ? 'single_ticket_row_differs' THEN 'offer'
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
$function$;

CREATE OR REPLACE FUNCTION public.sub_finder_cover_flags(cv jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN cv ? 'flags' THEN coalesce(cv->'flags', '[]'::jsonb)
              ELSE to_jsonb(array_remove(ARRAY[
                     CASE WHEN cv->>'label' LIKE '% zone unverified%' THEN 'zone_unverified' END,
                     CASE WHEN cv->>'label' LIKE '% obstructed view%' THEN 'obstructed_view' END,
                     CASE WHEN cv->>'label' LIKE '% wheelchair row%'  THEN 'wheelchair_row' END,
                     CASE WHEN cv->>'label' LIKE '% row letters differ%' THEN 'row_letter_mismatch' END,
                     CASE WHEN cv->>'label' LIKE '% single ticket%' AND cv->>'row_relation' IS DISTINCT FROM 'same'
                          THEN 'single_ticket_row_differs' END,
                     CASE WHEN cv->>'label' LIKE '% repost single%'   THEN 'repost_single' END,
                     CASE WHEN cv->>'label' LIKE '% no sale price%'   THEN 'no_sale_price' END], NULL)) END;
$function$;
