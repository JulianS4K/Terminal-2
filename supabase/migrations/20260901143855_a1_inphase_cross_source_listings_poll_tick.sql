-- Migration 20260901143855 · level:admin · lane:A1 · operator-directed 2026-09-01
--   ("have the poll timers be parallel for each source" -> in-phase: both sources
--    sample the same event on the same tick).
--
--   writes: listings_poll_tick(int) [fn NEW], cron.job (evo_listings_poll_2min command,
--           gt_listings_poll_2min deactivated)
--   reads:  events, gotickets_event, evo_listings_poll_state, gt_listings_poll_state,
--           collector_cadence
--
-- WHY. After mig 20260901141447 the two pollers shared a scope and a cadence ladder
-- but still kept SEPARATE clocks: evo_listings_poll_state.last_polled_listings_at and
-- gt_listings_poll_state.last_polled_listings_at advanced independently. Identical
-- intervals do not imply identical phase -- EVO could sample an event at :03 and GT
-- the same event at :09. Any cross-source spread computed from those two snapshots
-- then carries up to a full band-interval of timing noise, which for the far bands is
-- up to 12 or 24 hours. That noise is indistinguishable from a real price gap, which
-- is precisely the signal this pipeline exists to measure.
--
-- WHAT. One tick, one due-computation, both requests fired inside the same loop
-- iteration. The EVO event is the unit of work and evo_listings_poll_state is the
-- single clock; GoTickets no longer has a timer of its own to drift.
--
--   * Due set + ordering: unchanged from evo_listings_poll_tick -- EVO ladder,
--     2/3 of the budget by overdue ratio, 1/3 by absolute age.
--   * For each selected event: fire the EVO collect-listings edge function AND, in
--     the same iteration, a GoTickets listings GET for every mapped gotickets_event
--     that passes GT's own health guards (AS_SCHEDULED, non-parking, not quarantined
--     or cold). Both are async pg_net calls, so they leave together.
--   * gt_listings_poll_state is still written -- it remains the record of what GT
--     fetched and feeds gt_deals_scan's median refresh -- but it is now an OUTPUT of
--     the shared clock, never an input to a due decision.
--
-- Sizing. p_max stays 120 EVO events per 2-minute tick. ~42% of in-scope EVO events
-- have a GT twin, so GT rides along at ~50 requests/tick (~1,500/hr) against measured
-- GT demand of ~1,369/hr. Total pg_net calls per tick fall from 120 (EVO) + 300 (GT)
-- to ~170.
--
-- gt_listings_poll_2min is deactivated rather than unscheduled, and
-- gt_listings_poll_tick is left in place, so the standalone GT poller stays available
-- for manual catch-up. Do NOT re-enable that cron alongside this one -- the two would
-- double-poll and the shared phase would be lost.
--
-- NOTE, not fixed here: EVO's ladder demands ~5,401 polls/hr and 120/tick supplies
-- 3,600/hr, so EVO runs at ~67% of its own ladder. It is coping (near bands showed
-- full hourly coverage at apply time) and this is pre-existing, not introduced here.
-- Raising p_max is the lever if the near bands start slipping; it now lifts both
-- sources together.
--
-- RULE 2. Read-only upstream: the EVO side invokes our own collect-listings edge
-- function; the GT side is the same net.http_get against the GoTickets Pro listings
-- endpoint as before. No write path to any broker is added.

