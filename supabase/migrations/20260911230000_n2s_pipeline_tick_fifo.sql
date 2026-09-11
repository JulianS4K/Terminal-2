-- ============================================================================
-- Migration 20260911230000 — N2S sub finder: one ordered pipeline, FIFO by CRM send order
-- Migration 20260911230000 · level:secondary-sales · lane:A1,D7 · writes:cron.job,cron_policy,n2s_items,n2s_cover_queue · reads:n2s_items_pending,ticketsdata_event_xref · pre:20260910100000,20260911090000,20260911210000
--
-- Lane:     A1 (crons + pipeline) / D7 (n2s_* surface)
-- Touches:  n2s_items (W via existing fns), cron.job (W), cron_policy (W),
--           n2s_cover_queue (W via fns), n2s_items_pending (R/W via fns)
-- Pre-reqs: 20260910100000 (n2s core), 20260911090000 (n2s_order_identity_probe),
--           20260911210000 (event_mapper_switchover), vault crm.s4kcs.com/n2s
--
-- The sub finder is priority #1: an N2S order carries a 15-MINUTE timer
-- (measured: avg 15.0 min from alert_at to timer_expires_at), so the whole
-- CRM -> map -> pull sources -> cover -> return-subs chain has to complete
-- inside that window. It was not.
--
-- Two defects, both fixed here:
--
-- 1. NO ORDERING BETWEEN STAGES. The six n2s crons were all scheduled
--    '* * * * *' as independent jobs. pg_cron gives no ordering guarantee
--    between jobs on the same minute mark, so cover_queue_refresh routinely
--    ran BEFORE items_drain landed the order it was meant to cover. Each
--    mis-ordered stage costs a full cycle, and with six stages the chain
--    drifted to a 17-hour p90 (measured: median 5.0 min to first cover, but
--    p90 1030 min; only 31 of 53 orders in the last 48h beat their timer).
--    Now ONE job, n2s_pipeline_tick(), runs the stages in dependency order
--    within a single tick. Six cron slots collapse to one — which also buys
--    back scheduler headroom (see 20260911233000).
--
-- 2. NEW ORDERS PROCESSED NEWEST-FIRST. n2s_pull_all_sources picked
--    never-pulled items 'ORDER BY i.alert_at DESC LIMIT p_new_max'. Under a
--    burst larger than p_new_max that is LIFO: the oldest order — the one
--    with the LEAST time left on its 15-minute timer — is served last and
--    can starve indefinitely. Flipped to ASC so orders are worked in the
--    order the CRM sent them, which is also soonest-timer-first (the timer
--    is a uniform alert_at + 15 min).
--
-- Stage order is the data dependency, and it is deliberate: responses fired
-- by net.http_get in tick N are only readable in tick N+1, so the CRM fetch
-- is fired LAST, after this tick has consumed what the previous one queued.
-- Every stage is individually exception-guarded (one failing stage must not
-- abort the orders behind it) and the tick carries a wall-clock budget so it
-- can never hold a cron slot open indefinitely (CLAUDE.md scheduler-wedge
-- rule / PROJECT_BIBLE §3).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. FIFO: work never-pulled orders oldest-first (CRM send order)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.n2s_pull_all_sources(
  p_max             integer  DEFAULT 10,
  p_refresh_after   interval DEFAULT '00:05:00'::interval,
  p_sweep_after     interval DEFAULT '00:20:00'::interval,
  p_uncovered_only  boolean  DEFAULT true,
  p_new_max         integer  DEFAULT 200)
