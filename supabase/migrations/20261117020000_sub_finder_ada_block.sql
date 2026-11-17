-- Migration 20261117020000 · level:secondary-sales · lane:D0 · writes:sub_finder_seat_is_ada(new),sub_finder_match,sub_finder_buy,sub_finder_gt_offer_request,sub_finder_autobuy,sub_finder_gt_offer_buy
--
-- ACCESSIBLE (ADA / WHEELCHAIR) SEATS ARE NEVER SWAPPED WITH ORDINARY SEATS.
-- Operator 2026-11-17, on StubHub order 659535353 (Stevie Wonder, Madison Square Garden, section
-- "204LWC" row 1): "it should also block because WC is ADA".
--
-- BEFORE. 20261113450000 looked for a wheelchair marker in the ROW only ("WC", "ADA",
-- "Wheelchair"), and a mismatch was a review flag (`wheelchair_row`): the cover was still quoted
-- and the CRM could buy it with "confirm": true. A venue that writes the marker in the SECTION
-- ("204LWC", "103WC", "103 WC") was not recognised at all.
--
-- NOW.
--   - sub_finder_seat_is_ada(section, row): the row test as before, or a section that carries the
--     marker: "WC" / "ADA" as a word, "WC" straight after the section number with at most one
--     letter between ("204LWC", "103WC"), or the words wheelchair / accessible / handicap.
--   - sub_finder_match: a listing whose ADA status differs from the sold seat's is not a cover, in
--     the order's own section and in its zone, whichever of the two is the accessible one. The
--     `wheelchair_row` flag and the " wheelchair row" label are no longer produced.
--     Like for like still matches (an accessible seat for an accessible seat).
--   - sub_finder_buy, sub_finder_gt_offer_request: refuse such a cover if one was quoted before
--     this migration (error forbidden, limit ada_seating). Nothing a person can confirm past.
--   - sub_finder_autobuy, sub_finder_gt_offer_buy: the two paths that buy with no person in the
--     loop refuse the same stale cover or offer (auto_buy_note / buy_note `ada_seating`).
--
-- sub_finder_cover_flags still reads " wheelchair row" from a stored label, for covers quoted
-- before today. sub_finder_row_is_wheelchair stays (the letter-row test and the N2S dry run use
-- it). The N2S auto-buyer's own rule (20261113460000, lane D7) is not changed here.
-- Functions are shipped whole (MIGRATION_CONVENTIONS 6a). Nothing here calls a market.
--
-- rollback: re-apply sub_finder_match, sub_finder_buy, sub_finder_gt_offer_request,
--           sub_finder_autobuy and sub_finder_gt_offer_buy from their previous migrations
--           (tests/sql/sub_finder/functions at the parent commit); DROP FUNCTION public.sub_finder_seat_is_ada(text, text);

