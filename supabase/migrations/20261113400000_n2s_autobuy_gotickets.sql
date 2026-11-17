-- Migration 20261113400000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,n2s_autobuy_gt_profile_ok,n2s_autobuy_enqueue_trg,n2s_autobuy_live_claim,n2s_autobuy_live_record,n2s_autobuy_outcome_tick · reads:n2s_gt_order_dryrun,n2s_items,n2s_autobuy_exec,n2s_evo_seller_window,n2s_evo_venue_tax_rate,v_n2s_market_cutoff,n2s_tickpick_seen · pre:20261113110000
--
-- N2S auto-buy LIVE: GoTickets subs, like EVO subs.
--
-- Operator 2026-11-13: "wire in gotickets similar to evo and set same limits and same one buy
-- condition", then: GoTickets gets its OWN single live run, and its OWN $666 caps (per order,
-- per day, project), separate from EVO's.
--   * Why GoTickets: in the last 30 days GoTickets had the best gate-1 cover 21 times to EVO's 11.
--   * How it pays: gift cards. GoTickets shows a saved card to the API only when it is shared
--     with the whole account (global = true); none is (GET /payment-methods = [] 2026-11-13), so
--     POST /orders carries giftCardIds and no paymentMethodToken (gotickets_buy_client.py).
--   * GoTickets requires the buyer's email, phone, billing address and (Mobile Transfer / PDF)
--     a recipient on every order. Those live in the config (gt_buyer_email, gt_buyer_phone,
--     gt_billing_address, gt_recipient), never in code; until all are set no GoTickets row is
--     enqueued as a buy ('gt_buyer_profile_missing'). Operator 2026-11-13: "use the
--     tu@s4kent.com office info from evo as the buyer details" + "use julian G": set below from
--     EVO office 42029 (Office 3: tu@s4kent.com, 212-913-9751, 362 5th Ave, New York NY 10001).
--
--   1. n2s_autobuy_config: gt_live_runs_allowed (1) / gt_live_runs_used, gt_per_order_cap_usd /
--      gt_daily_cap_usd / gt_project_cap_usd (666 each), gt_project_stopped (+ at / reason),
--      gt_seller_window_s (540: no GoTickets acceptance history to measure; the EVO fallback),
--      the buyer profile, gt_gift_card_ids (NULL = any card with a balance); buy_sources gains
--      'gotickets'.
--   2. n2s_autobuy_enqueue_trg(): a GoTickets sub may be a live buy; spend, buys, failures and
--      the project total are counted per sub source, against that source's caps, run counter and
--      stop flag. GoTickets cost at enqueue is the quoted all-in total (no venue tax estimate);
--      the worker re-runs every money guard on GoTickets' own total, tax and delivery included.
--   3. n2s_autobuy_live_claim(): hands out a GoTickets buy while ITS run remains (spending it),
--      with that source's caps in cfg, the buyer profile, and the row's gt_event_id.
--   4. n2s_autobuy_live_record(): a stopped-before-send run is given back to its own source.
--   5. n2s_autobuy_outcome_tick(): the outcome email names the sub's market, not always EVO.
--
-- Nothing here calls a market. The one new market write is POST gotickets.com/rest/pro/api/orders,
-- path-pinned in gotickets_buy_client.py (RULE 2 carve-out, CLAUDE.md §2). Guarded: each replaced
-- function must match the prod text it was written against (md5).
--
-- rollback: UPDATE n2s_autobuy_config SET buy_sources = array_remove(buy_sources, 'gotickets'),
--           gt_live_runs_allowed = 0;  (stops every GoTickets buy at enqueue AND at claim), then
--           re-create the three functions from 20261112020000 / 20261113110000 if wanted.

