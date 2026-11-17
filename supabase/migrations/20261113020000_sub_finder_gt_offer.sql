-- Migration 20261113020000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_gt_offer,sub_finder_gt_offer_buy,sub_finder_access,sub_finder_gt_offer_request,sub_finder_gt_offer_claim,sub_finder_gt_offer_record,sub_finder_gt_offer_follow_claim,sub_finder_gt_offer_follow_record,sub_finder_offer_json,sub_finder_order_json · reads:sub_finder_order,n2s_items,v_s4kcs_orders,manual_sub_buy · pre:20261113010000
--
-- SUB FINDER: offer a sub to the customer through GoTickets, when the CRM says yes.
--
-- Operator 2026-11-13: "when order is from gotickets thats flagged as sub by crm and
-- evo/gotix/seatgeek results fits gates 3-6, ask crm if it should offer sub to go tickets api.
-- for gate 3-4, just offer the sub via api if crm confirms. for gate 5 look at order total vs
-- new sub total and if new sub is cheaper offer the difference as rebate. for 6 only send crm
-- results." and "gates 1-2 we dont need to offer".
--
--   gate 1-2  same section, same or better row: no offer needed, nothing here
--   gate 3-4  another section in the same zone, same or better row: offered as is
--   gate 5    rows back, cheaper than the sale: offered with the difference as a rebate
--             (sale total - sub total; a gate 5 cover is cheaper by definition)
--   gate 6    rows back, not cheaper: results only, never offered
--
-- How it runs:
--   1. The order's JSON gains `sub_offer` for a GoTickets order whose best cover is gate 3-6:
--      what would be offered (`ask_crm: true`) or that it is results only.
--   2. The CRM answers yes with POST /api/v1/subs/orders/{n}/offer-sub {listing_id} ->
--      sub_finder_gt_offer_request files ONE row here. It is refused unless: the switch and
--      the key allow it; the order is GoTickets, watched, and found in OUR copy of the order
--      books with the same seats and quantity; the cover is one this lookup quoted, from EVO /
--      GoTickets / SeatGeek, at gate 3, 4 or 5; and no other offer for that order is live.
--   3. core/gt_sub_offer.py claims the row, re-reads the sale and its existing requests (GET),
--      and sends POST sc.gotickets.com/rest/substitution-requests once, through the
--      path-pinned gotickets_sub_client.py (RULE 2 carve-out, operator-authorized 2026-11-13).
--      Then it follows the request (GET) until the customer accepts or it is denied.
--
--   4. Operator 2026-11-13: "If gotickets subs are accepted and seats are in evo autobuy". When
--      GoTickets reports the offer ACCEPTED and the offered cover is an EVO listing,
--      sub_finder_gt_offer_buy files ONE manual_sub_buy request for it (the same path as every
--      other sub finder buy: fresh re-read, gone / dearer than quoted = no buy, never retried).
--      Only for exactly the quantity sold ("never buy extra automatically"), only when no
--      purchase exists for the order (ours, or an N2S auto-buy row), and inside the automatic
--      daily cap (auto_buy_daily_cap_usd, shared with the gate 1 buys). Off until
--      gt_offer_auto_buy. An accepted offer on GoTickets / SeatGeek seats is bought by a person.
--
-- No SQL here calls GoTickets. Otherwise nothing is bought: the replacement seats are bought by a person
-- outside this path. Off until sub_finder_config.gt_offer_enabled, the key is in
-- gt_offer_key_ids, and GT_SUB_OFFER_LIVE=1 on the web service.
--
-- rollback: DROP FUNCTION public.sub_finder_gt_offer_request(bigint, text, text, text, text, text),
--             public.sub_finder_gt_offer_claim(), public.sub_finder_gt_offer_record(bigint, uuid, jsonb),
--             public.sub_finder_gt_offer_follow_claim(), public.sub_finder_gt_offer_follow_record(bigint, jsonb),
--             public.sub_finder_gt_offer_buy(bigint);
--           re-apply sub_finder_order_json and sub_finder_access from 20261113010000 / 20261112010000;
--           DROP FUNCTION public.sub_finder_offer_json(public.sub_finder_order); DROP TABLE public.sub_finder_gt_offer;
--           ALTER TABLE public.sub_finder_config DROP COLUMN gt_offer_enabled, DROP COLUMN gt_offer_key_ids,
--             DROP COLUMN gt_offer_lease_s, DROP COLUMN gt_offer_recheck,
--             DROP COLUMN gt_offer_auto_buy;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS gt_offer_enabled boolean  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS gt_offer_key_ids bigint[] NOT NULL DEFAULT '{}',   -- keys allowed to confirm an offer
  ADD COLUMN IF NOT EXISTS gt_offer_lease_s integer  NOT NULL DEFAULT 120,
  ADD COLUMN IF NOT EXISTS gt_offer_recheck interval NOT NULL DEFAULT interval '5 minutes',
  ADD COLUMN IF NOT EXISTS gt_offer_auto_buy boolean  NOT NULL DEFAULT false;   -- buy the EVO seats once accepted

