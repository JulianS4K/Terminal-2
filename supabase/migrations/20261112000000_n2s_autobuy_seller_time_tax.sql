-- Migration 20261112000000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,n2s_autobuy_exec,n2s_evo_seller_window,n2s_evo_venue_tax_rate,n2s_autobuy_enqueue_trg,n2s_autobuy_live_claim,n2s_autobuy_live_record · reads:evo_orders,events,n2s_gt_order_dryrun,n2s_items,v_n2s_market_cutoff,n2s_tickpick_seen · pre:20261111020000
--
-- N2S auto-buy LIVE: time for the sub's seller, EVO's tax, the real clock, a safe retry.
--
-- Operator 2026-11-11, after a timing study of our 129 EVO purchases ("do it all"):
--   * Sellers on EVO accept our purchases in a median 16 s, but 1 in 10 takes 8.5 min or more.
--     A sale's window is short (EVO auto-rejects at a median 12.4 min) and the old floor for
--     time left was 90 s. Nothing visible before a buy names the real seller: every listing
--     shows Victory Live's exchange office (1692). The one signal is in_hand: listings in hand
--     reach p90 at 298 s, not in hand at 534 s.
--   * EVO charged sales tax on 2 of 129 buys (Camp Randall, 5.5%, 2026-11-11), which nothing
--     here counted: a capped buy could cost more than the cap and look more profitable than it was.
--   * Rows from the one-minute pipeline tick are stamped with that transaction's now(), up to
--     a minute before they are inserted, so the time-left check read stale time.
--   * The live worker's database calls fail now and then with "Server disconnected" (5 times on
--     2026-11-11). A retried record of a step that had already landed would flip kill_switch.
--
--   1. n2s_evo_seller_window(pct, min_samples, fallback_s): acceptance time of our EVO purchases
--      at that percentile, for listings in hand and for the rest (fallback when too few samples).
--      Config: seller_window_pct 0.9, seller_window_min_samples 20, seller_window_fallback_s 540.
--   2. n2s_evo_venue_tax_rate(event): the highest tax rate EVO has charged us at that venue, else 0.
--   3. n2s_autobuy_enqueue_trg(): cost = sub + that tax for every cap, approval and the profit test
--      (stored as est_tax_usd; sub_total_usd stays the pre-tax quote); time left read from the
--      real clock; new skip 'not_enough_time_for_seller' when even an in-hand seller's window
--      does not fit; the two windows are stored on the row for the worker.
--   4. n2s_autobuy_live_claim(): hands out a buy only with that in-hand window left (it spends the
--      live run the moment it hands one out). The worker re-checks with the listing's own in_hand.
--   5. n2s_autobuy_live_record(): a repeated call for a step that is already recorded returns the
--      phase and changes nothing; holds ('buying', 'sub_accepted') still need the live lease.
--   6. n2s_autobuy_live_record(): a run the worker stops BEFORE sending the buy (a guard, the fresh
--      listing read, the seller-time check) gives the live run back. The live run is a buy sent to
--      EVO: one EVO rejected ('buy_failed') or whose outcome is unknown still counts. Without this
--      the new seller-time check would spend the one test run on a buy that never went out.
--
-- rollback: UPDATE n2s_autobuy_config SET seller_window_pct = 0.01, seller_window_fallback_s = 0;
--           (to keep counting a stopped-before-send run, re-create the record function from 20261110000000)
--           (windows ~0 s: the 90 s floor is all that is left) and re-create the three functions from
--           20261111000000 (enqueue) and 20261110000000 (claim, record); added columns are harmless.

ALTER TABLE public.n2s_autobuy_config
  ADD COLUMN IF NOT EXISTS seller_window_pct         numeric NOT NULL DEFAULT 0.9
                           CHECK (seller_window_pct > 0 AND seller_window_pct < 1),
  ADD COLUMN IF NOT EXISTS seller_window_min_samples integer NOT NULL DEFAULT 20 CHECK (seller_window_min_samples >= 1),
  ADD COLUMN IF NOT EXISTS seller_window_fallback_s  integer NOT NULL DEFAULT 540 CHECK (seller_window_fallback_s >= 0);
ALTER TABLE public.n2s_autobuy_exec
  ADD COLUMN IF NOT EXISTS est_tax_usd             numeric,
  ADD COLUMN IF NOT EXISTS seller_window_s         integer,
  ADD COLUMN IF NOT EXISTS seller_window_in_hand_s integer;

