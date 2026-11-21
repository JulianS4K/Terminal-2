-- Stand-ins for the N2S auto-buy enqueue (lane D7) as it is in production, for the monthly
-- project cap (mig 20261121060000): the columns and helpers n2s_autobuy_enqueue_trg() and
-- n2s_autobuy_job_json() read, and both functions, as 20261113400000 + 20261116180000 +
-- 20261113470000 + 20261117013000 left them. The migration's md5 guards
-- (83d1d69b24bd3c5e6188383f79751c45, 5376a0f8ca2751037518061a884a7425) pass only if these copies
-- equal production's. Seller window, venue tax, market cutoff and event lead are fixed stand-ins.
ALTER TABLE public.n2s_autobuy_exec
  ADD COLUMN IF NOT EXISTS cutoff_s integer, ADD COLUMN IF NOT EXISTS cutoff_source text,
  ADD COLUMN IF NOT EXISTS sale_deadline timestamptz, ADD COLUMN IF NOT EXISTS spend_today_before numeric,
  ADD COLUMN IF NOT EXISTS project_spent_before numeric, ADD COLUMN IF NOT EXISTS alert_at timestamptz,
  ADD COLUMN IF NOT EXISTS seller_window_s integer;
ALTER TABLE public.n2s_autobuy_config
  ADD COLUMN IF NOT EXISTS project_stopped_at timestamptz, ADD COLUMN IF NOT EXISTS project_stopped_reason text,
  ADD COLUMN IF NOT EXISTS gt_project_stopped_at timestamptz, ADD COLUMN IF NOT EXISTS gt_project_stopped_reason text,
  ADD COLUMN IF NOT EXISTS stop_emailed_at timestamptz,
  ADD COLUMN IF NOT EXISTS seller_window_pct numeric DEFAULT 0.9, ADD COLUMN IF NOT EXISTS seller_window_min_samples integer DEFAULT 20,
  ADD COLUMN IF NOT EXISTS seller_window_fallback_s integer DEFAULT 540, ADD COLUMN IF NOT EXISTS gt_seller_window_s integer DEFAULT 540,
  ADD COLUMN IF NOT EXISTS default_cutoff_s integer DEFAULT 900, ADD COLUMN IF NOT EXISTS accept_buffer_s integer DEFAULT 60,
  ADD COLUMN IF NOT EXISTS allow_same_day boolean DEFAULT true, ADD COLUMN IF NOT EXISTS max_read_age_s integer DEFAULT 120;
ALTER TABLE public.n2s_gt_order_dryrun
  ADD COLUMN IF NOT EXISTS s4k_source text, ADD COLUMN IF NOT EXISTS order_number text, ADD COLUMN IF NOT EXISTS event_name text,
  ADD COLUMN IF NOT EXISTS tevo_event_id bigint, ADD COLUMN IF NOT EXISTS sub_qty integer, ADD COLUMN IF NOT EXISTS sold_ea numeric,
  ADD COLUMN IF NOT EXISTS quoted_ea numeric, ADD COLUMN IF NOT EXISTS live_price_ea numeric,
  ADD COLUMN IF NOT EXISTS live_pulled_at timestamptz, ADD COLUMN IF NOT EXISTS captured_at timestamptz DEFAULT now();
CREATE TABLE IF NOT EXISTS public.n2s_tickpick_seen (order_number text, confirm_by timestamptz);
CREATE OR REPLACE VIEW public.v_n2s_market_cutoff AS
  SELECT NULL::text AS market, NULL::integer AS median_cutoff_s, 0 AS samples WHERE false;
CREATE OR REPLACE FUNCTION public.n2s_evo_seller_window(numeric, integer, integer)
 RETURNS TABLE (window_s integer, in_hand_window_s integer) LANGUAGE sql AS $$ SELECT 60, 60 $$;
CREATE OR REPLACE FUNCTION public.n2s_evo_venue_tax_rate(bigint) RETURNS numeric LANGUAGE sql AS $$ SELECT 0::numeric $$;
CREATE OR REPLACE FUNCTION public.n2s_autobuy_event_lead(c public.n2s_autobuy_config, p_start timestamptz)
 RETURNS interval LANGUAGE sql AS $$ SELECT interval '6 hours' $$;
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
  v_start    timestamptz;
  v_tax      numeric;
  v_cost     numeric;
  v_left     interval;
  v_win      int;
  v_win_hand int;
  -- 20261113400000: GoTickets subs have their own run, caps and stop flag
  v_gt       boolean := (NEW.sub_source = 'gotickets');
  v_cap_ord  numeric;
  v_cap_day  numeric;
  v_cap_proj numeric;
  v_stopped  boolean;