-- true when the seat is accessible (ADA / wheelchair) seating, by its row or its section label
CREATE OR REPLACE FUNCTION public.sub_finder_seat_is_ada(p_section text, p_row text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT public.sub_finder_row_is_wheelchair(p_row)
      OR coalesce(p_section ~* '(^|[^a-z])(wc|ada)([^a-z]|$)'
               OR p_section ~* '[0-9] ?[a-z]?wc([^a-z]|$)'
               OR p_section ~* '(wheelchair|accessible|handicap)', false)
$function$;

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
           public.sub_finder_row_letters_differ(o.seat_row, l.seat_row) AS letters_differ
    FROM o JOIN _sf_l l ON l.eid = o.tevo_event_id
     AND public.seat_section_norm(l.section) = public.seat_section_norm(o.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(o.seat_row)
     -- a single-letter row against a double-letter one is shown either way round: venues
     -- disagree on whether AA sits in front of A or behind Z
     AND (public.seat_row_rank(l.seat_row) <= public.seat_row_rank(o.seat_row) + v_back
          OR public.sub_finder_row_letters_differ(o.seat_row, l.seat_row))
    WHERE l.px > 0 AND l.quantity > 0
      -- 20261117020000: an accessible (ADA / wheelchair) seat and an ordinary seat never replace
      -- each other, whichever was sold. Not a flag a person can confirm: the listing is not a cover.
      AND public.sub_finder_seat_is_ada(o.section, o.seat_row) = public.sub_finder_seat_is_ada(l.section, l.seat_row)
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
           public.sub_finder_row_letters_differ(n.seat_row, l.seat_row) AS letters_differ
    FROM need n
    JOIN oz ON oz.job_id = n.job_id AND oz.idx = n.idx AND oz.z IS NOT NULL
    JOIN lz ON lz.eid = n.tevo_event_id AND lz.z = oz.z
    JOIN _sf_l l ON l.eid = lz.eid AND l.section = lz.section AND l.seat_row = lz.seat_row
     AND public.seat_section_norm(l.section) <> public.seat_section_norm(n.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(n.seat_row)
     AND (public.seat_row_rank(l.seat_row) <= public.seat_row_rank(n.seat_row) + v_back
          OR public.sub_finder_row_letters_differ(n.seat_row, l.seat_row))
    WHERE l.px > 0 AND l.quantity > 0
      AND public.sub_finder_seat_is_ada(n.section, n.seat_row) = public.sub_finder_seat_is_ada(l.section, l.seat_row)
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
             'row_relation', CASE WHEN letters_differ THEN 'unknown'
                                  WHEN row_delta < 0 THEN 'better' WHEN row_delta = 0 THEN 'same' ELSE 'back' END,
             'gate', gate,
             'label', CASE gate WHEN 1 THEN 'Index' WHEN 2 THEN 'S4KTrading' WHEN 3 THEN 'Index offer subs'
                                WHEN 4 THEN 'offer subs s4ktrading' WHEN 5 THEN 'Index Down offer subs'
                                WHEN 6 THEN 'Down offer subs S4KTrading' ELSE 'over 200% of sale' END
                      || CASE WHEN gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL THEN ' zone unverified' ELSE '' END
                      || CASE WHEN view_note = 'obstructed' THEN ' obstructed view' ELSE '' END
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
                        CASE WHEN letters_differ THEN 'row_letter_mismatch' END,
                        CASE WHEN qty = 1 AND row_delta <> 0 THEN 'single_ticket_row_differs' END,
                        CASE WHEN buy_qty > qty THEN 'repost_single' END,
                        CASE WHEN sold_ea IS NULL AND gate IS NOT NULL THEN 'no_sale_price' END], NULL)),
             'confirm_needed', (gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL)
                               OR view_note IS NOT DISTINCT FROM 'obstructed' OR (qty = 1 AND row_delta <> 0)
                               OR letters_differ
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

