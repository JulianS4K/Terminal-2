-- Migration 20261124220000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:axs_watch_config(+fires_per_tick; max_in_flight 3),axs_watch_tick()(replaced),cron job axs_watch_tick_1m(rescheduled: every 15 seconds) · reads:none · pre:20261124210000
--
-- THE CASCADE FIRES ONE REQUEST AT A TIME, FIFTEEN SECONDS APART, NEVER MORE THAN THREE OPEN.
-- The first hour of the watch (2026-11-24 19:46–20:55Z) showed how TicketsData rate-limits: every HTTP 429 came from a
-- minute in which the tick fired four requests at once (4 of 4 or 3 of 4 refused; 13 in all), and none from a minute
-- with one. The tick ran once a minute and filled every free slot at once, so a burst of four was the normal case, the
-- 429s tripped the upstream slowdown (three of the last ten reads failing holds the drainer to one in flight), and the
-- pass crawled at about 1.5 reads a minute — half of what 193 events on an hourly cadence need.
--
-- Now the tick runs every 15 seconds (pg_cron 1.6 takes a seconds schedule) and fires at most `fires_per_tick` requests
-- (1), with `max_in_flight` 3: one request every 15 seconds, four a minute, never a burst, never more than three open.
-- The advisory lock keeps overlapping ticks apart; a tick is 1–3 seconds.
--
-- Applied to prod via MCP 2026-11-24 right after it was written; re-apply is a no-op.
-- rollback: ALTER TABLE public.axs_watch_config DROP COLUMN fires_per_tick; re-apply axs_watch_tick() from 20261124190000;
--           SELECT cron.schedule('axs_watch_tick_1m', '* * * * *', $$BEGIN; SET LOCAL statement_timeout = '50s'; SELECT public.axs_watch_tick(); COMMIT;$$);

ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS fires_per_tick smallint NOT NULL DEFAULT 1 CHECK (fires_per_tick BETWEEN 1 AND 20);
UPDATE public.axs_watch_config SET max_in_flight = least(max_in_flight, 3), updated_at = now();