-- ── 1. config ──────────────────────────────────────────────────────────────
ALTER TABLE public.n2s_autobuy_config
  ADD COLUMN IF NOT EXISTS gt_live_runs_allowed     integer NOT NULL DEFAULT 1   CHECK (gt_live_runs_allowed >= 0),
  ADD COLUMN IF NOT EXISTS gt_live_runs_used        integer NOT NULL DEFAULT 0   CHECK (gt_live_runs_used >= 0),
  ADD COLUMN IF NOT EXISTS gt_per_order_cap_usd     numeric NOT NULL DEFAULT 666 CHECK (gt_per_order_cap_usd >= 0),
  ADD COLUMN IF NOT EXISTS gt_daily_cap_usd         numeric NOT NULL DEFAULT 666 CHECK (gt_daily_cap_usd >= 0),
  ADD COLUMN IF NOT EXISTS gt_project_cap_usd       numeric NOT NULL DEFAULT 666 CHECK (gt_project_cap_usd >= 0),
  ADD COLUMN IF NOT EXISTS gt_project_stopped       boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS gt_project_stopped_at    timestamptz,
  ADD COLUMN IF NOT EXISTS gt_project_stopped_reason text,
  ADD COLUMN IF NOT EXISTS gt_seller_window_s       integer NOT NULL DEFAULT 540 CHECK (gt_seller_window_s >= 0),
  ADD COLUMN IF NOT EXISTS gt_buyer_email           text,
  ADD COLUMN IF NOT EXISTS gt_buyer_phone           text,
  ADD COLUMN IF NOT EXISTS gt_billing_address       jsonb,
  ADD COLUMN IF NOT EXISTS gt_recipient             jsonb,
  ADD COLUMN IF NOT EXISTS gt_gift_card_ids         bigint[];

COMMENT ON COLUMN public.n2s_autobuy_config.gt_billing_address IS
  'GoTickets billingAddress: {firstName, lastName, address1, city, state, postalCode, country}. 20261113400000.';
COMMENT ON COLUMN public.n2s_autobuy_config.gt_recipient IS
  'GoTickets recipient (who a Mobile Transfer / PDF goes to): {firstName, lastName, email, phoneNumber, address1?, city?, state?, postalCode?, country?}. 20261113400000.';
COMMENT ON COLUMN public.n2s_autobuy_config.gt_gift_card_ids IS
  'GoTickets gift cards the auto-buyer may spend (NULL = any card with a balance). 20261113400000.';

UPDATE public.n2s_autobuy_config
   SET buy_sources = buy_sources || 'gotickets'::text, updated_at = now()
 WHERE id AND NOT ('gotickets' = ANY (buy_sources));

-- The buyer profile (operator 2026-11-13): EVO office 42029's contact details, name Julian G.
-- Only fills fields that are still empty, so a later edit in the config is never overwritten.
UPDATE public.n2s_autobuy_config
   SET gt_buyer_email     = COALESCE(gt_buyer_email, 'tu@s4kent.com'),
       gt_buyer_phone     = COALESCE(gt_buyer_phone, '212-913-9751'),
       gt_billing_address = COALESCE(gt_billing_address, jsonb_build_object(
         'firstName', 'Julian', 'lastName', 'G', 'address1', '362 5th Ave', 'city', 'New York',
         'state', 'NY', 'postalCode', '10001', 'country', 'US')),
       gt_recipient       = COALESCE(gt_recipient, jsonb_build_object(
         'firstName', 'Julian', 'lastName', 'G', 'email', 'tu@s4kent.com', 'phoneNumber', '212-913-9751',
         'address1', '362 5th Ave', 'city', 'New York', 'state', 'NY', 'postalCode', '10001', 'country', 'US')),
       updated_at         = now()
 WHERE id;

-- Every GoTickets field the Pro API requires on an order is present.
CREATE OR REPLACE FUNCTION public.n2s_autobuy_gt_profile_ok(c public.n2s_autobuy_config)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(btrim(c.gt_buyer_email), '') <> '' AND COALESCE(btrim(c.gt_buyer_phone), '') <> ''
     AND (SELECT bool_and(COALESCE(btrim(c.gt_billing_address ->> k), '') <> '')
            FROM unnest(ARRAY['firstName', 'lastName', 'address1', 'city', 'state', 'postalCode', 'country']) k)
     AND (SELECT bool_and(COALESCE(btrim(c.gt_recipient ->> k), '') <> '')
            FROM unnest(ARRAY['firstName', 'lastName', 'email', 'phoneNumber']) k);
$function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_gt_profile_ok(public.n2s_autobuy_config) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_gt_profile_ok(public.n2s_autobuy_config) TO service_role;

-- ── 2. the enqueue trigger ─────────────────────────────────────────────────
DO $do$
BEGIN
  IF md5(pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure)) <> '8904372a7ce77c91ff608a184eca9861' THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg drifted from 20261112020000 — re-derive this migration';
  END IF;
END $do$;

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
                   FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')), 0),
         count(*) FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')),
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
     AND state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved');

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
      IF v_start < now() + c.min_event_lead THEN r := r || 'event_within_24h'::text; END IF;
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
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_enqueue_trg() FROM PUBLIC, anon, authenticated;

