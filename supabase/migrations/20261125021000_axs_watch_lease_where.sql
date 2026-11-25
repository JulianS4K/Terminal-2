-- Migration 20261125021000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:axs_watch_next()(replaced),axs_watch_pace_apply()(replaced) · reads:none · pre:20261125020000
--
-- AN UPDATE OF THE ONE-ROW CONFIG NAMES ITS ROW.
-- The API role on Supabase runs with safeupdate: an UPDATE without a WHERE clause is refused ("UPDATE requires a
-- WHERE clause", 21000). The lease's UPDATE in axs_watch_next (mig 20261125020000) had none, so every batch of the
-- worker failed from the deploy at 01:28Z until this was applied at 01:32Z (the harness runs on a plain Postgres,
-- where it passed). axs_watch_pace_apply's UPDATE had none either; it runs under pg_cron, where it is allowed, and
-- gets the clause too. `WHERE id` is the table's one-row key (id boolean, always true).
--
-- Applied to prod via MCP 2026-11-25 01:32Z. rollback: none needed (the clause changes nothing but the guard).

CREATE OR REPLACE FUNCTION public.axs_watch_next(p_limit integer DEFAULT NULL, p_worker text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  v_budget jsonb; v_cap integer; v_fired_today integer; v_errors integer; v_newest text; v_due jsonb;
  v_n integer := 0; v_events jsonb := '[]'::jsonb; t record;
BEGIN
  -- the config row is locked for the call: two workers asking at once take turns, and only one gets the lease
  SELECT * INTO v_cfg FROM public.axs_watch_config FOR UPDATE;
  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'paused');
  END IF;
  IF v_cfg.reader <> 'worker' THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'the database reads (axs_watch_config.reader)');
  END IF;
  IF p_worker IS NOT NULL THEN
    IF v_cfg.worker_id IS NOT NULL AND v_cfg.worker_id <> p_worker AND v_cfg.worker_lease_until > now() THEN
      RETURN jsonb_build_object('events', '[]'::jsonb, 'hold_s', 10, 'reason', 'another worker holds the lease',
                                'lease_holder', v_cfg.worker_id, 'lease_until', v_cfg.worker_lease_until);
    END IF;
    UPDATE public.axs_watch_config SET worker_id = p_worker, worker_lease_until = now() + make_interval(secs => v_cfg.worker_lease_s) WHERE id;
  END IF;
  v_budget := public.axs_watch_budget();
  v_cap := (v_budget->>'daily_cap')::integer;
  v_fired_today := (v_budget->>'fired_today')::integer;
  -- upstream trouble: three of the last ten reads failed upstream and so did the newest; try again in a minute
  SELECT count(*) FILTER (WHERE x.outcome IN ('upstream_error', 'timeout', 'lost')), max(x.outcome) FILTER (WHERE x.rn = 1)
    INTO v_errors, v_newest
    FROM (SELECT p.outcome, row_number() OVER (ORDER BY p.checked_at DESC) AS rn
            FROM public.axs_watch_poll p WHERE p.checked_at IS NOT NULL ORDER BY p.checked_at DESC LIMIT 10) x;
  IF v_errors >= v_cfg.upstream_errors_max AND v_newest IN ('upstream_error', 'timeout', 'lost') THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'hold_s', 60, 'upstream_errors', v_errors,
                              'daily_cap', v_cap, 'fired_today', v_fired_today);
  END IF;
  v_due := public.primary_poll_due('axs', coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                                                      WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL), '[]'::jsonb));
  FOR t IN SELECT e.source_event_id, e.ticket_url, e.poll_interval, e.event_date
             FROM public.primary_poll_event e
            WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL
              AND e.source_event_id IN (SELECT jsonb_array_elements_text(v_due))
              AND NOT EXISTS (SELECT 1 FROM public.axs_watch_poll p WHERE p.axs_event_id = e.source_event_id AND p.checked_at IS NULL)
              AND (e.event_date IS NULL OR e.event_date >= current_date - 1)
            ORDER BY e.next_poll_at NULLS FIRST, e.event_date NULLS LAST, e.source_event_id
  LOOP
    EXIT WHEN v_n >= least(coalesce(p_limit, v_cfg.worker_batch), v_cfg.worker_batch);
    IF v_fired_today + v_n >= v_cap THEN
      -- over the day's share: only an event on a hot cadence, and only up to the overrun
      CONTINUE WHEN t.poll_interval IS NULL OR t.poll_interval > v_cfg.hot_every;
      CONTINUE WHEN v_fired_today + v_n >= v_cap + (v_cap * v_cfg.hot_overrun_pct) / 100;
    END IF;
    v_events := v_events || jsonb_build_object('id', t.source_event_id, 'url', t.ticket_url,
                                               'every_min', (extract(epoch FROM t.poll_interval) / 60)::integer);
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('events', v_events, 'spacing_ms', v_cfg.read_spacing_ms, 'upstream_errors', v_errors,
                            'daily_cap', v_cap, 'fired_today', v_fired_today, 'pool_remaining', v_budget->'pool_remaining',
                            'lease_s', CASE WHEN p_worker IS NOT NULL THEN v_cfg.worker_lease_s END);
END $function$;

CREATE OR REPLACE FUNCTION public.axs_watch_pace_apply()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE; v_pace jsonb; v_pick interval; v_demand numeric; v_note text; r record;
BEGIN
  SELECT * INTO v_cfg FROM public.axs_watch_config;
  v_pace := public.axs_watch_pace();
  FOR r IN SELECT (key::text) AS label, value::numeric AS per_hour, make_interval(mins => split_part(key, ' ', 1)::integer) AS every
             FROM jsonb_each_text(v_pace->'demand_per_hour')
            ORDER BY every
  LOOP
    CONTINUE WHEN r.every < v_cfg.pace_min_every OR r.every > v_cfg.pace_max_every;
    v_pick := r.every; v_demand := r.per_hour;     -- the slowest allowed rung is the fallback
    EXIT WHEN r.per_hour <= (v_pace->>'usable_per_hour')::numeric AND r.per_hour * 24 <= (v_pace->>'daily_cap')::numeric;
  END LOOP;
  IF v_pick IS NULL THEN
    RETURN v_pace || jsonb_build_object('applied', false, 'note', 'no rung between pace_min_every and pace_max_every');
  END IF;
  v_note := format('%s reads measured: settle %ss, response %ss, %ss a read, %s usable an hour (%s%% of %s); ladder demand %s an hour at %s%s',
                   v_pace->>'reads_measured', v_pace->>'settle_p50_s', v_pace->>'response_p50_s', v_pace->>'s_per_read',
                   v_pace->>'usable_per_hour', v_pace->>'target_pct', v_pace->>'reads_per_hour', v_demand, v_pick::text,
                   CASE WHEN NOT (v_pace->>'day_of_fits')::boolean THEN '; the day-of rung alone outruns the reader' ELSE '' END);
  UPDATE public.axs_watch_config
     SET far_out_every = v_pick, pace_s_per_read = (v_pace->>'s_per_read')::numeric, pace_set_at = now(), pace_note = v_note,
         updated_at = CASE WHEN far_out_every IS DISTINCT FROM v_pick THEN now() ELSE updated_at END
   WHERE id;
  RETURN v_pace || jsonb_build_object('applied', true, 'picked', v_pick::text, 'picked_demand_per_hour', v_demand,
                                      'changed', v_cfg.far_out_every IS DISTINCT FROM v_pick, 'note', v_note);
END $function$;

