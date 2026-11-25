-- Migration 20261125010000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:axs_watch_config(+pace_target_pct,+pace_min_every,+pace_max_every,+not_on_sale_every,+pace_s_per_read,+pace_set_at,+pace_note),axs_watch_pace()(new),axs_watch_pace_apply()(new),axs_watch_settle_one()(replaced),cron axs_watch_pace_hourly(new) · reads:axs_watch_poll,primary_poll_event,primary_poll_cadence · pre:20261125000000
--
-- THE CADENCE FOLLOWS WHAT THE READER CAN DELIVER.
-- Operator 2026-11-25: "Fix cadence to account for median first to settle and response times". One read costs what
-- it costs: the median time from fire to settle (the worker: 7.6 s, TicketsData's own 6.4 s plus the trip; the
-- database cascade: 60 s, pg_net's queue) and the spacing between reads (3 s, TicketsData's rule). The ladder
-- (10 min the day of, 30 min within two days, an hour further; mig 20261123194030) asks for a number of reads an hour
-- that the reader may or may not be able to make: for 193 events the plain ladder wants ~330 reads an hour, and a
-- reader at 8.6 s a read makes ~420. So the slowest rung is now set from the measurement, every hour:
--   axs_watch_pace()        the measurement: the median settle and response of the last 300 reads, the seconds a
--                           read takes (settle + 1 s of overhead, never less than the spacing), the reads an hour
--                           the reader can make, the share of it the ladder may use (pace_target_pct, 75), and what
--                           the ladder demands at each candidate rung (1 h, 90 min, 2 h, 3 h, 4 h, 6 h).
--   axs_watch_pace_apply()  sets far_out_every to the fastest rung whose demand fits the capacity and the day's
--                           credit cap, within [pace_min_every, pace_max_every]; records the choice on the config.
--                           Runs hourly (cron axs_watch_pace_hourly) and once on apply. far_out_days (14) is unchanged:
--                           an event within two weeks keeps the ladder's own rung.
-- Also, from the failures of day one (16 of 17 "Coming Soon" on AXS: the 14 RodeoHouston concerts, a Kings game, a
-- Greek Theatre show; one "Buy Tickets" show with no tickets): an event TicketsData reports as not on sale is read
-- every not_on_sale_every (6 h) instead of the ladder's rung, until a read finds tickets. Day one spent ~12 reads an
-- event on those answers.
--
-- rollback: UPDATE axs_watch_config SET far_out_every = interval '2 hours'; cron.unschedule('axs_watch_pace_hourly');
--           re-apply axs_watch_settle_one() from 20261125000000; the columns and functions can stay.

ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS pace_target_pct   smallint NOT NULL DEFAULT 75 CHECK (pace_target_pct BETWEEN 10 AND 100);
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS pace_min_every    interval NOT NULL DEFAULT interval '1 hour' CHECK (pace_min_every >= interval '10 minutes');
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS pace_max_every    interval NOT NULL DEFAULT interval '6 hours' CHECK (pace_max_every >= interval '1 hour');
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS not_on_sale_every interval NOT NULL DEFAULT interval '6 hours' CHECK (not_on_sale_every >= interval '30 minutes');
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS pace_s_per_read   numeric;
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS pace_set_at       timestamptz;
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS pace_note         text;