BEGIN
  -- FOR UPDATE serializes enqueues: concurrent would_buys queue here, so each sees the spend
  -- the others committed and two buys can never both pass the daily / project cap.
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id FOR UPDATE;
  SELECT * INTO i FROM public.n2s_items WHERE n2s_id = NEW.n2s_id;
  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec WHERE n2s_id = NEW.n2s_id) THEN
    RETURN NULL;                                         -- one attempt per sale; never a retry
  END IF;
  v_cap_ord  := CASE WHEN v_gt THEN c.gt_per_order_cap_usd ELSE c.per_order_cap_usd END;
  v_cap_day  := CASE WHEN v_gt THEN c.gt_daily_cap_usd ELSE c.daily_cap_usd END;
  v_cap_proj := CASE WHEN v_gt THEN c.gt_project_cap_usd ELSE c.project_cap_usd END;
  v_stopped  := CASE WHEN v_gt THEN c.gt_project_stopped ELSE c.project_stopped END;
  -- 20261111000000: the event's real start (UTC), from public.events' offset-bearing text; else the
  -- venue-local time read as UTC, which is never later than the real start for US venues.
  BEGIN
    SELECT NULLIF(e.occurs_at_local, '')::timestamptz INTO v_start FROM public.events e WHERE e.id = NEW.tevo_event_id;
  EXCEPTION WHEN OTHERS THEN
    v_start := NULL;
  END;
  v_start := COALESCE(v_start, i.event_dt AT TIME ZONE 'UTC');

  v_market := CASE WHEN lower(NEW.s4k_source) LIKE 'evo%' THEN 'evo'
                   WHEN lower(NEW.s4k_source) LIKE 'gotickets%' THEN 'gotickets'
                   WHEN lower(NEW.s4k_source) LIKE 'seatgeek%' THEN 'seatgeek'
                   WHEN lower(NEW.s4k_source) LIKE 'vivid%' THEN 'vivid'
                   WHEN lower(NEW.s4k_source) LIKE 'tickpick%' THEN 'tickpick' END;
  v_qty   := NEW.sub_qty;
  v_price := COALESCE(NEW.live_price_ea, NEW.quoted_ea);
  v_sub   := round(v_price * v_qty, 2);
  v_sold  := round(NEW.sold_ea * NEW.sold_qty, 2);
  -- 20261112020000: EVO adds sales tax at some venues (Camp Randall, 5.5%, 2026-11-11). The cost
  -- every cap and the profit test use is the sub plus the tax EVO has charged us at this venue.
  -- 20261113400000: a GoTickets quote is the all-in price; its tax and delivery fee are only known
  -- from the live listing, so the worker re-runs every money guard on GoTickets' own total.
  v_tax   := CASE WHEN v_gt THEN 0
                  ELSE round(COALESCE(v_sub, 0) * public.n2s_evo_venue_tax_rate(NEW.tevo_event_id), 2) END;
  v_cost  := v_sub + v_tax;
  -- 20261112020000: how long EVO's sellers take to accept our purchases (our own history, at
  -- seller_window_pct): the time the sub's seller needs before we may accept the sale.
  -- 20261113400000: GoTickets has no measured history yet, so its window is gt_seller_window_s.
  IF v_gt THEN
    v_win := c.gt_seller_window_s;
    v_win_hand := c.gt_seller_window_s;
  ELSE
    SELECT w.window_s, w.in_hand_window_s INTO v_win, v_win_hand
      FROM public.n2s_evo_seller_window(c.seller_window_pct, c.seller_window_min_samples, c.seller_window_fallback_s) w;
  END IF;

  IF v_market = 'tickpick' THEN
    -- 20261110070000: TickPick states each sale's own confirm deadline (10 min for a same-day
    -- event, 60 min later out, 2026-11-10). Use it once n2s_tickpick_watch_tick has seen the
    -- sale; until then 9 min, under the shortest window seen.
    SELECT extract(epoch FROM s.confirm_by - i.alert_at)::int INTO v_cut
      FROM public.n2s_tickpick_seen s WHERE s.order_number = i.n2s_order_key AND s.confirm_by IS NOT NULL;
    v_cut_src := CASE WHEN v_cut IS NULL THEN 'tickpick default (deadline not seen yet)'
                      ELSE 'tickpick confirmation_deadline' END;
    v_cut := COALESCE(v_cut, 540);
  ELSE
    -- allotted time: the market's median auto-reject (≥ 3 samples), else the CRM's 15 minutes
    SELECT median_cutoff_s, 'median of ' || samples || ' market rejects' INTO v_cut, v_cut_src
      FROM public.v_n2s_market_cutoff WHERE market = v_market AND samples >= 3;
    IF v_cut IS NULL THEN v_cut := c.default_cutoff_s; v_cut_src := 'default (no market data)'; END IF;
  END IF;
  v_confirm := i.alert_at + make_interval(secs => v_cut - c.accept_buffer_s);

  -- 20261113400000: spend, buys and failures are counted per sub source (separate caps)
  SELECT COALESCE(sum(sub_total_usd + COALESCE(est_tax_usd, 0))
                   FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL)), 0),
         count(*) FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL)),
         count(*) FILTER (WHERE state = 'blocked' AND 'circuit_breaker' <> ALL (reasons)
                            AND reasons && ARRAY['sub_rejected', 'sub_unconfirmed', 'buy_failed'])
    INTO v_spend, v_buys, v_fail
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND sub_source = NEW.sub_source
     AND (created_at AT TIME ZONE 'America/New_York')::date = v_tz_today;

  -- Project spend: every buy ever committed in this mode from this sub source, any market.
  SELECT COALESCE(sum(sub_total_usd + COALESCE(est_tax_usd, 0)), 0) INTO v_proj
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND sub_source = NEW.sub_source
     AND state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL);

  IF c.mode = 'off' OR c.kill_switch THEN
    v_state := 'off';
  ELSE
    IF v_market IS NULL THEN r := r || 'sell_market_no_token'::text; END IF;
    IF NEW.sub_source NOT IN ('gotickets', 'tevo') THEN r := r || 'sub_source_not_buyable'::text; END IF;
    -- 20261109200000: soft launch buys only from the sources listed in buy_sources.
    IF NEW.sub_source <> ALL (c.buy_sources) THEN r := r || 'sub_source_disabled'::text; END IF;
    -- 20261110000000 / 20261113400000: live mode = an EVO or GoTickets sub, while that source's
    -- live runs remain; a GoTickets buy also needs the buyer profile and the GoTickets event id.
    IF c.mode = 'live' THEN
      IF v_market IS NULL OR v_market <> ALL (c.live_sell_markets) THEN r := r || 'sell_market_not_live'::text; END IF;
      IF NEW.sub_source NOT IN ('tevo', 'gotickets') THEN r := r || 'sub_source_not_live'::text; END IF;
      IF (v_gt AND c.gt_live_runs_used >= c.gt_live_runs_allowed)
         OR (NOT v_gt AND c.live_runs_used >= c.live_runs_allowed) THEN
        r := r || 'live_runs_used_up'::text;
      END IF;
      IF v_gt AND NOT public.n2s_autobuy_gt_profile_ok(c) THEN r := r || 'gt_buyer_profile_missing'::text; END IF;
      IF v_gt AND NEW.gt_event_id IS NULL THEN r := r || 'no_gt_event_id'::text; END IF;
    END IF;
    IF v_start IS NULL THEN
      r := r || 'event_time_unknown'::text;
    ELSE
      -- 20261111000000: lead counted from the real start; 'event_within_24h' now means "within
      -- min_event_lead" (12 h since 20261111000000). Same-day sales allowed when allow_same_day.
      IF v_start < now() + public.n2s_autobuy_event_lead(c, v_start) THEN r := r || 'event_within_24h'::text; END IF;
      IF NOT c.allow_same_day
         AND COALESCE(i.event_dt::date, (v_start AT TIME ZONE 'America/New_York')::date) <= v_tz_today THEN
        r := r || 'same_day_event'::text;
      END IF;
    END IF;
    IF v_sub IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN r := r || 'no_price'::text; END IF;
    IF v_cost > v_cap_ord THEN r := r || 'over_per_order_cap'::text; END IF;
    IF v_spend + v_cost > v_cap_day THEN r := r || 'over_daily_cap'::text; END IF;
    IF v_buys >= c.max_buys_per_day THEN r := r || 'max_buys_today'::text; END IF;
    IF v_fail >= c.max_failures_per_day THEN r := r || 'circuit_breaker'::text; END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.tevo_event_id = NEW.tevo_event_id AND x.mode = c.mode
                  AND x.state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL)
                  AND (x.created_at AT TIME ZONE 'America/New_York')::date = v_tz_today) THEN
      r := r || 'event_already_bought_today'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.sub_source = NEW.sub_source AND x.sub_listing_id = NEW.sub_listing_id
                  AND x.state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL)) THEN
      r := r || 'listing_already_used'::text;
    END IF;
    IF v_sold IS NULL OR v_cost >= v_sold THEN r := r || 'not_profitable'::text; END IF;
    IF NEW.live_price_ea IS NOT NULL AND NEW.quoted_ea IS NOT NULL AND NEW.live_price_ea > NEW.quoted_ea THEN
      r := r || 'price_rose'::text;
    END IF;
    IF NEW.live_pulled_at IS NULL OR NEW.captured_at - NEW.live_pulled_at > make_interval(secs => c.max_read_age_s) THEN
      r := r || 'stale_live_read'::text;
    END IF;
    -- 20261112020000: the real clock. A row from the minute tick is inserted up to a minute after
    -- that transaction's now(), which made the time left look longer than it was.
    v_left := v_confirm - clock_timestamp();
    IF i.alert_at IS NULL OR v_left < make_interval(secs => c.min_confirm_window_s) THEN
      r := r || 'not_enough_time_for_market'::text;
    ELSIF v_left < make_interval(secs => GREATEST(c.min_confirm_window_s, COALESCE(v_win_hand, 0))) THEN
      -- even a seller holding the tickets in hand may not accept before the sale must be confirmed
      r := r || 'not_enough_time_for_seller'::text;
    END IF;
    IF v_stopped THEN
      r := r || 'stopped_pending_review'::text;
    ELSIF v_cost IS NOT NULL AND v_proj + v_cost > v_cap_proj THEN
      -- Stop only when the cap is what blocks a buy that would otherwise go through; a sub
      -- already blocked by another guard (e.g. a $1,800 one over the order cap) must not freeze buying.
      IF cardinality(r) = 0 THEN
        IF v_gt THEN
          UPDATE public.n2s_autobuy_config SET gt_project_stopped = true, gt_project_stopped_at = now(), updated_at = now(),
                 gt_project_stopped_reason = format('dryrun %s: $%s would take GoTickets project spend from $%s past the $%s cap',
                                                    NEW.dryrun_id, v_cost, v_proj, v_cap_proj)
           WHERE id;
        ELSE
          UPDATE public.n2s_autobuy_config SET project_stopped = true, project_stopped_at = now(), updated_at = now(),
                 project_stopped_reason = format('dryrun %s: $%s would take project spend from $%s past the $%s cap',
                                             NEW.dryrun_id, v_cost, v_proj, v_cap_proj)
           WHERE id;
        END IF;
      END IF;
      r := r || 'over_project_cap'::text;
    END IF;
    v_state := CASE WHEN cardinality(r) > 0 THEN 'blocked'
                    WHEN v_cost > c.approval_over_usd THEN 'awaiting_approval'
                    WHEN c.mode = 'live' THEN 'live_buy'
                    ELSE 'shadow_buy' END;
  END IF;

  INSERT INTO public.n2s_autobuy_exec
         (n2s_id, dryrun_id, mode, state, reasons, sell_market, order_number, sub_source, sub_listing_id,
          tevo_event_id, event_name, event_dt_local, qty, sub_total_usd, sold_total_usd, margin_usd, alert_at,
          cutoff_s, cutoff_source, sub_confirm_by, sale_deadline, spend_today_before, project_spent_before,
          event_start_utc, est_tax_usd, seller_window_s, seller_window_in_hand_s)
  VALUES (NEW.n2s_id, NEW.dryrun_id, c.mode, v_state, r, v_market, NEW.order_number, NEW.sub_source,
          NEW.sub_listing_id, NEW.tevo_event_id, NEW.event_name, i.event_dt, v_qty, v_sub, v_sold,
          v_sold - v_cost, i.alert_at, v_cut, v_cut_src, v_confirm,
          i.alert_at + make_interval(secs => v_cut), v_spend, v_proj, v_start, v_tax, v_win, v_win_hand)
  ON CONFLICT DO NOTHING;
  -- reaching the project cap exactly also stops buying (this source) until the operator reviews
  IF v_state IN ('shadow_buy', 'live_buy', 'awaiting_approval')
     AND v_proj + v_cost >= v_cap_proj THEN
    IF v_gt THEN
      UPDATE public.n2s_autobuy_config SET gt_project_stopped = true, gt_project_stopped_at = now(), updated_at = now(),
             gt_project_stopped_reason = format('GoTickets project spend reached $%s of the $%s cap (dryrun %s)',
                                                v_proj + v_cost, v_cap_proj, NEW.dryrun_id)
       WHERE id;
    ELSE
      UPDATE public.n2s_autobuy_config SET project_stopped = true, project_stopped_at = now(), updated_at = now(),
             project_stopped_reason = format('Project spend reached $%s of the $%s cap (dryrun %s)',
                                         v_proj + v_cost, v_cap_proj, NEW.dryrun_id)
       WHERE id;
    END IF;
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'n2s_autobuy_enqueue_trg: % (dryrun %)', SQLERRM, NEW.dryrun_id;  -- never break the dry run
  RETURN NULL;