CREATE TABLE IF NOT EXISTS public.sub_finder_gt_offer (
  offer_id          bigserial PRIMARY KEY,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  job_id            uuid    NOT NULL,
  idx               integer NOT NULL,
  key_id            bigint  NOT NULL,
  requested_by      text    NOT NULL,
  order_number      text    NOT NULL,
  gt_order_id       bigint  NOT NULL,
  gate              integer NOT NULL CHECK (gate IN (3, 4, 5)),
  market            text    NOT NULL,
  listing_id        text    NOT NULL,
  section           text    NOT NULL,
  seat_row          text    NOT NULL,
  qty               integer NOT NULL,
  buy_qty           integer NOT NULL,          -- what the listing makes us buy (qty, or qty + 1)
  price_ea          numeric NOT NULL,          -- quoted; the ceiling for a buy after acceptance
  buy_id            bigint,                    -- manual_sub_buy row filed once accepted (EVO only)
  buy_note          text,                      -- why no buy was filed after acceptance
  order_total       numeric,
  sub_total         numeric,
  rebate_amount     numeric CHECK (rebate_amount IS NULL OR rebate_amount > 0),
  notes             text,
  state             text    NOT NULL DEFAULT 'requested'
                    CHECK (state IN ('requested', 'sending', 'sent', 'stopped', 'unknown')),
  live              boolean NOT NULL DEFAULT true,     -- false once stopped, denied or cancelled
  reasons           text[]  NOT NULL DEFAULT '{}',
  lease_token       uuid,
  lease_until       timestamptz,
  gt_request_id     bigint,
  gt_status         text,                              -- PENDING / CUSTOMER_REVIEW / ACCEPTED / DENIED / CANCELLED
  denial_reason     text,
  status_checked_at timestamptz,
  status_checks     integer NOT NULL DEFAULT 0,
  final_at          timestamptz,
  error             text
);
-- One live offer per order: a second is refused until the first is stopped, denied or cancelled.
-- An accepted offer, and one whose outcome is unknown, stay live.
CREATE UNIQUE INDEX IF NOT EXISTS sub_finder_gt_offer_one_live ON public.sub_finder_gt_offer (order_number) WHERE live;
CREATE INDEX IF NOT EXISTS sub_finder_gt_offer_state ON public.sub_finder_gt_offer (state, created_at);
ALTER TABLE public.sub_finder_gt_offer ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_gt_offer FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.sub_finder_gt_offer IS
  'Substitution offers the CRM confirmed for a GoTickets order (20261113020000): one sub finder '
  'cover at gate 3-5, sent once to GoTickets by core/gt_sub_offer.py, then followed to accepted / denied.';

CREATE OR REPLACE FUNCTION public.sub_finder_access(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'enabled', c.enabled,
    'find', c.enabled AND p_key_id = ANY (c.key_ids),
    'buy',  c.enabled AND c.buy_enabled AND p_key_id = ANY (c.key_ids) AND p_key_id = ANY (c.buy_key_ids),
    'offer', c.enabled AND c.gt_offer_enabled AND p_key_id = ANY (c.key_ids) AND p_key_id = ANY (c.gt_offer_key_ids),
    'max_orders_per_job', c.max_orders_per_job, 'ticketsdata_fallback', c.td_enabled)
  FROM public.sub_finder_config c;
$$;