-- ── 3. the claim ───────────────────────────────────────────────────────────
DO $do$
BEGIN
  IF md5(pg_get_functiondef('public.n2s_autobuy_live_claim()'::regprocedure)) <> '5bca3d2ec05e2e8a256b5c6f46039c5b' THEN
    RAISE EXCEPTION 'n2s_autobuy_live_claim drifted from 20261113110000 — re-derive this migration';
  END IF;
END $do$;

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

-- ── 4. the record ──────────────────────────────────────────────────────────
DO $do$
BEGIN
  IF md5(pg_get_functiondef('public.n2s_autobuy_live_record(bigint, uuid, jsonb)'::regprocedure)) <> '793e5bc35823a6258153d5df1f7c8931' THEN
    RAISE EXCEPTION 'n2s_autobuy_live_record drifted from 20261112020000 — re-derive this migration';
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.n2s_autobuy_live_record(p_exec_id bigint, p_token uuid, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_phase text := p_patch ->> 'phase'; v_ok boolean; v_prev text; v_prev_order text; v_src text;
BEGIN
  SELECT phase, buy_order_id, sub_source INTO v_prev, v_prev_order, v_src
    FROM public.n2s_autobuy_exec WHERE exec_id = p_exec_id;
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
  -- 20261112020000: stopped while still 'buying', with no purchase id and no market refusal = the
  -- worker stopped before the buy went out: the live run was not used, give it back.
  -- 20261113400000: to the sub source it was taken from.
  IF v_ok AND v_prev = 'buying' AND v_phase = 'stopped' AND v_prev_order IS NULL
     AND p_patch ->> 'buy_order_id' IS NULL AND NOT COALESCE((p_patch -> 'reasons') ? 'buy_failed', false) THEN
    IF v_src = 'gotickets' THEN
      UPDATE public.n2s_autobuy_config SET gt_live_runs_used = GREATEST(gt_live_runs_used - 1, 0), updated_at = now() WHERE id;
    ELSE
      UPDATE public.n2s_autobuy_config SET live_runs_used = GREATEST(live_runs_used - 1, 0), updated_at = now() WHERE id;
    END IF;
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

-- ── 5. the outcome email names the sub's market ────────────────────────────
DO $do$
DECLARE d text; n int;
BEGIN
  d := pg_get_functiondef('public.n2s_autobuy_outcome_tick()'::regprocedure);
  IF md5(d) <> '1e66a316b902a8cad7d7aceae57298f0' THEN
    RAISE EXCEPTION 'n2s_autobuy_outcome_tick drifted from 20261110000000 — re-derive this migration';
  END IF;
  n := 0;
  -- subject: ", EVO purchase <id>" -> the sub's market
  IF position($r$', EVO purchase ' || e.buy_order_id$r$ in d) > 0 THEN n := n + 1; END IF;
  d := replace(d, $r$', EVO purchase ' || e.buy_order_id$r$,
    $r$', ' || CASE e.sub_source WHEN 'gotickets' THEN 'GoTickets' ELSE 'EVO' END || ' purchase ' || e.buy_order_id$r$);
  -- body: "EVO purchase (buy) id" -> "Sub purchase (buy) id" (the subject names the market)
  IF position($r$E'EVO purchase (buy) id: $r$ in d) > 0 THEN n := n + 1; END IF;
  d := replace(d, $r$E'EVO purchase (buy) id: $r$, $r$E'Sub purchase (buy) id: $r$);
  -- unknown outcome: "CHECK EVO NOW" -> the sub's market
  IF position($r$THEN 'A write had an unknown outcome: CHECK EVO NOW. The kill switch is on.'$r$ in d) > 0 THEN n := n + 1; END IF;
  d := replace(d, $r$THEN 'A write had an unknown outcome: CHECK EVO NOW. The kill switch is on.'$r$,
    $r$THEN 'A write had an unknown outcome: CHECK ' || CASE e.sub_source WHEN 'gotickets' THEN 'GOTICKETS' ELSE 'EVO' END || ' NOW. The kill switch is on.'$r$);
  IF n <> 3 THEN
    RAISE EXCEPTION 'n2s_autobuy_outcome_tick: % of 3 anchors found — re-derive this migration', n;
  END IF;
  EXECUTE d;
END $do$;
