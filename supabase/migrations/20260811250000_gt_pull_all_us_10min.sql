-- Migration 20260811250000 · lane:D0/A1 (GoTickets ingest) · operator-directed 2026-08-11
--   ("go tickets: pull all their events [US-only]; follow EVO's DTE refresh cadence, not a
--    flat interval; data retention happens after processing; refresh + map catalogue daily").
--
--   writes: collector_cadence [GT listings → EVO DTE curve], gt_listings_poll_tick(int) [fn
--           replace — poll ALL US AS_SCHEDULED future events, not just tevo-mapped],
--           cron gt_listings_poll_2min [batch ↑], cron gt_listings_drain_1min [batch ↑],
--           cron gt_map_events_wide_daily [NEW — daily comprehensive map].
--   reads: gotickets_event, gt_listings_poll_state, collector_cadence.
--   auth: builder service_role-guarded SECDEF poller.
--
-- WHY / DECISIONS
--  * Coverage: the poller previously required tevo_event_id IS NOT NULL (mapped only ≈1.6k).
--    Now it polls ALL US (venue_state ∈ 50 states+DC) AS_SCHEDULED future events (~44k).
--    tevo_event_id is nullable on gt_listings_inflight + gotickets_listings_snapshots, so
--    unmapped polls store fine; they simply don't feed the tevo-joined deals scanner.
--  * Refresh cadence = EVO's DTE curve (operator directive): ≤3d 5m · 3-7d 15m · 8-14d 30m/60m
--    peak/off · 15-30d 60m · 31-60d 4h · 61-180d 12h · 180d+ 24h. collector_band('GT',...)
--    reads collector_cadence, restored here to those values (they mirror EVO). Because most
--    events are far-out (long intervals), all-US coverage stays a sane ~10-12 req/s to
--    GoTickets — no flat-10-min 73 req/s ban risk.
--  * Data retention = "after processing" — UNCHANGED. gotickets_listings_snapshots already
--    runs EVO's exact policy (retention_policy: keep_days=15, captured_at, enabled); the
--    retention_tick sweep prunes on schedule after rows are ingested/processed.
--  * Throughput: DTE steady-state ≈ 1.3-1.5k events due per 2-min tick (near-term dominates),
--    plus a one-time ≈44k initial-coverage burst. poll batch 120→2000/2min (~16 req/s during
--    the initial sweep, settling to ~10-12), drain 1000→3000/min so responses don't backlog.
--    The DTE gate caps re-polling regardless of batch size.
--  * Daily map: gt_map_events_wide_daily runs the wide-horizon instant matcher + the US venue
--    matcher once daily so the whole catalogue (not just ≤120d) stays mapped for the deals
--    cross-reference. Catalog *refresh* already runs hourly (gt_catalog_sync/drain).
--
-- ROLLBACK: restore gt_listings_poll_tick to the mapped-only WHERE (prev def);
--   cron.schedule('gt_listings_poll_2min','*/2 * * * *',$$SELECT gt_listings_poll_tick(120)$$);
--   cron.schedule('gt_listings_drain_1min','* * * * *',$$SELECT gt_listings_drain(1000)$$);
--   cron.unschedule('gt_map_events_wide_daily');

-- 1. GT listings cadence = EVO DTE curve (idempotent restore).
UPDATE public.collector_cadence SET peak_interval_min=5,    offpeak_interval_min=5,    updated_at=now() WHERE source='GT' AND scope='listings' AND band='le3d';
UPDATE public.collector_cadence SET peak_interval_min=15,   offpeak_interval_min=15,   updated_at=now() WHERE source='GT' AND scope='listings' AND band='le7d';
UPDATE public.collector_cadence SET peak_interval_min=30,   offpeak_interval_min=60,   updated_at=now() WHERE source='GT' AND scope='listings' AND band='d8_14';
UPDATE public.collector_cadence SET peak_interval_min=60,   offpeak_interval_min=60,   updated_at=now() WHERE source='GT' AND scope='listings' AND band='d15_30';
UPDATE public.collector_cadence SET peak_interval_min=240,  offpeak_interval_min=240,  updated_at=now() WHERE source='GT' AND scope='listings' AND band='d31_60';
UPDATE public.collector_cadence SET peak_interval_min=720,  offpeak_interval_min=720,  updated_at=now() WHERE source='GT' AND scope='listings' AND band='d61p';
UPDATE public.collector_cadence SET peak_interval_min=1440, offpeak_interval_min=1440, updated_at=now() WHERE source='GT' AND scope='listings' AND band='d181p';

-- 2. Poller — poll ALL US AS_SCHEDULED future GoTickets events (mapped or not), DTE-gated.
CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(p_max integer DEFAULT 120)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_n int := 0; v_req bigint; v_token text;
  us_states text[] := ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC'];
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      SELECT g.gt_event_id, g.tevo_event_id,
             EXTRACT(epoch FROM (g.event_time_utc - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
      WHERE g.status = 'AS_SCHEDULED'
        AND g.event_time_utc > now() - interval '3 hours'
        AND upper(btrim(coalesce(g.venue_state,''))) = ANY(us_states)
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at
      FROM ev JOIN LATERAL public.collector_band('GT','listings', ev.hte) c ON true
      WHERE ev.last_polled_listings_at IS NULL
         OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    )
    SELECT gt_event_id, tevo_event_id FROM due ORDER BY last_polled_listings_at NULLS FIRST LIMIT p_max
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

-- 3. Raise poll + drain throughput for the wider (all-US) candidate set.
SELECT cron.schedule('gt_listings_poll_2min', '*/2 * * * *', $$SELECT public.gt_listings_poll_tick(2000);$$);
SELECT cron.schedule('gt_listings_drain_1min', '* * * * *',   $$SELECT public.gt_listings_drain(3000);$$);

-- 4. Daily comprehensive map — wide-horizon instant matcher + US venue matcher.
SELECT cron.schedule('gt_map_events_wide_daily', '50 8 * * *',
  $$SELECT public.gt_map_events(3650); SELECT public.match_gotickets_us_events(3000, 3650, 0.80, true);$$);
