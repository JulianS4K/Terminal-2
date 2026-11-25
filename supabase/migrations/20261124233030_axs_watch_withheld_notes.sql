-- Migration 20261124233030 · level:data-collection · lane:A1 (data plane; the AXS watch, routed to this session by the operator) · writes:axs_watch_parse()(replaced),primary_poll_listing(AXS rows: non-transferable removed, limited and side view marked obstructed),primary_poll_listing_piece(rows of those listings),primary_poll_event(counts recomputed for those events) · reads:axs_watch_poll,net._http_response · pre:20261124230000 (the AXS Premium rule, PR 1197: this file carries its clause, so either order of merge is right),20261124230030
--
-- THE AXS WATCH WITHHOLDS SEATS WITH A LIMITED OR SIDE VIEW, AND SEATS THAT CANNOT BE TRANSFERRED.
-- Operator 2026-11-24: "look at the axs and see if it has notes per listing like limited view etc, also note when it
-- says non-transferable"; on the findings: "go, withhold side view too".
--
-- What a listing carries (120 events, 52,102 listings read 2026-11-24): `offer_name` (the box office's offer),
-- `price_code` (resale), `price_level`, `status` (the venue's seat label) and `seller_notes` (resale, rarely filled).
--   NOT TRANSFERABLE: 59 box-office listings (547 seats) over 15 Red Rocks events, rows 2 to 4, said so in the offer's
--   name and nowhere else ("Sublime - Rows 2 to 4 Non Transferable"). They were sent like any seat. A seat we cannot
--   transfer cannot be a sub, so such a listing is now left out of the parse, as a parking offer is.
--   LIMITED VIEW: 26 resale listings (83 seats) at MGM Grand Garden carried `price_code` "Limited View". The parser
--   looked for it in `price_level` and `seller_notes` only, so they were sent as full-view seats, and no AXS listing
--   had ever been marked obstructed. SIDE VIEW: 84 resale listings (262 seats) at Toyota Center, `price_code` "Adult
--   SIDE VIEW". Both are now marked obstructed, in whichever label says so, and the feed never sends an obstructed
--   listing (operator 2026-11-23: "also dont send obstructed out"); they stay in the history as obstructed.
-- VIP and merchandise packages (604 listings) are not touched: the operator was asked and did not name them.
--
-- The rows already stored: for each event whose last good read is still in net._http_response, that read is parsed
-- again; a stored listing the parse no longer returns is removed, one it now marks is marked, and the event's counts
-- are recomputed as primary_poll_ingest() computes them. An event whose response is gone is corrected at its next
-- read; until then its listings are past their age limit and not sent.
--
-- Applied to prod via MCP 2026-11-24 (operator: "go, withhold side view too"): the function first (23:47 UTC), the
-- correction of the stored rows after it; re-apply is a no-op.
--
-- rollback: re-apply axs_watch_parse() from 20261124230000; the rows return at each event's next read.

CREATE OR REPLACE FUNCTION public.axs_watch_parse(p_body jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH raw AS (
    SELECT l
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'listings') = 'array' THEN p_body->'listings' ELSE '[]'::jsonb END) l
     WHERE coalesce(l->>'kind', 'primary') IN ('primary', 'resale')
       -- `status` is the venue's own seat-status label (Available, CA-OPEN, CA-ADA OPEN, AXS VIP 1, ...): only an
       -- explicitly sold / held / unavailable label leaves a listing out
       AND coalesce(l->>'status', '') !~* 'sold|\mhold\M|held|unavail|not available|killed'
       AND coalesce(l->>'offer_name', '') !~* 'parking|\mpass\M|upgrade'
       -- AXS Premium is priced per seat on the page; the body carries only the price level, so the seat is not shared
       AND NOT (coalesce(l->>'kind', 'primary') = 'primary'
                AND (coalesce(l->>'seat_type', '') ~* 'premium' OR coalesce(l->>'status', '') ~* 'axs premium'))
       -- a seat that cannot be transferred cannot be passed on to a customer. AXS has no flag for it: the offer says
       -- so in its name ("Rows 2 to 4 Non Transferable" at Red Rocks); the other labels are read too
       AND concat_ws(' | ', l->>'offer_name', l->>'price_code', l->>'price_level', l->>'status', l->>'seller_notes')
           !~* 'non[- ]?transfer|no[- ]transfer|not[- ]transfer|cannot be transferred|transfers?[- ](disabled|restricted)'
       AND coalesce(nullif(l->>'quantity', '')::integer,
                    CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN jsonb_array_length(l->'seats') END, 0) > 0),
  rows AS (
    SELECT coalesce(l->>'kind', 'primary') AS market, l->>'section' AS section, l->>'row' AS seat_row,
           CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN l->'seats' END AS seats,
           coalesce(nullif(l->>'quantity', '')::integer, CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN jsonb_array_length(l->'seats') END) AS qty,
           CASE WHEN jsonb_typeof(l->'purchasable_quantities') = 'array' THEN l->'purchasable_quantities' END AS allowed,
           nullif(l->'pricing'->>'face', '')::numeric AS price,
           coalesce(nullif(l->'pricing'->>'fees_total', '')::numeric, nullif(l->'pricing'->>'connection_fee', '')::numeric) AS fee,
           nullif(l->'pricing'->>'all_in', '')::numeric AS all_in,
           nullif(l->'pricing'->>'tax', '')::numeric AS tax,
           l->>'neighborhood' AS area, l->>'seat_type' AS ticket_type,
           coalesce((l->>'general_admission')::boolean, false) AS ga,
           (coalesce(l->>'seat_type', '') ~* 'ada|wheelchair' OR coalesce(l->>'price_level', '') ~* '\mada\M|wheelchair|accessible') AS ada,
           -- a view that is not whole, in any label the listing carries: the price level, the price code (where AXS
           -- resale puts "Limited View" and "SIDE VIEW"), the offer, the seat status or the seller's note. A note that
           -- says the view is unobstructed is not one
           regexp_replace(concat_ws(' | ', l->>'price_level', l->>'price_code', l->>'offer_name', l->>'status', l->>'seller_notes'),
                          'unobstructed|un-obstructed|not obstructed|no obstructions?|without obstructions?', '', 'gi')
             ~* '(limited|partial|restricted|obstructed|side)[- ]?view|obstruct' AS obstructed,
           l->>'offer_id' AS offer_id
      FROM raw),
  listings AS (
    SELECT jsonb_strip_nulls(jsonb_build_object(
             'id', abs(hashtextextended(concat_ws('|', r.offer_id, r.market, r.section, r.seat_row, r.ticket_type,
                                                       coalesce(r.seats::text, r.qty::text), r.price::text), 0))::text,
             'market', r.market, 'section', r.section, 'row', r.seat_row,
             'seat_low', r.seats->>0, 'seat_high', r.seats->>-1, 'seats', r.seats, 'qty', r.qty,
             'allowed_quantities', r.allowed, 'price', r.price, 'fee', r.fee, 'all_in', r.all_in, 'tax', r.tax,
             'price_includes_tax', false, 'area', r.area, 'ticket_type', r.ticket_type,
             'ada', r.ada, 'obstructed', r.obstructed, 'ga', r.ga)) AS l,
           r.price, r.qty
      FROM rows r),
  groups AS (
    SELECT nullif(g->'ticket_qty'->>'min', '')::integer AS omin, nullif(g->'ticket_qty'->>'max', '')::integer AS omax
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'groups') = 'array' THEN p_body->'groups' ELSE '[]'::jsonb END) g)
  SELECT jsonb_build_object(
           'listings', coalesce((SELECT jsonb_agg(l.l ORDER BY l.l->>'section', l.l->>'row', l.l->>'id') FROM listings l), '[]'::jsonb),
           'price_min', (SELECT min(price) FROM listings),
           'price_max', (SELECT max(price) FROM listings),
           'total_available', (SELECT coalesce(sum(qty), 0) FROM listings),
           'order_min', (SELECT min(omin) FROM groups WHERE omin > 0),
           'order_max', (SELECT max(omax) FROM groups),
           'offer_id', nullif(p_body->'onsale'->>'offer_id', ''),
           'on_sale_now', (p_body->'onsale'->'status'->>'onSaleNow')::boolean,
           'summary', p_body->'listings_summary')
