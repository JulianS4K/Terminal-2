-- Migration 20261109200000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,n2s_autobuy_enqueue_trg · reads:n2s_gt_order_dryrun,n2s_items,n2s_autobuy_exec · pre:20261109030000
--
-- N2S auto-buy executor: soft launch on EVO subs only.
--
-- Operator direction 2026-11-09: "evo only for soft launch". GoTickets subs cannot be bought
-- yet (the Pro API key sees no payment method: GET /rest/pro/api/payment-methods returns []),
-- and EVO buys are paid from Office 3's EVO balance. New n2s_autobuy_config.buy_sources
-- (default '{tevo}') lists the sub sources the executor may buy from; any other sub is blocked
-- with reason sub_source_disabled. Re-enable GoTickets with:
--   UPDATE n2s_autobuy_config SET buy_sources = '{tevo,gotickets}';
-- The enqueue trigger function is re-created with that one extra guard; nothing else changes.
-- Shadow mode: nothing is sent to any market.
--
-- rollback: re-create n2s_autobuy_enqueue_trg() from 20261109030000;
--           ALTER TABLE n2s_autobuy_config DROP COLUMN buy_sources;

ALTER TABLE public.n2s_autobuy_config
  ADD COLUMN IF NOT EXISTS buy_sources text[] NOT NULL DEFAULT ARRAY['tevo']
    CHECK (buy_sources <@ ARRAY['tevo', 'gotickets']);

CREATE OR REPLACE FUNCTION public.n2s_autobuy_enqueue_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c          public.n2s_autobuy_config%ROWTYPE;
  i          public.n2s_items%ROWTYPE;
  r          text[] := '{}';
  v_market   text;
  v_qty      int;
  v_price    numeric;
  v_sub      numeric;
  v_sold     numeric;
  v_cut      int;
  v_cut_src  text;
  v_confirm  timestamptz;
  v_spend    numeric;
  v_buys     int;
  v_fail     int;
  v_proj      numeric;
  v_tz_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_state    text;
