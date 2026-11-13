CREATE OR REPLACE FUNCTION public.sub_finder_offer_json(o sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' THEN NULL
    WHEN r.offer_id IS NULL AND coalesce((o.best->>'gate')::int, 0) < 3
         AND NOT (public.sub_finder_cover_flags(o.best) ? 'single_ticket_row_differs') THEN NULL
    ELSE jsonb_build_object(
      'via', 'gotickets',
      -- true: tell us yes with POST /orders/{n}/offer-sub and this listing_id
      'ask_crm', r.offer_id IS NULL AND o.watching AND o.order_source IN ('api', 'n2s', 'marketplace')
                 AND ((o.best->>'gate')::int IN (3, 4, 5)
                      OR public.sub_finder_cover_flags(o.best) ? 'single_ticket_row_differs'),
      -- true: you may skip the offer and buy the cover outright (buy route, "confirm": true)
      'bypass_allowed', r.offer_id IS NULL AND coalesce((o.best->>'offer_bypass')::boolean, false),
      'results_only', r.offer_id IS NULL AND (o.best->>'gate')::int = 6,
      'gate', coalesce(r.gate, (o.best->>'gate')::int),
      'market', coalesce(r.market, o.best->>'market'),
      'listing_id', coalesce(r.listing_id, o.best->>'listing_id'),
      'section', coalesce(r.section, o.best->>'section'), 'row', coalesce(r.seat_row, o.best->>'row'),
      -- the rebate is yours to set: `rebate` is what was offered; before that, `rebate_needed`
      -- says an amount must come with the yes (rows back) and `rebate_suggested` is sale - sub
      'rebate', r.rebate_amount,
      'rebate_needed', r.offer_id IS NULL AND (o.best->>'gate')::int = 5,
      'rebate_suggested', CASE WHEN r.offer_id IS NULL AND (o.best->>'gate')::int IN (3, 4, 5)
                               THEN greatest((o.best->>'profit')::numeric, 0) END,
      'request', CASE WHEN r.offer_id IS NOT NULL THEN jsonb_build_object(
                   'offer_id', r.offer_id, 'state', r.state, 'reasons', r.reasons,
                   'gotickets_request_id', r.gt_request_id, 'status', r.gt_status,
                   'denial_reason', r.denial_reason, 'status_checked_at', r.status_checked_at,
                   -- after ACCEPTED: 'buy_requested' (see the order's `buy`) or why we did not buy
                   'buy', CASE WHEN r.buy_id IS NOT NULL THEN 'buy_requested' ELSE r.buy_note END,
                   'final_at', r.final_at) END,
      -- the customer said yes: `accepted` flips true (the order's updated_at moves, so it comes
      -- back in the sync feed). `accepted_next` says what happens to the seats:
      --   'buy_requested'   we are buying EVO seats (see the order's `buy`)
      --   'buy_manually'    the offered seats are still listed and we cannot buy them: buy them yourselves
      --   'new_sub_needed'  the offered seats are gone (`offered_gone`) and no one-to-one EVO cover
      --                     was there to buy: `new_best` is the best cover now, with its gate
      'accepted', coalesce(r.gt_status = 'ACCEPTED', false),
      'accepted_at', CASE WHEN r.gt_status = 'ACCEPTED'
                          THEN to_char(r.final_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') END,
      'offered_gone', gn.gone,
      'accepted_next', CASE WHEN r.gt_status IS DISTINCT FROM 'ACCEPTED' THEN NULL
                            WHEN r.buy_id IS NOT NULL OR o.buy_id IS NOT NULL THEN 'buy_requested'
                            WHEN coalesce(gn.gone, false) THEN 'new_sub_needed'
                            ELSE 'buy_manually' END,
      'new_best', CASE WHEN r.gt_status = 'ACCEPTED' AND coalesce(gn.gone, false) AND o.best IS NOT NULL
                       THEN jsonb_build_object(
                              'market', o.best->>'market', 'listing_id', o.best->>'listing_id',
                              'section', o.best->>'section', 'row', o.best->>'row',
                              'gate', (o.best->>'gate')::int, 'label', o.best->>'label',
                              'buy_qty', (o.best->>'buy_qty')::int, 'total', (o.best->>'total')::numeric,
                              'profit', (o.best->>'profit')::numeric) END)
  END
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT g.* FROM public.sub_finder_gt_offer g
                      WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                      ORDER BY g.live DESC, g.offer_id DESC LIMIT 1) r ON true
  LEFT JOIN LATERAL (SELECT public.sub_finder_offer_gone(r, o.tevo_event_id) AS gone WHERE r.offer_id IS NOT NULL) gn ON true;
$function$