CREATE OR REPLACE FUNCTION public.sub_finder_buy(p_key_id bigint, p_key_label text, p_job_id uuid, p_order_number text, p_listing_id text, p_requested_by text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  o     public.sub_finder_order;
  cv    jsonb;
  v_buy bigint;
  v_n   integer;
  c     public.sub_finder_config;
  v_spent numeric;
  v_pct numeric;                     -- the CRM's own limit on a buy's cost, % of the sale (20261116030000)
  v_sale numeric;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'buy')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'buying is not enabled for this key');
  END IF;
  SELECT count(*) INTO v_n FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number;
  IF v_n = 0 THEN RETURN jsonb_build_object('error', 'not_found', 'detail', 'no such order in this job'); END IF;
  IF v_n > 1 THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this order number appears more than once in the job');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number FOR UPDATE;
  IF o.buy_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id AND b.state = 'stopped') THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy was already requested for this order',
                              'buy_id', o.buy_id);
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) x
   WHERE public.sub_finder_market_buyable(x->>'market') AND x->>'listing_id' = p_listing_id
   ORDER BY (x->>'market' = 'evo') DESC LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', 'that listing is not a cover we can buy that this job quoted for this order');
  END IF;
  -- 20261117020000: an accessible (ADA / wheelchair) seat and an ordinary seat never replace each
  -- other. The lookup no longer quotes such a cover; this refuses one quoted before that.
  IF public.sub_finder_seat_is_ada(o.section, o.seat_row)
     <> public.sub_finder_seat_is_ada(cv->>'section', cv->>'row') THEN
    RETURN jsonb_build_object('error', 'forbidden', 'limit', 'ada_seating',
      'detail', 'an accessible (ADA / wheelchair) seat and an ordinary seat cannot replace each other');
  END IF;
  -- 20261116000000: the caps on buys a CRM key asks for (NULL = none; the buyer's own ceilings
  -- still apply afterwards). Per order: this buy's quoted total. Per New York day: with every
  -- other buy a CRM key asked for today that was not stopped or failed.
  SELECT * INTO c FROM public.sub_finder_config;
  IF (cv->>'total')::numeric > c.crm_buy_per_order_cap_usd THEN
    RETURN jsonb_build_object('error', 'forbidden',
      'detail', 'this buy is over the limit for one order',
      'limit', 'per_order', 'limit_usd', c.crm_buy_per_order_cap_usd, 'this_buy_usd', (cv->>'total')::numeric);
  END IF;
  IF c.crm_buy_daily_cap_usd IS NOT NULL THEN
    -- one cap check + request at a time: held to the end of the transaction, so two buys for
    -- different orders cannot both read the same total and together pass the limit
    PERFORM pg_advisory_xact_lock(hashtext('sub_finder_crm_buy_cap'));
    SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
      FROM public.manual_sub_buy b
     WHERE b.requested_by LIKE 'crm api key %' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
       AND (b.created_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date;
    IF v_spent + (cv->>'total')::numeric > c.crm_buy_daily_cap_usd THEN
      RETURN jsonb_build_object('error', 'forbidden',
        'detail', 'this buy would take today''s buys over the daily limit',
        'limit', 'per_day', 'limit_usd', c.crm_buy_daily_cap_usd, 'this_buy_usd', (cv->>'total')::numeric,
        'spent_today_usd', v_spent);
    END IF;
  END IF;
  -- 20261116030000: the CRM's own limit on what a cover it asks for may cost, as a percent of
  -- the sale total, for the marketplace the order sold on. Not set: no percentage limit. An
  -- order with no sale price cannot be measured, so it is refused while a limit is set.
  v_pct := public.sub_finder_crm_limit_pct('buy_max_cost', o.site);
  IF v_pct IS NOT NULL THEN
    v_sale := round(o.sold_ea * o.qty, 2);
    IF v_sale IS NULL OR v_sale <= 0 OR (cv->>'total')::numeric > round(v_sale * v_pct / 100.0, 2) THEN
      RETURN jsonb_build_object('error', 'forbidden',
        'detail', CASE WHEN v_sale IS NULL OR v_sale <= 0
                       THEN 'this order has no sale price to measure your buy limit against'
                       ELSE 'this buy costs more than your limit for one buy (buy_max_cost_pct)' END,
        'limit', 'buy_max_cost_pct', 'limit_pct', trim_scale(v_pct), 'sale_total', v_sale,
        'max_usd', round(v_sale * v_pct / 100.0, 2), 'this_buy_usd', (cv->>'total')::numeric);
    END IF;
  END IF;
  -- The purchase is decided on OUR copy of the order, not on what the caller sent: it must be
  -- in the N2S book or the marketplace order book with this event, these seats, this quantity
  -- and this sale price.
  IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'n2s', 'marketplace'], true) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this order is not in our copy of the order books with these seats, quantity and sale price; '
                || 'alert us with the order number only');
  END IF;
  IF public.sub_finder_report_only(o.order_number) THEN                    -- 20261113250000
    RETURN jsonb_build_object('error', 'forbidden',
      'detail', 'this is a PED Need2Buy order: it is reported only and never bought through this API');
  END IF;
  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = o.order_number) THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'the Need-to-Sub auto-buy already has this order');
  END IF;
  -- the sale must still be live (about 1.7 s; last, only for a buy that would otherwise go ahead)
  IF public.sub_finder_order_closed(o.order_number, o.site) IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this sale is marked fulfilled, cancelled or rejected');
  END IF;
  BEGIN
    v_buy := public.manual_sub_buy_request_market(cv->>'market',
      coalesce(o.site, 'CRM'), o.order_number, o.tevo_event_id, (cv->>'listing_id')::bigint,
      (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, o.sold_ea, o.event_name,
      'crm api key ' || coalesce(p_key_label, p_key_id::text)
        || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
      'sub finder job ' || p_job_id || ': sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
        || '; sub ' || (cv->>'section') || ' row ' || (cv->>'row') || ' x' || (cv->>'buy_qty'));
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy already exists for this sale');
  END;
  UPDATE public.sub_finder_order SET buy_id = v_buy, updated_at = now()
   WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('buy_id', v_buy, 'state', 'requested', 'order_number', o.order_number,
                            'market', cv->>'market', 'listing_id', cv->>'listing_id', 'qty', (cv->>'buy_qty')::int,
                            'max_price_ea', (cv->>'price_ea')::numeric);
END
$function$;

CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_request(p_key_id bigint, p_key_label text, p_order_number text, p_listing_id text, p_market text DEFAULT NULL::text, p_requested_by text DEFAULT NULL::text, p_rebate_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  o      public.sub_finder_order;
  cv     jsonb;
  v_gate integer;
  v_id   bigint;
  v_back integer;
  v_sale numeric;
  v_max  numeric;                    -- the most a rebate may be (20261116000000)
  v_reb  numeric := nullif(round(p_rebate_amount, 2), 0);   -- 0 = no rebate
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'offer')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'offering subs is not enabled for this key');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE key_id = p_key_id AND order_number = p_order_number AND watching
   ORDER BY updated_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'not_found', 'detail', 'no open lookup holds this order; alert us first');
  END IF;
  IF lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' OR p_order_number !~ '^\d{1,18}$' THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'only GoTickets orders can be offered a sub here');
  END IF;
  -- the offer is decided on OUR copy of the order, not on what the caller sent
  IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'n2s', 'marketplace'], false) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this order is not in our copy of the GoTickets order book with these seats; alert us with the order number only');
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
   WHERE x->>'listing_id' = p_listing_id AND x->>'source' = 'native'
     AND (p_market IS NULL OR x->>'market' = lower(btrim(p_market)))
   ORDER BY n LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'that listing is not a cover this lookup quoted for this order');
  END IF;
  -- 20261117020000: as for a buy, accessible and ordinary seats are never offered for each other
  IF public.sub_finder_seat_is_ada(o.section, o.seat_row)
     <> public.sub_finder_seat_is_ada(cv->>'section', cv->>'row') THEN
    RETURN jsonb_build_object('error', 'forbidden', 'limit', 'ada_seating',
      'detail', 'an accessible (ADA / wheelchair) seat and an ordinary seat cannot replace each other');
  END IF;
  v_gate := (cv->>'gate')::int;
  IF v_gate IS NULL OR (v_gate < 3 AND NOT (public.sub_finder_cover_flags(cv) ? 'single_ticket_row_differs')) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'gate 1-2 covers need no offer: the seats are in the same section, same or better row');
  END IF;
  IF v_gate = 6 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'gate 6 covers are results only and are not offered');
  END IF;
  -- The rebate is the CRM's call: we suggest one (sale total - sub total) but never set it.
  -- Rows back (gate 5) need an explicit answer, 0 included; other gates take one if sent.
  v_sale := round(o.sold_ea * o.qty, 2);
  v_max  := public.sub_finder_rebate_limit(v_sale, o.site);   -- the CRM's own limit (20261116030000)
  IF v_gate = 5 AND p_rebate_amount IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'this sub moves the customer back: send rebate_amount (0 for none)',
      'rebate_suggested', least(greatest((cv->>'profit')::numeric, 0), v_max), 'rebate_max', v_max);
  END IF;
  IF v_reb IS NOT NULL AND (v_reb < 0 OR v_max IS NULL OR v_reb > v_max) THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', CASE WHEN v_max IS DISTINCT FROM v_sale
                     THEN 'rebate_amount must be between 0 and the rebate limit (rebate_max)'
                     ELSE 'rebate_amount must be between 0 and the sale total' END,
      'sale_total', v_sale, 'rebate_max', v_max);
  END IF;
  v_back := public.seat_row_rank(cv->>'row') - public.seat_row_rank(o.seat_row);
  BEGIN
    INSERT INTO public.sub_finder_gt_offer
      (job_id, idx, key_id, requested_by, order_number, gt_order_id, gate, market, listing_id, section, seat_row,
       qty, buy_qty, price_ea, order_total, sub_total, rebate_amount, notes)
    VALUES (o.job_id, o.idx, p_key_id,
            'crm api key ' || coalesce(p_key_label, p_key_id::text) || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
            o.order_number, o.order_number::bigint, v_gate, cv->>'market', cv->>'listing_id', cv->>'section', cv->>'row',
            o.qty, (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, round(o.sold_ea * o.qty, 2), (cv->>'total')::numeric,
            v_reb,                                                        -- the amount the CRM gave
            CASE WHEN v_gate = 5
                 THEN 'Replacement seats in the same area, ' || v_back || ' row' || CASE WHEN v_back = 1 THEN '' ELSE 's' END
                      || ' further back than the original row ' || o.seat_row
                      || CASE WHEN v_reb IS NOT NULL THEN ', with a rebate.' ELSE '.' END
                 ELSE 'Comparable replacement seats in the same area, in the same row or closer than the original section '
                      || o.section || ' row ' || o.seat_row || '.' END)
    RETURNING offer_id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'an offer already exists for this order');
  END;
  UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('offer_id', v_id, 'state', 'requested', 'gate', v_gate,
                            'section', cv->>'section', 'row', cv->>'row',
                            'rebate', v_reb);
