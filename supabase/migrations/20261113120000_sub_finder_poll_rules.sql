-- Migration 20261113120000 · level:secondary-sales · lane:D0 · writes:n2s_sg_polled,n2s_pull_events,sub_finder_offer_pending,sub_finder_submit,sub_finder_refresh,sub_finder_offer_gone,sub_finder_offer_json,sub_finder_gt_offer_follow_record,sub_finder_order_json · reads:n2s_mkt_pull,sub_finder_gt_offer · pre:20261113060000
--
-- POLLING RULES: N2S asks SeatGeek once per event; the sub finder keeps asking; an order
-- with a GoTickets sub offer out is not polled.
--
-- Operator 2026-11-13: "stop n2s from polling sg after the first poll but allow this [the sub
-- finder] to do so, stop polling if subs are offered on gotickets".
--
--   n2s_sg_polled     one row per SeatGeek event that has had a listings pull from
--                     n2s_pull_events (first / last time, count). n2s_mkt_pull cannot say
--                     this: it keeps 3 days. Seeded from what n2s_mkt_pull still holds.
--   n2s_pull_events   a 3-argument version (events, refresh, p_sg_repeat) now does the work.
--                     With p_sg_repeat false, a SeatGeek event already in n2s_sg_polled is
--                     skipped, whoever made that first pull. The 2-argument function every
--                     N2S caller uses (n2s_pull_all_sources, n2s_hub_quick_map,
--                     inbox_n2b_pull) is kept by name and now just calls it with false, so
--                     no caller is edited and nothing is dropped. EVO, GoTickets and
--                     TicketsData are untouched. Otherwise the body is prod's, byte for byte
--                     (checked by md5 against pg_get_functiondef on 2026-11-13).
--   sub_finder_submit, sub_finder_refresh
--                     pass p_sg_repeat = true: the sub finder pulls SeatGeek on every round,
--                     paced by pull_refresh like the other two markets.
--   sub_finder_refresh also skips an order whose GoTickets sub offer is still PENDING
--                     (sub_finder_offer_pending: a live offer GoTickets has not shown as
--                     accepted — requested, sending, sent or unknown): its event is not pulled
--                     for it and its covers are not re-matched, so what the customer is being
--                     offered stays what the order shows. It resumes by itself when the offer
--                     is stopped, denied or cancelled, AND when it is accepted (operator: "If
--                     offer for go Tix is accepted resume polling and if subs on evo autobuy").
--                     The order is still closed as before (event passed, sale over, left N2S).
--                     Another watched order on the same event still gets that event pulled.
--   after an acceptance (operator: "When gotickets subs are accepted only buy if 1-1 index
--                     conditions in cases where original quoted subs are gone, and if other
--                     gates report back to crm and give new best subs and gate"):
--                     * the offered seats are an EVO listing: bought at once, as before
--                       (sub_finder_gt_offer_buy, unchanged);
--                     * the offered seats are GONE (that buy stopped, or the listing is no
--                       longer in the market's fresh pull): nothing else is bought on the
--                       strength of the acceptance. The order is back in the normal re-match,
--                       so the standing automatic one-to-one rule (sub_finder_autobuy: an EVO
--                       cover in the ORIGINAL section, same row or better, exact quantity,
--                       breakeven or better / inside auto_buy_max_loss_pct) is the only thing
--                       that can buy. sub_finder_refresh releases a stopped offer buy from the
--                       order so that rule can run;
--                     * any other gate is reported, not bought: `sub_offer.offered_gone` is
--                       true, `accepted_next` is 'new_sub_needed' and `new_best` carries the
--                       new best cover and its gate (the order's `best` / `covers` too).
--   sub_finder_offer_gone
--                     true when the offered listing is not in its market's current pull for
--                     the event although that market has been pulled since the acceptance.
--   sub_finder_offer_json
--                     the acceptance as fields the CRM reads: `accepted`, `accepted_at`,
--                     `offered_gone`, `accepted_next` ('buy_requested' / 'buy_manually' /
--                     'new_sub_needed') and `new_best`. No call out to the CRM: the acceptance
--                     moves the order's updated_at, so the order comes back in the sync feed
--                     (GET /results?updated_since=) carrying these fields. The body is
--                     20261113100000's (the rebate fields) plus these, so the two migrations
--                     can be applied in either order.
--   sub_finder_order_json
--                     as 20261113080000, except `action`: after an acceptance, while the
--                     offered seats are still there and nothing is bought, 'offer' reads
--                     'buy_manually' (the customer has already said yes). Everything else in
--                     the order is sent as normal: best, covers, markets, buy.
--   sub_finder_gt_offer_follow_record
--                     operator: "If offer denied check order status before repolling". When
--                     GoTickets shows the offer DENIED or CANCELLED, the sale is checked first:
--                     the worker reads it fresh from GoTickets (a GET, core/gt_sub_offer.py)
--                     and sends 'sale_closed' when it is cancelled or delivered; our own copy
--                     of the order (sub_finder_order_closed) is checked too. A sale that is
--                     over closes the lookup (order_cancelled / order_fulfilled) and is not
--                     polled again; a live sale goes back to the normal polling.
--
-- Read paths only: every request these functions send is a GET (RULE 2).
--
-- rollback: re-apply sub_finder_submit and sub_finder_refresh from 20261113060000;
--           re-create the 2-argument n2s_pull_events with its own body (the 3-argument body without
--           the p_sg_repeat line and the n2s_sg_polled insert), then DROP FUNCTION
--           public.n2s_pull_events(bigint[], interval, boolean);
--           DROP FUNCTION public.sub_finder_offer_pending(text, bigint); DROP TABLE public.n2s_sg_polled;

CREATE TABLE IF NOT EXISTS public.n2s_sg_polled (
  sg_event_id   bigint PRIMARY KEY,
  tevo_event_id bigint,
  first_at      timestamptz NOT NULL DEFAULT now(),
  last_at       timestamptz NOT NULL DEFAULT now(),
  polls         integer     NOT NULL DEFAULT 1
);
ALTER TABLE public.n2s_sg_polled ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_sg_polled FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.n2s_sg_polled IS
  'SeatGeek events that have had a listings pull from n2s_pull_events (20261113120000). N2S pulls a '
  'SeatGeek event once: a row here stops a second pull unless the caller passes p_sg_repeat (the sub finder).';

INSERT INTO public.n2s_sg_polled (sg_event_id, tevo_event_id, first_at, last_at, polls)
SELECT q.mkt_event_id, max(q.tevo_event_id), min(q.fired_at), max(q.fired_at), count(*)
  FROM public.n2s_mkt_pull q WHERE q.source = 'seatgeek' GROUP BY q.mkt_event_id
ON CONFLICT (sg_event_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.n2s_pull_events(p_events bigint[], p_refresh_after interval, p_sg_repeat boolean)
 RETURNS TABLE(evo_fired integer, gt_fired integer, sg_queued integer, td_queued integer, evo_skipped_fresh integer, gt_skipped_fresh integer, evo_skipped_unknown integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_tok text; v_sec text; v_q text; v_req bigint;
  v_evo int := 0; v_gt int := 0; v_sg int := 0; v_td int := 0;
  v_evo_known int := 0; v_gt_cand int := 0; v_evo_unknown int := 0;
  -- another poller hit this event this recently -> skip (rate-limit guard)
  v_shared interval := interval '60 seconds';
BEGIN
  IF p_events IS NULL OR cardinality(p_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 0; RETURN;
  END IF;

  SELECT count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e)),
         count(*) FILTER (WHERE EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e))
    INTO v_evo_unknown, v_evo_known
    FROM unnest(p_events) AS e;

  -- EVO: signed GET /v9/ticket_groups (read-only), one call = whole event
  v_tok := public.get_app_secret('TEVO_API_TOKEN');
  v_sec := public.get_app_secret('TEVO_SECRET');
  IF COALESCE(v_tok, '') <> '' AND COALESCE(v_sec, '') <> '' THEN
    FOR r IN
      SELECT DISTINCT e AS eid FROM unnest(p_events) AS e
       WHERE EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e)
         AND NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                          WHERE q.source = 'evo' AND q.mkt_event_id = e
                            AND (q.resolved_at IS NULL OR q.fired_at >= now() - p_refresh_after))
         AND NOT EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                          WHERE ps.event_id = e AND ps.last_polled_listings_at >= now() - v_shared)
    LOOP
      v_q := 'event_id=' || r.eid::text;
      SELECT net.http_get(
        url := 'https://api.ticketevolution.com/v9/ticket_groups?' || v_q,
        headers := jsonb_build_object(
          'X-Token', v_tok,
          'X-Signature', encode(extensions.hmac('GET api.ticketevolution.com/v9/ticket_groups?' || v_q, v_sec, 'sha256'), 'base64'),
          'Accept', 'application/vnd.ticketevolution.api+json; version=9'),
        timeout_milliseconds := 30000) INTO v_req;
      INSERT INTO public.n2s_mkt_pull(request_id, source, tevo_event_id, mkt_event_id)
      VALUES (v_req, 'evo', r.eid, r.eid);
      INSERT INTO public.evo_listings_poll_state(
               event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.eid, now(), 1, current_date)
      ON CONFLICT (event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
      v_evo := v_evo + 1;
    END LOOP;
  END IF;

  -- GoTickets
  v_tok := public._gotickets_pro_token();
  IF COALESCE(btrim(v_tok), '') <> '' THEN
    SELECT count(*) INTO v_gt_cand
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
     WHERE g.tevo_event_id = ANY(p_events)
       AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now());

    FOR r IN
      SELECT g.gt_event_id, g.tevo_event_id
        FROM public.gotickets_event g
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.tevo_event_id = ANY(p_events)
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
         AND (ps.last_polled_listings_at IS NULL OR ps.last_polled_listings_at < now() - v_shared)
         AND NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                          WHERE q.source = 'gotickets' AND q.mkt_event_id = g.gt_event_id
                            AND (q.resolved_at IS NULL OR q.fired_at >= now() - p_refresh_after))
    LOOP
      SELECT net.http_get(
        url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
        headers := jsonb_build_object('X-Broker-Api-Token', v_tok, 'Accept', 'application/json'),
        timeout_milliseconds := 30000) INTO v_req;
      INSERT INTO public.n2s_mkt_pull(request_id, source, tevo_event_id, mkt_event_id)
      VALUES (v_req, 'gotickets', r.tevo_event_id, r.gt_event_id);
      INSERT INTO public.gt_listings_poll_state(
               gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.gt_event_id, now(), 1, current_date)
      ON CONFLICT (gt_event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
      v_gt := v_gt + 1;
    END LOOP;
  END IF;

  -- SeatGeek: register hub-resolved events (fires nothing: p_max_events = 0),
  -- then fire our own request per event. Unless p_sg_repeat (the sub finder), an event that
  -- has had its SeatGeek pull (n2s_sg_polled) is not pulled again: N2S asks SeatGeek once.
  BEGIN
    PERFORM * FROM public.sg_listings_pull_on_demand(p_events, 0, p_refresh_after);
    v_tok := public.get_app_secret('SEATGEEK_API_TOKEN');
    IF COALESCE(v_tok, '') <> '' THEN
      FOR r IN
        WITH want AS (SELECT DISTINCT x AS tevo_event_id FROM unnest(p_events) AS x),
        resolved AS (
          SELECT w.tevo_event_id,
                 COALESCE(
                   (SELECT c.sg_event_id FROM public.sg_events_canonical c
                     WHERE c.tevo_event_id = w.tevo_event_id ORDER BY c.sg_event_id LIMIT 1),
                   (SELECT a.sg_event_id FROM public.aq_event_map a
                     WHERE a.tevo_event_id = w.tevo_event_id AND a.sg_event_id IS NOT NULL
                     ORDER BY a.sg_event_id LIMIT 1),
                   -- mig 20260928190000: our own SeatGeek orders for the event,
                   -- only when they all agree on one SeatGeek event
                   (SELECT min(o.sg_event_id) FROM public.seatgeek_orders o
                     WHERE o.tevo_event_id = w.tevo_event_id AND o.sg_event_id IS NOT NULL
                    HAVING count(DISTINCT o.sg_event_id) = 1)) AS sg_event_id
            FROM want w)
        SELECT rs.tevo_event_id, rs.sg_event_id
          FROM resolved rs
         WHERE rs.sg_event_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM public.n2s_sg_expired x WHERE x.sg_event_id = rs.sg_event_id)
           AND (p_sg_repeat OR NOT EXISTS (SELECT 1 FROM public.n2s_sg_polled sp WHERE sp.sg_event_id = rs.sg_event_id))
           AND EXISTS (SELECT 1 FROM public.sg_events_canonical c WHERE c.sg_event_id = rs.sg_event_id)
           AND NOT EXISTS (SELECT 1 FROM public.sg_event_priority_state ps
                            WHERE ps.sg_event_id = rs.sg_event_id
                              AND ps.last_polled_listings_at >= now() - v_shared)
           AND NOT EXISTS (SELECT 1 FROM public.sg_broker_pending b
                            WHERE b.scope = 'listings' AND b.sg_event_id = rs.sg_event_id
                              AND b.fired_at >= now() - v_shared)
           AND NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull q
                            WHERE q.source = 'seatgeek' AND q.mkt_event_id = rs.sg_event_id
                              AND (q.resolved_at IS NULL OR q.fired_at >= now() - p_refresh_after))
      LOOP
        SELECT net.http_get(
          url := 'https://brokerdata.seatgeek.com/listings?token=' || v_tok
                 || '&event_id=' || r.sg_event_id::text,
          timeout_milliseconds := 30000) INTO v_req;
        INSERT INTO public.n2s_mkt_pull(request_id, source, tevo_event_id, mkt_event_id)
        VALUES (v_req, 'seatgeek', r.tevo_event_id, r.sg_event_id);
        INSERT INTO public.n2s_sg_polled AS sp (sg_event_id, tevo_event_id)
        VALUES (r.sg_event_id, r.tevo_event_id)
        ON CONFLICT (sg_event_id) DO UPDATE SET last_at = now(), polls = sp.polls + 1;
        UPDATE public.sg_event_priority_state
           SET last_polled_listings_at = now(),
               listings_polls_today    = listings_polls_today + 1
         WHERE sg_event_id = r.sg_event_id;
        v_sg := v_sg + 1;
      END LOOP;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_events: seatgeek failed: %', SQLERRM;
  END;

  BEGIN
    SELECT events_enqueued INTO v_td FROM public.n2s_td_enqueue(cardinality(p_events));
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_events: ticketsdata enqueue failed: %', SQLERRM;
    v_td := 0;
  END;

  RETURN QUERY SELECT v_evo, v_gt, v_sg, COALESCE(v_td,0),
                      GREATEST(v_evo_known - v_evo, 0), GREATEST(v_gt_cand - v_gt, 0), v_evo_unknown;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_pull_events(bigint[], interval, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_pull_events(bigint[], interval, boolean) TO service_role;

-- The 2-argument function every N2S caller uses keeps its name, arguments and grants, and now
-- only hands over with p_sg_repeat = false: N2S asks SeatGeek once per event.
CREATE OR REPLACE FUNCTION public.n2s_pull_events(p_events bigint[], p_refresh_after interval DEFAULT '00:05:00'::interval)
 RETURNS TABLE(evo_fired integer, gt_fired integer, sg_queued integer, td_queued integer, evo_skipped_fresh integer, gt_skipped_fresh integer, evo_skipped_unknown integer)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
  SELECT * FROM public.n2s_pull_events(p_events, p_refresh_after, false);
$function$;

-- Is a GoTickets sub offer out for this order and not yet accepted? (requested, sending, sent, unknown)
CREATE OR REPLACE FUNCTION public.sub_finder_offer_pending(p_order_number text, p_key_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g
                  WHERE g.order_number = p_order_number AND g.key_id = p_key_id AND g.live
                    AND g.gt_status IS DISTINCT FROM 'ACCEPTED');
$$;
REVOKE ALL ON FUNCTION public.sub_finder_offer_pending(text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_offer_pending(text, bigint) TO service_role;

CREATE OR REPLACE FUNCTION public.sub_finder_submit(
  p_key_id bigint, p_key_label text, p_orders jsonb, p_idempotency_key text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c       public.sub_finder_config;
  v_job   uuid;
  v_n     integer;
  v_evs   bigint[];
  v_miss  jsonb;
  v_idem  text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT (p_key_id = ANY (c.key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF v_idem IS NOT NULL THEN
    SELECT job_id INTO v_job FROM public.sub_finder_job WHERE key_id = p_key_id AND idempotency_key = v_idem;
    IF FOUND THEN
      RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                        'created_at', j.created_at, 'replayed', true)
              FROM public.sub_finder_job j WHERE j.job_id = v_job);
    END IF;
  END IF;
  IF jsonb_typeof(p_orders) IS DISTINCT FROM 'array' OR jsonb_array_length(p_orders) = 0 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'orders must be a non-empty array');
  END IF;
  IF jsonb_array_length(p_orders) > c.max_orders_per_job THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', format('at most %s orders per job', c.max_orders_per_job));
  END IF;

  IF to_regclass('pg_temp._sf_in') IS NOT NULL THEN DROP TABLE _sf_in; END IF;
  CREATE TEMP TABLE _sf_in ON COMMIT DROP AS
  SELECT o.ord::int AS idx, btrim(o.j->>'order_number') AS order_number,
         coalesce(nullif(btrim(o.j->>'site'), ''), m.site)                 AS site,
         coalesce(nullif(btrim(o.j->>'section'), ''), m.section)           AS section,
         coalesce(nullif(btrim(o.j->>'row'), ''), m.seat_row)              AS seat_row,
         coalesce((o.j->>'qty')::int, m.qty)                               AS qty,
         coalesce((o.j->>'sold_ea')::numeric, m.sold_ea)                   AS sold_ea,
         (o.j->>'tevo_event_id')::bigint                                   AS sent_event,
         m.tevo_event_id                                                   AS book_event,
         coalesce(nullif(btrim(o.j->>'event_name'), ''), m.event_name)     AS event_name,
         coalesce((o.j->>'event_date')::date, m.event_date)                AS event_date,
         coalesce(nullif(btrim(o.j->>'venue'), ''), m.venue)               AS venue,
         m.book
  FROM jsonb_array_elements(p_orders) WITH ORDINALITY o(j, ord)
  -- the marketplace's own order feed first, then our mirror of the CRM's books
  LEFT JOIN LATERAL public.sub_finder_lookup_best(btrim(o.j->>'order_number'), nullif(btrim(o.j->>'site'), '')) m ON true;

  SELECT jsonb_agg(order_number ORDER BY idx) INTO v_miss FROM _sf_in
   WHERE section IS NULL OR seat_row IS NULL OR qty IS NULL OR qty NOT BETWEEN 1 AND 50;
  SELECT count(*) INTO v_n FROM _sf_in
   WHERE section IS NOT NULL AND seat_row IS NOT NULL AND qty BETWEEN 1 AND 50;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('error', 'not_found', 'not_found', v_miss,
      'detail', 'none of these orders is in the CRM books we mirror; send section, row, qty and the event');
  END IF;

  INSERT INTO public.sub_finder_job (key_id, key_label, idempotency_key, order_count)
  VALUES (p_key_id, p_key_label, v_idem, v_n) RETURNING job_id INTO v_job;

  INSERT INTO public.sub_finder_order (job_id, idx, key_id, order_number, site, tevo_event_id, event_name,
                                       event_date, venue, section, seat_row, qty, sold_ea, state, order_source)
  SELECT v_job, i.idx, p_key_id, i.order_number, i.site, ev.id, coalesce(ev.name, i.event_name),
         coalesce(ev.occurs_at_local::date, i.event_date), i.venue, i.section, i.seat_row, i.qty, i.sold_ea,
         CASE WHEN ev.id IS NULL THEN 'unmapped' ELSE 'pending' END,
         coalesce(i.book, 'request')
  FROM _sf_in i
  LEFT JOIN LATERAL (
    SELECT e.id, e.name, e.occurs_at_local
    FROM public.events e
    WHERE CASE WHEN i.sent_event IS NOT NULL THEN e.id = i.sent_event
               WHEN i.book_event IS NOT NULL THEN e.id = i.book_event
               ELSE lower(e.name) = lower(i.event_name) AND e.occurs_at_local::date = i.event_date
                    AND (SELECT count(*) FROM public.events e2
                         WHERE lower(e2.name) = lower(i.event_name)
                           AND e2.occurs_at_local::date = i.event_date) = 1
          END
    LIMIT 1) ev ON true
  WHERE i.section IS NOT NULL AND i.seat_row IS NOT NULL AND i.qty BETWEEN 1 AND 50;

  UPDATE public.sub_finder_order t
     SET in_n2s = true
   WHERE t.job_id = v_job AND EXISTS (SELECT 1 FROM public.n2s_items n
                                       WHERE n.order_number = t.order_number OR n.n2s_order_key = t.order_number);

  -- a new lookup of an order takes over: older lookups of it stop being refreshed
  UPDATE public.sub_finder_order o
     SET watching = false, closed_reason = 'superseded', closed_at = now()
   WHERE o.key_id = p_key_id AND o.watching AND o.job_id <> v_job
     AND o.order_number IN (SELECT n.order_number FROM public.sub_finder_order n WHERE n.job_id = v_job);
  -- nothing to refresh on an order with no event
  UPDATE public.sub_finder_order SET watching = false, closed_reason = 'unmapped', closed_at = now()
   WHERE job_id = v_job AND state = 'unmapped';

  -- Pull only the events the routine polling does not already have: one with EVO listings
  -- pulled within refresh_fresh is being polled (N2S does every open order's event, every
  -- market, about every 2 minutes), so its data is used as it stands.
  SELECT array_agg(DISTINCT o.tevo_event_id) INTO v_evs
  FROM public.sub_finder_order o
  WHERE o.job_id = v_job AND o.tevo_event_id IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM public.n2s_evo_current x
                    WHERE x.event_id = o.tevo_event_id AND x.pulled_at > now() - c.refresh_fresh);
  IF v_evs IS NOT NULL THEN
    PERFORM public.n2s_pull_events(v_evs, c.pull_refresh, true);   -- true: SeatGeek too, every time
  ELSE
    -- nothing to wait for: answer now (also closes a job whose orders are all unmapped)
    UPDATE public.sub_finder_job SET pulled = false WHERE job_id = v_job;
    PERFORM public.sub_finder_settle(v_job);
  END IF;

  RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                    'created_at', j.created_at, 'replayed', false,
                                    'not_found', coalesce(v_miss, '[]'::jsonb),
                                    'unmapped', (SELECT count(*) FROM public.sub_finder_order o
                                                 WHERE o.job_id = v_job AND o.state = 'unmapped'))
          FROM public.sub_finder_job j WHERE j.job_id = v_job);
