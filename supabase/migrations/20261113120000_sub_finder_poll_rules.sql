-- Migration 20261113120000 · level:secondary-sales · lane:D0 · writes:n2s_sg_polled,n2s_pull_events,sub_finder_offer_pending,sub_finder_submit,sub_finder_refresh,sub_finder_gt_offer_buy,sub_finder_offer_json · reads:n2s_mkt_pull,sub_finder_gt_offer · pre:20261113060000
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
--   n2s_pull_events   gains p_sg_repeat (default false). Without it, a SeatGeek event already
--                     in n2s_sg_polled is skipped, whoever made that first pull. Every N2S
--                     caller (n2s_pull_all_sources, n2s_hub_quick_map, inbox_n2b_pull) uses
--                     the default, unchanged. EVO, GoTickets and TicketsData are untouched.
--                     Otherwise the body is prod's, byte for byte (checked by md5 against
--                     pg_get_functiondef on 2026-11-13). The 2-argument version is dropped
--                     (a 2-argument call resolves to this one through the default).
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
--   sub_finder_gt_offer_buy
--                     the buy after an acceptance no longer needs the OFFERED listing to be on
--                     EVO. If it is, that listing is bought, as before. If it is not (GoTickets
--                     / SeatGeek seats were offered), the order's fresh covers are searched for
--                     an EVO listing that delivers what the customer accepted: the same section,
--                     the same row or closer, exactly the quantity sold, not obstructed, and a
--                     total (expected tax included) no higher than the sub total the CRM said
--                     yes to. The best such cover is bought; with none, the offer's buy note is
--                     'no_evo_match' and sub_finder_refresh asks again every round while the
--                     order is watched. Every other rule is unchanged (switches, sale still
--                     live, one buy per sale, daily cap, the manual sub buy path's own ceilings).
--
--   sub_finder_offer_json
--                     tells the CRM the customer accepted: `sub_offer.accepted`, `accepted_at`
--                     and `accepted_next` ('buy_requested' or 'buy_manually'). There is no
--                     call out to the CRM (it has given us no address to call): the acceptance
--                     already moves the order's updated_at, so the order comes back in the
--                     sync feed (GET /results?updated_since=) carrying these fields.
--                     The body is 20261113100000's (the rebate fields) plus these three, so
--                     the two migrations can be applied in either order.
--
-- Read paths only: every request these functions send is a GET (RULE 2).
--
-- rollback: re-apply sub_finder_submit and sub_finder_refresh from 20261113060000;
--           DROP FUNCTION public.n2s_pull_events(bigint[], interval, boolean) and re-create the
--           2-argument version (this body without the p_sg_repeat line and the n2s_sg_polled insert);
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

DROP FUNCTION IF EXISTS public.n2s_pull_events(bigint[], interval);

CREATE OR REPLACE FUNCTION public.n2s_pull_events(p_events bigint[], p_refresh_after interval DEFAULT '00:05:00'::interval,
                                                  p_sg_repeat boolean DEFAULT false)
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

  -- 4. accepted GoTickets offers whose seats are not bought yet: look again for EVO seats that
  --    deliver what the customer accepted (the buy function decides and keeps its own rules)
  IF c.gt_offer_enabled AND c.gt_offer_auto_buy THEN
    FOR r IN
      SELECT g.offer_id FROM public.sub_finder_gt_offer g
        JOIN public.sub_finder_order o ON o.job_id = g.job_id AND o.idx = g.idx
       WHERE g.live AND g.gt_status = 'ACCEPTED' AND g.buy_id IS NULL
         AND g.buy_note IN ('not_on_evo', 'no_evo_match') AND o.watching AND o.buy_id IS NULL
       ORDER BY g.offer_id LIMIT 20
    LOOP
      PERFORM public.sub_finder_gt_offer_buy(r.offer_id);
    END LOOP;
  END IF;
  RETURN jsonb_build_object('closed', v_closed, 'events', cardinality(v_evs), 'jobs_rematched', v_jobs);
END
$$;

-- the buy after an acceptance: the offered EVO listing, or EVO seats that deliver the same
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_buy(p_offer_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c       public.sub_finder_config;
  r       public.sub_finder_gt_offer;
  o       public.sub_finder_order;
  v_note  text;
  v_buy   bigint;
  v_spent numeric;
  v_label text;
  v_lid   text;      -- the EVO listing to buy, its quantity and price
  v_qty   integer;
  v_px    numeric;
  cv      jsonb;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  PERFORM pg_advisory_xact_lock(hashtext('sub_finder_autobuy'));      -- one cap check + request at a time
  SELECT * INTO r FROM public.sub_finder_gt_offer WHERE offer_id = p_offer_id FOR UPDATE;
  IF NOT FOUND OR r.gt_status IS DISTINCT FROM 'ACCEPTED' OR r.buy_id IS NOT NULL
     OR r.buy_note NOT IN ('not_on_evo', 'no_evo_match') THEN         -- NULL note passes: not decided yet
    RETURN NULL;                                                      -- not accepted, or already decided
  END IF;
  SELECT * INTO o FROM public.sub_finder_order WHERE job_id = r.job_id AND idx = r.idx FOR UPDATE;
  v_note := CASE
    -- every switch above this one must be on too: the API, GoTickets offers, and this buy
    WHEN NOT (c.enabled AND c.gt_offer_enabled AND c.gt_offer_auto_buy) THEN 'auto_buy_off'
    WHEN NOT o.watching
      OR public.sub_finder_order_closed(r.order_number, 'GoTickets') IS NOT NULL
      THEN 'order_closed'
    WHEN r.market = 'evo' AND r.buy_qty <> r.qty THEN 'needs_spare_ticket'
    WHEN o.buy_id IS NOT NULL
      OR EXISTS (SELECT 1 FROM public.manual_sub_buy b WHERE b.sale_order_number = r.order_number
                    AND b.state IN ('requested', 'buying', 'bought', 'unknown'))
      OR EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = r.order_number)
      THEN 'already_bought_for_this_sale'
  END;
  IF v_note IS NULL AND r.market = 'evo' THEN
    v_lid := r.listing_id; v_qty := r.buy_qty; v_px := r.price_ea;   -- the offered seats themselves
  ELSIF v_note IS NULL THEN
    -- other seats were offered: EVO seats that deliver what the customer accepted, from the
    -- order's current covers — same section, same row or closer, the quantity sold, a clear
    -- view, and no dearer (expected tax included) than the sub the CRM said yes to
    SELECT x INTO cv FROM jsonb_array_elements(coalesce(o.covers, '[]'::jsonb)) x
     WHERE x->>'market' = 'evo' AND x->>'source' = 'native'
       AND public.seat_section_norm(x->>'section') = public.seat_section_norm(r.section)
       AND public.seat_row_rank(x->>'row') <= public.seat_row_rank(r.seat_row)
       AND (x->>'buy_qty')::int = r.qty AND (x->>'spare')::int = 0
       AND x->>'view' IS DISTINCT FROM 'obstructed'
       AND (x->>'total')::numeric <= r.sub_total
     ORDER BY (x->>'total')::numeric, x->>'listing_id' LIMIT 1;
    IF cv IS NULL THEN
      v_note := 'no_evo_match';                                       -- asked again by sub_finder_refresh
    ELSE
      v_lid := cv->>'listing_id'; v_qty := (cv->>'buy_qty')::int; v_px := (cv->>'price_ea')::numeric;
    END IF;
  END IF;
  IF v_note IS NULL THEN
    SELECT coalesce(sum(coalesce(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0) INTO v_spent
      FROM public.manual_sub_buy b
     WHERE b.requested_by LIKE 'sub finder auto%' AND b.state IN ('requested', 'buying', 'bought', 'unknown')
       AND (b.created_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date;
    IF v_spent + v_px * v_qty > c.auto_buy_daily_cap_usd THEN v_note := 'over_daily_cap'; END IF;
  END IF;
  IF v_note IS NULL THEN
    SELECT key_label INTO v_label FROM public.sub_finder_job WHERE job_id = r.job_id;
    BEGIN
      v_buy := public.manual_sub_buy_request(
        'GoTickets', r.order_number, o.tevo_event_id, v_lid::bigint, v_qty, v_px, o.sold_ea,
        o.event_name, 'sub finder auto (gotickets offer accepted, key ' || coalesce(v_label, r.key_id::text) || ')',
        'customer accepted GoTickets substitution ' || r.gt_request_id || ' (gate ' || r.gate || '): sub '
          || coalesce(cv->>'section', r.section) || ' row ' || coalesce(cv->>'row', r.seat_row) || ' x' || v_qty
          || CASE WHEN cv IS NOT NULL THEN ' (EVO seats for the accepted ' || r.market || ' sub '
                                           || r.section || ' row ' || r.seat_row || ')' ELSE '' END
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
$$;

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
      -- back in the sync feed). `accepted_next` says what happens to the seats: 'buy_requested'
      -- (we are buying EVO seats, see the order's `buy`) or 'buy_manually' (no EVO seats that
      -- deliver the accepted sub yet: buy them yourselves; we keep looking and buy if some appear)
      'accepted', coalesce(r.gt_status = 'ACCEPTED', false),
      'accepted_at', CASE WHEN r.gt_status = 'ACCEPTED'
                          THEN to_char(r.final_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') END,
      'accepted_next', CASE WHEN r.gt_status IS DISTINCT FROM 'ACCEPTED' THEN NULL
                            WHEN r.buy_id IS NOT NULL OR o.buy_id IS NOT NULL THEN 'buy_requested'
                            ELSE 'buy_manually' END)
  END
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT g.* FROM public.sub_finder_gt_offer g
                      WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                      ORDER BY g.live DESC, g.offer_id DESC LIMIT 1) r ON true;
$$;
