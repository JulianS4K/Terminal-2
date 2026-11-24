-- Migration 20261125000000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:axs_watch_config(+reader,+read_spacing_ms,+worker_batch),axs_watch_poll(+reader),axs_watch_worker_read_seq(new),axs_watch_settle_one()(new),axs_watch_next()(new),axs_watch_record()(new),axs_watch_tick()(replaced) · reads:primary_poll_event,ticketsdata_credit_usage · pre:20261124230000
--
-- THE AXS WATCH CAN BE READ BY A WORKER INSTEAD OF BY THE DATABASE.
-- Operator 2026-11-24: "build the worker-side reader". The database-side cascade fires its requests through pg_net,
-- whose worker sends the whole outbound queue in batches: a request waits a median 56 to 91 s in the queue behind
-- the other jobs' calls, and two AXS requests in one batch reach TicketsData together, which refuses the second
-- ("Please wait at least 3 seconds between AXS requests", HTTP 429). Holding to one in flight made the watch
-- correct and slow: about one read a minute, a full pass over the 200 events in three to six hours, while the
-- cadence asks for a read every 10 to 60 minutes an event.
--
-- A worker (core/axs_watch_reader.py, on the web service, AXS_WATCH_READER_LIVE=1) reads the events one at a time,
-- `read_spacing_ms` apart (3 s: TicketsData's rule), about 8 a minute: a full pass in 25 minutes. The selection and
-- the settling stay in the database so that both readers behave the same:
--   axs_watch_next(limit)  the events the worker should read now: the same choice as the tick's (due, most overdue
--                          first, within the day's cap, hot-only over it, never one already in flight), plus a hold
--                          of 60 s while the upstream is failing (three of the last ten reads, and the newest).
--                          Empty unless `axs_watch_config.reader = 'worker'`.
--   axs_watch_record(...)  one read's result, as the worker got it: the body (TicketsData's JSON), the HTTP status, or
--                          the transport error. Settled at once (axs_watch_settle_one: the parse, primary_poll_ingest,
--                          the credit) and written to axs_watch_poll with reader = 'worker' and an id from
--                          axs_watch_worker_read_seq (from 10^12: never a pg_net id).
--   axs_watch_tick()       settles what pg_net still has and loses the stale, as before; fires nothing while the
--                          worker reads (`reader = 'worker'`). `reader = 'db'` (the default) is the cascade as it was.
-- The ledger, the budget (fired_today counts both readers' rows), the feed and the fill are unchanged.
--
-- Switch: UPDATE public.axs_watch_config SET reader = 'worker';   -- once the worker is live
--         UPDATE public.axs_watch_config SET reader = 'db';       -- back to the cascade (the worker then idles)
-- rollback: UPDATE axs_watch_config SET reader = 'db'; re-apply axs_watch_tick() from 20261124220000; the new columns,
--           sequence and functions can stay or be dropped.

ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS reader text NOT NULL DEFAULT 'db' CHECK (reader IN ('db', 'worker'));
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS read_spacing_ms integer NOT NULL DEFAULT 3000 CHECK (read_spacing_ms BETWEEN 1000 AND 60000);
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS worker_batch smallint NOT NULL DEFAULT 20 CHECK (worker_batch BETWEEN 1 AND 100);
ALTER TABLE public.axs_watch_poll   ADD COLUMN IF NOT EXISTS reader text NOT NULL DEFAULT 'db' CHECK (reader IN ('db', 'worker'));
CREATE SEQUENCE IF NOT EXISTS public.axs_watch_worker_read_seq START WITH 1000000000000;
COMMENT ON SEQUENCE public.axs_watch_worker_read_seq IS 'axs_watch_poll.request_id for reads made by the worker (never a pg_net id)';

-- One read, settled: the body classified as the tick always did (expired / not AXS / upstream error / timeout /
-- unparsed / ok / empty), the event ingested with its listings or its failure, the credit charged on a 200. Shared by
-- the cascade (a pg_net response) and the worker (the response it got itself).
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

-- The worker's next reads. Empty unless the worker is the reader; held (hold_s) while the upstream is failing.
CREATE OR REPLACE FUNCTION public.axs_watch_next(p_limit integer DEFAULT NULL)
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
  SELECT * INTO v_cfg FROM public.axs_watch_config;
  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'paused');
  END IF;
  IF v_cfg.reader <> 'worker' THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'the database reads (axs_watch_config.reader)');
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
                            'daily_cap', v_cap, 'fired_today', v_fired_today, 'pool_remaining', v_budget->'pool_remaining');
END $function$;

-- One read by the worker: settled at once and written to the ledger.
CREATE OR REPLACE FUNCTION public.axs_watch_record(p_event_id text, p_status_code integer, p_content jsonb, p_timed_out boolean DEFAULT false,
                                                    p_error_msg text DEFAULT NULL, p_fired_at timestamptz DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r jsonb; v_id bigint;
BEGIN
  r := public.axs_watch_settle_one(p_event_id, p_status_code, p_content, p_timed_out, p_error_msg);
  v_id := nextval('public.axs_watch_worker_read_seq');
  INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, error, response_s, listings, quota_remaining, reader)
  VALUES (v_id, p_event_id, coalesce(p_fired_at, now()), now(), p_status_code, r->>'outcome', r->>'error',
          (r->>'response_s')::numeric, (r->>'listings')::integer, (r->>'quota_remaining')::bigint, 'worker');
  RETURN r || jsonb_build_object('request_id', v_id, 'event_id', p_event_id);
END $function$;

-- The cascade: settles and loses as before (through axs_watch_settle_one); fires only while the database is the reader.
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
  w record; t record; r jsonb; v_rid bigint; v_due jsonb;
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
    r := public.axs_watch_settle_one(w.axs_event_id, w.status_code, public.safe_jsonb(w.content), coalesce(w.timed_out, false), w.error_msg);
    UPDATE public.axs_watch_poll p
       SET checked_at = now(), status_code = w.status_code, outcome = r->>'outcome', error = r->>'error',
           response_s = (r->>'response_s')::numeric, listings = (r->>'listings')::integer, quota_remaining = (r->>'quota_remaining')::bigint
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
  IF v_cfg.reader = 'worker' THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'reader', 'worker');
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

REVOKE ALL ON FUNCTION public.axs_watch_settle_one(text, integer, jsonb, boolean, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_next(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_record(text, integer, jsonb, boolean, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_settle_one(text, integer, jsonb, boolean, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_next(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_record(text, integer, jsonb, boolean, text, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_tick() TO service_role;