$function$;

REVOKE ALL ON FUNCTION public.axs_watch_parse(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_parse(jsonb) TO service_role;

DO $$
DECLARE
  r record; v_body jsonb; v_new jsonb; n integer; v_gone integer := 0; v_marked integer := 0; v_events integer := 0;
BEGIN
  CREATE TEMP TABLE axs_notes_touched (source_event_id text PRIMARY KEY) ON COMMIT DROP;
  FOR r IN
    SELECT x.axs_event_id, x.checked_at, h.content
      FROM (SELECT DISTINCT ON (p.axs_event_id) p.axs_event_id, p.request_id, p.outcome, p.checked_at
              FROM public.axs_watch_poll p
             WHERE p.checked_at IS NOT NULL
             ORDER BY p.axs_event_id, p.checked_at DESC) x
      JOIN net._http_response h ON h.id = x.request_id AND h.status_code = 200
      JOIN public.primary_poll_event e ON e.source = 'axs' AND e.source_event_id = x.axs_event_id
     WHERE x.outcome = 'ok' AND e.poll_status = 'ok'
       AND e.poll_ok_at BETWEEN x.checked_at - interval '2 minutes' AND x.checked_at + interval '2 minutes'
  LOOP
    -- every such read is parsed again (a tenth of a second each). Searching the raw answers for the words first was
    -- tried and is what is slow: a case-blind pattern over 100 MB of text ran for five minutes on prod and was cancelled
    v_body := public.safe_jsonb(r.content)->'body';
    v_new := public.axs_watch_parse(v_body)->'listings';
    CONTINUE WHEN v_new IS NULL OR jsonb_typeof(v_new) <> 'array';
    DELETE FROM public.primary_poll_listing l
     WHERE l.source = 'axs' AND l.source_event_id = r.axs_event_id
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_new) x(l) WHERE x.l->>'id' = l.listing_id)
       -- still the rows of that read: the watch may have read the event again since this loop began
       AND EXISTS (SELECT 1 FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = r.axs_event_id
                      AND e.poll_ok_at BETWEEN r.checked_at - interval '2 minutes' AND r.checked_at + interval '2 minutes');
    GET DIAGNOSTICS n = ROW_COUNT;
    v_gone := v_gone + n;
    IF n > 0 THEN INSERT INTO axs_notes_touched VALUES (r.axs_event_id) ON CONFLICT DO NOTHING; END IF;
    UPDATE public.primary_poll_listing l SET obstructed = true
     WHERE l.source = 'axs' AND l.source_event_id = r.axs_event_id AND NOT l.obstructed
       AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_new) x(l) WHERE x.l->>'id' = l.listing_id AND (x.l->>'obstructed')::boolean)
       AND EXISTS (SELECT 1 FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = r.axs_event_id
                      AND e.poll_ok_at BETWEEN r.checked_at - interval '2 minutes' AND r.checked_at + interval '2 minutes');
    GET DIAGNOSTICS n = ROW_COUNT;
    v_marked := v_marked + n;
    IF n > 0 THEN INSERT INTO axs_notes_touched VALUES (r.axs_event_id) ON CONFLICT DO NOTHING; END IF;
  END LOOP;
  DELETE FROM public.primary_poll_listing_piece p
   USING public.primary_poll_listing l
   WHERE l.source = p.source AND l.source_event_id = p.source_event_id AND l.listing_id = p.listing_id
     AND l.source = 'axs' AND l.obstructed;
  UPDATE public.primary_poll_event t
     SET listing_count   = coalesce(a.n, 0),
         median_price    = a.median,
         listed_quantity = coalesce(a.qty, 0),
         total_available = coalesce(a.total, 0),
         price_min       = a.pmin,
         price_max       = a.pmax
    FROM (SELECT g.source_event_id,
                 count(l.listing_id) FILTER (WHERE NOT l.obstructed) AS n,
                 round((percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(l.all_in_price, l.price)) FILTER (WHERE NOT l.obstructed))::numeric, 2) AS median,
                 sum(l.quantity) FILTER (WHERE NOT l.obstructed) AS qty,
                 sum(l.quantity) AS total, min(l.price) AS pmin, max(l.price) AS pmax
            FROM axs_notes_touched g
            LEFT JOIN public.primary_poll_listing l ON l.source = 'axs' AND l.source_event_id = g.source_event_id
           GROUP BY g.source_event_id) a
   WHERE t.source = 'axs' AND t.source_event_id = a.source_event_id AND t.poll_status = 'ok';
  GET DIAGNOSTICS v_events = ROW_COUNT;
  RAISE NOTICE 'axs watch: % non-transferable listings removed, % limited or side view listings marked, % events recomputed', v_gone, v_marked, v_events;
END $$;