END
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_refresh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c        public.sub_finder_config;
  v_closed integer := 0;
  v_jobs   integer := 0;
  v_evs    bigint[];
  r        record;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT c.refresh_enabled THEN RETURN jsonb_build_object('skipped', 'off'); END IF;
  IF NOT public.cron_try_lock('sub_finder_refresh') THEN RETURN jsonb_build_object('skipped', 'overlap'); END IF;

  -- 1. stop watching what is finished. Only these reasons end a watch (plus a newer lookup
  --    of the same order, in sub_finder_submit). The cheap ones run for every order every tick.
  UPDATE public.sub_finder_order o
     SET watching = false, closed_reason = x.reason, closed_at = now(), updated_at = now()
    FROM (
      SELECT w.job_id, w.idx, CASE
          WHEN w.event_date < (now() AT TIME ZONE 'America/New_York')::date THEN 'event_passed'
          -- it came from the CRM's N2S book and is no longer open there
          WHEN (w.order_source = 'n2s' OR w.in_n2s) AND NOT EXISTS (
                 SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = w.order_number OR n.n2s_order_key = w.order_number)
                   AND NOT coalesce(n.is_terminal, false) AND n.status IN ('n2s', 'n2b'))
            THEN 'left_crm_n2s'
        END AS reason
      FROM public.sub_finder_order w WHERE w.watching) x
   WHERE o.job_id = x.job_id AND o.idx = x.idx AND x.reason IS NOT NULL;
  GET DIAGNOSTICS v_closed = ROW_COUNT;
  -- "The marketplace says the sale is over": the order's own marketplace feed first (GoTickets,
  -- TickPick, Vivid, SeatGeek, EVO — each read by its indexed order id), then our mirror of the
  -- CRM's books. Paced: up to feed_check_batch orders a tick, each at most every feed_check_every.
  FOR r IN SELECT w.job_id, w.idx, w.order_number, w.site FROM public.sub_finder_order w
            WHERE w.watching AND (w.feed_checked_at IS NULL OR w.feed_checked_at < now() - c.feed_check_every)
            ORDER BY w.feed_checked_at NULLS FIRST, w.updated_at LIMIT c.feed_check_batch
  LOOP
    UPDATE public.sub_finder_order o
       SET feed_checked_at = now(),
           watching      = (f.reason IS NULL),
           closed_reason = coalesce(f.reason, o.closed_reason),
           closed_at     = CASE WHEN f.reason IS NULL THEN o.closed_at ELSE now() END,
           updated_at    = CASE WHEN f.reason IS NULL THEN o.updated_at ELSE now() END
      FROM (SELECT 'order_' || public.sub_finder_order_closed(r.order_number, r.site) AS reason) f
     WHERE o.job_id = r.job_id AND o.idx = r.idx;
    IF NOT (SELECT watching FROM public.sub_finder_order WHERE job_id = r.job_id AND idx = r.idx) THEN
      v_closed := v_closed + 1;
    END IF;
  END LOOP;

  -- 2. the watched events, longest-unrefreshed first. Their listings come from the routine
  --    polling; a pull of our own is fired only if refresh_pull is switched on (the pull
  --    function then skips any market whose own last pull is newer than pull_refresh).
  --    An order whose GoTickets sub offer is still pending (requested, sent or unknown) is left
  --    alone: no pull and no re-match for it until the offer is accepted, stopped, denied or cancelled.
  SELECT array_agg(e) INTO v_evs FROM (
    SELECT o.tevo_event_id AS e
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.tevo_event_id IS NOT NULL
      AND NOT public.sub_finder_offer_pending(o.order_number, o.key_id)
    GROUP BY 1 ORDER BY min(coalesce(o.refreshed_at, j.done_at)) LIMIT c.refresh_max_events) q;
  IF v_evs IS NULL THEN
    RETURN jsonb_build_object('closed', v_closed, 'events', 0, 'jobs_rematched', 0);
  END IF;
  IF c.refresh_pull THEN
    PERFORM public.n2s_pull_events(v_evs, c.pull_refresh, true);   -- true: SeatGeek too, every time
  END IF;

  -- 3. re-match the jobs with a watched order whose event has landed something newer
  FOR r IN
    SELECT DISTINCT o.job_id
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.state IN ('cover', 'no_cover')
      AND o.tevo_event_id = ANY (v_evs)
      AND NOT public.sub_finder_offer_pending(o.order_number, o.key_id)
      AND (EXISTS (SELECT 1 FROM public.n2s_evo_current x WHERE x.event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at))
        OR EXISTS (SELECT 1 FROM public.n2s_gt_current x WHERE x.tevo_event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at))
        OR EXISTS (SELECT 1 FROM public.n2s_sg_current x WHERE x.tevo_event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at)))
    LIMIT 200
  LOOP
    UPDATE public.sub_finder_order SET rematch = true
     WHERE job_id = r.job_id AND watching AND state IN ('cover', 'no_cover')
       AND NOT public.sub_finder_offer_pending(order_number, key_id);
    PERFORM public.sub_finder_load_native(r.job_id, c.refresh_fresh);
    PERFORM public.sub_finder_match(r.job_id);
    v_jobs := v_jobs + 1;
  END LOOP;

  -- 4. an accepted GoTickets offer whose buy of the offered EVO seats stopped (the listing went
  --    before we could buy it): let go of that dead buy, so the standing automatic one-to-one
  --    rule may buy for the order on a later re-match. Nothing else buys on the acceptance.
  FOR r IN
    SELECT g.offer_id, g.job_id, g.idx, g.buy_id FROM public.sub_finder_gt_offer g
      JOIN public.manual_sub_buy b ON b.buy_id = g.buy_id
     WHERE g.live AND g.gt_status = 'ACCEPTED' AND b.state = 'stopped'
     ORDER BY g.offer_id LIMIT 20
  LOOP
    UPDATE public.sub_finder_gt_offer SET buy_id = NULL, buy_note = 'offered_seats_gone', updated_at = now()
     WHERE offer_id = r.offer_id;
    UPDATE public.sub_finder_order
       SET buy_id = NULL, action = CASE WHEN action = 'auto_bought' THEN 'offer' ELSE action END,
           rematch = true, updated_at = now()
     WHERE job_id = r.job_id AND idx = r.idx AND buy_id = r.buy_id;
  END LOOP;
  RETURN jsonb_build_object('closed', v_closed, 'events', cardinality(v_evs), 'jobs_rematched', v_jobs);