END $function$;;
CREATE TRIGGER n2s_autobuy_enqueue_trg
  AFTER INSERT ON public.n2s_gt_order_dryrun
  FOR EACH ROW WHEN (NEW.decision = 'would_buy' AND NEW.n2s_id > 0)
  EXECUTE FUNCTION public.n2s_autobuy_enqueue_trg();
CREATE OR REPLACE FUNCTION public.n2s_autobuy_job_json(p_exec_id bigint, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c      public.n2s_autobuy_config%ROWTYPE;
  e      public.n2s_autobuy_exec%ROWTYPE;
  v_sale text;
  v_gt   boolean;
  v_gt_event bigint;
BEGIN
  SELECT * INTO e FROM public.n2s_autobuy_exec WHERE exec_id = p_exec_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;
  SELECT n2s_order_key INTO v_sale FROM public.n2s_items WHERE n2s_id = e.n2s_id;
  v_gt := (e.sub_source = 'gotickets');
  SELECT d.gt_event_id INTO v_gt_event FROM public.n2s_gt_order_dryrun d WHERE d.dryrun_id = e.dryrun_id;

  RETURN jsonb_build_object(
    'action', p_action,
    'row', to_jsonb(e) || jsonb_build_object('sale_order_key', v_sale, 'gt_event_id', v_gt_event),
    'cfg', jsonb_build_object(
      -- this sub source's caps (20261113400000: GoTickets has its own)
      'per_order_cap_usd', CASE WHEN v_gt THEN c.gt_per_order_cap_usd ELSE c.per_order_cap_usd END,
      'daily_cap_usd', CASE WHEN v_gt THEN c.gt_daily_cap_usd ELSE c.daily_cap_usd END,
      'max_buys_per_day', c.max_buys_per_day, 'max_failures_per_day', c.max_failures_per_day,
      'approval_over_usd', c.approval_over_usd,
      'project_cap_usd', CASE WHEN v_gt THEN c.gt_project_cap_usd ELSE c.project_cap_usd END,
      'min_event_lead_s', extract(epoch FROM public.n2s_autobuy_event_lead(c, e.event_start_utc))::int,
      'min_confirm_window_s', c.min_confirm_window_s, 'buy_sources', to_jsonb(c.buy_sources),
      'evo_buyer_office_id', c.evo_buyer_office_id, 'evo_reviewer_id', c.evo_reviewer_id,
      'evo_email_address_id', c.evo_email_address_id,
      'tax_quote', c.tax_quote,
      'gt_buyer_email', c.gt_buyer_email, 'gt_buyer_phone', c.gt_buyer_phone,
      'gt_billing_address', c.gt_billing_address, 'gt_recipient', c.gt_recipient,
      'gt_gift_card_ids', to_jsonb(c.gt_gift_card_ids)));
END $function$;
