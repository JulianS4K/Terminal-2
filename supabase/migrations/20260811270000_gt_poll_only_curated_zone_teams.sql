-- Migration 20260811270000 · lane:D0 · operator-directed 2026-08-11
--   ("only poll teams that have a manual zone").
--
--   writes: gt_listings_poll_tick(int) [fn — require a curated manual zone].
--
-- WHY. Deals need a zone-precise realized-sale anchor, and the operator's manual curated zones
-- (performer_zones.source='curated' + performer_zone_rules) are the authoritative section→zone
-- source — not derive_zone_fallback ("zones we created") nor site zones. So poll ONLY events
-- whose mapped home performer+venue has a curated zone (119 performers → ~1,148 future events,
-- vs ~29.5k). Implicitly requires a tevo map (we need performer_id+venue_id to look up the
-- zone), which is exactly the set the deals scanner + realized-median can properly value.
-- Massive credit reduction as a bonus; the empty-backoff / value-gate / quarantine logic all
-- still apply on top.
--
-- ROLLBACK: restore gt_listings_poll_tick to mig 20260811262000 (US + parking filter, no zone).

CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(p_max integer DEFAULT 120)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_n int := 0; v_req bigint; v_token text;
  v_daily_cap int := 1000000;
  us_states text[] := ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC'];
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  IF (SELECT coalesce(sum(listings_polls_today),0) FROM public.gt_listings_poll_state
        WHERE budget_day = current_date) >= v_daily_cap THEN
    RETURN 0;
  END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      SELECT g.gt_event_id, g.tevo_event_id, g.event_time_utc,
             EXTRACT(epoch FROM (g.event_time_utc - now()))/3600.0 AS hte,
             ps.last_polled_listings_at, ps.event_median_price
      FROM public.gotickets_event g
      JOIN public.events e ON e.id = g.tevo_event_id
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
      WHERE g.status = 'AS_SCHEDULED'
        AND g.event_time_utc > now() - interval '3 hours'
        AND upper(btrim(coalesce(g.venue_state,''))) = ANY(us_states)
        AND coalesce(g.name,'')       !~* 'parking'
        AND coalesce(g.venue_name,'')  !~* 'parking'
        AND coalesce(g.performer,'')   !~* 'parking'
        -- ONLY teams with a manual curated zone at this venue.
        AND EXISTS (SELECT 1 FROM public.performer_zones pz
                     WHERE pz.performer_id = e.primary_performer_id
                       AND pz.venue_id = e.venue_id
                       AND pz.source = 'curated')
        AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
        AND (ps.cold_until       IS NULL OR ps.cold_until       < now())
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at,
             CASE WHEN ev.event_time_utc >= now() + interval '14 days'
                       AND coalesce(ev.event_median_price, 9999) >= 25 THEN 10
                  ELSE (SELECT required_min FROM public.collector_band('GT','listings', ev.hte)) END AS req_min
      FROM ev
    )
    SELECT gt_event_id, tevo_event_id FROM due
    WHERE last_polled_listings_at IS NULL
       OR last_polled_listings_at < now() - make_interval(mins => req_min)
    ORDER BY last_polled_listings_at NULLS FIRST
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
      headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept','application/json'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.gt_listings_inflight(request_id, gt_event_id, tevo_event_id, fired_at)
      VALUES (v_req, r.gt_event_id, r.tevo_event_id, now());
    INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.gt_event_id, now(), 1, current_date)
      ON CONFLICT (gt_event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

-- Retire feed deals for events without a curated zone (no longer polled → would go stale).
UPDATE public.gotickets_deals_feed f SET gone_at = now()
WHERE f.gone_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.events e
    JOIN public.performer_zones pz ON pz.performer_id = e.primary_performer_id
      AND pz.venue_id = e.venue_id AND pz.source = 'curated'
    WHERE e.id = f.tevo_event_id);