END
$$;

-- Are the offered seats gone? True when the listing is not in its market's current pull for the
-- event although that market has been pulled for it since the acceptance; NULL when unknown.
CREATE OR REPLACE FUNCTION public.sub_finder_offer_gone(g public.sub_finder_gt_offer, p_event bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN g.buy_note = 'offered_seats_gone' THEN true
    WHEN g.gt_status IS DISTINCT FROM 'ACCEPTED' OR p_event IS NULL THEN NULL
    WHEN g.market = 'evo' THEN
      CASE WHEN EXISTS (SELECT 1 FROM public.n2s_evo_current x WHERE x.event_id = p_event
                           AND x.tevo_ticket_group_id::text = g.listing_id) THEN false
           WHEN EXISTS (SELECT 1 FROM public.n2s_evo_current x WHERE x.event_id = p_event
                           AND x.pulled_at > g.final_at) THEN true END
    WHEN g.market = 'gotickets' THEN
      CASE WHEN EXISTS (SELECT 1 FROM public.n2s_gt_current x WHERE x.tevo_event_id = p_event
                           AND x.gt_listing_id::text = g.listing_id) THEN false
           WHEN EXISTS (SELECT 1 FROM public.n2s_gt_current x WHERE x.tevo_event_id = p_event
                           AND x.pulled_at > g.final_at) THEN true END
    WHEN g.market = 'seatgeek' THEN
      CASE WHEN EXISTS (SELECT 1 FROM public.n2s_sg_current x WHERE x.tevo_event_id = p_event
                           AND x.sglid::text = g.listing_id) THEN false
           WHEN EXISTS (SELECT 1 FROM public.n2s_sg_current x WHERE x.tevo_event_id = p_event
                           AND x.pulled_at > g.final_at) THEN true END
  END;
$$;
REVOKE ALL ON FUNCTION public.sub_finder_offer_gone(public.sub_finder_gt_offer, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_offer_gone(public.sub_finder_gt_offer, bigint) TO service_role;

-- sub_offer: as 20261113100000, plus the acceptance fields
CREATE OR REPLACE FUNCTION public.sub_finder_offer_json(o public.sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN lower(regexp_replace(coalesce(o.site, ''), '[^A-Za-z]', '', 'g')) <> 'gotickets' THEN NULL
    WHEN r.offer_id IS NULL AND coalesce((o.best->>'gate')::int, 0) < 3 THEN NULL
    ELSE jsonb_build_object(
      'via', 'gotickets',
      -- true: tell us yes with POST /orders/{n}/offer-sub and this listing_id
      'ask_crm', r.offer_id IS NULL AND o.watching AND o.order_source IN ('api', 'n2s', 'marketplace')
                 AND (o.best->>'gate')::int IN (3, 4, 5),
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
$$;

-- the offer's status from GoTickets: as 20261113020000, plus the sale check after a denial
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_follow_record(p_offer_id bigint, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  r        public.sub_finder_gt_offer;
  v_status text := upper(nullif(btrim(p_patch->>'gt_status'), ''));
  v_closed text;
BEGIN
  IF v_status IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.sub_finder_gt_offer WHERE offer_id = p_offer_id AND state = 'sent' FOR UPDATE;
  IF NOT FOUND OR r.gt_status IS NOT DISTINCT FROM v_status THEN RETURN v_status; END IF;
  UPDATE public.sub_finder_gt_offer
     SET gt_status = v_status, denial_reason = p_patch->>'denial_reason',
         final_at = CASE WHEN v_status IN ('ACCEPTED', 'DENIED', 'CANCELLED') THEN now() END,
         live = (v_status NOT IN ('DENIED', 'CANCELLED')),
         updated_at = now()
   WHERE offer_id = p_offer_id;
  -- The offer ended without a sub: check the sale before the order is polled again. The worker's
  -- fresh read of the sale comes first; our own copy of the order book is checked either way
  -- (it is all there is when the read failed). A sale that is over closes the lookup.
  IF v_status IN ('DENIED', 'CANCELLED') THEN
    v_closed := coalesce(
      CASE WHEN p_patch->>'sale_closed' IN ('cancelled', 'fulfilled') THEN p_patch->>'sale_closed' END,
      public.sub_finder_order_closed(r.order_number, 'GoTickets'));
  END IF;
  UPDATE public.sub_finder_order
     SET updated_at = now(),
         feed_checked_at = CASE WHEN v_status IN ('DENIED', 'CANCELLED') THEN now() ELSE feed_checked_at END,
         watching      = CASE WHEN v_closed IS NOT NULL THEN false ELSE watching END,
         closed_reason = CASE WHEN v_closed IS NOT NULL AND watching THEN 'order_' || v_closed ELSE closed_reason END,
         closed_at     = CASE WHEN v_closed IS NOT NULL AND watching THEN now() ELSE closed_at END
   WHERE job_id = r.job_id AND idx = r.idx;
  IF v_status = 'ACCEPTED' THEN PERFORM public.sub_finder_gt_offer_buy(p_offer_id); END IF;
  RETURN v_status;
END
$$;

-- the order as the CRM reads it: as 20261113080000, with the action after an acceptance
CREATE OR REPLACE FUNCTION public.sub_finder_order_json(o public.sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'job_id', o.job_id, 'order_number', o.order_number, 'site', o.site,
    'tevo_event_id', o.tevo_event_id, 'event_name', o.event_name, 'event_date', o.event_date, 'venue', o.venue,
    'section', o.section, 'row', o.seat_row, 'qty', o.qty, 'sold_ea', o.sold_ea,
    'order_source', o.order_source, 'state', o.state,
    -- what to do with the answer, and why it was not bought automatically
    -- once a GoTickets customer has accepted the sub there is nobody left to ask: while the offered
    -- seats are still there, 'offer' reads 'buy_manually' until they are bought. If they are gone
    -- the action is the new match's own (see sub_offer.accepted_next / new_best)
    'action', CASE WHEN o.action = 'offer' AND o.buy_id IS NULL
                        AND EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g
                                     WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                                       AND g.live AND g.gt_status = 'ACCEPTED'
                                       AND NOT coalesce(public.sub_finder_offer_gone(g, o.tevo_event_id), false))
                   THEN 'buy_manually' ELSE o.action END,
    'auto_buy_note', o.auto_buy_note,
    -- GoTickets orders only: the sub we would offer the customer, and how that offer stands
    'sub_offer', public.sub_finder_offer_json(o),
    'best', o.best, 'covers', o.covers,
    'markets_searched', CASE WHEN o.state IN ('cover', 'no_cover')
                             THEN to_jsonb(ARRAY['evo', 'gotickets', 'seatgeek']
                                           || CASE WHEN o.td_state = 'searched' THEN ARRAY['ticketsdata']
                                                   ELSE ARRAY[]::text[] END) END,
    'ticketsdata', o.td_state,
    'watching', o.watching, 'refreshed_at', o.refreshed_at, 'closed_reason', o.closed_reason,
    'buy', (SELECT jsonb_build_object(
                     'buy_id', b.buy_id, 'request_state', b.state, 'reasons', b.reasons,
                     'evo_order_id', b.buy_order_id, 'outcome', b.outcome,
                     'seller_state', b.seller_state, 'order_state', b.order_state,
                     'rejection_reason', b.rejection_reason,
                     'qty', b.qty, 'price_ea', b.bought_price_ea,
                     'total', coalesce(b.order_total_usd, b.bought_total_usd),
                     -- what the buy really made or lost once EVO's charge (tax included) is known, and
                     -- the gate that makes it: 1 Index = a profit, 2 S4KTrading = tax or price turned it into a loss
                     'profit_actual', round(o.sold_ea * o.qty - b.order_total_usd, 2),
                     'gate_actual', CASE WHEN b.order_total_usd IS NULL OR o.sold_ea IS NULL THEN NULL
                                         WHEN o.sold_ea * o.qty - b.order_total_usd > 0 THEN 1 ELSE 2 END,
                     'label_actual', CASE WHEN b.order_total_usd IS NULL OR o.sold_ea IS NULL THEN NULL
                                          WHEN o.sold_ea * o.qty - b.order_total_usd > 0 THEN 'Index' ELSE 'S4KTrading' END,
                     'section', b.bought_section, 'row', b.bought_row, 'seats', b.seats,
                     'status_checked_at', b.status_checked_at, 'final_at', b.final_at)
            FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id),
    'updated_at', to_char(o.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
$$;
