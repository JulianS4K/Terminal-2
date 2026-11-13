-- Migration 20261113000000 · level:secondary-sales · lane:D0 · writes:sub_finder_refresh · reads:events,collector_cadence,sub_finder_order,sub_finder_job,n2s_items,v_sub_orders,n2s_evo_current,n2s_gt_current,n2s_sg_current · pre:20261112010000
--
-- SISTER BUCKET POLLING: orders the CRM marks "need to sub" get their event polled routinely.
--
-- Operator 2026-11-13: accepted orders with ticket problems are "a sister to n2s but not the
-- same thing ... expand poller to include these events once they come into this bucket", on
-- the pace the terminal polls EVO and GoTickets ("see terminal main"). Asked how the CRM marks
-- them: "we built the crm check pipeline in our outbound crm api" — so the bucket is the
-- orders alerted through the sub finder API (sub_finder_order, while `watching`).
--
-- WHY THIS IS NEEDED. The sub finder was told to use the polling we already do, but in prod
-- that covers little: the N2S pipeline pulls only orders whose sale timer is still open (about
-- 7 events at a time), and the fleet pollers have been paused since 2026-09-27. An order past
-- its timer kept its first answer forever.
--
-- WHAT CHANGES. Only sub_finder_refresh's own pull (behind refresh_pull, still default OFF):
-- instead of one flat pull_refresh interval for every watched event, each event is pulled on
-- the terminal's time-to-event band from collector_cadence (EVO listings: 5 min inside 3 days,
-- 15 min to 7 days, 30/60 min to 14, 60 min to 30, 4 h to 60, 12 h to 180, daily beyond),
-- never faster than pull_refresh. It still goes through n2s_pull_events, so EVO, GoTickets and
-- SeatGeek are each skipped when their own last pull is newer than the band, and the listings
-- land in n2s_*_current where the sub finder already reads them. Those tables keep one hour,
-- which is fine: between two pulls of a slow band the order keeps the covers it had.
--
-- NOT N2S: no gate, cap, live-run budget, sale accept or n2s_* write is touched. GETs only.
-- Stop conditions are unchanged (left the CRM book, order feed says over, event passed,
-- superseded).
--
-- rollback: re-apply sub_finder_refresh() from 20261112010000_sub_finder_api.sql.

