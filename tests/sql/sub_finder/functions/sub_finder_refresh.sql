CREATE OR REPLACE FUNCTION public.sub_finder_refresh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  c        public.sub_finder_config;
  v_closed integer := 0;
  v_jobs   integer := 0;
  v_evs    bigint[];
  r        record;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT c.refresh_enabled THEN RETURN jsonb_build_object('skipped', 'off'); END IF;
  IF NOT public.cron_try_lock('sub_finder_refresh') THEN RETURN jsonb_build_object('skipped', 'overlap'); END IF;

  -- 0. CRM N2S-feed items labelled need2buy start their lookups here (20261113160000)
  PERFORM public.sub_finder_n2b_intake();
  -- and the CRM's decisions on them (sub_decision in the same feed, 20261113170000)
  PERFORM public.sub_finder_feed_decisions();

  -- 1. stop watching what is finished. Only these reasons end a watch (plus a newer lookup
  --    of the same order, in sub_finder_submit). The cheap ones run for every order every tick.
  UPDATE public.sub_finder_order o
     SET watching = false, closed_reason = x.reason, closed_at = now(), updated_at = now()
    FROM (
      SELECT w.job_id, w.idx, CASE
          WHEN w.event_date < (now() AT TIME ZONE 'America/New_York')::date THEN 'event_passed'
          -- it came from the CRM's N2S book and is no longer open there
          -- a need2buy lookup lives as long as its label: gone, changed or the item finished -> closed
          WHEN w.via_need2buy AND NOT EXISTS (
                 SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = w.order_number OR n.n2s_order_key = w.order_number)
                   AND n.item_source IS DISTINCT FROM 'gmail' AND NOT coalesce(n.is_terminal, false)
                   AND public.sub_finder_need2buy(n.status, n.status_label, n.raw))
            THEN 'label_removed'
          WHEN (w.order_source = 'n2s' OR w.in_n2s) AND NOT w.via_need2buy AND NOT EXISTS (
                 SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = w.order_number OR n.n2s_order_key = w.order_number)
                   AND NOT coalesce(n.is_terminal, false)
                   AND (n.status IN ('n2s', 'n2b') OR public.sub_finder_need2buy(n.status, n.status_label, n.raw)))
            THEN 'left_crm_n2s'
        END AS reason
      FROM public.sub_finder_order w WHERE w.watching) x
   WHERE o.job_id = x.job_id AND o.idx = x.idx AND x.reason IS NOT NULL;
  GET DIAGNOSTICS v_closed = ROW_COUNT;
  -- "The marketplace says the sale is over": the order's own marketplace feed first (GoTickets,
  -- TickPick, Vivid, SeatGeek, EVO — each read by its indexed order id), then our mirror of the
  -- CRM's books. Paced: up to feed_check_batch orders a tick, each at most every feed_check_every.
  FOR r IN SELECT w.job_id, w.idx, w.order_number, w.site FROM public.sub_finder_order w
            WHERE w.watching AND (w.feed_checked_at IS NULL OR w.feed_checked_at < now() - c.feed_check_every)
            ORDER BY w.feed_checked_at NULLS FIRST, w.updated_at LIMIT c.feed_check_batch
  LOOP
    UPDATE public.sub_finder_order o
       SET feed_checked_at = now(),
           watching      = (f.reason IS NULL),
           closed_reason = coalesce(f.reason, o.closed_reason),
           closed_at     = CASE WHEN f.reason IS NULL THEN o.closed_at ELSE now() END,
           updated_at    = CASE WHEN f.reason IS NULL THEN o.updated_at ELSE now() END
      FROM (SELECT 'order_' || public.sub_finder_order_closed(r.order_number, r.site) AS reason) f
     WHERE o.job_id = r.job_id AND o.idx = r.idx;
    IF NOT (SELECT watching FROM public.sub_finder_order WHERE job_id = r.job_id AND idx = r.idx) THEN
      v_closed := v_closed + 1;
    END IF;
  END LOOP;

  -- 2. the watched events, longest-unrefreshed first. Their listings come from the routine
  --    polling; a pull of our own is fired only if refresh_pull is switched on (the pull
  --    function then skips any market whose own last pull is newer than pull_refresh).
  --    An order whose GoTickets sub offer is still pending (requested, sent or unknown) is left
  --    alone: no pull and no re-match for it until the offer is accepted, stopped, denied or cancelled.
  SELECT array_agg(e) INTO v_evs FROM (
    SELECT o.tevo_event_id AS e
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.tevo_event_id IS NOT NULL
      AND NOT public.sub_finder_offer_pending(o.order_number, o.key_id)
    GROUP BY 1 ORDER BY min(coalesce(o.refreshed_at, j.done_at)) LIMIT c.refresh_max_events) q;
  IF v_evs IS NULL THEN
    RETURN jsonb_build_object('closed', v_closed, 'events', 0, 'jobs_rematched', 0);
  END IF;
  IF c.refresh_pull THEN
    PERFORM public.n2s_pull_events(v_evs, c.pull_refresh, true);   -- true: SeatGeek too, every time
  END IF;

  -- 3. re-match the jobs with a watched order whose event has landed something newer
  FOR r IN
    SELECT DISTINCT o.job_id
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.state IN ('cover', 'no_cover')
      AND o.tevo_event_id = ANY (v_evs)
      AND NOT public.sub_finder_offer_pending(o.order_number, o.key_id)
      AND (EXISTS (SELECT 1 FROM public.n2s_evo_current x WHERE x.event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at))
        OR EXISTS (SELECT 1 FROM public.n2s_gt_current x WHERE x.tevo_event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at))
        OR EXISTS (SELECT 1 FROM public.n2s_sg_current x WHERE x.tevo_event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at)))
    LIMIT 200
  LOOP
    UPDATE public.sub_finder_order SET rematch = true
     WHERE job_id = r.job_id AND watching AND state IN ('cover', 'no_cover')
       AND NOT public.sub_finder_offer_pending(order_number, key_id);
    PERFORM public.sub_finder_load_native(r.job_id, c.refresh_fresh);
    PERFORM public.sub_finder_match(r.job_id);
    v_jobs := v_jobs + 1;
  END LOOP;

  -- 4. an accepted GoTickets offer whose buy of the offered EVO seats stopped (the listing went
  --    before we could buy it): let go of that dead buy, so the standing automatic one-to-one
  --    rule may buy for the order on a later re-match. Nothing else buys on the acceptance.
  FOR r IN
    SELECT g.offer_id, g.job_id, g.idx, g.buy_id FROM public.sub_finder_gt_offer g
      JOIN public.manual_sub_buy b ON b.buy_id = g.buy_id
     WHERE g.live AND g.gt_status = 'ACCEPTED' AND b.state = 'stopped'
     ORDER BY g.offer_id LIMIT 20
  LOOP
    UPDATE public.sub_finder_gt_offer SET buy_id = NULL, buy_note = 'offered_seats_gone', updated_at = now()
     WHERE offer_id = r.offer_id;
    UPDATE public.sub_finder_order
       SET buy_id = NULL, action = CASE WHEN action = 'auto_bought' THEN 'offer' ELSE action END,
           rematch = true, updated_at = now()
     WHERE job_id = r.job_id AND idx = r.idx AND buy_id = r.buy_id;
  END LOOP;
  PERFORM public.sub_finder_release_stopped();           -- 20261113310000: does nothing while the switch is off
  RETURN jsonb_build_object('closed', v_closed, 'events', cardinality(v_evs), 'jobs_rematched', v_jobs);
END
$function$

