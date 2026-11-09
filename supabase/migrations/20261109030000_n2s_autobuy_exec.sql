-- Migration 20261109030000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,n2s_autobuy_exec,v_n2s_market_cutoff,trigger,cron · reads:n2s_gt_order_dryrun,n2s_items,n2s_order_timer_log,vault.decrypted_secrets · pre:20261104190000
--
-- N2S auto-buy EXECUTOR — SHADOW MODE. Applies every limit and safety net to each
-- dry-run would_buy and records what it would do. Sends nothing to any market.
--
-- Operator direction 2026-11-09: "Build one and add spend limits so we can test on order
-- totalling under 250 a day to start … add other safety nets … only buy when event is over
-- 24 hours in time, no same day events … if the sub isn't confirmed by timer do not accept,
-- figure out median cutoff time from our data and set those as allotted time. If sub is
-- rejected don't retry, no min. No approval channel unless sub is over $1000 … then trigger
-- text or whatsapp."
--
-- What it does: every dry-run row with decision = would_buy gets ONE row in n2s_autobuy_exec
-- (UNIQUE n2s_id: one attempt per sale, never a retry), state:
--   shadow_buy         every guard passed — a live executor would buy now
--   awaiting_approval  sub total over approval_over_usd — text / WhatsApp sent to the operator
--   blocked            a guard failed (reasons[] says which)
--   off                kill switch / mode off
-- Guards (all must pass):
--   mode/kill switch · sell market has a working token (EVO, GoTickets, SeatGeek, Vivid) ·
--   sub source we can buy from (GoTickets, EVO) · event start > now + 24 h and not today
--   (America/New_York) · sub total ≤ per-order cap · today's spend + this ≤ daily cap ·
--   buys today < max_buys_per_day · one buy per event per day · listing not already used ·
--   profit > 0 (no minimum) · live price not above the quote · live read ≤ 120 s old ·
--   enough time to get the sub confirmed before the market's cutoff · circuit breaker
--   (failures today < max_failures_per_day).
-- Project cap (operator 2026-11-09: "put strict spend cap on evo for full project at 500,
-- autostop when it hits that cap, until i review", then "for now 500 cap on entire project
-- after that soft launch is 250 an order"): every buy ever committed in the current mode, on any
-- market, counts against project_cap_usd ($500). A buy that would otherwise go through but
-- would cross it is blocked (over_project_cap) and ALL buying stops (project_stopped); reaching
-- the cap exactly stops it too. A sub already blocked by another guard is tagged
-- over_project_cap but does not stop. While stopped every buy is blocked
-- (stopped_pending_review) until n2s_autobuy_resume([new_cap]) — the operator's review.
-- Shadow and a future live mode count separately. The $250 per-order cap stays.
-- Allotted time per selling market = the MEDIAN time from the CRM alert to the market's own
-- auto-reject, from our order timer (v_n2s_market_cutoff, ≥ 3 samples, manual rejects under
-- 5 min excluded); otherwise the CRM's 15-minute timer. The sub must be CONFIRMED by
-- cutoff − accept_buffer (sub_confirm_by) or the sale is NOT accepted.
--
-- mode is constrained to 'off' | 'shadow'. 'live' is deliberately impossible here: going live
-- needs buyer credentials, the operator's written authorization for the write endpoints
-- (CLAUDE.md RULE 2) and a separate PR that adds the guarded write client.
--
-- Buy email (operator 2026-11-09: "send an email to me containing both the evo buy id and sale
-- it bought for id"): n2s_autobuy_notify_tick() emails email_to through Resend for every buy
-- that has a buy_order_id (live), naming the purchase id and the sale order it covers — and for
-- shadow buys too when email_shadow is on. It also emails once when the project cap auto-stops buying.
--
-- The approval text goes to Twilio (SMS, or WhatsApp when notify_channel = 'whatsapp') from
-- n2s_autobuy_notify_tick(); it is inert until notify_to / notify_from are set in
-- n2s_autobuy_config. No market API is called.
--
-- rollback: SELECT cron.unschedule('n2s_autobuy_notify_1min');
--           DROP TRIGGER n2s_autobuy_enqueue_trg ON n2s_gt_order_dryrun;
--           DROP FUNCTION n2s_autobuy_enqueue_trg(), n2s_autobuy_notify_tick(),
--                         n2s_autobuy_approve(bigint, boolean), n2s_autobuy_resume(numeric);
--           DROP VIEW v_n2s_market_cutoff; DROP TABLE n2s_autobuy_exec, n2s_autobuy_config;

CREATE TABLE IF NOT EXISTS public.n2s_autobuy_config (
  id                    boolean     PRIMARY KEY DEFAULT true CHECK (id),
  mode                  text        NOT NULL DEFAULT 'shadow' CHECK (mode IN ('off', 'shadow')),
  kill_switch           boolean     NOT NULL DEFAULT false,
  per_order_cap_usd     numeric     NOT NULL DEFAULT 250  CHECK (per_order_cap_usd > 0),
  daily_cap_usd         numeric     NOT NULL DEFAULT 250  CHECK (daily_cap_usd > 0),
  max_buys_per_day      integer     NOT NULL DEFAULT 3    CHECK (max_buys_per_day > 0),
  max_failures_per_day  integer     NOT NULL DEFAULT 2    CHECK (max_failures_per_day > 0),
  approval_over_usd     numeric     NOT NULL DEFAULT 1000 CHECK (approval_over_usd > 0),
  min_event_lead        interval    NOT NULL DEFAULT '24 hours',
  accept_buffer_s       integer     NOT NULL DEFAULT 60,
  min_confirm_window_s  integer     NOT NULL DEFAULT 90,
  default_cutoff_s      integer     NOT NULL DEFAULT 900,
  max_read_age_s        integer     NOT NULL DEFAULT 120,
  notify_channel        text        NOT NULL DEFAULT 'sms' CHECK (notify_channel IN ('sms', 'whatsapp')),
  notify_to             text,       -- E.164, e.g. +15551234567 (unset = no text is sent)
  notify_from           text,       -- the Twilio number / WhatsApp sender (unset = no text is sent)
  project_cap_usd   numeric     NOT NULL DEFAULT 500  CHECK (project_cap_usd > 0),
  evo_reviewer_id       integer     NOT NULL DEFAULT 53658,  -- operator 2026-11-09: tu3 (Office 3, the N2S EVO seller)
  evo_buyer_office_id   integer     NOT NULL DEFAULT 42029,  -- operator 2026-11-09: EVO buys from Office 3
  project_stopped           boolean     NOT NULL DEFAULT false,
  project_stopped_at        timestamptz,
  project_stopped_reason    text,
  stop_emailed_at   timestamptz,
  email_to              text[]      DEFAULT ARRAY['julian@s4kent.com', 'aljuinc@gmail.com'],  -- operator 2026-11-09
  email_from            text        DEFAULT 'N2S Auto-buy <onboarding@resend.dev>',
  email_shadow          boolean     NOT NULL DEFAULT false,      -- also email shadow buys (to test)
  updated_at            timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.n2s_autobuy_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.n2s_autobuy_exec (
  exec_id          bigserial   PRIMARY KEY,
  n2s_id           bigint      NOT NULL UNIQUE,          -- one attempt per sale: never a retry
  dryrun_id        bigint      NOT NULL,
  mode             text        NOT NULL,
  state            text        NOT NULL CHECK (state IN ('off', 'blocked', 'shadow_buy', 'awaiting_approval',
                                                          'approved', 'declined', 'approval_expired')),
  reasons          text[]      NOT NULL DEFAULT '{}',
  sell_market      text,
  order_number     text,
  sub_source       text,
  sub_listing_id   text,
  tevo_event_id    bigint,
  event_name       text,
  event_dt_local   timestamp,
  qty              integer,
  sub_total_usd    numeric,
  sold_total_usd   numeric,
  margin_usd       numeric,
  alert_at         timestamptz,
  cutoff_s         integer,
  cutoff_source    text,
  sub_confirm_by   timestamptz,
  sale_deadline    timestamptz,
  spend_today_before numeric,
  project_spent_before numeric,
  notified_at      timestamptz,
  notify_http      integer,
  buy_order_id     text,        -- our purchase id on the sub's market (set by the live worker)
  emailed_at       timestamptz,
  email_http       integer,
  decided_at       timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS n2s_autobuy_exec_created ON public.n2s_autobuy_exec (created_at);
-- One live attempt per sub listing: a listing can only cover one sale.
CREATE UNIQUE INDEX IF NOT EXISTS n2s_autobuy_exec_listing
  ON public.n2s_autobuy_exec (sub_source, sub_listing_id) WHERE state IN ('shadow_buy', 'awaiting_approval', 'approved');

ALTER TABLE public.n2s_autobuy_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n2s_autobuy_exec   ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_autobuy_config, public.n2s_autobuy_exec FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.n2s_autobuy_config, public.n2s_autobuy_exec TO service_role;

-- Allotted time per selling market: median seconds from the CRM alert to the market's own
-- auto-reject, from the order timer. Rejects under 5 minutes are someone acting by hand.
CREATE OR REPLACE VIEW public.v_n2s_market_cutoff
WITH (security_invoker = true) AS
SELECT s.market,
       count(*)                                                                  AS samples,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM l.seen_at - s.alert_at))::int AS median_cutoff_s,
       min(extract(epoch FROM l.seen_at - s.alert_at))::int                      AS min_cutoff_s,
       max(extract(epoch FROM l.seen_at - s.alert_at))::int                      AS max_cutoff_s
  FROM public.n2s_order_timer_log l
  JOIN public.n2s_order_timer_state s USING (market, order_key)
 WHERE lower(l.state) IN ('rejected', 'denied', 'cancelled', 'canceled', 'expired')
   AND l.seen_at - s.alert_at >= interval '5 minutes'
 GROUP BY s.market;
REVOKE ALL ON public.v_n2s_market_cutoff FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_n2s_market_cutoff TO service_role;

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

DROP TRIGGER IF EXISTS n2s_autobuy_enqueue_trg ON public.n2s_gt_order_dryrun;
CREATE TRIGGER n2s_autobuy_enqueue_trg
  AFTER INSERT ON public.n2s_gt_order_dryrun
  FOR EACH ROW WHEN (NEW.decision = 'would_buy' AND NEW.n2s_id > 0)
  EXECUTE FUNCTION public.n2s_autobuy_enqueue_trg();

-- Approval text (subs over approval_over_usd). Inert until notify_to and notify_from are set.
CREATE OR REPLACE FUNCTION public.n2s_autobuy_notify_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c    public.n2s_autobuy_config%ROWTYPE;
  e    RECORD;
  sid  text; tok text; pre text; body text; rk text; addr text; best int;
  resp extensions.http_response;
  n    int := 0;
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;
  -- an unanswered request lapses when the sub can no longer be confirmed in time
  UPDATE public.n2s_autobuy_exec SET state = 'approval_expired', decided_at = now()
   WHERE state = 'awaiting_approval' AND sub_confirm_by - now() < make_interval(secs => c.min_confirm_window_s);
  -- Buy emails: the purchase id and the sale it covers (Resend). Then the cap auto-stop email.
  SELECT max(decrypted_secret) FILTER (WHERE name = 'RESEND_API_KEY') INTO rk FROM vault.decrypted_secrets;
  IF rk IS NOT NULL AND cardinality(c.email_to) > 0 AND c.email_from IS NOT NULL THEN
    PERFORM set_config('http.timeout_msec', '5000', true);
    FOR e IN SELECT * FROM public.n2s_autobuy_exec
              WHERE emailed_at IS NULL
                AND (buy_order_id IS NOT NULL OR (c.email_shadow AND state IN ('shadow_buy', 'approved')))
              ORDER BY exec_id LIMIT 5 LOOP
      body := format(E'%s buy for N2S sale %s\n\n'
                     || E'Buy (purchase) id: %s on %s, listing %s\n'
                     || E'Sale it covers:    order %s on %s\n\n'
                     || E'Event: %s (%s)\nQty %s, buy $%s, sale $%s, margin $%s\n'
                     || 'Sub must confirm by %s ET or the sale is not accepted.',
                     CASE WHEN e.buy_order_id IS NULL THEN 'SHADOW (not sent)' ELSE 'LIVE' END, e.n2s_id,
                     COALESCE(e.buy_order_id, 'none - shadow mode'),
                     CASE e.sub_source WHEN 'tevo' THEN 'EVO' WHEN 'gotickets' THEN 'GoTickets' ELSE e.sub_source END,
                     e.sub_listing_id, e.order_number, e.sell_market, e.event_name, e.event_dt_local, e.qty,
                     e.sub_total_usd, e.sold_total_usd, e.margin_usd,
                     to_char(e.sub_confirm_by AT TIME ZONE 'America/New_York', 'HH24:MI:SS'));
      -- One message per recipient: Resend rejects a whole message when any recipient is not
      -- allowed (its test sender only reaches the account owner), and one bad address must not
      -- cost the others the email. email_http keeps the best status.
      best := NULL;
      FOREACH addr IN ARRAY c.email_to LOOP
        BEGIN
          resp := extensions.http(('POST', 'https://api.resend.com/emails',
                    ARRAY[extensions.http_header('Authorization', 'Bearer ' || rk)], 'application/json',
                    jsonb_build_object('from', c.email_from, 'to', jsonb_build_array(addr),
                      'subject', format('N2S %s buy: %s purchase %s for sale %s',
                                        CASE WHEN e.buy_order_id IS NULL THEN 'SHADOW' ELSE 'LIVE' END,
                                        CASE e.sub_source WHEN 'tevo' THEN 'EVO' ELSE 'GoTickets' END,
                                        COALESCE(e.buy_order_id, 'n/a'), e.order_number),
                      'text', body)::text)::extensions.http_request);
          best := CASE WHEN best = 200 THEN 200 ELSE resp.status END;
        EXCEPTION WHEN OTHERS THEN
          best := COALESCE(best, -1);
        END;
      END LOOP;
      UPDATE public.n2s_autobuy_exec SET emailed_at = now(), email_http = best WHERE exec_id = e.exec_id;
    END LOOP;
    IF c.project_stopped AND c.stop_emailed_at IS NULL THEN
      FOREACH addr IN ARRAY c.email_to LOOP
        BEGIN
          resp := extensions.http(('POST', 'https://api.resend.com/emails',
                    ARRAY[extensions.http_header('Authorization', 'Bearer ' || rk)], 'application/json',
                    jsonb_build_object('from', c.email_from, 'to', jsonb_build_array(addr),
                      'subject', 'N2S auto-buy: buying STOPPED at the project cap',
                      'text', format(E'%s\n\nAll buys stay blocked until you review and run '
                                     || 'n2s_autobuy_resume() (or n2s_autobuy_resume(<new cap>)).',
                                     c.project_stopped_reason))::text)::extensions.http_request);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
      END LOOP;
      UPDATE public.n2s_autobuy_config SET stop_emailed_at = now() WHERE id;
    END IF;
  END IF;

  IF c.notify_to IS NULL OR c.notify_from IS NULL THEN RETURN 0; END IF;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'Twilio_Account SID'),
         max(decrypted_secret) FILTER (WHERE name = 'Twilio_Auth Token')
    INTO sid, tok FROM vault.decrypted_secrets;
  IF sid IS NULL OR tok IS NULL THEN RETURN 0; END IF;
  pre := CASE WHEN c.notify_channel = 'whatsapp' THEN 'whatsapp:' ELSE '' END;
  PERFORM set_config('http.timeout_msec', '5000', true);
  FOR e IN SELECT * FROM public.n2s_autobuy_exec WHERE state = 'awaiting_approval' AND notified_at IS NULL LIMIT 3 LOOP
    body := format('N2S auto-buy needs OK (%s mode): %s on %s, %s x%s for $%s (sale $%s, margin $%s). '
                   'Sub must confirm by %s ET. Approve: n2s_autobuy_approve(%s, true)',
                   e.mode, e.order_number, e.sell_market, e.event_name, e.qty, e.sub_total_usd,
                   e.sold_total_usd, e.margin_usd,
                   to_char(e.sub_confirm_by AT TIME ZONE 'America/New_York', 'HH24:MI'), e.n2s_id);
    BEGIN
      resp := extensions.http((
        'POST', 'https://api.twilio.com/2010-04-01/Accounts/' || sid || '/Messages.json',
        ARRAY[extensions.http_header('Authorization',
              'Basic ' || replace(encode(convert_to(sid || ':' || tok, 'UTF8'), 'base64'), E'\n', ''))],
        'application/x-www-form-urlencoded',
        'To=' || extensions.urlencode((pre || c.notify_to)::varchar) || '&From=' || extensions.urlencode((pre || c.notify_from)::varchar)
          || '&Body=' || extensions.urlencode(body::varchar))::extensions.http_request);
      UPDATE public.n2s_autobuy_exec SET notified_at = now(), notify_http = resp.status WHERE exec_id = e.exec_id;
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.n2s_autobuy_exec SET notified_at = now(), notify_http = -1 WHERE exec_id = e.exec_id;
    END;
    n := n + 1;
  END LOOP;
  RETURN n;
END $function$;

-- The operator's answer to an approval text (service role only).
CREATE OR REPLACE FUNCTION public.n2s_autobuy_approve(p_n2s_id bigint, p_approve boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v text;
BEGIN
  UPDATE public.n2s_autobuy_exec
     SET state = CASE WHEN p_approve AND sub_confirm_by > now() THEN 'approved'
                      WHEN p_approve THEN 'approval_expired' ELSE 'declined' END,
         decided_at = now()
   WHERE n2s_id = p_n2s_id AND state = 'awaiting_approval'
  RETURNING state INTO v;
  RETURN COALESCE(v, 'not_awaiting_approval');
END $function$;

-- The operator's review of a cap stop: clears it, optionally with a new project cap.
CREATE OR REPLACE FUNCTION public.n2s_autobuy_resume(p_new_cap_usd numeric DEFAULT NULL)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF p_new_cap_usd IS NOT NULL AND p_new_cap_usd <= 0 THEN
    RAISE EXCEPTION 'cap must be positive';
  END IF;
  UPDATE public.n2s_autobuy_config
     SET project_stopped = false, project_stopped_at = NULL, project_stopped_reason = NULL, stop_emailed_at = NULL,
         project_cap_usd = COALESCE(p_new_cap_usd, project_cap_usd), updated_at = now()
   WHERE id;
  RETURN format('Auto-buy resumed; project cap $%s',
                (SELECT project_cap_usd FROM public.n2s_autobuy_config WHERE id));
END $function$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_enqueue_trg(), public.n2s_autobuy_notify_tick(),
                       public.n2s_autobuy_approve(bigint, boolean), public.n2s_autobuy_resume(numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_notify_tick(), public.n2s_autobuy_approve(bigint, boolean),
                          public.n2s_autobuy_resume(numeric) TO service_role;

SELECT cron.schedule('n2s_autobuy_notify_1min', '* * * * *', $$SELECT public.n2s_autobuy_notify_tick();$$);
