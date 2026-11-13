-- Stand-ins for the N2S auto-buyer (lane D7) as it is in production, for the shared buy
-- control (mig 20261113330000): the columns its claim and its results read, and the two
-- functions themselves, copied whole from 20261113400000 / 20261113410000. The migration's
-- md5 guard on n2s_autobuy_live_claim() passes only if this copy equals production's.
ALTER TABLE public.n2s_autobuy_exec
  ADD COLUMN IF NOT EXISTS n2s_id bigint, ADD COLUMN IF NOT EXISTS dryrun_id bigint,
  ADD COLUMN IF NOT EXISTS mode text DEFAULT 'live', ADD COLUMN IF NOT EXISTS state text,
  ADD COLUMN IF NOT EXISTS reasons text[] NOT NULL DEFAULT '{}', ADD COLUMN IF NOT EXISTS sell_market text,
  ADD COLUMN IF NOT EXISTS sub_source text, ADD COLUMN IF NOT EXISTS sub_listing_id text,
  ADD COLUMN IF NOT EXISTS tevo_event_id bigint, ADD COLUMN IF NOT EXISTS event_name text,
  ADD COLUMN IF NOT EXISTS event_dt_local timestamp, ADD COLUMN IF NOT EXISTS qty integer,
  ADD COLUMN IF NOT EXISTS sub_total_usd numeric, ADD COLUMN IF NOT EXISTS sold_total_usd numeric,
  ADD COLUMN IF NOT EXISTS sub_confirm_by timestamptz, ADD COLUMN IF NOT EXISTS buy_order_id text,
  ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now(), ADD COLUMN IF NOT EXISTS phase text,
  ADD COLUMN IF NOT EXISTS buy_state text, ADD COLUMN IF NOT EXISTS sale_state text,
  ADD COLUMN IF NOT EXISTS live_error text, ADD COLUMN IF NOT EXISTS lease_until timestamptz,
  ADD COLUMN IF NOT EXISTS lease_token uuid, ADD COLUMN IF NOT EXISTS live_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS live_updated_at timestamptz, ADD COLUMN IF NOT EXISTS event_start_utc timestamptz,
  ADD COLUMN IF NOT EXISTS est_tax_usd numeric, ADD COLUMN IF NOT EXISTS seller_window_in_hand_s integer,
  ADD COLUMN IF NOT EXISTS buy_total_usd numeric;
ALTER TABLE public.n2s_autobuy_config
  ADD COLUMN IF NOT EXISTS mode text DEFAULT 'live', ADD COLUMN IF NOT EXISTS kill_switch boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS live_sell_markets text[] DEFAULT '{vivid}',
  ADD COLUMN IF NOT EXISTS project_stopped boolean DEFAULT false, ADD COLUMN IF NOT EXISTS gt_project_stopped boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS live_runs_used integer DEFAULT 0, ADD COLUMN IF NOT EXISTS live_runs_allowed integer DEFAULT 5,
  ADD COLUMN IF NOT EXISTS gt_live_runs_used integer DEFAULT 0, ADD COLUMN IF NOT EXISTS gt_live_runs_allowed integer DEFAULT 5,
  ADD COLUMN IF NOT EXISTS min_confirm_window_s integer DEFAULT 60,
  ADD COLUMN IF NOT EXISTS per_order_cap_usd numeric, ADD COLUMN IF NOT EXISTS daily_cap_usd numeric,
  ADD COLUMN IF NOT EXISTS gt_per_order_cap_usd numeric, ADD COLUMN IF NOT EXISTS gt_daily_cap_usd numeric,
  ADD COLUMN IF NOT EXISTS max_buys_per_day integer, ADD COLUMN IF NOT EXISTS max_failures_per_day integer,
  ADD COLUMN IF NOT EXISTS approval_over_usd numeric, ADD COLUMN IF NOT EXISTS project_cap_usd numeric,
  ADD COLUMN IF NOT EXISTS gt_project_cap_usd numeric, ADD COLUMN IF NOT EXISTS min_event_lead interval DEFAULT '2 hours',
  ADD COLUMN IF NOT EXISTS buy_sources text[] DEFAULT '{tevo,gotickets}',
  ADD COLUMN IF NOT EXISTS evo_buyer_office_id bigint, ADD COLUMN IF NOT EXISTS evo_reviewer_id bigint,
  ADD COLUMN IF NOT EXISTS tax_quote boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS gt_buyer_email text, ADD COLUMN IF NOT EXISTS gt_buyer_phone text,
  ADD COLUMN IF NOT EXISTS gt_billing_address jsonb, ADD COLUMN IF NOT EXISTS gt_recipient jsonb,
  ADD COLUMN IF NOT EXISTS gt_gift_card_ids bigint[], ADD COLUMN IF NOT EXISTS updated_at timestamptz DEFAULT now();