RETURNS TABLE(orders integer, new_orders integer, evo_fired integer,
              gt_fired integer, sg_queued integer, td_queued integer,
              sg_orders_stored integer, sg_prices_filled integer,
              evo_skipped_fresh integer, gt_skipped_fresh integer,
              evo_skipped_unknown integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_ids bigint[]; v_events bigint[]; p RECORD; v_new int := 0;
  v_sg_stored int := 0; v_sg_fill int := 0;
BEGIN
  BEGIN
    SELECT d.stored, d.prices_filled INTO v_sg_stored, v_sg_fill
      FROM public.n2s_sg_drain() d;
    PERFORM public.n2s_sg_queue(10);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_all_sources: seatgeek order enrich failed: %', SQLERRM;
    v_sg_stored := 0; v_sg_fill := 0;
  END;

  WITH newly AS (
    SELECT i.n2s_id, i.tevo_event_id
      FROM public.n2s_items i
     WHERE i.tevo_event_id IS NOT NULL
       AND NOT i.is_terminal
       AND i.event_dt::date >= current_date
       AND i.sources_pulled_at IS NULL
     -- FIFO: oldest alert first = the order the CRM sent them, and the order
     -- their 15-minute timers expire in. Was DESC (newest-first), which
     -- starved the most urgent orders under any burst > p_new_max.
     ORDER BY i.alert_at ASC
     LIMIT p_new_max
  ),
  sweep AS (
    SELECT i.n2s_id, i.tevo_event_id
      FROM public.n2s_items i
     WHERE i.tevo_event_id IS NOT NULL
       AND NOT i.is_terminal
       AND i.event_dt::date >= current_date
       AND i.sources_pulled_at < now() - p_sweep_after
       AND (NOT p_uncovered_only
            OR NOT EXISTS (SELECT 1 FROM public.n2s_cover_queue q
                            WHERE q.n2s_id = i.n2s_id))
     ORDER BY i.sources_pulled_at ASC
     LIMIT p_max
  )
  SELECT array_agg(x.n2s_id), array_agg(DISTINCT x.tevo_event_id),
         count(*) FILTER (WHERE x.is_new)
    INTO v_ids, v_events, v_new
    FROM (SELECT n2s_id, tevo_event_id, true  AS is_new FROM newly
          UNION ALL
          SELECT n2s_id, tevo_event_id, false            FROM sweep) x;

  IF v_events IS NULL OR cardinality(v_events) = 0 THEN
    RETURN QUERY SELECT 0,0,0,0,0,0,
                        COALESCE(v_sg_stored,0), COALESCE(v_sg_fill,0), 0, 0, 0;
    RETURN;
  END IF;

  SELECT * INTO p FROM public.n2s_pull_events(v_events, p_refresh_after);

  UPDATE public.n2s_items SET sources_pulled_at = now() WHERE n2s_id = ANY(v_ids);

  RETURN QUERY SELECT cardinality(v_ids), COALESCE(v_new,0), p.evo_fired, p.gt_fired,
                      p.sg_queued, p.td_queued,
                      COALESCE(v_sg_stored,0), COALESCE(v_sg_fill,0),
                      p.evo_skipped_fresh, p.gt_skipped_fresh,
                      COALESCE(p.evo_skipped_unknown, 0);
END
$fn$;

COMMENT ON FUNCTION public.n2s_pull_all_sources(integer, interval, interval, boolean, integer)
  IS 'Fires per-event source pulls for live N2S orders. Never-pulled orders are '
     'taken FIFO by alert_at (CRM send order = soonest-timer-first); the sweep '
     'leg re-pulls stalest-first. Called by n2s_pipeline_tick().';

-- ---------------------------------------------------------------------------
-- 2. One ordered tick for the whole sub finder
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.n2s_pipeline_tick(p_budget_seconds integer DEFAULT 45)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_start   timestamptz := clock_timestamp();
  v_out     jsonb := '{}'::jsonb;
  v_errors  jsonb := '[]'::jsonb;
  v_stage   text;
BEGIN
  -- Serialise ticks: a slow tick must never overlap its successor and double
  -- fire CRM/marketplace pulls. xact-scoped, released on commit.
  IF NOT public.cron_try_lock('n2s_pipeline_tick') THEN
    RETURN jsonb_build_object('skipped', 'overlap');
  END IF;

  -- Stage 1 — land the CRM item responses fired at the end of the last tick.
  v_stage := 'items_drain';
  BEGIN
    PERFORM * FROM public.n2s_items_drain();
  EXCEPTION WHEN OTHERS THEN
    v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
  END;

  -- Stage 2 — marketplace order identity (Vivid/GT by id), feeds mapping.
  v_stage := 'order_identity_pull';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      PERFORM * FROM public.n2s_order_identity_pull();
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
  END IF;

  -- Stage 3 — map orders to tevo_event_id. An order with no event has no
  -- cover path at all, so this must precede the source pull every tick.
  v_stage := 'event_mapper_run';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      v_out := v_out || jsonb_build_object('mapper', public.event_mapper_run('n2s_items'));
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
  END IF;

  v_stage := 'gt_map_by_name';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      PERFORM * FROM public.n2s_gt_map_by_name();
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
  END IF;

  -- Stage 4 — fire EVO/GT/SG listing pulls for the mapped events, FIFO.
  v_stage := 'pull_all_sources';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      PERFORM * FROM public.n2s_pull_all_sources();
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
  END IF;

  -- Stage 5 — build the covers from whatever listings have landed.
  v_stage := 'cover_queue_refresh';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      PERFORM * FROM public.n2s_cover_queue_refresh();
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
    BEGIN
      PERFORM * FROM public.n2s_cover_history_append();
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', 'cover_history_append', 'err', SQLERRM);
    END;
    BEGIN
      PERFORM * FROM public.n2s_profitable_cover_sync();
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', 'profitable_cover_sync', 'err', SQLERRM);
    END;
  END IF;

  -- Stage 6 — announce newly covered orders (this is "return the subs").
  v_stage := 'sub_ping';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      PERFORM * FROM public.n2s_sub_ping();
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
  END IF;

  -- Stage 7 — push covers outbound.
  v_stage := 'cover_push';
  IF clock_timestamp() - v_start < make_interval(secs => p_budget_seconds) THEN
    BEGIN
      PERFORM * FROM public.n2s_cover_push_drain();
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
    END;
    BEGIN
      PERFORM * FROM public.n2s_cover_push_queue(25);
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors || jsonb_build_object('stage', 'cover_push_queue', 'err', SQLERRM);
    END;
  END IF;

  -- Stage 8 — fire the NEXT CRM fetch last. net.http_get is async: these
  -- responses are only readable by the next tick's stage 1, so firing them
  -- here (rather than first) is what keeps the chain one tick deep instead
  -- of two.
  v_stage := 'items_queue';
  BEGIN
    PERFORM public.n2s_items_queue(150, 0);
    PERFORM public.n2s_items_queue(150, 150);
    PERFORM public.n2s_items_queue(150, 300);
  EXCEPTION WHEN OTHERS THEN
    v_errors := v_errors || jsonb_build_object('stage', v_stage, 'err', SQLERRM);
  END;

  RETURN v_out
    || jsonb_build_object(
         'elapsed_s', round(extract(epoch FROM clock_timestamp() - v_start)::numeric, 1),
         'budget_s',  p_budget_seconds,
         'errors',    v_errors);
END
$fn$;

COMMENT ON FUNCTION public.n2s_pipeline_tick(integer)
  IS 'THE sub finder. Runs CRM-drain -> identity -> map -> source pull -> cover '
     '-> ping -> push -> next CRM fetch in dependency order in one tick, so a '
     'new N2S order can complete the chain inside its 15-minute timer. '
     'Replaces six independently-scheduled n2s crons that had no ordering '
     'guarantee between them. Wall-clock bounded; overlap-locked.';

REVOKE ALL ON FUNCTION public.n2s_pipeline_tick(integer) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Six racing crons -> one ordered tick
--
-- Every one of these was scheduled '* * * * *' (despite the _2min/_5min names)
-- and they raced each other every minute. n2s_pipeline_tick runs the same work
-- in dependency order, in one slot.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_job text;
BEGIN
  FOREACH v_job IN ARRAY ARRAY[
    'n2s_items_sync_2min',
    'n2s_items_drain_2min',
    'n2s_sub_ping_2min',
    'n2s_map_events_5min',
    'n2s_cover_queue_refresh_2min',
    'n2s_cover_push_1min'
  ] LOOP
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_job) THEN
      PERFORM cron.unschedule(v_job);
    END IF;
  END LOOP;
END
$do$;

-- The sub finder is priority #1 and is deliberately NOT cron_policy-gated:
-- no interval skip, no daily cap, no peak/offpeak window. Its own
-- cron_try_lock handles overlap and its wall-clock budget handles runtime.
SELECT cron.schedule(
  'n2s_pipeline_tick_1min',
  '* * * * *',
  $cron$ SET statement_timeout='55s'; SELECT public.n2s_pipeline_tick(45); $cron$);

-- The mapper parity shadow was riding inside the old n2s_map_events_5min
-- command. It is a dry-run diagnostic for the 20260911210000 switchover, not
-- part of the cover path, so it keeps running but off the hot path.
SELECT cron.schedule(
  'n2s_mapper_shadow_10min',
  '8-59/10 * * * *',
  $cron$ SET statement_timeout='60s'; SELECT public.event_mapper_shadow_tick('n2s_items', 150); $cron$);

INSERT INTO public.cron_policy(
  jobname, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, enabled, notes)
VALUES (
  'n2s_mapper_shadow_10min', 10, 30, NULL, true,
  'Shadow parity dry-run for the event_mapper switchover (20260911210000). '
  'Diagnostic only — split out of n2s_map_events_5min so it cannot delay the '
  'cover path. Retire with the switchover.')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();
