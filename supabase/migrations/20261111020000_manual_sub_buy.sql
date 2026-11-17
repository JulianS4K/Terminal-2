-- Migration 20261111020000 · level:secondary-sales · lane:D0 · writes:manual_sub_buy_config,manual_sub_buy,manual_sub_buy_request,manual_sub_buy_claim,manual_sub_buy_record · reads:none · pre:20261111010000
--
-- MANUAL sub buy: the operator picks one EVO listing for one sale and has it bought.
--
-- Operator 2026-11-11, after a sheet of PED/PAC orders was matched against EVO: "build the path
-- so i can auto buy these if i choose outside of set conditions but keep separate from n2s".
--
-- SEPARATE FROM N2S ON PURPOSE. Nothing here reads or writes an n2s_* table, n2s_autobuy_config,
-- or n2s_autobuy_exec; N2S's caps, its one-live-run allowance, its kill switch and its dry-run
-- log are untouched, and nothing N2S does can start a buy here. The two share only the EVO
-- buy client (evo_buy_client.py, POST /v9/orders, path-pinned) and the buyer office.
--
-- "OUTSIDE OF SET CONDITIONS" means the N2S judgement rules do not apply: no Index gate, no
-- profit test, no lead-time / same-day rule, no view or row-letter rule, no sale timer. The
-- operator's request IS the decision. What stays, because each one protects against a wrong
-- or doubled purchase rather than a judgement call:
--   * nothing runs until manual_sub_buy_config.enabled is true (default FALSE) and the web
--     service has MANUAL_SUB_BUY_LIVE=1; kill_switch stops it at once
--   * one request = one listing, one quantity and a price ceiling the operator approved
--     (max_price_ea); the worker re-reads the listing and stops if it is gone, is ours, has
--     too few tickets, forbids that split, or costs more than the ceiling
--   * one live request per sale (site + order number), so a sale entered twice on a sheet
--     cannot be covered twice
--   * per-order and per-day spend ceilings in this table's own config
--   * a buy is sent ONCE: a claimed row never returns to 'requested'. If the worker dies
--     mid-buy, or EVO times out, the row becomes 'unknown' and the kill switch flips until a
--     person has looked at EVO. No sale is accepted or rejected here: these sales are already
--     accepted on their markets.
--
-- No upstream call is made from SQL in this migration.
--
-- rollback: DROP FUNCTION public.manual_sub_buy_record(bigint, uuid, jsonb), public.manual_sub_buy_claim(),
--             public.manual_sub_buy_request(text, text, bigint, bigint, integer, numeric, numeric, text, text, text);
--           DROP TABLE public.manual_sub_buy, public.manual_sub_buy_config;