CREATE TABLE IF NOT EXISTS public.n2s_gt_order_dryrun (
  dryrun_id bigint PRIMARY KEY, gt_event_id bigint, sold_section text, sold_row text, sold_qty integer,
  sub_section text, sub_row text);
ALTER TABLE public.sub_finder_config ADD COLUMN IF NOT EXISTS autobuys_key_ids bigint[] NOT NULL DEFAULT '{}';
CREATE OR REPLACE FUNCTION public.n2s_autobuy_gt_profile_ok(c public.n2s_autobuy_config)
 RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;

CREATE OR REPLACE FUNCTION public.n2s_autobuy_live_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c      public.n2s_autobuy_config%ROWTYPE;
  e      public.n2s_autobuy_exec%ROWTYPE;
  v_act  text;
  v_sale text;
  v_gt   boolean;
  v_gt_event bigint;
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id FOR UPDATE;
  IF c.mode <> 'live' OR c.kill_switch THEN RETURN NULL; END IF;
  -- Fail closed: a buy whose worker lost its lease may or may not have reached the sub's market.
  UPDATE public.n2s_autobuy_exec
     SET phase = 'buy_unknown', reasons = reasons || 'worker_lost'::text, lease_until = NULL, lease_token = NULL,
         live_error = COALESCE(live_error, 'lease expired during the buy step: check '
                               || CASE sub_source WHEN 'gotickets' THEN 'GoTickets' ELSE 'EVO' END
                               || ' for this purchase'),
         live_updated_at = now()
   WHERE mode = 'live' AND phase = 'buying' AND lease_until < now();
  IF FOUND THEN
    UPDATE public.n2s_autobuy_config SET kill_switch = true, updated_at = now() WHERE id;
    RETURN NULL;
  END IF;

  SELECT * INTO e FROM public.n2s_autobuy_exec
   WHERE mode = 'live' AND phase IN ('buy_sent', 'sub_accepted')
     AND (lease_until IS NULL OR lease_until < now())
   ORDER BY exec_id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF FOUND THEN
    v_act := 'poll';
  ELSE
    -- 20261112020000: handing out a buy spends the live run, so only hand one out while even a
    -- seller with the tickets in hand still has time to accept (the window stored at enqueue).
    -- 20261113400000: EVO and GoTickets each have their own run counter and stop flag.
    SELECT * INTO e FROM public.n2s_autobuy_exec x
     WHERE x.mode = 'live' AND x.state IN ('live_buy', 'approved') AND x.phase IS NULL
       AND x.sell_market = ANY (c.live_sell_markets)
       AND ((x.sub_source = 'tevo' AND NOT c.project_stopped AND c.live_runs_used < c.live_runs_allowed)
         OR (x.sub_source = 'gotickets' AND NOT c.gt_project_stopped AND c.gt_live_runs_used < c.gt_live_runs_allowed
             AND public.n2s_autobuy_gt_profile_ok(c)))
       AND x.sub_confirm_by - now() > make_interval(secs => GREATEST(c.min_confirm_window_s,
                                                                     COALESCE(x.seller_window_in_hand_s, 0)))
     ORDER BY x.exec_id LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF FOUND THEN
      v_act := 'buy';
      IF e.sub_source = 'gotickets' THEN
        UPDATE public.n2s_autobuy_config SET gt_live_runs_used = gt_live_runs_used + 1, updated_at = now() WHERE id;
      ELSE
        UPDATE public.n2s_autobuy_config SET live_runs_used = live_runs_used + 1, updated_at = now() WHERE id;
      END IF;
    END IF;
  END IF;
  IF v_act IS NULL THEN RETURN NULL; END IF;

  UPDATE public.n2s_autobuy_exec
     SET lease_until = now() + interval '180 seconds', lease_token = gen_random_uuid(), live_updated_at = now(),
         phase = CASE WHEN v_act = 'buy' THEN 'buying' ELSE phase END,
         live_started_at = COALESCE(live_started_at, now())
   WHERE exec_id = e.exec_id
  RETURNING * INTO e;
  SELECT n2s_order_key INTO v_sale FROM public.n2s_items WHERE n2s_id = e.n2s_id;
  v_gt := (e.sub_source = 'gotickets');
  SELECT d.gt_event_id INTO v_gt_event FROM public.n2s_gt_order_dryrun d WHERE d.dryrun_id = e.dryrun_id;

  RETURN jsonb_build_object(
    'action', v_act,
    'row', to_jsonb(e) || jsonb_build_object('sale_order_key', v_sale, 'gt_event_id', v_gt_event),
    'cfg', jsonb_build_object(
      -- this sub source's caps (20261113400000: GoTickets has its own)
      'per_order_cap_usd', CASE WHEN v_gt THEN c.gt_per_order_cap_usd ELSE c.per_order_cap_usd END,
      'daily_cap_usd', CASE WHEN v_gt THEN c.gt_daily_cap_usd ELSE c.daily_cap_usd END,
      'max_buys_per_day', c.max_buys_per_day, 'max_failures_per_day', c.max_failures_per_day,
      'approval_over_usd', c.approval_over_usd,
      'project_cap_usd', CASE WHEN v_gt THEN c.gt_project_cap_usd ELSE c.project_cap_usd END,
      'min_event_lead_s', extract(epoch FROM c.min_event_lead)::int,
      'min_confirm_window_s', c.min_confirm_window_s, 'buy_sources', to_jsonb(c.buy_sources),
      'evo_buyer_office_id', c.evo_buyer_office_id, 'evo_reviewer_id', c.evo_reviewer_id,
      'evo_email_address_id', c.evo_email_address_id,
      'tax_quote', c.tax_quote,
      'gt_buyer_email', c.gt_buyer_email, 'gt_buyer_phone', c.gt_buyer_phone,
      'gt_billing_address', c.gt_billing_address, 'gt_recipient', c.gt_recipient,
      'gt_gift_card_ids', to_jsonb(c.gt_gift_card_ids)));
