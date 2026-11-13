-- Migration 20261113440000 · level:secondary-sales · lane:D0 · writes:manual_sub_buy,manual_sub_buy_file_n2s,manual_sub_buy_claim_for,manual_sub_buy_claim,manual_sub_buy_record,manual_sub_buy_follow_claim,manual_sub_buy_alert_tick,sub_buy_evo_inflight,sub_buy_spent_today,sub_finder_buys · reads:n2s_autobuy_exec,n2s_autobuy_config,n2s_gt_order_dryrun,n2s_autobuy_queue_job,n2s_autobuy_queue_result · pre:20261113430000
--
-- ONE BUYER, stage 3, the sub finder's SQL side: the N2S auto-buyer may FILE its buys into
-- the manual sub buy queue, and one worker sends them.
--
-- Operator 2026-11-13: "do 3 but retain n2s buy conditions" · "allow stage 3" · (relayed by
-- lane D7, bot_chat 6688) "n2s gets priority in queue". Interface agreed with lane D7 in
-- bot_chat 6689 / 6691.
--
-- NOTHING HERE IS IN FORCE WHEN APPLIED. A row of origin 'n2s' exists only once N2S's claim
-- files one, which it does only with n2s_autobuy_config.buyer = 'queue' (lane D7's switch,
-- default 'own', flipped by hand). Until then every function below does what it did before.
--
--   1. manual_sub_buy.origin ('manual' | 'n2s'), n2s_exec_id (one row per N2S exec row),
--      buy_by (never send after this instant).
--   2. manual_sub_buy_file_n2s(exec_id, buy_by, max_total_usd): N2S's claim files a buy it would
--      have handed to its own worker. NULL = not filed (the sale already has a live buy, the
--      row cannot be filed, or its time has passed): N2S stops its row and takes the run back.
--   3. manual_sub_buy_claim_for(p_can): the claim. A worker that passes 'n2s' gets N2S rows
--      first. An N2S row: skips this path's switch and ceilings (N2S's own ran when it filed)
--      but obeys the control over both buyers; is handed out only while N2S is live, not
--      killed and not stopped for that market, read again at hand-out; is stopped unsent
--      ('queue_expired') once buy_by passes; and carries the N2S job as N2S builds it
--      (n2s_autobuy_queue_job, lane D7). One buy at a time, whoever it is for. An unknown buy
--      holds back its own origin only.
--      manual_sub_buy_claim() stays, as manual_sub_buy_claim_for('{}'): a worker that does not
--      know N2S rows (the old instance during a deploy) is never handed one.
--   4. manual_sub_buy_record(): the result of an N2S row goes to N2S's own row in the same
--      transaction (n2s_autobuy_queue_result, lane D7). An unknown there is N2S's kill
--      switch, not this path's.
--   5. Following, money alerts, the purchases feed and the shared spend / in-flight counts
--      leave an N2S row to N2S's own row, so nothing is done or counted twice.
--
-- n2s_autobuy_queue_job / n2s_autobuy_queue_result are lane D7's and ship in their migration;
-- they are called only for a row of origin 'n2s'. Nothing here calls a market. Functions are
-- shipped whole (MIGRATION_CONVENTIONS 6a).
--
-- rollback: none needed while no row has origin 'n2s' (n2s_autobuy_config.buyer = 'own').

-- ── 1. where a buy came from ───────────────────────────────────────────────
ALTER TABLE public.manual_sub_buy
  ADD COLUMN IF NOT EXISTS origin      text NOT NULL DEFAULT 'manual' CHECK (origin IN ('manual', 'n2s')),
  ADD COLUMN IF NOT EXISTS n2s_exec_id bigint,
  ADD COLUMN IF NOT EXISTS buy_by      timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS manual_sub_buy_one_per_n2s_exec
  ON public.manual_sub_buy (n2s_exec_id) WHERE n2s_exec_id IS NOT NULL;
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'manual_sub_buy_n2s_row_complete') THEN
    ALTER TABLE public.manual_sub_buy ADD CONSTRAINT manual_sub_buy_n2s_row_complete
      CHECK (origin = 'manual' OR (n2s_exec_id IS NOT NULL AND buy_by IS NOT NULL AND max_total_usd IS NOT NULL));
  END IF;