CREATE TABLE IF NOT EXISTS public.manual_sub_buy_config (
  id                   boolean PRIMARY KEY DEFAULT true CHECK (id),
  enabled              boolean NOT NULL DEFAULT false,
  kill_switch          boolean NOT NULL DEFAULT false,
  kill_reason          text,
  per_order_cap_usd    numeric NOT NULL DEFAULT 666,
  daily_cap_usd        numeric NOT NULL DEFAULT 666,
  lease_s              integer NOT NULL DEFAULT 120,
  evo_buyer_office_id  integer NOT NULL DEFAULT 42029,
  evo_email_address_id integer DEFAULT 10497966,
  updated_at           timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.manual_sub_buy_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.manual_sub_buy (
  buy_id            bigserial PRIMARY KEY,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  requested_by      text        NOT NULL,
  sale_site         text        NOT NULL,
  sale_order_number text        NOT NULL,
  event_name        text,
  tevo_event_id     bigint,
  ticket_group_id   bigint      NOT NULL,
  qty               integer     NOT NULL CHECK (qty > 0),
  max_price_ea      numeric     NOT NULL CHECK (max_price_ea > 0),
  sold_ea           numeric,
  note              text,
  state             text        NOT NULL DEFAULT 'requested'
                    CHECK (state IN ('requested', 'buying', 'bought', 'stopped', 'unknown', 'cancelled')),
  reasons           text[]      NOT NULL DEFAULT '{}',
  lease_token       uuid,
  lease_until       timestamptz,
  buy_order_id      text,
  buy_state         text,
  bought_price_ea   numeric,
  bought_total_usd  numeric,
  error             text
);

-- One live request per sale: a second row for the same sale is refused until the first one
-- has stopped or been cancelled. 'unknown' counts as live (the buy may have gone through).
CREATE UNIQUE INDEX IF NOT EXISTS manual_sub_buy_one_per_sale
  ON public.manual_sub_buy (lower(sale_site), sale_order_number)
  WHERE state IN ('requested', 'buying', 'bought', 'unknown');
CREATE INDEX IF NOT EXISTS manual_sub_buy_state_idx ON public.manual_sub_buy (state, created_at);

ALTER TABLE public.manual_sub_buy_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.manual_sub_buy        ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.manual_sub_buy_config FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.manual_sub_buy        FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.manual_sub_buy IS
  'Operator-requested EVO sub buys (20261111020000), separate from N2S. One row = one listing '
  'the operator chose for one sale, with a price ceiling. Bought once by core/manual_sub_buy.py '
  'when manual_sub_buy_config.enabled; never retried.';

-- ── request: the operator's choice, recorded. Buys nothing by itself. ──────────────────────
CREATE OR REPLACE FUNCTION public.manual_sub_buy_request(
  p_sale_site text, p_sale_order_number text, p_tevo_event_id bigint, p_ticket_group_id bigint,
  p_qty integer, p_max_price_ea numeric, p_sold_ea numeric DEFAULT NULL, p_event_name text DEFAULT NULL,
  p_requested_by text DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id bigint;
BEGIN
  IF COALESCE(btrim(p_sale_site), '') = '' OR COALESCE(btrim(p_sale_order_number), '') = '' THEN
    RAISE EXCEPTION 'manual_sub_buy_request: the sale site and order number are required';
  END IF;
  IF COALESCE(btrim(p_requested_by), '') = '' THEN
    RAISE EXCEPTION 'manual_sub_buy_request: requested_by is required (who chose this buy)';
  END IF;
  INSERT INTO public.manual_sub_buy (requested_by, sale_site, sale_order_number, event_name, tevo_event_id,
                                     ticket_group_id, qty, max_price_ea, sold_ea, note)
  VALUES (btrim(p_requested_by), btrim(p_sale_site), btrim(p_sale_order_number), p_event_name, p_tevo_event_id,
          p_ticket_group_id, p_qty, p_max_price_ea, p_sold_ea, p_note)
  RETURNING buy_id INTO v_id;
  RETURN v_id;
END $function$;

-- ── claim: hand ONE requested row to a worker, once. ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manual_sub_buy_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c        public.manual_sub_buy_config%ROWTYPE;
  b        public.manual_sub_buy%ROWTYPE;
  v_total  numeric;
  v_spent  numeric;
  v_today  date := (now() AT TIME ZONE 'America/New_York')::date;
  r        text[] := '{}';
BEGIN
  -- FOR UPDATE serializes claims, so two workers see each other's spend and never share a row.
  SELECT * INTO c FROM public.manual_sub_buy_config WHERE id FOR UPDATE;

  -- A row left in 'buying' past its lease means a worker died around the buy: the outcome is
  -- unknown. It is NEVER handed out again (that could buy twice); everything stops for a person.
  UPDATE public.manual_sub_buy
     SET state = 'unknown', reasons = reasons || 'worker_lost_mid_buy'::text, updated_at = now(),
         lease_token = NULL
   WHERE state = 'buying' AND lease_until < now();
  IF FOUND THEN
    UPDATE public.manual_sub_buy_config
       SET kill_switch = true, kill_reason = 'a buy was left unfinished: check EVO', updated_at = now()
     WHERE id;
    RETURN NULL;
  END IF;

  IF NOT c.enabled OR c.kill_switch THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.manual_sub_buy WHERE state IN ('buying', 'unknown')) THEN
    RETURN NULL;                                        -- one at a time; nothing while one is unresolved
  END IF;

  SELECT * INTO b FROM public.manual_sub_buy
   WHERE state = 'requested' ORDER BY created_at, buy_id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;

  v_total := round(b.max_price_ea * b.qty, 2);
  SELECT COALESCE(sum(COALESCE(bought_total_usd, round(max_price_ea * qty, 2))), 0) INTO v_spent
    FROM public.manual_sub_buy
   WHERE state IN ('bought', 'unknown') AND (updated_at AT TIME ZONE 'America/New_York')::date = v_today;
  IF v_total > c.per_order_cap_usd          THEN r := r || 'over_order_cap'::text; END IF;
  IF v_spent + v_total > c.daily_cap_usd    THEN r := r || 'over_daily_cap'::text; END IF;
  IF cardinality(r) > 0 THEN
    UPDATE public.manual_sub_buy SET state = 'stopped', reasons = r, updated_at = now() WHERE buy_id = b.buy_id;
    RETURN NULL;
  END IF;

  UPDATE public.manual_sub_buy
     SET state = 'buying', lease_token = gen_random_uuid(),
         lease_until = now() + make_interval(secs => c.lease_s), updated_at = now()
   WHERE buy_id = b.buy_id
  RETURNING * INTO b;

  RETURN jsonb_build_object(
    'row', to_jsonb(b),
    'cfg', jsonb_build_object('evo_buyer_office_id', c.evo_buyer_office_id,
                              'evo_email_address_id', c.evo_email_address_id));
END $function$;

-- ── record: the worker's result, accepted only under its own live lease. ───────────────────
CREATE OR REPLACE FUNCTION public.manual_sub_buy_record(p_buy_id bigint, p_token uuid, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_state text := p_patch->>'state';
BEGIN
  IF v_state IS NULL OR v_state NOT IN ('buying', 'bought', 'stopped', 'unknown') THEN
    RAISE EXCEPTION 'manual_sub_buy_record: bad state %', v_state;
  END IF;
  UPDATE public.manual_sub_buy
     SET state            = v_state,
         reasons          = CASE WHEN p_patch ? 'reasons'
                                 THEN ARRAY(SELECT jsonb_array_elements_text(p_patch->'reasons')) ELSE reasons END,
         buy_order_id     = COALESCE(p_patch->>'buy_order_id', buy_order_id),
         buy_state        = COALESCE(p_patch->>'buy_state', buy_state),
         bought_price_ea  = COALESCE((p_patch->>'bought_price_ea')::numeric, bought_price_ea),
         bought_total_usd = COALESCE((p_patch->>'bought_total_usd')::numeric, bought_total_usd),
         error            = COALESCE(p_patch->>'error', error),
         lease_token      = CASE WHEN v_state = 'buying' THEN lease_token END,
         updated_at       = now()
   WHERE buy_id = p_buy_id AND state = 'buying' AND lease_token = p_token AND lease_until >= now();
  IF NOT FOUND THEN
    RETURN 'lease_lost';
  END IF;
  IF v_state = 'unknown' THEN
    UPDATE public.manual_sub_buy_config
       SET kill_switch = true, updated_at = now(),
           kill_reason = format('buy %s: outcome unknown, check EVO', p_buy_id)
     WHERE id;
  END IF;
  RETURN v_state;
END $function$;

REVOKE ALL ON FUNCTION public.manual_sub_buy_request(text, text, bigint, bigint, integer, numeric, numeric, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manual_sub_buy_claim() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manual_sub_buy_record(bigint, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_request(text, text, bigint, bigint, integer, numeric, numeric, text, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_claim() TO service_role;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_record(bigint, uuid, jsonb) TO service_role;