-- The CRM's yes: file one offer for a cover this lookup quoted. Sends nothing itself.
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_request(
  p_key_id bigint, p_key_label text, p_order_number text, p_listing_id text,
  p_market text DEFAULT NULL, p_requested_by text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  o      public.sub_finder_order;
  cv     jsonb;
  v_gate integer;
  v_id   bigint;
  v_back integer;
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
  IF NOT EXISTS (
       SELECT 1 FROM public.n2s_items n
        WHERE (n.order_number = o.order_number OR n.n2s_order_key = o.order_number)
          AND lower(regexp_replace(coalesce(n.marketplace, ''), '[^A-Za-z]', '', 'g')) = 'gotickets'
          AND public.seat_section_norm(n.section) = public.seat_section_norm(o.section)
          AND upper(btrim(n.row)) = upper(btrim(o.seat_row)) AND n.qty = o.qty
          AND n.tevo_event_id = o.tevo_event_id)
     AND NOT EXISTS (
       SELECT 1 FROM public.v_s4kcs_orders v
        WHERE v.s4k_order_id = o.order_number
          AND lower(regexp_replace(coalesce(v.source, ''), '[^A-Za-z]', '', 'g')) = 'gotickets'
          AND public.seat_section_norm(v.section) = public.seat_section_norm(o.section)
          AND upper(btrim(v.row)) = upper(btrim(o.seat_row)) AND v.quantity = o.qty
          AND v.tevo_event_id = o.tevo_event_id) THEN
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
  v_gate := (cv->>'gate')::int;
  IF v_gate IS NULL OR v_gate < 3 THEN
    RETURN jsonb_build_object('error', 'invalid',
      'detail', 'gate 1-2 covers need no offer: the seats are in the same section, same or better row');
  END IF;
  IF v_gate = 6 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'gate 6 covers are results only and are not offered');
  END IF;
  IF v_gate = 5 AND coalesce((cv->>'profit')::numeric, 0) <= 0 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'no rebate can be worked out for this cover');
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
            CASE WHEN v_gate = 5 THEN (cv->>'profit')::numeric END,       -- sale total - sub total
            CASE WHEN v_gate = 5
                 THEN 'Replacement seats in the same area, ' || v_back || ' row' || CASE WHEN v_back = 1 THEN '' ELSE 's' END
                      || ' further back than the original row ' || o.seat_row || ', with a rebate.'
                 ELSE 'Comparable replacement seats in the same area, in the same row or closer than the original section '
                      || o.section || ' row ' || o.seat_row || '.' END)
    RETURNING offer_id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'an offer already exists for this order');
  END;
  UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('offer_id', v_id, 'state', 'requested', 'gate', v_gate,
                            'section', cv->>'section', 'row', cv->>'row',
                            'rebate', CASE WHEN v_gate = 5 THEN (cv->>'profit')::numeric END);
END
$$;

-- Hand ONE requested offer to a worker, once, under a lease. An offer left 'sending' past its
-- lease may or may not have gone out: it becomes 'unknown' and stays live.
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c public.sub_finder_config;
  r public.sub_finder_gt_offer;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  UPDATE public.sub_finder_gt_offer
     SET state = 'unknown', reasons = ARRAY['offer_unknown'], error = 'worker stopped mid-offer', updated_at = now()
   WHERE state = 'sending' AND lease_until < now();
  IF NOT c.enabled OR NOT c.gt_offer_enabled THEN RETURN NULL; END IF;
  SELECT * INTO r FROM public.sub_finder_gt_offer
   WHERE state = 'requested' AND (lease_until IS NULL OR lease_until < now())
   ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.sub_finder_gt_offer
     SET lease_token = gen_random_uuid(), lease_until = now() + make_interval(secs => c.gt_offer_lease_s), updated_at = now()
   WHERE offer_id = r.offer_id RETURNING * INTO r;
  RETURN to_jsonb(r);
END
$$;