CREATE OR REPLACE FUNCTION public.sub_finder_refresh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
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

  -- 1. stop watching what is finished. Only these reasons end a watch (plus a newer lookup
  --    of the same order, in sub_finder_submit). The cheap ones run for every order every tick.
  UPDATE public.sub_finder_order o
     SET watching = false, closed_reason = x.reason, closed_at = now(), updated_at = now()
    FROM (
      SELECT w.job_id, w.idx, CASE
          WHEN w.event_date < (now() AT TIME ZONE 'America/New_York')::date THEN 'event_passed'
          -- it came from the CRM's N2S book and is no longer open there
          WHEN w.order_source = 'n2s' AND NOT EXISTS (
                 SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = w.order_number OR n.n2s_order_key = w.order_number)
                   AND NOT coalesce(n.is_terminal, false) AND n.status IN ('n2s', 'n2b'))
            THEN 'left_crm_n2s'
        END AS reason
      FROM public.sub_finder_order w WHERE w.watching) x
   WHERE o.job_id = x.job_id AND o.idx = x.idx AND x.reason IS NOT NULL;
  GET DIAGNOSTICS v_closed = ROW_COUNT;
  -- "One of our order feeds says the sale is over" is a lookup in v_sub_orders by order
  -- number, which costs about 1.7 s each (its EVO arm cannot use an index on a text id). So
  -- it is paced: a few orders per tick, each at most every 15 minutes.
  FOR r IN SELECT w.job_id, w.idx, w.order_number FROM public.sub_finder_order w
            WHERE w.watching AND (w.feed_checked_at IS NULL OR w.feed_checked_at < now() - interval '15 minutes')
            ORDER BY w.feed_checked_at NULLS FIRST, w.updated_at LIMIT 3
  LOOP
    UPDATE public.sub_finder_order o
       SET feed_checked_at = now(),
           watching      = (f.reason IS NULL),
           closed_reason = coalesce(f.reason, o.closed_reason),
           closed_at     = CASE WHEN f.reason IS NULL THEN o.closed_at ELSE now() END,
           updated_at    = CASE WHEN f.reason IS NULL THEN o.updated_at ELSE now() END
      FROM (SELECT (SELECT 'order_' || v.canonical_status FROM public.v_sub_orders v
                    WHERE v.order_id = r.order_number AND NOT v.is_open
                      AND v.canonical_status IN ('fulfilled', 'cancelled', 'rejected') LIMIT 1) AS reason) f
     WHERE o.job_id = r.job_id AND o.idx = r.idx;
    IF NOT (SELECT watching FROM public.sub_finder_order WHERE job_id = r.job_id AND idx = r.idx) THEN
      v_closed := v_closed + 1;
    END IF;
  END LOOP;

  -- 2. the watched events, longest-unrefreshed first. Their listings come from the routine
  --    polling; a pull of our own is fired only if refresh_pull is switched on (the pull
  --    function then skips any market whose own last pull is newer than pull_refresh).
  SELECT array_agg(e) INTO v_evs FROM (
    SELECT o.tevo_event_id AS e
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.tevo_event_id IS NOT NULL
    GROUP BY 1 ORDER BY min(coalesce(o.refreshed_at, j.done_at)) LIMIT c.refresh_max_events) q;
  IF v_evs IS NULL THEN
    RETURN jsonb_build_object('closed', v_closed, 'events', 0, 'jobs_rematched', 0);
  END IF;
  -- The sister bucket's own polling: each watched event on the terminal's time-to-event band
  -- (collector_cadence, EVO listings: 5 min inside 3 days ... daily far out), never faster
  -- than pull_refresh. n2s_pull_events skips a market whose own last pull is newer than the
  -- interval it is given, so one call per band keeps every market on that band's pace.
  IF c.refresh_pull THEN
    FOR r IN
      SELECT greatest(coalesce(b.required_min, 60), ceil(extract(epoch FROM c.pull_refresh) / 60)::int) AS mins,
             array_agg(e.id) AS evs
      FROM public.events e
      LEFT JOIN LATERAL public.collector_band(
        'EVO', 'listings', greatest(extract(epoch FROM (e.occurs_at_local - now())) / 3600.0, 0)::numeric) b ON true
      WHERE e.id = ANY (v_evs)
      GROUP BY 1
    LOOP
      PERFORM public.n2s_pull_events(r.evs, make_interval(mins => r.mins));
    END LOOP;
  END IF;

  -- 3. re-match the jobs with a watched order whose event has landed something newer
  FOR r IN
    SELECT DISTINCT o.job_id
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.state IN ('cover', 'no_cover')
      AND o.tevo_event_id = ANY (v_evs)
      AND (EXISTS (SELECT 1 FROM public.n2s_evo_current x WHERE x.event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at))
        OR EXISTS (SELECT 1 FROM public.n2s_gt_current x WHERE x.tevo_event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at))
        OR EXISTS (SELECT 1 FROM public.n2s_sg_current x WHERE x.tevo_event_id = o.tevo_event_id
                     AND x.pulled_at > coalesce(o.refreshed_at, j.done_at)))
    LIMIT 200
  LOOP
    UPDATE public.sub_finder_order SET rematch = true
     WHERE job_id = r.job_id AND watching AND state IN ('cover', 'no_cover');
    PERFORM public.sub_finder_load_native(r.job_id, c.refresh_fresh);
    PERFORM public.sub_finder_match(r.job_id);
    v_jobs := v_jobs + 1;
  END LOOP;
  RETURN jsonb_build_object('closed', v_closed, 'events', cardinality(v_evs), 'jobs_rematched', v_jobs);
END
$$;

REVOKE ALL ON FUNCTION public.sub_finder_refresh() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_refresh() TO service_role;
