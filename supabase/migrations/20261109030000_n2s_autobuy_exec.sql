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
-- Allotted time per selling market = the MEDIAN time from the CRM alert to the market's own
-- auto-reject, from our order timer (v_n2s_market_cutoff, ≥ 3 samples, manual rejects under
-- 5 min excluded); otherwise the CRM's 15-minute timer. The sub must be CONFIRMED by
-- cutoff − accept_buffer (sub_confirm_by) or the sale is NOT accepted.
--
-- mode is constrained to 'off' | 'shadow'. 'live' is deliberately impossible here: going live
-- needs buyer credentials, the operator's written authorization for the write endpoints
-- (CLAUDE.md RULE 2) and a separate PR that adds the guarded write client.
--
-- The approval text goes to Twilio (SMS, or WhatsApp when notify_channel = 'whatsapp') from
-- n2s_autobuy_notify_tick(); it is inert until notify_to / notify_from are set in
-- n2s_autobuy_config. No market API is called.
--
-- rollback: SELECT cron.unschedule('n2s_autobuy_notify_1min');
--           DROP TRIGGER n2s_autobuy_enqueue_trg ON n2s_gt_order_dryrun;
--           DROP FUNCTION n2s_autobuy_enqueue_trg(), n2s_autobuy_notify_tick(),
--                         n2s_autobuy_approve(bigint, boolean);
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
  notified_at      timestamptz,
  notify_http      integer,
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
  v_tz_today date := (now() AT TIME ZONE 'America/New_York')::date;
  v_state    text;
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;
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
    v_state := CASE WHEN cardinality(r) > 0 THEN 'blocked'
                    WHEN v_sub > c.approval_over_usd THEN 'awaiting_approval'
                    ELSE 'shadow_buy' END;
  END IF;

  INSERT INTO public.n2s_autobuy_exec
         (n2s_id, dryrun_id, mode, state, reasons, sell_market, order_number, sub_source, sub_listing_id,
          tevo_event_id, event_name, event_dt_local, qty, sub_total_usd, sold_total_usd, margin_usd, alert_at,
          cutoff_s, cutoff_source, sub_confirm_by, sale_deadline, spend_today_before)
  VALUES (NEW.n2s_id, NEW.dryrun_id, c.mode, v_state, r, v_market, NEW.order_number, NEW.sub_source,
          NEW.sub_listing_id, NEW.tevo_event_id, NEW.event_name, i.event_dt, v_qty, v_sub, v_sold,
          v_sold - v_sub, i.alert_at, v_cut, v_cut_src, v_confirm,
          i.alert_at + make_interval(secs => v_cut), v_spend)
  ON CONFLICT DO NOTHING;
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
  sid  text; tok text; pre text; body text;
  resp extensions.http_response;
  n    int := 0;
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;
  -- an unanswered request lapses when the sub can no longer be confirmed in time
  UPDATE public.n2s_autobuy_exec SET state = 'approval_expired', decided_at = now()
   WHERE state = 'awaiting_approval' AND sub_confirm_by - now() < make_interval(secs => c.min_confirm_window_s);
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

REVOKE ALL ON FUNCTION public.n2s_autobuy_enqueue_trg(), public.n2s_autobuy_notify_tick(),
                       public.n2s_autobuy_approve(bigint, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_notify_tick(), public.n2s_autobuy_approve(bigint, boolean) TO service_role;

SELECT cron.schedule('n2s_autobuy_notify_1min', '* * * * *', $$SELECT public.n2s_autobuy_notify_tick();$$);