-- Record one step of the worker, only while its lease holds. Returns the new state or 'lease_lost'.
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_record(p_offer_id bigint, p_token uuid, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  r       public.sub_finder_gt_offer;
  v_state text := p_patch->>'state';
BEGIN
  IF v_state IS NULL OR v_state NOT IN ('sending', 'sent', 'stopped', 'unknown') THEN
    RAISE EXCEPTION 'sub_finder_gt_offer_record: bad state %', v_state;
  END IF;
  UPDATE public.sub_finder_gt_offer
     SET state = v_state,
         live = (v_state <> 'stopped'),
         reasons = CASE WHEN p_patch ? 'reasons'
                        THEN ARRAY(SELECT jsonb_array_elements_text(p_patch->'reasons')) ELSE reasons END,
         error = coalesce(p_patch->>'error', error),
         gt_request_id = coalesce((p_patch->>'gt_request_id')::bigint, gt_request_id),
         gt_status = coalesce(p_patch->>'gt_status', gt_status),
         final_at = CASE WHEN v_state = 'stopped' THEN now() ELSE final_at END,
         updated_at = now()
   WHERE offer_id = p_offer_id AND lease_token = p_token AND lease_until > now()
     AND state IN ('requested', 'sending')
  RETURNING * INTO r;
  IF NOT FOUND THEN RETURN 'lease_lost'; END IF;
  UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = r.job_id AND idx = r.idx;
  RETURN v_state;
END
$$;

-- One sent offer that is due a status read (GET). Stamps the check so the next tick takes another.
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_follow_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c public.sub_finder_config;
  r public.sub_finder_gt_offer;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  SELECT * INTO r FROM public.sub_finder_gt_offer
   WHERE state = 'sent' AND final_at IS NULL AND gt_request_id IS NOT NULL
     AND (status_checked_at IS NULL OR status_checked_at < now() - c.gt_offer_recheck)
   ORDER BY status_checked_at NULLS FIRST, offer_id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.sub_finder_gt_offer SET status_checked_at = now(), status_checks = status_checks + 1
   WHERE offer_id = r.offer_id;
  RETURN jsonb_build_object('offer_id', r.offer_id, 'gt_order_id', r.gt_order_id, 'gt_request_id', r.gt_request_id);
END
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_follow_record(p_offer_id bigint, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  r        public.sub_finder_gt_offer;
  v_status text := upper(nullif(btrim(p_patch->>'gt_status'), ''));
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
  UPDATE public.sub_finder_order SET updated_at = now() WHERE job_id = r.job_id AND idx = r.idx;
  IF v_status = 'ACCEPTED' THEN PERFORM public.sub_finder_gt_offer_buy(p_offer_id); END IF;
  RETURN v_status;
END
$$;

-- The customer accepted: buy the offered seats when they are an EVO listing. Files a
-- manual_sub_buy request (no upstream call here) or records why not in buy_note.
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
      OR EXISTS (SELECT 1 FROM public.v_sub_orders v WHERE v.order_id = r.order_number AND NOT v.is_open)
      THEN 'order_closed'
    WHEN r.market <> 'evo' THEN 'not_on_evo'
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
      v_buy := public.manual_sub_buy_request(
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
$$;

-- The `sub_offer` block of an order: null unless it is a GoTickets order with an offer made,
-- or one whose best cover is gate 3-6.
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
      'ask_crm', r.offer_id IS NULL AND o.watching AND o.order_source IN ('n2s', 'marketplace')
                 AND (o.best->>'gate')::int IN (3, 4, 5),
      'results_only', r.offer_id IS NULL AND (o.best->>'gate')::int = 6,
      'gate', coalesce(r.gate, (o.best->>'gate')::int),
      'market', coalesce(r.market, o.best->>'market'),
      'listing_id', coalesce(r.listing_id, o.best->>'listing_id'),
      'section', coalesce(r.section, o.best->>'section'), 'row', coalesce(r.seat_row, o.best->>'row'),
      'rebate', CASE WHEN r.offer_id IS NOT NULL THEN r.rebate_amount
                     WHEN (o.best->>'gate')::int = 5 THEN (o.best->>'profit')::numeric END,
      'request', CASE WHEN r.offer_id IS NOT NULL THEN jsonb_build_object(
                   'offer_id', r.offer_id, 'state', r.state, 'reasons', r.reasons,
                   'gotickets_request_id', r.gt_request_id, 'status', r.gt_status,
                   'denial_reason', r.denial_reason, 'status_checked_at', r.status_checked_at,
                   -- after ACCEPTED: 'buy_requested' (see the order's `buy`) or why we did not buy
                   'buy', CASE WHEN r.buy_id IS NOT NULL THEN 'buy_requested' ELSE r.buy_note END,
                   'final_at', r.final_at) END)
  END
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT g.* FROM public.sub_finder_gt_offer g
                      WHERE g.order_number = o.order_number AND g.key_id = o.key_id
                      ORDER BY g.live DESC, g.offer_id DESC LIMIT 1) r ON true;
$$;

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
    'action', o.action, 'auto_buy_note', o.auto_buy_note,
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
                     'section', b.bought_section, 'row', b.bought_row, 'seats', b.seats,
                     'status_checked_at', b.status_checked_at, 'final_at', b.final_at)
            FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id),
    'updated_at', to_char(o.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
$$;

REVOKE ALL ON FUNCTION public.sub_finder_gt_offer_request(bigint, text, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_gt_offer_claim() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_gt_offer_record(bigint, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_gt_offer_follow_claim() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_gt_offer_follow_record(bigint, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_offer_json(public.sub_finder_order) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_gt_offer_buy(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_gt_offer_buy(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_gt_offer_request(bigint, text, text, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_gt_offer_claim() TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_gt_offer_record(bigint, uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_gt_offer_follow_claim() TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_gt_offer_follow_record(bigint, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_offer_json(public.sub_finder_order) TO service_role;