BEGIN
  -- FOR UPDATE serializes enqueues: concurrent would_buys queue here, so each sees the spend
  -- the others committed and two buys can never both pass the daily / project cap.
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id FOR UPDATE;
  SELECT * INTO i FROM public.n2s_items WHERE n2s_id = NEW.n2s_id;
  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec WHERE n2s_id = NEW.n2s_id) THEN
    RETURN NULL;                                         -- one attempt per sale; never a retry
  END IF;

  v_market := CASE WHEN lower(NEW.s4k_source) LIKE 'evo%' THEN 'evo'
                   WHEN lower(NEW.s4k_source) LIKE 'gotickets%' THEN 'gotickets'
                   WHEN lower(NEW.s4k_source) LIKE 'seatgeek%' THEN 'seatgeek'
                   WHEN lower(NEW.s4k_source) LIKE 'vivid%' THEN 'vivid' END;
  v_qty   := NEW.sub_qty;
  v_price := COALESCE(NEW.live_price_ea, NEW.quoted_ea);
  v_sub   := round(v_price * v_qty, 2);
  v_sold  := round(NEW.sold_ea * NEW.sold_qty, 2);

  -- allotted time: the market's median auto-reject (≥ 3 samples), else the CRM's 15 minutes
  SELECT median_cutoff_s, 'median of ' || samples || ' market rejects' INTO v_cut, v_cut_src
    FROM public.v_n2s_market_cutoff WHERE market = v_market AND samples >= 3;
  IF v_cut IS NULL THEN v_cut := c.default_cutoff_s; v_cut_src := 'default (no market data)'; END IF;
  v_confirm := i.alert_at + make_interval(secs => v_cut - c.accept_buffer_s);

  SELECT COALESCE(sum(sub_total_usd) FILTER (WHERE state IN ('shadow_buy', 'awaiting_approval', 'approved')), 0),
         count(*) FILTER (WHERE state IN ('shadow_buy', 'awaiting_approval', 'approved')),
         count(*) FILTER (WHERE state = 'blocked' AND 'circuit_breaker' <> ALL (reasons)
                            AND reasons && ARRAY['sub_rejected', 'sub_unconfirmed', 'buy_failed'])
    INTO v_spend, v_buys, v_fail
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND (created_at AT TIME ZONE 'America/New_York')::date = v_tz_today;

  -- Project spend: every buy ever committed in this mode, any market.
  SELECT COALESCE(sum(sub_total_usd), 0) INTO v_proj
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND state IN ('shadow_buy', 'awaiting_approval', 'approved');

  IF c.mode = 'off' OR c.kill_switch THEN
    v_state := 'off';
  ELSE
    IF v_market IS NULL THEN r := r || 'sell_market_no_token'::text; END IF;
    IF NEW.sub_source NOT IN ('gotickets', 'tevo') THEN r := r || 'sub_source_not_buyable'::text; END IF;
    -- 20261109200000: soft launch buys only from the sources listed in buy_sources (EVO).
    IF NEW.sub_source <> ALL (c.buy_sources) THEN r := r || 'sub_source_disabled'::text; END IF;
    IF i.event_dt IS NULL THEN
      r := r || 'event_time_unknown'::text;
    ELSE
      -- event_dt is venue-local; read as UTC it is never later than the real start for US venues.
      IF (i.event_dt AT TIME ZONE 'UTC') < now() + c.min_event_lead THEN r := r || 'event_within_24h'::text; END IF;
      IF i.event_dt::date <= v_tz_today THEN r := r || 'same_day_event'::text; END IF;
    END IF;
    IF v_sub IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN r := r || 'no_price'::text; END IF;
    IF v_sub > c.per_order_cap_usd THEN r := r || 'over_per_order_cap'::text; END IF;
    IF v_spend + v_sub > c.daily_cap_usd THEN r := r || 'over_daily_cap'::text; END IF;
    IF v_buys >= c.max_buys_per_day THEN r := r || 'max_buys_today'::text; END IF;
    IF v_fail >= c.max_failures_per_day THEN r := r || 'circuit_breaker'::text; END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.tevo_event_id = NEW.tevo_event_id AND x.mode = c.mode
                  AND x.state IN ('shadow_buy', 'awaiting_approval', 'approved')
                  AND (x.created_at AT TIME ZONE 'America/New_York')::date = v_tz_today) THEN
      r := r || 'event_already_bought_today'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.sub_source = NEW.sub_source AND x.sub_listing_id = NEW.sub_listing_id
                  AND x.state IN ('shadow_buy', 'awaiting_approval', 'approved')) THEN
      r := r || 'listing_already_used'::text;
    END IF;
    IF v_sold IS NULL OR v_sub >= v_sold THEN r := r || 'not_profitable'::text; END IF;
    IF NEW.live_price_ea IS NOT NULL AND NEW.quoted_ea IS NOT NULL AND NEW.live_price_ea > NEW.quoted_ea THEN
      r := r || 'price_rose'::text;
    END IF;
    IF NEW.live_pulled_at IS NULL OR NEW.captured_at - NEW.live_pulled_at > make_interval(secs => c.max_read_age_s) THEN
      r := r || 'stale_live_read'::text;
    END IF;
    IF i.alert_at IS NULL OR v_confirm - now() < make_interval(secs => c.min_confirm_window_s) THEN
      r := r || 'not_enough_time_for_market'::text;
    END IF;
    IF c.project_stopped THEN
      r := r || 'stopped_pending_review'::text;
    ELSIF v_sub IS NOT NULL AND v_proj + v_sub > c.project_cap_usd THEN
      -- Stop only when the cap is what blocks a buy that would otherwise go through; a sub
      -- already blocked by another guard (e.g. a $1,800 one over the order cap) must not freeze buying.
      IF cardinality(r) = 0 THEN
        UPDATE public.n2s_autobuy_config SET project_stopped = true, project_stopped_at = now(), updated_at = now(),
               project_stopped_reason = format('dryrun %s: $%s would take project spend from $%s past the $%s cap',
                                           NEW.dryrun_id, v_sub, v_proj, c.project_cap_usd)
         WHERE id;
      END IF;
      r := r || 'over_project_cap'::text;
    END IF;
    v_state := CASE WHEN cardinality(r) > 0 THEN 'blocked'
                    WHEN v_sub > c.approval_over_usd THEN 'awaiting_approval'
                    ELSE 'shadow_buy' END;
  END IF;

  INSERT INTO public.n2s_autobuy_exec
         (n2s_id, dryrun_id, mode, state, reasons, sell_market, order_number, sub_source, sub_listing_id,
          tevo_event_id, event_name, event_dt_local, qty, sub_total_usd, sold_total_usd, margin_usd, alert_at,
          cutoff_s, cutoff_source, sub_confirm_by, sale_deadline, spend_today_before, project_spent_before)
  VALUES (NEW.n2s_id, NEW.dryrun_id, c.mode, v_state, r, v_market, NEW.order_number, NEW.sub_source,
          NEW.sub_listing_id, NEW.tevo_event_id, NEW.event_name, i.event_dt, v_qty, v_sub, v_sold,
          v_sold - v_sub, i.alert_at, v_cut, v_cut_src, v_confirm,
          i.alert_at + make_interval(secs => v_cut), v_spend, v_proj)
  ON CONFLICT DO NOTHING;
  -- reaching the project cap exactly also stops buying until the operator reviews
  IF v_state IN ('shadow_buy', 'awaiting_approval')
     AND v_proj + v_sub >= c.project_cap_usd THEN
    UPDATE public.n2s_autobuy_config SET project_stopped = true, project_stopped_at = now(), updated_at = now(),
           project_stopped_reason = format('Project spend reached $%s of the $%s cap (dryrun %s)',
                                       v_proj + v_sub, c.project_cap_usd, NEW.dryrun_id)
     WHERE id;
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'n2s_autobuy_enqueue_trg: % (dryrun %)', SQLERRM, NEW.dryrun_id;  -- never break the dry run
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_enqueue_trg() FROM PUBLIC, anon, authenticated;