END $function$;

CREATE OR REPLACE FUNCTION public.n2s_autobuy_result_json(e public.n2s_autobuy_exec)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'buy_ref',             CASE e.sub_source WHEN 'tevo' THEN 'evo' ELSE e.sub_source END || '-' || e.buy_order_id,
    'bought_on',           CASE e.sub_source WHEN 'tevo' THEN 'evo' ELSE e.sub_source END,
    'bought_order_number', e.buy_order_id,
    'for_order', jsonb_build_object(
        'order_number', e.order_number,
        'ref',          coalesce(e.sell_market, 'unknown') || '-' || e.order_number,
        'sold_on',      e.sell_market,
        'section',      coalesce(d.sold_section, i.section),
        'row',          coalesce(d.sold_row, i.row),
        'qty',          coalesce(d.sold_qty, i.qty),
        'sold_total_usd', e.sold_total_usd,
        'state',        e.sale_state),
    'status', CASE WHEN e.phase = 'accepted' THEN 'went_through'
                   WHEN e.phase IN ('buy_sent', 'sub_accepted', 'buying') THEN 'pending'
                   WHEN e.phase IN ('buy_unknown', 'accept_unknown', 'accept_failed') THEN 'check_manually'
                   ELSE 'stopped' END,
    'went_through', e.phase = 'accepted',
    'phase',        e.phase,
    'reasons',      to_jsonb(e.reasons),
    'event', jsonb_build_object('name', e.event_name, 'local_start', e.event_dt_local,
                                'start_utc', e.event_start_utc, 'venue', i.venue,
                                'tevo_event_id', e.tevo_event_id, 'gotickets_event_id', d.gt_event_id),
    'bought', jsonb_build_object('listing_id', e.sub_listing_id, 'section', d.sub_section, 'row', d.sub_row,
                                 'qty', e.qty, 'state', e.buy_state),
    'totals', jsonb_build_object(
        'quoted_usd',  round(e.sub_total_usd + coalesce(e.est_tax_usd, 0), 2),
        'charged_usd', e.buy_total_usd,
        'sold_usd',    e.sold_total_usd,
        'margin_usd',  round(e.sold_total_usd - coalesce(e.buy_total_usd, e.sub_total_usd + coalesce(e.est_tax_usd, 0)), 2)),
    'bought_at',  e.live_started_at,
    'updated_at', e.live_updated_at)
  FROM (SELECT 1) one
  LEFT JOIN public.n2s_items i ON i.n2s_id = e.n2s_id
  LEFT JOIN public.n2s_gt_order_dryrun d ON d.dryrun_id = e.dryrun_id;
$$;