END
$do$;
COMMENT ON COLUMN public.manual_sub_buy.origin IS
  '''manual'' = asked for through this path (operator, CRM key, automatic one-to-one buy, accepted GoTickets offer); ''n2s'' = filed by the N2S auto-buyer (n2s_exec_id is its n2s_autobuy_exec row, buy_by the last instant it may be sent). 20261113440000.';

-- ── 2. N2S files a buy ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manual_sub_buy_file_n2s(
  p_exec_id bigint, p_buy_by timestamptz DEFAULT NULL, p_max_total_usd numeric DEFAULT NULL)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e     public.n2s_autobuy_exec%ROWTYPE;
  n     public.n2s_autobuy_config%ROWTYPE;
  v_by  timestamptz;
  v_max numeric;
  v_gt  bigint;
  v_id  bigint;
BEGIN
  SELECT * INTO e FROM public.n2s_autobuy_exec WHERE exec_id = p_exec_id;
  IF NOT FOUND OR e.mode IS DISTINCT FROM 'live' OR e.sub_source IS NULL OR e.sub_source NOT IN ('tevo', 'gotickets')
     OR e.sub_listing_id IS NULL OR e.sub_listing_id !~ '^[0-9]{1,18}$'
     OR coalesce(e.qty, 0) < 1 OR coalesce(e.sub_total_usd, 0) <= 0
     OR e.sell_market IS NULL OR e.order_number IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO n FROM public.n2s_autobuy_config WHERE id;
  -- lane D7's rule (bot_chat 6691 E) when the caller passes none: the seller must still have time
  v_by := coalesce(p_buy_by, e.sub_confirm_by - make_interval(secs =>
            GREATEST(coalesce(n.min_confirm_window_s, 0), coalesce(e.seller_window_in_hand_s, 0))));
  v_max := coalesce(p_max_total_usd, round(e.sub_total_usd + coalesce(e.est_tax_usd, 0), 2));
  IF v_by IS NULL OR v_by <= now() OR v_max IS NULL OR v_max <= 0 THEN RETURN NULL; END IF;
  SELECT d.gt_event_id INTO v_gt FROM public.n2s_gt_order_dryrun d WHERE d.dryrun_id = e.dryrun_id;
  BEGIN
    INSERT INTO public.manual_sub_buy
      (requested_by, sale_site, sale_order_number, event_name, tevo_event_id, ticket_group_id, qty,
       max_price_ea, sold_ea, market, gt_event_id, max_total_usd, origin, n2s_exec_id, buy_by)
    VALUES
      (format('n2s auto (exec %s)', e.exec_id), e.sell_market, e.order_number, e.event_name, e.tevo_event_id,
       e.sub_listing_id::bigint, e.qty, round(e.sub_total_usd / e.qty, 4), round(e.sold_total_usd / e.qty, 4),
       CASE e.sub_source WHEN 'tevo' THEN 'evo' ELSE 'gotickets' END, v_gt, v_max, 'n2s', e.exec_id, v_by)
    RETURNING buy_id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN NULL;                    -- this sale already has a live buy, or this exec row was filed before
  END;
  RETURN v_id;
END $function$;

-- ── 3. the claim ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manual_sub_buy_claim_for(p_can text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c        public.manual_sub_buy_config%ROWTYPE;
  n        public.n2s_autobuy_config%ROWTYPE;
  b        public.manual_sub_buy%ROWTYPE;
  x        record;
  v_n2s    boolean := 'n2s' = ANY (coalesce(p_can, '{}'));
  v_lost   boolean := false;
  v_total  numeric;
  v_spent  numeric;
  v_today  date := (now() AT TIME ZONE 'America/New_York')::date;
  v_gate   text;
  r        text[] := '{}';
BEGIN
  -- FOR UPDATE serializes claims, so two workers see each other's spend and never share a row.
  SELECT * INTO c FROM public.manual_sub_buy_config WHERE id FOR UPDATE;

  -- A row left in 'buying' past its lease means a worker died around the buy: the outcome is
  -- unknown. It is NEVER handed out again (that could buy twice); its side stops for a person.
  UPDATE public.manual_sub_buy
     SET state = 'unknown', reasons = reasons || 'worker_lost_mid_buy'::text, updated_at = now(),
         lease_token = NULL
   WHERE state = 'buying' AND lease_until < now() AND origin = 'manual';
  IF FOUND THEN
    UPDATE public.manual_sub_buy_config
       SET kill_switch = true, kill_reason = 'a buy was left unfinished: check EVO and GoTickets', updated_at = now()
     WHERE id;
    v_lost := true;
  END IF;
  -- The same for a buy the N2S auto-buyer filed: the unknown is the N2S desk's, and so is the
  -- kill switch (n2s_autobuy_queue_result flips theirs). This path's switch is not touched.
  FOR x IN
    UPDATE public.manual_sub_buy
       SET state = 'unknown', reasons = reasons || 'worker_lost_mid_buy'::text, updated_at = now(),
           lease_token = NULL
     WHERE state = 'buying' AND lease_until < now() AND origin = 'n2s'
    RETURNING n2s_exec_id
  LOOP
    PERFORM public.n2s_autobuy_queue_result(x.n2s_exec_id, 'unknown',
              jsonb_build_object('reasons', jsonb_build_array('worker_lost_mid_buy')));
    v_lost := true;
  END LOOP;
  IF v_lost THEN RETURN NULL; END IF;

  IF EXISTS (SELECT 1 FROM public.manual_sub_buy WHERE state = 'buying') THEN
    RETURN NULL;                                        -- one buy at a time, whoever it is for
  END IF;

  -- ── buys the N2S auto-buyer filed: always first, and only for a worker that can run them ──
  IF v_n2s THEN
    -- past the instant N2S said never to send after: stopped unsent, and the run goes back
    FOR x IN
      UPDATE public.manual_sub_buy
         SET state = 'stopped', reasons = reasons || 'queue_expired'::text, updated_at = now()
       WHERE state = 'requested' AND origin = 'n2s' AND buy_by <= now()
      RETURNING n2s_exec_id
    LOOP
      PERFORM public.n2s_autobuy_queue_result(x.n2s_exec_id, 'stopped',
                jsonb_build_object('reasons', jsonb_build_array('queue_expired')));
    END LOOP;
    -- An unknown N2S buy holds back N2S buys only. N2S's own switches are read again now: a
    -- kill switch or a stop set after filing keeps the row queued (it expires at buy_by).
    IF NOT EXISTS (SELECT 1 FROM public.manual_sub_buy WHERE state = 'unknown' AND origin = 'n2s') THEN
      SELECT * INTO n FROM public.n2s_autobuy_config WHERE id;
      IF n.mode = 'live' AND NOT n.kill_switch THEN
        SELECT * INTO b FROM public.manual_sub_buy
         WHERE state = 'requested' AND origin = 'n2s'
           AND NOT (CASE market WHEN 'gotickets' THEN n.gt_project_stopped ELSE n.project_stopped END)
         ORDER BY created_at, buy_id LIMIT 1 FOR UPDATE SKIP LOCKED;
        -- N2S's own ceilings ran when it filed the row; the control over both buyers still applies
        IF FOUND AND public.sub_buy_gate(b.market, b.max_total_usd) IS NULL THEN
          UPDATE public.manual_sub_buy
             SET state = 'buying', lease_token = gen_random_uuid(),
                 lease_until = now() + make_interval(secs => c.lease_s), updated_at = now()
           WHERE buy_id = b.buy_id
          RETURNING * INTO b;
          -- the N2S job as N2S builds it (fresh config, its row, its caps): one source, theirs
          RETURN jsonb_build_object('row', to_jsonb(b), 'cfg', '{}'::jsonb,
                                    'n2s', public.n2s_autobuy_queue_job(b.n2s_exec_id));
        END IF;
      END IF;
    END IF;
  END IF;

  -- ── this path's own buys, as before ──
  IF NOT c.enabled OR c.kill_switch THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.manual_sub_buy WHERE state = 'unknown' AND origin = 'manual') THEN
    RETURN NULL;                                        -- nothing while one of ours is unresolved
  END IF;

  -- 20261113430000: the control over both buyers (sub_buy_control). Asked with no amount first:
  -- that answers the shared stop and whether EVO is at its in-flight limit. A waiting buy
  -- stays 'requested' and is looked at again on the next tick.
  v_gate := public.sub_buy_gate('evo', 0);
  IF v_gate = 'shared_stop' THEN RETURN NULL; END IF;

  SELECT * INTO b FROM public.manual_sub_buy
   WHERE state = 'requested' AND origin = 'manual'
     AND (market <> 'evo' OR v_gate IS DISTINCT FROM 'evo_inflight_full')
   ORDER BY created_at, buy_id LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;

  v_total := round(b.max_price_ea * b.qty, 2);
  SELECT COALESCE(sum(COALESCE(bought_total_usd, round(max_price_ea * qty, 2))), 0) INTO v_spent
    FROM public.manual_sub_buy
   WHERE state IN ('bought', 'unknown') AND (updated_at AT TIME ZONE 'America/New_York')::date = v_today
     AND market = b.market AND origin = 'manual';       -- each market spends against its own ceiling
  IF b.market = 'gotickets' AND NOT c.gt_enabled THEN r := r || 'gotickets_buy_off'::text; END IF;
  IF v_total > (CASE b.market WHEN 'gotickets' THEN coalesce(c.gt_per_order_cap_usd, c.per_order_cap_usd)
                              ELSE c.per_order_cap_usd END)
    THEN r := r || 'over_order_cap'::text; END IF;
  IF v_spent + v_total > (CASE b.market WHEN 'gotickets' THEN coalesce(c.gt_daily_cap_usd, c.daily_cap_usd)
                                        ELSE c.daily_cap_usd END)
    THEN r := r || 'over_daily_cap'::text; END IF;
  IF public.sub_buy_gate(b.market, v_total) = 'over_shared_ceiling'
    THEN r := r || 'over_shared_ceiling'::text; END IF;  -- both buyers' spend today, every market
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
                              'tax_quote', c.tax_quote,
                              'gt_buyer_email', c.gt_buyer_email, 'gt_buyer_phone', c.gt_buyer_phone,
                              'gt_billing_address', c.gt_billing_address, 'gt_recipient', c.gt_recipient,
                              'gt_gift_card_ids', to_jsonb(c.gt_gift_card_ids),
                              -- the first run is a test: ask, store the answer, change nothing else
                              'tax_quote_test', c.tax_quote_test AND NOT c.tax_quote
                                AND NOT EXISTS (SELECT 1 FROM public.manual_sub_buy q WHERE q.quote_raw IS NOT NULL)));
END $function$;

CREATE OR REPLACE FUNCTION public.manual_sub_buy_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- a worker that does not say it can run N2S rows is never handed one (20261113440000)
  RETURN public.manual_sub_buy_claim_for('{}'::text[]);
END $function$;

-- ── 4. the result ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.manual_sub_buy_record(p_buy_id bigint, p_token uuid, p_patch jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_state  text := p_patch->>'state';
  v_origin text;
  v_exec   bigint;
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
         quote_raw        = COALESCE(p_patch->'quote_raw', quote_raw),
         error            = COALESCE(p_patch->>'error', error),
         lease_token      = CASE WHEN v_state = 'buying' THEN lease_token END,
         updated_at       = now()
   WHERE buy_id = p_buy_id AND state = 'buying' AND lease_token = p_token AND lease_until >= now()
  RETURNING origin, n2s_exec_id INTO v_origin, v_exec;
  IF NOT FOUND THEN
    RETURN 'lease_lost';
  END IF;
  IF v_origin = 'n2s' THEN
    -- 20261113440000: a buy filed by the N2S auto-buyer. Its result goes to the N2S desk's own
    -- row in the same transaction (bought -> buy_sent, stopped -> stopped with the run given
    -- back, unknown -> buy_unknown and THEIR kill switch). This path's kill switch is not touched.
    IF v_state <> 'buying' THEN
      PERFORM public.n2s_autobuy_queue_result(v_exec, v_state, COALESCE(p_patch->'n2s', p_patch));
    END IF;
  ELSIF v_state = 'unknown' THEN
    UPDATE public.manual_sub_buy_config
       SET kill_switch = true, updated_at = now(),
           kill_reason = format('buy %s: outcome unknown, %s', p_buy_id,
                                (SELECT CASE b.market WHEN 'gotickets' THEN 'check GoTickets' ELSE 'check EVO' END
                                   FROM public.manual_sub_buy b WHERE b.buy_id = p_buy_id))
     WHERE id;
  END IF;
  RETURN v_state;
END $function$;

-- ── 5. left to N2S's own row: following, alerts, the feed, the shared counts ──
CREATE OR REPLACE FUNCTION public.manual_sub_buy_follow_claim()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  b public.manual_sub_buy%ROWTYPE;
BEGIN
  SELECT * INTO b FROM public.manual_sub_buy
   WHERE state = 'bought' AND final_at IS NULL AND buy_order_id ~ '^\d+$'
     AND origin = 'manual'                              -- the N2S desk follows its own buys (20261113440000)
     AND created_at > now() - interval '7 days'
     AND (status_checked_at IS NULL OR status_checked_at < now() - CASE
            WHEN status_checks < 20 THEN interval '30 seconds'
            WHEN status_checks < 60 THEN interval '5 minutes'
            ELSE interval '30 minutes' END)
   ORDER BY status_checked_at NULLS FIRST, buy_id
   LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.manual_sub_buy
     SET status_checked_at = now(), status_checks = status_checks + 1,
         outcome = CASE WHEN outcome = 'none' THEN 'pending' ELSE outcome END
   WHERE buy_id = b.buy_id;
  RETURN jsonb_build_object('buy_id', b.buy_id, 'buy_order_id', b.buy_order_id, 'market', b.market);
END $function$;

CREATE OR REPLACE FUNCTION public.manual_sub_buy_alert_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c     public.manual_sub_buy_config;
  v_to  text[];
  v_from text;
  rk    text;
  e     record;
  m     jsonb;
  addr  text;
  best  integer;
  resp  extensions.http_response;
  n     integer := 0;
BEGIN
  SELECT * INTO c FROM public.manual_sub_buy_config;
  IF NOT coalesce(c.alerts_enabled, false) THEN RETURN 0; END IF;
  SELECT coalesce(c.alert_email_to, a.email_to), a.email_from INTO v_to, v_from FROM public.n2s_autobuy_config a;
  SELECT max(decrypted_secret) FILTER (WHERE name = 'RESEND_API_KEY') INTO rk FROM vault.decrypted_secrets;
  IF rk IS NULL OR v_from IS NULL OR coalesce(cardinality(v_to), 0) = 0 THEN RETURN 0; END IF;
  PERFORM set_config('http.timeout_msec', '5000', true);
  FOR e IN
    SELECT b AS buy, k.kind
      FROM public.manual_sub_buy b
      CROSS JOIN LATERAL (VALUES
        ('bought',  b.state = 'bought' AND b.buy_order_id IS NOT NULL AND b.alerted_bought_at IS NULL),
        ('unknown', b.state = 'unknown' AND b.alerted_unknown_at IS NULL),
        ('final',   b.outcome IN ('confirmed', 'rejected', 'canceled') AND b.alerted_final_at IS NULL)
      ) AS k(kind, due)
     WHERE k.due AND b.origin = 'manual'               -- the N2S desk sends its own (20261113440000)
     ORDER BY b.buy_id, k.kind LIMIT 5
  LOOP
    m := public.manual_sub_buy_alert_text(e.buy, e.kind);
    best := NULL;
    FOREACH addr IN ARRAY v_to LOOP
      BEGIN
        resp := extensions.http(('POST', 'https://api.resend.com/emails',
                  ARRAY[extensions.http_header('Authorization', 'Bearer ' || rk)], 'application/json',
                  jsonb_build_object('from', v_from, 'to', jsonb_build_array(addr),
                                     'subject', m->>'subject', 'text', m->>'text')::text)::extensions.http_request);
        best := CASE WHEN best = 200 THEN 200 ELSE resp.status END;
      EXCEPTION WHEN OTHERS THEN
        best := coalesce(best, -1);
      END;
    END LOOP;
    UPDATE public.manual_sub_buy
       SET alerted_bought_at  = CASE WHEN e.kind = 'bought'  THEN now() ELSE alerted_bought_at END,
           alerted_unknown_at = CASE WHEN e.kind = 'unknown' THEN now() ELSE alerted_unknown_at END,
           alerted_final_at   = CASE WHEN e.kind = 'final'   THEN now() ELSE alerted_final_at END,
           alert_http = best
     WHERE buy_id = (e.buy).buy_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END
$function$;

CREATE OR REPLACE FUNCTION public.sub_buy_evo_inflight()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT ((SELECT count(*) FROM public.manual_sub_buy b
            WHERE b.market = 'evo'                      -- a buy filed by N2S is counted on its own row once sent
              AND (b.state = 'buying'
                OR (b.origin = 'manual' AND b.state = 'bought' AND b.final_at IS NULL
                    AND b.updated_at > now() - make_interval(mins => k.evo_inflight_minutes))))
        + (SELECT count(*) FROM public.n2s_autobuy_exec e
            WHERE e.mode = 'live' AND e.sub_source = 'tevo'
              AND (e.phase = 'buying'
                OR (e.phase = 'buy_sent'
                    AND e.live_started_at > now() - make_interval(mins => k.evo_inflight_minutes)))))::integer
    FROM public.sub_buy_control k
$function$;

CREATE OR REPLACE FUNCTION public.sub_buy_spent_today()
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (SELECT COALESCE(sum(COALESCE(b.bought_total_usd, round(b.max_price_ea * b.qty, 2))), 0)
            FROM public.manual_sub_buy b
           WHERE (b.state = 'buying' OR (b.origin = 'manual' AND b.state IN ('bought', 'unknown')))  -- N2S's own row counts its buy once sent
             AND (b.updated_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date)
       + (SELECT COALESCE(sum(COALESCE(e.buy_total_usd, e.sub_total_usd + COALESCE(e.est_tax_usd, 0))), 0)
            FROM public.n2s_autobuy_exec e
           WHERE e.mode = 'live'
             AND e.phase IN ('buying', 'buy_sent', 'sub_accepted', 'accepted', 'buy_unknown', 'accept_failed', 'accept_unknown')
             AND (e.live_started_at AT TIME ZONE 'America/New_York')::date = (now() AT TIME ZONE 'America/New_York')::date)
$function$;

CREATE OR REPLACE FUNCTION public.sub_finder_buys(p_key_id bigint, p_updated_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c       public.sub_finder_config;
  v_now   timestamptz := now();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) OR NOT (p_key_id = ANY (c.autobuys_key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not read buy results');
  END IF;
  RETURN (
    WITH f AS (
      SELECT e.live_updated_at AS at, 1 AS src, e.exec_id AS id
        FROM public.n2s_autobuy_exec e
       WHERE e.mode = 'live' AND e.buy_order_id IS NOT NULL
         AND (p_updated_since IS NULL OR e.live_updated_at >= p_updated_since)
      UNION ALL
      SELECT b.changed_at, 2, b.buy_id
        FROM public.manual_sub_buy b
       WHERE b.buy_order_id IS NOT NULL AND b.origin = 'manual'   -- a buy filed by N2S is the n2s_auto item above
         AND (p_updated_since IS NULL OR b.changed_at >= p_updated_since)
    ), page AS (
      SELECT * FROM f ORDER BY at, src, id LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off,
      'items', (SELECT coalesce(jsonb_agg(
                         CASE p.src
                           WHEN 1 THEN (SELECT public.n2s_autobuy_result_json(e) || jsonb_build_object('buyer', 'n2s_auto')
                                          FROM public.n2s_autobuy_exec e WHERE e.exec_id = p.id)
                           ELSE (SELECT public.sub_finder_buy_result_json(b)
                                   FROM public.manual_sub_buy b WHERE b.buy_id = p.id) END
                         ORDER BY p.at, p.src, p.id), '[]'::jsonb) FROM page p),
      'generated_at', to_char(v_now AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$function$;

REVOKE ALL ON FUNCTION public.manual_sub_buy_file_n2s(bigint, timestamptz, numeric),
                       public.manual_sub_buy_claim_for(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.manual_sub_buy_file_n2s(bigint, timestamptz, numeric),
                          public.manual_sub_buy_claim_for(text[]) TO service_role;
