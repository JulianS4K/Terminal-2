-- Migration 20261113090000 · level:secondary-sales · lane:D0 · writes:sub_finder_refresh · reads:events,collector_cadence(via collector_band),sub_finder_order,sub_finder_job,n2s_items,n2s_evo_current,n2s_gt_current,n2s_sg_current · pre:20261113060000
--
-- SUB FINDER: watched orders' events are pulled on the terminal's time-to-event cadence.
--
-- Operator 2026-11-13: orders the CRM flags are "a sister to n2s ... expand poller to include
-- these events once they come into this bucket", on the pace the terminal polls EVO and
-- GoTickets; then, shown that a watched order outside N2S's open-timer set got no new listings
-- after its first lookup: "turn it on and rework 1079".
--
-- refresh_pull was switched on in prod the same day with the flat rule: every watched event
-- pulled every pull_refresh (2 minutes), whether it plays tonight or in three weeks. This
-- replaces only that pull step. Each watched event is now pulled on its time-to-event band
-- from collector_cadence (EVO listings: 5 min inside 3 days, 15 min to 7 days, 30/60 min to 14,
-- 60 min to 30, 4 h to 60, 12 h to 180, daily beyond), never faster than pull_refresh, and 60
-- minutes when no band matches. It still goes through n2s_pull_events, so EVO, GoTickets and
-- SeatGeek are each skipped when their own last pull is newer than the band. GETs only.
--
-- The listing tables keep one hour. Between two pulls of a slower band an order keeps the
-- covers it had (the rematch carry-over), so its answer does not flicker to "no cover".
--
-- Everything else in sub_finder_refresh is as in 20261113060000 (stop conditions, live status
-- from the marketplace feeds, the rematch).
--
-- rollback: re-apply sub_finder_refresh() from 20261113060000_sub_finder_api_first.sql.

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
          WHEN (w.order_source = 'n2s' OR w.in_n2s) AND NOT EXISTS (
                 SELECT 1 FROM public.n2s_items n
                 WHERE (n.order_number = w.order_number OR n.n2s_order_key = w.order_number)
                   AND NOT coalesce(n.is_terminal, false) AND n.status IN ('n2s', 'n2b'))
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
  SELECT array_agg(e) INTO v_evs FROM (
    SELECT o.tevo_event_id AS e
    FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
    WHERE o.watching AND j.status = 'done' AND o.tevo_event_id IS NOT NULL
    GROUP BY 1 ORDER BY min(coalesce(o.refreshed_at, j.done_at)) LIMIT c.refresh_max_events) q;
  IF v_evs IS NULL THEN
    RETURN jsonb_build_object('closed', v_closed, 'events', 0, 'jobs_rematched', 0);
  END IF;
  IF c.refresh_pull THEN
    -- one pull per cadence band: the nearer the event, the more often (never faster than pull_refresh)
    FOR r IN
      SELECT greatest(coalesce(b.required_min, 60), ceil(extract(epoch FROM c.pull_refresh) / 60)::int) AS mins,
             array_agg(e.id) AS evs
      FROM public.events e
      LEFT JOIN LATERAL public.collector_band(
             'EVO', 'listings',
             greatest(extract(epoch FROM (e.occurs_at_local::timestamp - (now() AT TIME ZONE 'America/New_York'))) / 3600.0, 0)::numeric) b ON true
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
