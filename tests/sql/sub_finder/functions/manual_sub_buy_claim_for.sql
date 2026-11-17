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
END $function$