CREATE OR REPLACE FUNCTION public.listings_poll_tick(p_max integer DEFAULT 120)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; g RECORD;
  v_n int := 0; v_gt int := 0; v_req bigint; v_token text;
  v_near int := GREATEST(1, (p_max * 2) / 3);
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  v_token := public._gotickets_pro_token();

  FOR r IN
    WITH ev AS (
      SELECT e.id,
             EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
        FROM public.events e
        LEFT JOIN public.evo_listings_poll_state ps ON ps.event_id = e.id
       WHERE e.occurs_at_local IS NOT NULL
         AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
         AND coalesce(e.state, 'shown') <> 'ignored'
    ),
    due AS (
      SELECT ev.id, ev.last_polled_listings_at,
             CASE WHEN ev.last_polled_listings_at IS NULL THEN 1e9
                  ELSE (EXTRACT(epoch FROM (now() - ev.last_polled_listings_at))/60.0)
                       / NULLIF(c.required_min, 0) END AS overdue_ratio
        FROM ev
        JOIN LATERAL public.collector_band('EVO','listings', ev.hte) c ON true
       WHERE ev.last_polled_listings_at IS NULL
          OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    ),
    near AS (
      SELECT id FROM due ORDER BY overdue_ratio DESC LIMIT v_near
    ),
    tail AS (
      SELECT id FROM due
       WHERE id NOT IN (SELECT id FROM near)
       ORDER BY last_polled_listings_at ASC NULLS FIRST
       LIMIT GREATEST(0, p_max - (SELECT count(*) FROM near))
    )
    SELECT id FROM near
    UNION ALL
    SELECT id FROM tail
  LOOP
    -- ---- EVO leg -------------------------------------------------------
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id=' || r.id::text,
      '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state(event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.id, now(), 1, current_date)
      ON CONFLICT (event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;

    -- ---- GoTickets leg, same iteration so both samples are contemporaneous ----
    FOR g IN
      SELECT gt.gt_event_id
        FROM public.gotickets_event gt
        LEFT JOIN public.gt_listings_poll_state gps ON gps.gt_event_id = gt.gt_event_id
       WHERE gt.tevo_event_id = r.id
         AND gt.status = 'AS_SCHEDULED'
         AND coalesce(gt.name,'')       !~* 'parking'
         AND coalesce(gt.venue_name,'')  !~* 'parking'
         AND coalesce(gt.performer,'')   !~* 'parking'
         AND (gps.quarantined_until IS NULL OR gps.quarantined_until < now())
         AND (gps.cold_until       IS NULL OR gps.cold_until       < now())
    LOOP
      SELECT net.http_get(
        url := 'https://gotickets.com/rest/pro/api/events/' || g.gt_event_id::text || '/listings',
        headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept','application/json'),
        timeout_milliseconds := 30000
      ) INTO v_req;
      INSERT INTO public.gt_listings_inflight(request_id, gt_event_id, tevo_event_id, fired_at)
        VALUES (v_req, g.gt_event_id, r.id, now());
      INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
        VALUES (g.gt_event_id, now(), 1, current_date)
        ON CONFLICT (gt_event_id) DO UPDATE SET
          last_polled_listings_at = now(),
          listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                      THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
          budget_day = current_date;
      v_gt := v_gt + 1;
    END LOOP;

    v_n := v_n + 1;
  END LOOP;

  RAISE NOTICE 'listings_poll_tick: % events sampled, % GoTickets legs', v_n, v_gt;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.listings_poll_tick(integer) FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION public.listings_poll_tick(integer) TO service_role;

COMMENT ON FUNCTION public.listings_poll_tick(integer) IS
  'Unified in-phase listings poller. One due-computation per EVO event (EVO ladder, '
  '2/3 overdue-ratio + 1/3 absolute age); fires the EVO collect-listings call and every '
  'mapped GoTickets listings GET in the SAME loop iteration so both sources sample the '
  'event contemporaneously. evo_listings_poll_state is the single clock; '
  'gt_listings_poll_state is an output, never a due input. Mig 20260901143855. '
  'Do not run alongside gt_listings_poll_2min -- that would double-poll and break phase.';

DO $cron$
DECLARE v_evo bigint; v_gt bigint;
BEGIN
  SELECT jobid INTO v_evo FROM cron.job WHERE jobname = 'evo_listings_poll_2min';
  SELECT jobid INTO v_gt  FROM cron.job WHERE jobname = 'gt_listings_poll_2min';
  IF v_evo IS NULL OR v_gt IS NULL THEN
    RAISE EXCEPTION 'expected both evo_listings_poll_2min and gt_listings_poll_2min to exist';
  END IF;

  PERFORM cron.alter_job(job_id := v_evo, command := $cmd$
 DO $b$ BEGIN IF NOT public.cron_should_fire('evo_listings_poll_2min') THEN RETURN; END IF; IF NOT public.cron_try_lock('listings_poll_tick') THEN RETURN; END IF; PERFORM public.listings_poll_tick(120); END $b$;
$cmd$);

  -- The GT half now happens inside the shared tick. Deactivate rather than
  -- unschedule so the standalone poller stays one alter_job away.
  PERFORM cron.alter_job(job_id := v_gt, active := false);
END $cron$;

DO $verify$
DECLARE v_cmd text; v_gt_active boolean;
BEGIN
  SELECT command INTO v_cmd FROM cron.job WHERE jobname = 'evo_listings_poll_2min';
  IF v_cmd NOT LIKE '%listings_poll_tick(120)%' THEN
    RAISE EXCEPTION 'evo cron not repointed at the shared tick: %', v_cmd;
  END IF;
  SELECT active INTO v_gt_active FROM cron.job WHERE jobname = 'gt_listings_poll_2min';
  IF v_gt_active THEN
    RAISE EXCEPTION 'gt_listings_poll_2min still active -- it would double-poll and break phase';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                  WHERE n.nspname='public' AND p.proname='listings_poll_tick') THEN
    RAISE EXCEPTION 'listings_poll_tick missing';
  END IF;
END $verify$;