-- The measurement and the ladder's demand at each candidate rung.
CREATE OR REPLACE FUNCTION public.axs_watch_pace()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cfg AS (SELECT * FROM public.axs_watch_config),
  reads AS (SELECT extract(epoch FROM p.checked_at - p.fired_at) AS settle_s, p.response_s
              FROM public.axs_watch_poll p, cfg
             WHERE p.checked_at IS NOT NULL AND p.reader = cfg.reader
             ORDER BY p.checked_at DESC LIMIT 300),
  m AS (SELECT count(*) AS n,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY settle_s) AS settle_p50,
               percentile_cont(0.9) WITHIN GROUP (ORDER BY settle_s) AS settle_p90,
               percentile_cont(0.5) WITHIN GROUP (ORDER BY response_s) AS response_p50
          FROM reads),
  pace AS (SELECT m.n, m.settle_p50, m.settle_p90, m.response_p50,
                  CASE WHEN cfg.reader = 'worker' THEN cfg.read_spacing_ms / 1000.0 ELSE 15.0 END AS spacing_s,
                  -- a read takes its settle plus a second of overhead, never less than the spacing; unmeasured: assume 10 s
                  greatest(coalesce(m.settle_p50, 9.0) + 1.0, CASE WHEN cfg.reader = 'worker' THEN cfg.read_spacing_ms / 1000.0 ELSE 15.0 END) AS s_per_read
             FROM m, cfg),
  cap AS (SELECT pace.*, floor(3600.0 / pace.s_per_read) AS reads_per_hour,
                 floor(3600.0 / pace.s_per_read * cfg.pace_target_pct / 100.0) AS usable_per_hour,
                 (public.axs_watch_budget()->>'daily_cap')::integer AS daily_cap
            FROM pace, cfg),
  ev AS (SELECT e.event_date, public.primary_poll_interval(e.event_date, e.median_price, e.listed_quantity) AS ladder,
                e.event_date > current_date + coalesce(cfg.far_out_days, 0) AS far_out
           FROM public.primary_poll_event e, cfg WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL),
  rungs AS (SELECT r.every, round(sum(3600.0 / extract(epoch FROM CASE WHEN ev.far_out THEN greatest(ev.ladder, r.every) ELSE ev.ladder END))::numeric, 1) AS per_hour
              FROM (VALUES (interval '1 hour'), (interval '90 minutes'), (interval '2 hours'), (interval '3 hours'), (interval '4 hours'), (interval '6 hours')) r(every)
              LEFT JOIN ev ON true
             GROUP BY r.every),
  day_of AS (SELECT count(*) AS n FROM ev WHERE ev.ladder <= interval '10 minutes')
  SELECT jsonb_build_object(
           'reader', cfg.reader, 'reads_measured', cap.n,
           'settle_p50_s', round(cap.settle_p50::numeric, 1), 'settle_p90_s', round(cap.settle_p90::numeric, 1),
           'response_p50_s', round(cap.response_p50::numeric, 1), 'spacing_s', cap.spacing_s,
           's_per_read', round(cap.s_per_read::numeric, 1),
           'reads_per_hour', cap.reads_per_hour, 'usable_per_hour', cap.usable_per_hour, 'target_pct', cfg.pace_target_pct,
           'daily_cap', cap.daily_cap,
           'events', (SELECT count(*) FROM ev), 'day_of_events', day_of.n,
           'day_of_fits', day_of.n * cap.s_per_read <= 600 * cfg.pace_target_pct / 100.0,
           'demand_per_hour', (SELECT jsonb_object_agg((extract(epoch FROM r.every) / 60)::integer || ' min', r.per_hour) FROM rungs r),
           'far_out_every', cfg.far_out_every::text, 'far_out_days', cfg.far_out_days)
    FROM cfg, cap, day_of
$function$;

-- The fastest rung that fits: demand within the usable reads an hour and within the day's credit cap.
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
         updated_at = CASE WHEN far_out_every IS DISTINCT FROM v_pick THEN now() ELSE updated_at END;
  RETURN v_pace || jsonb_build_object('applied', true, 'picked', v_pick::text, 'picked_demand_per_hour', v_demand,
                                      'changed', v_cfg.far_out_every IS DISTINCT FROM v_pick, 'note', v_note);
END $function$;