END
$function$;

-- the automatic buyer: a cover quoted before this rule is not bought (auto_buy_note ada_seating)
CREATE OR REPLACE FUNCTION public.sub_finder_autobuy(p_job_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config;
  j       public.sub_finder_job;
  o       public.sub_finder_order;
  cv      jsonb;
  v_note  text;
  v_buy   bigint;
  v_spent numeric;
  v_n     integer := 0;
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_loss  numeric;                  -- the loss this order may be bought at, % of the sale; NULL = profit only
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF c.auto_buy_enabled THEN
    PERFORM pg_advisory_xact_lock(hashtext('sub_finder_autobuy'));   -- one cap check + request at a time
  END IF;
  SELECT * INTO j FROM public.sub_finder_job WHERE job_id = p_job_id;
  FOR o IN SELECT * FROM public.sub_finder_order
            WHERE job_id = p_job_id AND watching AND buy_id IS NULL AND state = 'cover' ORDER BY idx
  LOOP
    v_buy := NULL;
    -- 20261113320000: a loss is allowed only on a need2buy order, up to the CRM's limit for the
    -- marketplace it sold on (5% unless set); every other order is bought at a profit only
    v_loss := public.sub_finder_max_loss_pct(o.site, o.via_need2buy OR public.sub_finder_order_is_need2buy(o.order_number));
    -- the best one-to-one this may take: a profit, or (need2buy orders) breakeven or a gate 2 loss inside the limit;
    -- our own feed, exact quantity, clear view. Covers are ordered gate first, then cheapest.
    SELECT x INTO cv FROM jsonb_array_elements(o.covers) WITH ORDINALITY t(x, n)
     WHERE public.sub_finder_cover_buyable(o.order_number, x) AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x, v_loss)
       AND (x->>'spare')::int = 0 AND x->>'view' IS DISTINCT FROM 'obstructed'
       AND jsonb_array_length(public.sub_finder_cover_flags(x)) = 0     -- a flagged cover waits for the CRM
       AND ((x->>'gate')::int = 2      -- a gate 2 cover is already inside the loss limit (sub_finder_autobuy_gate)
            OR (x->>'profit')::numeric >= (x->>'total')::numeric * c.auto_buy_min_profit_pct / 100.0)
     ORDER BY n LIMIT 1;
    v_note := CASE
      WHEN NOT c.auto_buy_enabled THEN 'auto_buy_off'
      WHEN cv IS NOT NULL THEN NULL
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND x->>'source' = 'native' AND public.sub_finder_autobuy_gate(x, v_loss))
        THEN 'no_evo_one_to_one'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0)
        THEN 'needs_spare_ticket'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0
                         AND x->>'view' IS DISTINCT FROM 'obstructed')
        THEN 'obstructed_view'
      WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE public.sub_finder_cover_buyable(o.order_number, x) AND public.sub_finder_autobuy_gate(x, v_loss) AND (x->>'spare')::int = 0
                         AND x->>'view' IS DISTINCT FROM 'obstructed'
                         AND jsonb_array_length(public.sub_finder_cover_flags(x)) = 0)
        THEN 'needs_crm_confirm'
      ELSE 'profit_too_thin' END;
    -- 20261117020000: an accessible (ADA / wheelchair) seat and an ordinary seat never replace each
    -- other. The matcher no longer quotes such a cover; this stops one quoted before that rule.
    IF v_note IS NULL AND public.sub_finder_seat_is_ada(o.section, o.seat_row)
                       <> public.sub_finder_seat_is_ada(cv->>'section', cv->>'row') THEN
      v_note := 'ada_seating';
    END IF;
    -- 20261116000000: an order whose details the caller sent (order_source 'request') is never
    -- bought automatically, even if our own books later show the same seats and price
    IF v_note IS NULL AND o.order_source = 'request' THEN
      v_note := 'order_described_by_caller';
    END IF;
    IF v_note IS NULL AND (
         EXISTS (SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = o.order_number OR n.n2s_order_key = o.order_number)
                   AND NOT (n.item_source IS DISTINCT FROM 'gmail'
                            AND public.sub_finder_need2buy(n.status, n.status_label, n.raw)))
         OR EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = o.order_number)) THEN
      v_note := 'n2s_order';                           -- anything in the N2S book is never bought here
    END IF;
    IF v_note IS NULL AND EXISTS (
         SELECT 1 FROM public.manual_sub_buy b
          WHERE b.sale_order_number = o.order_number
            AND b.state IN ('requested', 'buying', 'bought', 'unknown')) THEN
      v_note := 'already_bought_for_this_sale';        -- whatever site name the other request used
    END IF;
    IF v_note IS NULL THEN
      -- the purchase is decided on OUR copy of the order, not on what the caller sent
      -- (the marketplace's own order feed, or our mirror of the CRM marketplace book; never N2S's)
      IF NOT public.sub_finder_order_verified(o, ARRAY['api', 'marketplace'], true) THEN
        v_note := CASE WHEN (SELECT count(DISTINCT public.sub_finder_site_norm(l.site))
                               FROM public.sub_finder_lookup(o.order_number) l) = 1
                        AND EXISTS (SELECT 1 FROM public.sub_finder_lookup(o.order_number) l WHERE l.book <> 'n2s')
                       THEN 'differs_from_our_books' ELSE 'not_in_our_books' END;
      -- the sale must still be live on its marketplace
      ELSIF public.sub_finder_order_closed(o.order_number, o.site) IS NOT NULL THEN
        v_note := 'order_closed';
      END IF;
    END IF;
    IF v_note IS NULL THEN
      SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
        FROM public.manual_sub_buy b
       WHERE b.requested_by LIKE 'sub finder auto%' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
         AND (b.created_at AT TIME ZONE 'America/New_York')::date = v_today;
      IF v_spent + (cv->>'total')::numeric > c.auto_buy_daily_cap_usd THEN v_note := 'over_daily_cap'; END IF;
    END IF;
    IF v_note IS NULL THEN
      BEGIN
        v_buy := public.manual_sub_buy_request_market(cv->>'market',
          coalesce(o.site, 'CRM'), o.order_number, o.tevo_event_id, (cv->>'listing_id')::bigint,
          (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, o.sold_ea, o.event_name,
          'sub finder auto (key ' || coalesce(j.key_label, o.key_id::text) || ')',
          'auto: gate ' || (cv->>'gate') || ', sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
            || '; sub ' || (cv->>'section') || ' row ' || (cv->>'row') || ' x' || (cv->>'buy_qty')
            || ', quoted profit ' || (cv->>'profit'));
        v_n := v_n + 1;
      EXCEPTION WHEN unique_violation THEN
        v_note := 'already_bought_for_this_sale';
      END;
    END IF;
    UPDATE public.sub_finder_order
       SET buy_id = coalesce(v_buy, buy_id),
           action = CASE WHEN v_buy IS NOT NULL THEN 'auto_bought' ELSE action END,
           auto_buy_note = v_note,
           updated_at = CASE WHEN v_buy IS NOT NULL OR auto_buy_note IS DISTINCT FROM v_note THEN now()
                             ELSE updated_at END
     WHERE job_id = o.job_id AND idx = o.idx;
  END LOOP;
  RETURN v_n;
END
$function$;

-- the buy after a GoTickets customer accepts: an offer made before this rule is not bought
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_buy(p_offer_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config;
  r       public.sub_finder_gt_offer;
  o       public.sub_finder_order;
  v_note  text;
  v_buy   bigint;
  v_spent numeric;
  v_label text;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  PERFORM pg_advisory_xact_lock(hashtext('sub_finder_autobuy'));      -- one cap check + request at a time
  SELECT * INTO r FROM public.sub_finder_gt_offer WHERE offer_id = p_offer_id FOR UPDATE;
  IF NOT FOUND OR r.gt_status IS DISTINCT FROM 'ACCEPTED' OR r.buy_id IS NOT NULL OR r.buy_note IS NOT NULL THEN
    RETURN NULL;                                                      -- not accepted, or already decided
  END IF;
  SELECT * INTO o FROM public.sub_finder_order WHERE job_id = r.job_id AND idx = r.idx FOR UPDATE;
  v_note := CASE
    -- every switch above this one must be on too: the API, GoTickets offers, and this buy
    WHEN NOT (c.enabled AND c.gt_offer_enabled AND c.gt_offer_auto_buy) THEN 'auto_buy_off'
    WHEN NOT o.watching
      OR public.sub_finder_order_closed(r.order_number, 'GoTickets') IS NOT NULL
      THEN 'order_closed'
    WHEN public.sub_finder_report_only(r.order_number) THEN 'report_only'   -- 20261113250000
    -- 20261117020000: never an accessible seat for an ordinary one, or the other way round, even
    -- when the customer accepted an offer made before that rule
    WHEN public.sub_finder_seat_is_ada(o.section, o.seat_row)
         <> public.sub_finder_seat_is_ada(r.section, r.seat_row) THEN 'ada_seating'
    WHEN NOT public.sub_finder_market_buyable(r.market) THEN 'not_on_evo'
    WHEN r.buy_qty <> r.qty THEN 'needs_spare_ticket'
    WHEN o.buy_id IS NOT NULL
      OR EXISTS (SELECT 1 FROM public.manual_sub_buy b WHERE b.sale_order_number = r.order_number
                    AND b.state IN ('requested', 'buying', 'bought', 'unknown'))
      OR EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = r.order_number)
      THEN 'already_bought_for_this_sale'
  END;
  IF v_note IS NULL THEN
    SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
      FROM public.manual_sub_buy b
     WHERE b.requested_by LIKE 'sub finder auto%' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
       AND (b.created_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date;
    IF v_spent + r.price_ea * r.buy_qty > c.auto_buy_daily_cap_usd THEN v_note := 'over_daily_cap'; END IF;
  END IF;
  IF v_note IS NULL THEN
    SELECT key_label INTO v_label FROM public.sub_finder_job WHERE job_id = r.job_id;
    BEGIN
      v_buy := public.manual_sub_buy_request_market(r.market,
        'GoTickets', r.order_number, o.tevo_event_id, r.listing_id::bigint, r.buy_qty, r.price_ea, o.sold_ea,
        o.event_name, 'sub finder auto (gotickets offer accepted, key ' || coalesce(v_label, r.key_id::text) || ')',
        'customer accepted GoTickets substitution ' || r.gt_request_id || ' (gate ' || r.gate || '): sub '
          || r.section || ' row ' || r.seat_row || ' x' || r.buy_qty
          || coalesce(', rebate ' || r.rebate_amount, ''));
    EXCEPTION WHEN unique_violation THEN
      v_note := 'already_bought_for_this_sale';
    END;
  END IF;
  UPDATE public.sub_finder_gt_offer SET buy_id = v_buy, buy_note = v_note, updated_at = now() WHERE offer_id = p_offer_id;
  UPDATE public.sub_finder_order
     SET buy_id = coalesce(v_buy, buy_id), action = CASE WHEN v_buy IS NOT NULL THEN 'auto_bought' ELSE action END,
         updated_at = now()
   WHERE job_id = r.job_id AND idx = r.idx;
  RETURN coalesce(v_note, 'buy_requested');
END
$function$;

REVOKE ALL ON FUNCTION public.sub_finder_match(uuid, boolean), public.sub_finder_buy(bigint, text, uuid, text, text, text),
  public.sub_finder_gt_offer_request(bigint, text, text, text, text, text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_match(uuid, boolean), public.sub_finder_buy(bigint, text, uuid, text, text, text),
  public.sub_finder_gt_offer_request(bigint, text, text, text, text, text, numeric) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_seat_is_ada(text, text) TO service_role;

NOTIFY pgrst, 'reload schema';
