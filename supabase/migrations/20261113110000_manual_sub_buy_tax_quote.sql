-- Migration 20261113110000 · level:secondary-sales · lane:D0 · writes:manual_sub_buy_config,manual_sub_buy,manual_sub_buy_total_ceiling,manual_sub_buy_claim,manual_sub_buy_record · reads:sub_finder_config · pre:20261113080000
--
-- MANUAL SUB BUY: ask EVO what it will charge, tax included, before buying.
--
-- Operator 2026-11-13: "For 1-1 have it cart and look at total before it confirms 1-1" and
-- "build the evo tax quote". EVO adds sales tax to some purchases, on top of the listed price,
-- and a listing does not show it. EVO's Tax Quotes / Create (POST /v9/tax_quotes) returns the
-- total it will charge for a ticket group and quantity, plus a tax_signature to send with the
-- order. The worker (core/manual_sub_buy.py) now, when manual_sub_buy_config.tax_quote is on:
--
--   1. asks for the quote after the listing checks and before the buy;
--   2. stops the row ('total_above_ceiling') when the quoted total is over the row's
--      max_total_usd, buying nothing;
--   3. sends the quote's tax_signature with the order.
--
-- max_total_usd is set when the row is claimed, by manual_sub_buy_total_ceiling():
--   * a sub finder AUTOMATIC one-to-one buy ('sub finder auto (key ...)'): sale total x
--     (1 + sub_finder_config.auto_buy_max_loss_pct / 100). That is the automatic buy's own
--     rule (breakeven or better, or a gate 2 loss of at most that percent) applied to what EVO
--     will really charge instead of to our venue-tax estimate;
--   * every other row (the operator's own choice, a cover the CRM confirmed, seats a GoTickets
--     customer accepted): NULL, no ceiling. A person or the customer already agreed to it;
--     the quote is still taken, recorded and its signature sent.
-- A row with a ceiling stops ('tax_quote_failed') when EVO gives no usable quote; a row
-- without one is bought as before, without a signature (EVO charges the tax either way).
-- A failed quote never flips the kill switch: nothing was bought.
--
-- tax_quote is OFF by default: nothing changes until the operator turns it on.
--
-- rollback: re-apply manual_sub_buy_claim and manual_sub_buy_record from 20261111020000;
--           DROP FUNCTION public.manual_sub_buy_total_ceiling(public.manual_sub_buy);
--           ALTER TABLE public.manual_sub_buy DROP COLUMN max_total_usd, DROP COLUMN quote_tax_usd, DROP COLUMN quote_total_usd;
--           ALTER TABLE public.manual_sub_buy_config DROP COLUMN tax_quote;

ALTER TABLE public.manual_sub_buy_config
  ADD COLUMN IF NOT EXISTS tax_quote boolean NOT NULL DEFAULT false;

ALTER TABLE public.manual_sub_buy
  ADD COLUMN IF NOT EXISTS max_total_usd   numeric,   -- ceiling on EVO's quoted total, tax included (NULL = none)
  ADD COLUMN IF NOT EXISTS quote_tax_usd   numeric,   -- what the tax quote said
  ADD COLUMN IF NOT EXISTS quote_total_usd numeric;

-- The most EVO may charge for this row, tax included; NULL = no ceiling.
CREATE OR REPLACE FUNCTION public.manual_sub_buy_total_ceiling(b public.manual_sub_buy)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN b.requested_by LIKE 'sub finder auto (key %' AND b.sold_ea > 0
              THEN round(b.sold_ea * b.qty * (1 + greatest(coalesce(c.auto_buy_max_loss_pct, 0), 0) / 100.0), 2) END
  FROM (SELECT 1) one LEFT JOIN public.sub_finder_config c ON c.id;
$$;
REVOKE ALL ON FUNCTION public.manual_sub_buy_total_ceiling(public.manual_sub_buy) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_total_ceiling(public.manual_sub_buy) TO service_role;

-- claim: as 20261111020000, plus the row's total ceiling and the tax_quote switch.
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
         lease_until = now() + make_interval(secs => c.lease_s), updated_at = now(),
         max_total_usd = public.manual_sub_buy_total_ceiling(b)
   WHERE buy_id = b.buy_id
  RETURNING * INTO b;

  RETURN jsonb_build_object(
    'row', to_jsonb(b),
    'cfg', jsonb_build_object('evo_buyer_office_id', c.evo_buyer_office_id,
                              'evo_email_address_id', c.evo_email_address_id,
                              'tax_quote', c.tax_quote));
END $function$;

-- record: as 20261111020000, plus what the tax quote said.
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
         quote_tax_usd    = COALESCE((p_patch->>'quote_tax_usd')::numeric, quote_tax_usd),
         quote_total_usd  = COALESCE((p_patch->>'quote_total_usd')::numeric, quote_total_usd),
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
