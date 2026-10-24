-- Migration 20260901141447 · level:admin · lane:A1 · operator-directed 2026-09-01
--   ("for go tickets have it poll on events we're polling for evolution and
--     match polling cadence and data retention schema").
--
--   writes: gt_listings_poll_tick(int) [fn], cron.job (gt_listings_poll_2min command),
--           retention_policy (gotickets_listings_snapshots.priority)
--   reads:  gotickets_event, events, gt_listings_poll_state, collector_cadence
--
-- WHY. GoTickets listings polling is realigned to be a mirror of the EVO poller
-- rather than an independent broad-US sweep. Three changes:
--
-- 1. SCOPE. Was: every US, non-parking, AS_SCHEDULED GT event -- 64,615 events,
--    the overwhelming majority of which have no EVO counterpart and so produce
--    no cross-source comparison. Now: only GT events that resolve to an event in
--    the EVO polling set, using the SAME predicate evo_listings_poll_tick() uses
--    (occurs_at_local present, > now()-3h, state <> 'ignored'), joined through
--    gotickets_event.tevo_event_id. That is 3,761 events -- a 94% cut.
--
-- 2. CADENCE. Was: collector_band('GT','listings',...) for most events, PLUS a
--    10-minute curated-zone deal tier (mig 20260811274000). Now: the EVO ladder
--    only -- collector_band('EVO','listings',...) -- with NO exceptions, per
--    operator decision this session. The band time-to-event is computed from the
--    EVO event's own occurs_at_local, not the GT event_time_utc, so a given event
--    lands in the SAME band on both sides and the two sources stay phase-matched.
--
--    The collector_cadence rows for source='GT' are byte-identical to source='EVO'
--    today, but reading EVO's rows directly means the two cannot silently drift:
--    retuning EVO now retunes GT. gt_listings_poll_tick was the ONLY reader of the
--    'GT' rows, so those rows are now inert (left in place, not deleted).
--
--    CONSEQUENCE, accepted by the operator: 2,485 of the 3,761 in-scope events
--    previously qualified for the 10-minute curated-zone tier and now follow their
--    band instead (mostly 240 or 720 min). scan_gotickets_deals() therefore sees
--    materially staler prices for most of what it values. Restoring the tier is a
--    one-clause change if deal quality regresses.
--
-- 3. ORDERING. Was: ORDER BY last_polled_listings_at NULLS FIRST -- absolute
--    staleness, which let the far-future long tail (59% of the old scope) crowd
--    out the near bands. Measured before this migration: 91% of polls went to the
--    two slowest bands, and EVERY event inside 14 days was overdue. Now: the exact
--    split evo_listings_poll_tick uses -- 2/3 of the budget by overdue RATIO
--    (minutes since poll / the band's required_min), 1/3 by absolute age so the
--    tail cannot starve. This is the mechanism that makes the 5-minute band real.
--
-- Budget. Demand at the EVO ladder over the new scope is ~1,369 polls/hour
-- (~46 per 2-minute tick). p_max drops 2000 -> 300, leaving ~6.5x headroom to
-- clear the initial backlog (~13 ticks) and absorb bursts. Upstream request rate
-- falls from ~16.7 req/s to at most 2.5 req/s. The 1,000,000/day cap is unchanged
-- and now sits far above the ~33k/day this will actually spend.
--
-- RULE 2. Read-only upstream: net.http_get against the GoTickets Pro listings
-- endpoint, unchanged from the prior version. No write path is added.

CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(p_max integer DEFAULT 300)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_n int := 0; v_req bigint; v_token text;
  v_daily_cap int := 1000000;
  v_near int := GREATEST(1, (p_max * 2) / 3);  -- ~2/3 budget on overdue-ratio (mirrors evo_listings_poll_tick)
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  IF (SELECT coalesce(sum(listings_polls_today),0) FROM public.gt_listings_poll_state
        WHERE budget_day = current_date) >= v_daily_cap THEN
    RETURN 0;
  END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      -- Scope == the EVO polling set, reached through the GT->TEvo mapping.
      -- Band hours come from the EVO event's clock so both sources agree on band.
      SELECT g.gt_event_id, g.tevo_event_id,
             EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
        FROM public.gotickets_event g
        JOIN public.events e ON e.id = g.tevo_event_id
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.status = 'AS_SCHEDULED'
         AND e.occurs_at_local IS NOT NULL
         AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
         AND coalesce(e.state, 'shown') <> 'ignored'
         AND coalesce(g.name,'')       !~* 'parking'
         AND coalesce(g.venue_name,'')  !~* 'parking'
         AND coalesce(g.performer,'')   !~* 'parking'
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
         AND (ps.cold_until       IS NULL OR ps.cold_until       < now())
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at,
             CASE WHEN ev.last_polled_listings_at IS NULL THEN 1e9
                  ELSE (EXTRACT(epoch FROM (now() - ev.last_polled_listings_at))/60.0)
                       / NULLIF(c.required_min, 0) END AS overdue_ratio
        FROM ev
        JOIN LATERAL public.collector_band('EVO','listings', ev.hte) c ON true
       WHERE ev.last_polled_listings_at IS NULL
          OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    ),
    near AS (
      SELECT gt_event_id, tevo_event_id FROM due ORDER BY overdue_ratio DESC LIMIT v_near
    ),
    tail AS (
      SELECT gt_event_id, tevo_event_id FROM due
       WHERE gt_event_id NOT IN (SELECT gt_event_id FROM near)
       ORDER BY last_polled_listings_at ASC NULLS FIRST
       LIMIT GREATEST(0, p_max - (SELECT count(*) FROM near))
    )
    SELECT gt_event_id, tevo_event_id FROM near
    UNION ALL
    SELECT gt_event_id, tevo_event_id FROM tail
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

REVOKE ALL ON FUNCTION public.gt_listings_poll_tick(integer) FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION public.gt_listings_poll_tick(integer) TO service_role;

COMMENT ON FUNCTION public.gt_listings_poll_tick(integer) IS
  'GoTickets listings poller. Scope, cadence ladder and near/tail ordering all mirror '
  'evo_listings_poll_tick: only GT events mapped to an event in the EVO polling set, '
  'banded by collector_band(''EVO'',''listings'',...) on the EVO event''s own clock, '
  '2/3 of each tick by overdue ratio and 1/3 by absolute age. Mig 20260901141447.';

-- Retune the tick budget to the new scope (2000 was sized for the 64k-event sweep).
DO $cron$
DECLARE v_id bigint;
BEGIN
  SELECT jobid INTO v_id FROM cron.job WHERE jobname = 'gt_listings_poll_2min';
  IF v_id IS NULL THEN RAISE EXCEPTION 'gt_listings_poll_2min not found'; END IF;
  PERFORM cron.alter_job(job_id := v_id, command := $cmd$
 DO $guard$ BEGIN IF NOT public.cron_try_lock('gt_listings_poll_tick') THEN RETURN; END IF; PERFORM public.gt_listings_poll_tick(300); END $guard$;
$cmd$);
END $cron$;

-- Retention: gotickets_listings_snapshots already matched listings_snapshots on
-- ts_column, keep_days, batch_rows and budget_seconds. Align the last field so the
-- two firehoses are full peers in retention_tick's ordering.
UPDATE public.retention_policy
   SET priority = 10, updated_at = now()
 WHERE table_name = 'gotickets_listings_snapshots';

DO $verify$
DECLARE v_gt record; v_evo record; v_cmd text;
BEGIN
  SELECT ts_column, keep_days, enabled, batch_rows, budget_seconds, priority INTO v_gt
    FROM public.retention_policy WHERE table_name = 'gotickets_listings_snapshots';
  SELECT ts_column, keep_days, enabled, batch_rows, budget_seconds, priority INTO v_evo
    FROM public.retention_policy WHERE table_name = 'listings_snapshots';
  IF v_gt IS DISTINCT FROM v_evo THEN
    RAISE EXCEPTION 'retention schema still differs: GT=% EVO=%', v_gt, v_evo;
  END IF;

  SELECT command INTO v_cmd FROM cron.job WHERE jobname = 'gt_listings_poll_2min';
  IF v_cmd NOT LIKE '%gt_listings_poll_tick(300)%' THEN
    RAISE EXCEPTION 'cron command not retuned: %', v_cmd;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                  WHERE n.nspname='public' AND p.proname='gt_listings_poll_tick'
                    AND p.prosrc LIKE '%collector_band(''EVO''%'
                    AND p.prosrc LIKE '%overdue_ratio%') THEN
    RAISE EXCEPTION 'gt_listings_poll_tick did not take the EVO ladder / overdue-ratio form';
  END IF;
END $verify$;