-- Settle: as before, plus the not-on-sale rung.
CREATE OR REPLACE FUNCTION public.axs_watch_settle_one(p_event_id text, p_status_code integer, p_content jsonb, p_timed_out boolean, p_error_msg text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  t record; body jsonb; parsed jsonb; v_ok boolean; v_outcome text; v_error text; v_tevo bigint;
BEGIN
  SELECT * INTO v_cfg FROM public.axs_watch_config;
  body := p_content->'body';
  parsed := NULL; v_error := NULL;
  IF coalesce(p_timed_out, false) OR p_error_msg IS NOT NULL THEN
    v_ok := false; v_outcome := 'timeout'; v_error := left(coalesce(p_error_msg, 'timed out'), 200);
  ELSIF p_status_code IN (400, 404, 410, 422) THEN
    v_ok := false; v_outcome := 'not_axs'; v_error := 'HTTP ' || p_status_code || ': AXS does not sell this event through TicketsData';
  ELSIF p_status_code IS DISTINCT FROM 200 THEN
    v_ok := false; v_outcome := 'upstream_error'; v_error := 'HTTP ' || coalesce(p_status_code::text, '?') || ' from TicketsData';
  ELSIF body->>'status' = 'expired' THEN
    v_ok := false; v_outcome := 'expired'; v_error := 'expired: the event is over on AXS';
  ELSIF jsonb_typeof(body->'event') = 'object' AND coalesce(body->>'status', '') IN ('ok', 'success') AND coalesce(body->>'exit_code', '0') = '0' THEN
    parsed := public.axs_watch_parse(body);
    v_ok := true; v_outcome := CASE WHEN jsonb_array_length(parsed->'listings') = 0 THEN 'empty' ELSE 'ok' END;
  ELSE
    v_ok := false; v_outcome := 'unparsed';
    v_error := left(coalesce(body->>'error', body->>'message', p_content->>'error', 'TicketsData answered without an event'), 200);
  END IF;

  v_tevo := NULL;
  SELECT * INTO t FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = p_event_id;
  IF FOUND THEN
    v_tevo := t.tevo_event_id;
    PERFORM public.primary_poll_ingest('axs', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
              'id', t.source_event_id, 'name', t.name, 'local_date', t.event_date::text,
              'local_time', to_char(t.start_local_time, 'HH24:MI'), 'start_utc', t.start_utc, 'timezone', t.timezone,
              'venue', t.venue_name, 'city', t.venue_city, 'state', t.venue_state, 'url', t.ticket_url,
              'offer_id', coalesce(parsed->>'offer_id', t.offer_id),
              'order_min', parsed->>'order_min', 'order_max', parsed->>'order_max',
              'total_available', parsed->>'total_available', 'price_min', parsed->>'price_min', 'price_max', parsed->>'price_max',
              'ok', v_ok, 'error', v_error)) || jsonb_build_object('listings', coalesce(parsed->'listings', '[]'::jsonb))));
    -- the optional slower rung for events far out: the feed's age limit follows next_poll_at, so it is moved too
    IF v_cfg.far_out_every IS NOT NULL AND v_cfg.far_out_days IS NOT NULL AND t.event_date > current_date + v_cfg.far_out_days THEN
      UPDATE public.primary_poll_event e
         SET poll_interval = greatest(e.poll_interval, v_cfg.far_out_every),
             next_poll_at = public.primary_poll_next(greatest(e.poll_interval, v_cfg.far_out_every), e.next_poll_at)
       WHERE e.source = 'axs' AND e.source_event_id = p_event_id AND e.poll_interval < v_cfg.far_out_every;
    END IF;
    -- not on sale (yet, or no longer): read again in about not_on_sale_every (three quarters to five quarters of it) until a read finds tickets
    IF v_outcome = 'unparsed' AND v_error ~* 'not (currently |yet )?on sale|not on sale yet|no tickets are currently available|coming soon' THEN
      UPDATE public.primary_poll_event e
         SET poll_interval = v_cfg.not_on_sale_every, next_poll_at = now() + v_cfg.not_on_sale_every * (0.75 + random() * 0.5)
       WHERE e.source = 'axs' AND e.source_event_id = p_event_id;
    END IF;
  END IF;
  IF p_status_code = 200 THEN                 -- a credit is spent on a 200, whatever the body said
    PERFORM public.td_charge_credit(1, v_tevo, 'AXS', '/fetch', p_status_code, nullif(p_content->>'quota_remaining', '')::integer);
  END IF;
  RETURN jsonb_build_object(
           'outcome', v_outcome, 'error', v_error,
           'response_s', nullif(coalesce(body->>'elapsed_seconds', p_content->>'response_s'), '')::numeric,
           'listings', CASE WHEN parsed IS NOT NULL THEN jsonb_array_length(parsed->'listings') END,
           'quota_remaining', nullif(p_content->>'quota_remaining', '')::bigint);
END $function$;

REVOKE ALL ON FUNCTION public.axs_watch_pace() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_pace_apply() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_settle_one(text, integer, jsonb, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_pace() TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_pace_apply() TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_settle_one(text, integer, jsonb, boolean, text) TO service_role;

-- every hour at :07, and once now
SELECT cron.schedule('axs_watch_pace_hourly', '7 * * * *',
  $cmd$BEGIN; SET LOCAL statement_timeout = '60s'; SELECT public.axs_watch_pace_apply(); COMMIT;$cmd$);
SELECT public.axs_watch_pace_apply();