CREATE OR REPLACE FUNCTION public.axs_watch_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  v_budget jsonb; v_cap integer; v_fired_today integer; v_in_flight integer; v_slots integer; v_errors integer;
  v_fired integer := 0; v_settled integer := 0; v_lost integer := 0;
  w record; t record; c jsonb; body jsonb; parsed jsonb; v_ok boolean; v_outcome text; v_error text; v_rid bigint; v_tevo bigint;
  v_due jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('axs_watch_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another axs_watch_tick is running');
  END IF;
  SELECT * INTO v_cfg FROM public.axs_watch_config;

  -- 1. settle: every pending request whose response has landed
  FOR w IN SELECT p.request_id, p.axs_event_id, r.status_code, r.content, r.timed_out, r.error_msg
             FROM public.axs_watch_poll p JOIN net._http_response r ON r.id = p.request_id
            WHERE p.checked_at IS NULL
            ORDER BY p.fired_at
  LOOP
    c := public.safe_jsonb(w.content);
    body := c->'body';
    parsed := NULL; v_error := NULL;
    IF coalesce(w.timed_out, false) OR w.error_msg IS NOT NULL THEN
      v_ok := false; v_outcome := 'timeout'; v_error := left(coalesce(w.error_msg, 'timed out'), 200);
    ELSIF w.status_code IN (400, 404, 410, 422) THEN
      v_ok := false; v_outcome := 'not_axs'; v_error := 'HTTP ' || w.status_code || ': AXS does not sell this event through TicketsData';
    ELSIF w.status_code IS DISTINCT FROM 200 THEN
      v_ok := false; v_outcome := 'upstream_error'; v_error := 'HTTP ' || coalesce(w.status_code::text, '?') || ' from TicketsData';
    ELSIF body->>'status' = 'expired' THEN
      v_ok := false; v_outcome := 'expired'; v_error := 'expired: the event is over on AXS';
    ELSIF jsonb_typeof(body->'event') = 'object' AND coalesce(body->>'status', '') IN ('ok', 'success') AND coalesce(body->>'exit_code', '0') = '0' THEN
      parsed := public.axs_watch_parse(body);
      v_ok := true; v_outcome := CASE WHEN jsonb_array_length(parsed->'listings') = 0 THEN 'empty' ELSE 'ok' END;
    ELSE
      v_ok := false; v_outcome := 'unparsed';
      v_error := left(coalesce(body->>'error', body->>'message', c->>'error', 'TicketsData answered without an event'), 200);
    END IF;

    v_tevo := NULL;
    SELECT * INTO t FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = w.axs_event_id;
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
         WHERE e.source = 'axs' AND e.source_event_id = w.axs_event_id AND e.poll_interval < v_cfg.far_out_every;
      END IF;
    END IF;
    IF w.status_code = 200 THEN                 -- a credit is spent on a 200, whatever the body said
      PERFORM public.td_charge_credit(1, v_tevo, 'AXS', '/fetch', w.status_code, nullif(c->>'quota_remaining', '')::integer);
    END IF;
    UPDATE public.axs_watch_poll p
       SET checked_at = now(), status_code = w.status_code, outcome = v_outcome, error = v_error,
           response_s = nullif(coalesce(body->>'elapsed_seconds', c->>'response_s'), '')::numeric,
           listings = CASE WHEN parsed IS NOT NULL THEN jsonb_array_length(parsed->'listings') END,
           quota_remaining = nullif(c->>'quota_remaining', '')::bigint
     WHERE p.request_id = w.request_id;
    v_settled := v_settled + 1;
  END LOOP;

  -- a request with no response by stale_after never will have one (pg_net gave up): a failed poll, retried on the cadence
  FOR w IN SELECT p.request_id, p.axs_event_id FROM public.axs_watch_poll p
            WHERE p.checked_at IS NULL AND p.fired_at < now() - v_cfg.stale_after
              AND NOT EXISTS (SELECT 1 FROM net._http_response r WHERE r.id = p.request_id)
  LOOP
    SELECT * INTO t FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = w.axs_event_id;
    IF FOUND THEN
      PERFORM public.primary_poll_ingest('axs', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'id', t.source_event_id, 'name', t.name, 'local_date', t.event_date::text,
                'local_time', to_char(t.start_local_time, 'HH24:MI'), 'start_utc', t.start_utc, 'timezone', t.timezone,
                'venue', t.venue_name, 'city', t.venue_city, 'state', t.venue_state, 'url', t.ticket_url, 'offer_id', t.offer_id,
                'ok', false, 'error', 'lost: no response from TicketsData')) || '{"listings": []}'::jsonb));
    END IF;
    UPDATE public.axs_watch_poll p SET checked_at = now(), outcome = 'lost', error = 'no response within stale_after' WHERE p.request_id = w.request_id;
    v_lost := v_lost + 1;
  END LOOP;

  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'paused', true);
  END IF;

  -- 2. the slots: in flight, the upstream's health, the budget; and never more than fires_per_tick in one tick
  v_budget := public.axs_watch_budget();
  v_cap := (v_budget->>'daily_cap')::integer;
  v_fired_today := (v_budget->>'fired_today')::integer;
  v_in_flight := (v_budget->>'in_flight')::integer;
  SELECT count(*) FILTER (WHERE x.outcome IN ('upstream_error', 'timeout', 'lost')) INTO v_errors
    FROM (SELECT p.outcome FROM public.axs_watch_poll p WHERE p.checked_at IS NOT NULL ORDER BY p.checked_at DESC LIMIT 10) x;
  v_slots := least(v_cfg.max_in_flight - v_in_flight, v_cfg.fires_per_tick);
  IF v_errors >= v_cfg.upstream_errors_max THEN v_slots := least(v_slots, 1 - v_in_flight); END IF;
  IF v_slots <= 0 THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'in_flight', v_in_flight,
                              'upstream_errors', v_errors, 'daily_cap', v_cap, 'fired_today', v_fired_today);
  END IF;

  -- 3. fire the due events, most overdue first; over the cap only the hot ones, up to the overrun
  v_due := public.primary_poll_due('axs', coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                                                      WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL), '[]'::jsonb));
  FOR t IN SELECT e.source_event_id, e.ticket_url, e.tevo_event_id, e.poll_interval, e.event_date
             FROM public.primary_poll_event e
            WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL
              AND e.source_event_id IN (SELECT jsonb_array_elements_text(v_due))
              AND NOT EXISTS (SELECT 1 FROM public.axs_watch_poll p WHERE p.axs_event_id = e.source_event_id AND p.checked_at IS NULL)
              AND (e.event_date IS NULL OR e.event_date >= current_date - 1)
            ORDER BY e.next_poll_at NULLS FIRST, e.event_date NULLS LAST, e.source_event_id
            LIMIT v_slots
  LOOP
    IF v_fired_today + v_fired >= v_cap THEN
      -- over the day's share: only an event on a hot cadence, and only up to the overrun
      CONTINUE WHEN t.poll_interval IS NULL OR t.poll_interval > v_cfg.hot_every;
      CONTINUE WHEN v_fired_today + v_fired >= v_cap + (v_cap * v_cfg.hot_overrun_pct) / 100;
    END IF;
    SELECT net.http_get(
      url := 'https://ticketsdata.com/fetch',
      params := jsonb_build_object(
        'username',  public.get_app_secret(p_name => 'TICKETSDATA_USERNAME'),
        'password',  public.get_app_secret(p_name => 'TICKETSDATA_PASSWORD'),
        'event_url', t.ticket_url, 'platform', 'axs'),
      timeout_milliseconds := v_cfg.fire_timeout_ms) INTO v_rid;
    INSERT INTO public.axs_watch_poll (request_id, axs_event_id) VALUES (v_rid, t.source_event_id);
    v_fired := v_fired + 1;
  END LOOP;

  RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', v_fired, 'in_flight', v_in_flight + v_fired,
                            'upstream_errors', v_errors, 'daily_cap', v_cap, 'fired_today', v_fired_today + v_fired,
                            'pool_remaining', v_budget->'pool_remaining');
END $function$;

REVOKE ALL ON FUNCTION public.axs_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_tick() TO service_role;

-- the cascade every 15 seconds (pg_cron 1.6 seconds schedule); the job keeps its name
SELECT cron.schedule('axs_watch_tick_1m', '15 seconds',
  $cmd$BEGIN; SET LOCAL statement_timeout = '12s'; SELECT public.axs_watch_tick(); COMMIT;$cmd$);
