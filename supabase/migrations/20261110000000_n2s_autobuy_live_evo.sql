-- Migration 20261110000000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,n2s_autobuy_exec,n2s_autobuy_enqueue_trg,n2s_autobuy_live_claim,n2s_autobuy_live_record,n2s_autobuy_outcome_tick,cron · reads:n2s_gt_order_dryrun,n2s_items,vault.decrypted_secrets · pre:20261109200000
--
-- N2S auto-buy: LIVE mode, EVO only, ONE live run.
--
-- Operator authorization 2026-11-09: "I authorize EVO only, build the live executor, limit to
-- only 1 live run for testing". Live = an EVO sub bought from Office 3 (POST /v9/orders, paid
-- by evopay) covering an EVO sale, which is then accepted as user 53658 (POST
-- /v9/orders/{id}/accept). Those two writes go through evo_buy_client.py, the only client
-- check_readonly.py lets POST to TEvo, path-pinned. Nothing here calls a market: the database
-- only decides and records; the web worker (core/n2s_autobuy_live.py) does the market steps.
--
-- What changes:
--   * n2s_autobuy_config.mode may be 'live'. The row stays 'shadow' — going live is the
--     operator's own UPDATE (see "Go live" below), with the worker's env flag also set.
--   * live_runs_allowed (1) / live_runs_used: a claim of a new buy uses one run up front, so at
--     most ONE live buy is ever attempted until the operator raises live_runs_allowed.
--   * live_sell_markets ('{evo}'): in live mode the enqueue trigger blocks any other sale
--     market (sell_market_not_live) and any non-EVO sub (sub_source_not_live).
--   * live-mode rows that pass every guard get state live_buy (shadow keeps shadow_buy); live
--     spend counts separately from shadow spend, so the $500 project cap starts fresh for live.
--   * n2s_autobuy_exec.phase tracks the live steps: buying → buy_sent → sub_accepted → accepted,
--     or stopped / buy_unknown / accept_failed / accept_unknown. No phase ever goes back to
--     buying: a stopped row is never retried. buy_unknown / accept_unknown (a write whose
--     outcome is unknown) also set kill_switch, so nothing else runs until a person checks EVO.
--   * n2s_autobuy_live_claim(): hands one row to a worker under a 180 s lease and a fresh
--     lease_token (FOR UPDATE SKIP LOCKED behind the config row lock), polls first, then at most
--     one new buy. A step makes at most three 20 s EVO calls, so the lease outlasts it.
--     n2s_autobuy_live_record() only writes with the live token of an unexpired lease, and the
--     worker records (and so re-checks the lease) right BEFORE each market write; the lease is
--     released only on buy_sent (waiting on EVO) or an end phase. A row left in 'buying' after its
--     lease ran out (worker died mid-buy, or the buy's result could not be recorded) is marked
--     buy_unknown and sets kill_switch at the next claim: fail closed, a person checks EVO.
--     The kill switch stops everything, polls included; project_stopped only stops new buys
--     (a buy that reached the cap must still get its sale accepted).
--   * n2s_autobuy_outcome_tick() (cron n2s_autobuy_outcome_1min): emails email_to the outcome of
--     each live row once it ends (accepted / stopped / failed / unknown).
--
-- Go live (operator): Render env N2S_AUTOBUY_LIVE=1 on the web service, then
--   UPDATE n2s_autobuy_config SET mode = 'live', updated_at = now();
-- Stop: UPDATE n2s_autobuy_config SET kill_switch = true;   (or mode = 'shadow')
--
-- rollback: SELECT cron.unschedule('n2s_autobuy_outcome_1min');
--           UPDATE n2s_autobuy_config SET mode = 'shadow';
--           re-create n2s_autobuy_enqueue_trg() from 20261109200000;
--           DROP FUNCTION n2s_autobuy_live_claim(), n2s_autobuy_live_record(bigint, uuid, jsonb), n2s_autobuy_outcome_tick();

ALTER TABLE public.n2s_autobuy_config DROP CONSTRAINT IF EXISTS n2s_autobuy_config_mode_check;
ALTER TABLE public.n2s_autobuy_config ADD CONSTRAINT n2s_autobuy_config_mode_check
  CHECK (mode IN ('off', 'shadow', 'live'));
ALTER TABLE public.n2s_autobuy_config
  ADD COLUMN IF NOT EXISTS live_runs_allowed integer NOT NULL DEFAULT 1 CHECK (live_runs_allowed >= 0),
  ADD COLUMN IF NOT EXISTS live_runs_used    integer NOT NULL DEFAULT 0 CHECK (live_runs_used >= 0),
  ADD COLUMN IF NOT EXISTS live_sell_markets text[]  NOT NULL DEFAULT ARRAY['evo'] CHECK (live_sell_markets <@ ARRAY['evo']),
  -- Office 3's delivery email on EVO (tu@s4kent.com), as on its own purchase orders.
  ADD COLUMN IF NOT EXISTS evo_email_address_id integer DEFAULT 10497966;

ALTER TABLE public.n2s_autobuy_exec DROP CONSTRAINT IF EXISTS n2s_autobuy_exec_state_check;
ALTER TABLE public.n2s_autobuy_exec ADD CONSTRAINT n2s_autobuy_exec_state_check
  CHECK (state IN ('off', 'blocked', 'shadow_buy', 'live_buy', 'awaiting_approval', 'approved', 'declined',
                   'approval_expired'));
ALTER TABLE public.n2s_autobuy_exec
  ADD COLUMN IF NOT EXISTS phase text CHECK (phase IN ('buying', 'buy_sent', 'sub_accepted', 'accepted', 'stopped',
                                                       'buy_unknown', 'accept_failed', 'accept_unknown')),
  ADD COLUMN IF NOT EXISTS buy_state          text,
  ADD COLUMN IF NOT EXISTS sale_state         text,
  ADD COLUMN IF NOT EXISTS live_error         text,
  ADD COLUMN IF NOT EXISTS lease_until        timestamptz,
  ADD COLUMN IF NOT EXISTS lease_token        uuid,
  ADD COLUMN IF NOT EXISTS live_started_at    timestamptz,
  ADD COLUMN IF NOT EXISTS live_updated_at    timestamptz,
  ADD COLUMN IF NOT EXISTS outcome_emailed_at timestamptz;

DROP INDEX IF EXISTS public.n2s_autobuy_exec_listing;
CREATE UNIQUE INDEX IF NOT EXISTS n2s_autobuy_exec_listing
  ON public.n2s_autobuy_exec (sub_source, sub_listing_id)
  WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved');

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

  SELECT COALESCE(sum(sub_total_usd) FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')), 0),
         count(*) FILTER (WHERE state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')),
         count(*) FILTER (WHERE state = 'blocked' AND 'circuit_breaker' <> ALL (reasons)
                            AND reasons && ARRAY['sub_rejected', 'sub_unconfirmed', 'buy_failed'])
    INTO v_spend, v_buys, v_fail
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND (created_at AT TIME ZONE 'America/New_York')::date = v_tz_today;

  -- Project spend: every buy ever committed in this mode, any market.
  SELECT COALESCE(sum(sub_total_usd), 0) INTO v_proj
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
                  AND x.state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')
                  AND (x.created_at AT TIME ZONE 'America/New_York')::date = v_tz_today) THEN
      r := r || 'event_already_bought_today'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x
                WHERE x.sub_source = NEW.sub_source AND x.sub_listing_id = NEW.sub_listing_id
                  AND x.state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved')) THEN
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
                    WHEN c.mode = 'live' THEN 'live_buy'
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
  IF v_state IN ('shadow_buy', 'live_buy', 'awaiting_approval')
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

-- One row to one worker. Polls (rows already bought) come first; then at most one new buy,
-- which uses up a live run before anything is sent.
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
    SELECT * INTO e FROM public.n2s_autobuy_exec
     WHERE mode = 'live' AND state IN ('live_buy', 'approved') AND phase IS NULL
       AND sub_source = 'tevo' AND sell_market = ANY (c.live_sell_markets)
       AND sub_confirm_by - now() > make_interval(secs => c.min_confirm_window_s)
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
CREATE OR REPLACE FUNCTION public.n2s_autobuy_live_record(p_exec_id bigint, p_token uuid, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_phase text := p_patch ->> 'phase'; v_ok boolean;
BEGIN
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
  IF v_phase IN ('buy_unknown', 'accept_unknown') THEN
    UPDATE public.n2s_autobuy_config SET kill_switch = true, updated_at = now() WHERE id;
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

-- Outcome email for each live row once it ends (the buy email itself is n2s_autobuy_notify_tick's).
CREATE OR REPLACE FUNCTION public.n2s_autobuy_outcome_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c    public.n2s_autobuy_config%ROWTYPE;
  e    RECORD;
  rk   text; addr text; body text; subj text;
  resp extensions.http_response;
  n    int := 0;
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'RESEND_API_KEY') INTO rk FROM vault.decrypted_secrets;
  IF rk IS NULL OR cardinality(c.email_to) = 0 OR c.email_from IS NULL THEN RETURN 0; END IF;
  PERFORM set_config('http.timeout_msec', '5000', true);
  FOR e IN SELECT * FROM public.n2s_autobuy_exec
            WHERE mode = 'live' AND outcome_emailed_at IS NULL
              AND phase IN ('accepted', 'stopped', 'buy_unknown', 'accept_failed', 'accept_unknown')
            ORDER BY exec_id LIMIT 5 LOOP
    subj := format('N2S LIVE %s: sale %s%s', upper(replace(e.phase, '_', ' ')), e.order_number,
                   CASE WHEN e.buy_order_id IS NOT NULL THEN ', EVO purchase ' || e.buy_order_id ELSE '' END);
    body := format(E'Outcome: %s\nReasons: %s\nError: %s\n\n'
                   || E'EVO purchase (buy) id: %s, state %s\nSale it covers: order %s on %s, state %s\n\n'
                   || E'Event: %s (%s)\nQty %s, buy $%s, sale $%s, margin $%s\n\n%s',
                   e.phase, array_to_string(e.reasons, ', '), COALESCE(e.live_error, '-'),
                   COALESCE(e.buy_order_id, 'none (nothing bought)'), COALESCE(e.buy_state, '-'),
                   e.order_number, e.sell_market, COALESCE(e.sale_state, '-'),
                   e.event_name, e.event_dt_local, e.qty, e.sub_total_usd, e.sold_total_usd, e.margin_usd,
                   CASE WHEN e.phase IN ('buy_unknown', 'accept_unknown')
                        THEN 'A write had an unknown outcome: CHECK EVO NOW. The kill switch is on.'
                        WHEN e.phase = 'accepted' THEN 'Sub confirmed and the sale was accepted.'
                        WHEN e.buy_order_id IS NOT NULL THEN 'We hold the sub but the sale was NOT accepted: handle by hand.'
                        ELSE 'Nothing was bought.' END);
    FOREACH addr IN ARRAY c.email_to LOOP
      BEGIN
        resp := extensions.http(('POST', 'https://api.resend.com/emails',
                  ARRAY[extensions.http_header('Authorization', 'Bearer ' || rk)], 'application/json',
                  jsonb_build_object('from', c.email_from, 'to', jsonb_build_array(addr),
                                     'subject', subj, 'text', body)::text)::extensions.http_request);
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END LOOP;
    UPDATE public.n2s_autobuy_exec SET outcome_emailed_at = now() WHERE exec_id = e.exec_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_live_claim(), public.n2s_autobuy_live_record(bigint, uuid, jsonb),
                       public.n2s_autobuy_outcome_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_live_claim(), public.n2s_autobuy_live_record(bigint, uuid, jsonb),
                          public.n2s_autobuy_outcome_tick() TO service_role;

SELECT cron.schedule('n2s_autobuy_outcome_1min', '* * * * *', $$SELECT public.n2s_autobuy_outcome_tick();$$);