-- Seconds from our EVO purchase to the seller accepting it, per purchase: 'accepted' = its last
-- update; 'completed' = the item's own update when it came later than the order (the accept), else
-- the delivery. Third-party sellers only (not our own office). Never errors: unreadable history
-- gives the fallback for both windows.
CREATE OR REPLACE FUNCTION public.n2s_evo_seller_window(p_pct numeric, p_min_samples integer, p_fallback_s integer)
 RETURNS TABLE(window_s integer, in_hand_window_s integer, samples integer, in_hand_samples integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_all int; v_hand int; v_n int; v_nh int; v_not int; v_nn int;
BEGIN
  WITH a AS (
    SELECT (o.raw #>> '{items,0,ticket_group,in_hand}') = 'true' AS in_hand,
           CASE WHEN o.state = 'accepted' THEN
                  extract(epoch FROM (o.raw ->> 'updated_at')::timestamptz - (o.raw ->> 'created_at')::timestamptz)
                ELSE
                  extract(epoch FROM LEAST(
                    CASE WHEN (o.raw #>> '{items,0,updated_at}')::timestamptz
                              > (o.raw ->> 'created_at')::timestamptz + interval '3 seconds'
                         THEN (o.raw #>> '{items,0,updated_at}')::timestamptz END,
                    (o.raw #>> '{shipments,0,updated_at}')::timestamptz) - (o.raw ->> 'created_at')::timestamptz)
           END AS s
      FROM public.evo_orders o
     WHERE o.buyer_brokerage_id = 1768 AND o.seller_brokerage_id IS DISTINCT FROM 1768
       AND o.state IN ('accepted', 'completed'))
  SELECT ceil(percentile_cont(p_pct) WITHIN GROUP (ORDER BY s))::int,
         ceil(percentile_cont(p_pct) WITHIN GROUP (ORDER BY s) FILTER (WHERE in_hand))::int,
         ceil(percentile_cont(p_pct) WITHIN GROUP (ORDER BY s) FILTER (WHERE NOT in_hand))::int,
         count(*)::int, (count(*) FILTER (WHERE in_hand))::int, (count(*) FILTER (WHERE NOT in_hand))::int
    INTO v_all, v_hand, v_not, v_n, v_nh, v_nn
    FROM a WHERE s >= 0;
  v_all  := CASE WHEN v_n  >= p_min_samples THEN v_all  ELSE p_fallback_s END;
  v_hand := CASE WHEN v_nh >= p_min_samples THEN v_hand ELSE v_all END;
  v_not  := CASE WHEN v_nn >= p_min_samples THEN v_not  ELSE v_all END;
  RETURN QUERY SELECT GREATEST(v_hand, v_not), v_hand, v_n, v_nh;
EXCEPTION WHEN OTHERS THEN
  RETURN QUERY SELECT p_fallback_s, p_fallback_s, 0, 0;
END $function$;

-- The highest tax rate EVO has charged on our purchases at this event's venue (0 when it never has
-- or the venue is unknown). Capped at 15% so one bad row cannot make every buy look unaffordable.
CREATE OR REPLACE FUNCTION public.n2s_evo_venue_tax_rate(p_tevo_event_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_rate numeric;
BEGIN
  SELECT max(o.tax / o.subtotal) INTO v_rate
    FROM public.evo_orders o
    JOIN public.events oe
      ON oe.id = COALESCE(o.tevo_event_id, NULLIF(o.raw #>> '{shipments,0,items,0,ticket_group,event,id}', '')::bigint)
    JOIN public.events se ON se.venue_id = oe.venue_id
   WHERE se.id = p_tevo_event_id AND o.buyer_brokerage_id = 1768
     AND o.subtotal > 0 AND o.tax > 0;
  RETURN LEAST(COALESCE(v_rate, 0), 0.15);
EXCEPTION WHEN OTHERS THEN
  RETURN 0;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_evo_seller_window(numeric, integer, integer),
                       public.n2s_evo_venue_tax_rate(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_evo_seller_window(numeric, integer, integer),
                          public.n2s_evo_venue_tax_rate(bigint) TO service_role;

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
BEGIN
  -- FOR UPDATE serializes enqueues: concurrent would_buys queue here, so each sees the spend
  -- the others committed and two buys can never both pass the daily / project cap.
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id FOR UPDATE;
  SELECT * INTO i FROM public.n2s_items WHERE n2s_id = NEW.n2s_id;
  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec WHERE n2s_id = NEW.n2s_id) THEN
    RETURN NULL;                                         -- one attempt per sale; never a retry
  END IF;
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
  -- 20261112000000: EVO adds sales tax at some venues (Camp Randall, 5.5%, 2026-11-11). The cost
  -- every cap and the profit test use is the sub plus the tax EVO has charged us at this venue.
  v_tax   := round(COALESCE(v_sub, 0) * public.n2s_evo_venue_tax_rate(NEW.tevo_event_id), 2);
  v_cost  := v_sub + v_tax;
  -- 20261112000000: how long EVO's sellers take to accept our purchases (our own history, at
  -- seller_window_pct): the time the sub's seller needs before we may accept the sale.
  SELECT w.window_s, w.in_hand_window_s INTO v_win, v_win_hand
    FROM public.n2s_evo_seller_window(c.seller_window_pct, c.seller_window_min_samples, c.seller_window_fallback_s) w;

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

  SELECT COALESCE(sum(sub_total_usd + COALESCE(est_tax_usd, 0))
                   FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')), 0),
         count(*) FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')),
         count(*) FILTER (WHERE state = 'blocked' AND 'circuit_breaker' <> ALL (reasons)
                            AND reasons && ARRAY['sub_rejected', 'sub_unconfirmed', 'buy_failed'])
    INTO v_spend, v_buys, v_fail
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND (created_at AT TIME ZONE 'America/New_York')::date = v_tz_today;

  -- Project spend: every buy ever committed in this mode, any market.
  SELECT COALESCE(sum(sub_total_usd + COALESCE(est_tax_usd, 0)), 0) INTO v_proj
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved');

  IF c.mode = 'off' OR c.kill_switch THEN
    v_state := 'off';
  ELSE
    IF v_market IS NULL THEN r := r || 'sell_market_no_token'::text; END IF;
    IF NEW.sub_source NOT IN ('gotickets', 'tevo') THEN r := r || 'sub_source_not_buyable'::text; END IF;
    -- 20261109200000: soft launch buys only from the sources listed in buy_sources (EVO).
    IF NEW.sub_source <> ALL (c.buy_sources) THEN r := r || 'sub_source_disabled'::text; END IF;
    -- 20261110000000: live mode = an EVO sub covering an EVO sale, only while live runs remain.
    IF c.mode = 'live' THEN
      IF v_market IS NULL OR v_market <> ALL (c.live_sell_markets) THEN r := r || 'sell_market_not_live'::text; END IF;
      IF NEW.sub_source <> 'tevo' THEN r := r || 'sub_source_not_live'::text; END IF;
      IF c.live_runs_used >= c.live_runs_allowed THEN r := r || 'live_runs_used_up'::text; END IF;
    END IF;
    IF v_start IS NULL THEN
      r := r || 'event_time_unknown'::text;
    ELSE
      -- 20261111000000: lead counted from the real start; 'event_within_24h' now means "within
      -- min_event_lead" (12 h since 20261111000000). Same-day sales allowed when allow_same_day.
      IF v_start < now() + c.min_event_lead THEN r := r || 'event_within_24h'::text; END IF;
      IF NOT c.allow_same_day
         AND COALESCE(i.event_dt::date, (v_start AT TIME ZONE 'America/New_York')::date) <= v_tz_today THEN
        r := r || 'same_day_event'::text;
      END IF;
    END IF;
    IF v_sub IS NULL OR v_qty IS NULL OR v_qty <= 0 THEN r := r || 'no_price'::text; END IF;
    IF v_cost > c.per_order_cap_usd THEN r := r || 'over_per_order_cap'::text; END IF;
    IF v_spend + v_cost > c.daily_cap_usd THEN r := r || 'over_daily_cap'::text; END IF;
    IF v_buys >= c.max_buys_per_day THEN r := r || 'max_buys_today'::text; END IF;
    IF v_fail >= c.max_failures_per_day THEN r := r || 'circuit_breaker'::text; END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.tevo_event_id = NEW.tevo_event_id AND x.mode = c.mode
                  AND x.state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')
                  AND (x.created_at AT TIME ZONE 'America/New_York')::date = v_tz_today) THEN
      r := r || 'event_already_bought_today'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.sub_source = NEW.sub_source AND x.sub_listing_id = NEW.sub_listing_id
                  AND x.state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')) THEN
      r := r || 'listing_already_used'::text;
    END IF;
    IF v_sold IS NULL OR v_cost >= v_sold THEN r := r || 'not_profitable'::text; END IF;
    IF NEW.live_price_ea IS NOT NULL AND NEW.quoted_ea IS NOT NULL AND NEW.live_price_ea > NEW.quoted_ea THEN
      r := r || 'price_rose'::text;
    END IF;
    IF NEW.live_pulled_at IS NULL OR NEW.captured_at - NEW.live_pulled_at > make_interval(secs => c.max_read_age_s) THEN
      r := r || 'stale_live_read'::text;
    END IF;
    -- 20261112000000: the real clock. A row from the minute tick is inserted up to a minute after
    -- that transaction's now(), which made the time left look longer than it was.
    v_left := v_confirm - clock_timestamp();
    IF i.alert_at IS NULL OR v_left < make_interval(secs => c.min_confirm_window_s) THEN
      r := r || 'not_enough_time_for_market'::text;
    ELSIF v_left < make_interval(secs => GREATEST(c.min_confirm_window_s, COALESCE(v_win_hand, 0))) THEN
      -- even a seller holding the tickets in hand may not accept before the sale must be confirmed
      r := r || 'not_enough_time_for_seller'::text;
    END IF;
    IF c.project_stopped THEN
      r := r || 'stopped_pending_review'::text;
    ELSIF v_cost IS NOT NULL AND v_proj + v_cost > c.project_cap_usd THEN
      -- Stop only when the cap is what blocks a buy that would otherwise go through; a sub
      -- already blocked by another guard (e.g. a $1,800 one over the order cap) must not freeze buying.
      IF cardinality(r) = 0 THEN
        UPDATE public.n2s_autobuy_config SET project_stopped = true, project_stopped_at = now(), updated_at = now(),
               project_stopped_reason = format('dryrun %s: $%s would take project spend from $%s past the $%s cap',
                                           NEW.dryrun_id, v_cost, v_proj, c.project_cap_usd)
         WHERE id;
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
  -- reaching the project cap exactly also stops buying until the operator reviews
  IF v_state IN ('shadow_buy', 'live_buy', 'awaiting_approval')
     AND v_proj + v_cost >= c.project_cap_usd THEN
    UPDATE public.n2s_autobuy_config SET project_stopped = true, project_stopped_at = now(), updated_at = now(),
           project_stopped_reason = format('Project spend reached $%s of the $%s cap (dryrun %s)',
                                       v_proj + v_cost, c.project_cap_usd, NEW.dryrun_id)
     WHERE id;
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'n2s_autobuy_enqueue_trg: % (dryrun %)', SQLERRM, NEW.dryrun_id;  -- never break the dry run
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_enqueue_trg() FROM PUBLIC, anon, authenticated;

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
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id FOR UPDATE;
  IF c.mode <> 'live' OR c.kill_switch THEN RETURN NULL; END IF;
  -- Fail closed: a buy whose worker lost its lease may or may not have reached EVO.
  UPDATE public.n2s_autobuy_exec
     SET phase = 'buy_unknown', reasons = reasons || 'worker_lost'::text, lease_until = NULL, lease_token = NULL,
         live_error = COALESCE(live_error, 'lease expired during the buy step: check EVO for this purchase'),
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
  ELSIF NOT c.project_stopped AND c.live_runs_used < c.live_runs_allowed THEN
    -- 20261112000000: handing out a buy spends the live run, so only hand one out while even a
    -- seller with the tickets in hand still has time to accept (the window stored at enqueue).
    SELECT * INTO e FROM public.n2s_autobuy_exec
     WHERE mode = 'live' AND state IN ('live_buy', 'approved') AND phase IS NULL
       AND sub_source = 'tevo' AND sell_market = ANY (c.live_sell_markets)
       AND sub_confirm_by - now() > make_interval(secs => GREATEST(c.min_confirm_window_s,
                                                                   COALESCE(seller_window_in_hand_s, 0)))
     ORDER BY exec_id LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF FOUND THEN
      v_act := 'buy';
      UPDATE public.n2s_autobuy_config SET live_runs_used = live_runs_used + 1, updated_at = now() WHERE id;
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

  RETURN jsonb_build_object(
    'action', v_act,
    'row', to_jsonb(e) || jsonb_build_object('sale_order_key', v_sale),
    'cfg', jsonb_build_object(
      'per_order_cap_usd', c.per_order_cap_usd, 'daily_cap_usd', c.daily_cap_usd,
      'max_buys_per_day', c.max_buys_per_day, 'max_failures_per_day', c.max_failures_per_day,
      'approval_over_usd', c.approval_over_usd, 'project_cap_usd', c.project_cap_usd,
      'min_event_lead_s', extract(epoch FROM c.min_event_lead)::int,
      'min_confirm_window_s', c.min_confirm_window_s, 'buy_sources', to_jsonb(c.buy_sources),
      'evo_buyer_office_id', c.evo_buyer_office_id, 'evo_reviewer_id', c.evo_reviewer_id,
      'evo_email_address_id', c.evo_email_address_id));
END $function$;

-- The worker's result for one step, only under its own unexpired lease ('lease_lost' otherwise).
-- An unknown write outcome sets kill_switch whatever the lease says.
-- 20261112000000: the worker retries a call once when the connection drops. A repeat of a step
-- that already landed (same phase, same purchase id) returns that phase and changes nothing, so a
-- retried 'buy_sent' can no longer fall into the lease-lost branch and flip kill_switch. Holds
-- ('buying', 'sub_accepted') are excluded: they must still prove the lease before a market write.
CREATE OR REPLACE FUNCTION public.n2s_autobuy_live_record(p_exec_id bigint, p_token uuid, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_phase text := p_patch ->> 'phase'; v_ok boolean; v_prev text; v_prev_order text;
BEGIN
  SELECT phase, buy_order_id INTO v_prev, v_prev_order FROM public.n2s_autobuy_exec WHERE exec_id = p_exec_id;
  UPDATE public.n2s_autobuy_exec
     SET phase        = COALESCE(v_phase, phase),
         buy_order_id = COALESCE(buy_order_id, p_patch ->> 'buy_order_id'),
         buy_state    = COALESCE(p_patch ->> 'buy_state', buy_state),
         sale_state   = COALESCE(p_patch ->> 'sale_state', sale_state),
         live_error   = COALESCE(p_patch ->> 'live_error', live_error),
         reasons      = reasons || COALESCE(ARRAY(SELECT jsonb_array_elements_text(p_patch -> 'reasons')), '{}'),
         lease_until  = CASE WHEN v_phase IN ('buying', 'sub_accepted') THEN lease_until END,
         lease_token  = CASE WHEN v_phase IN ('buying', 'sub_accepted') THEN lease_token END,
         live_updated_at = now()
   WHERE exec_id = p_exec_id AND mode = 'live' AND phase IS NOT NULL
     AND phase NOT IN ('accepted', 'stopped', 'buy_unknown', 'accept_failed', 'accept_unknown')
     AND lease_token = p_token AND lease_until > now();
  v_ok := FOUND;
  -- 20261112000000: stopped while still 'buying', with no purchase id and no EVO refusal = the
  -- worker stopped before the buy went out: the live run was not used, give it back.
  IF v_ok AND v_prev = 'buying' AND v_phase = 'stopped' AND v_prev_order IS NULL
     AND p_patch ->> 'buy_order_id' IS NULL AND NOT COALESCE((p_patch -> 'reasons') ? 'buy_failed', false) THEN
    UPDATE public.n2s_autobuy_config SET live_runs_used = GREATEST(live_runs_used - 1, 0), updated_at = now() WHERE id;
  END IF;
  -- an unknown write outcome flips kill_switch on EVERY call, a repeat included (fail closed)
  IF v_phase IN ('buy_unknown', 'accept_unknown') THEN
    UPDATE public.n2s_autobuy_config SET kill_switch = true, updated_at = now() WHERE id;
  END IF;
  IF NOT v_ok AND v_phase IS NOT NULL AND v_phase NOT IN ('buying', 'sub_accepted')
     AND EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                  WHERE x.exec_id = p_exec_id AND x.mode = 'live' AND x.phase = v_phase
                    AND (NOT p_patch ? 'buy_order_id' OR x.buy_order_id = p_patch ->> 'buy_order_id')) THEN
    RETURN v_phase;   -- a repeat of a step that is already recorded
  END IF;
  IF NOT v_ok AND p_patch ? 'buy_order_id' THEN
    -- the buy went through but this worker's lease is gone: keep the purchase id, fail closed
    UPDATE public.n2s_autobuy_exec
       SET buy_order_id = COALESCE(buy_order_id, p_patch ->> 'buy_order_id'), phase = 'buy_unknown',
           reasons = reasons || 'lease_lost_after_buy'::text, lease_until = NULL, lease_token = NULL,
           live_updated_at = now()
     WHERE exec_id = p_exec_id AND mode = 'live' AND phase = 'buying';
    UPDATE public.n2s_autobuy_config SET kill_switch = true, updated_at = now() WHERE id;
  END IF;
  IF NOT v_ok THEN RETURN 'lease_lost'; END IF;
  RETURN COALESCE(v_phase, 'recorded');
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_live_claim(), public.n2s_autobuy_live_record(bigint, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_live_claim(), public.n2s_autobuy_live_record(bigint, uuid, jsonb)
  TO service_role;
