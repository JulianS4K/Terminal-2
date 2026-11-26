-- Migration 20261126060000 · level:data-collection · lane:A1 (data plane: the AXS watch, routed to this session by the operator) · writes:axs_watch_config(reader +'extension',+ext_lanes,+ext_spacing_ms),axs_watch_poll(reader +'extension'),axs_watch_budget()(replaced),axs_watch_next()(replaced),axs_queue_claim()(replaced),axs_watch_pace()(replaced),axs_watch_record_ext()(new) · reads:primary_poll_event,ticketsdata_credit_usage · pre:20261126053000 (the pacer that now reads pace() for cadence_scale),20261126030000 (the queue claim this re-creates),20261126004500 (the next() this re-creates),20261125205000 (the budget() this re-creates),20261125214500 (settle_one() with p_charge / p_via, used as is)
--
-- THE AXS WATCH CAN BE READ BY OUR OWN BROWSER EXTENSION, WITHOUT TICKETSDATA.
-- Operator 2026-11-25: "Look at the axs poller, I want to build our own" ... "So we can poll more events and more
-- frequently", then "Build the extension for Firefox, incorporate containers". AXS's Cloudflare refuses a datacenter
-- address outright (the cloud container got AXS's "Access Info" 403 for both a plain GET and a headless Chromium), so
-- the reader is a Firefox extension (axs_extension/) on a machine with an ordinary connection. It opens each due
-- event's public AXS page in a tab of its own Firefox container, keeps the inventory answers the page itself receives,
-- and sends them to the web service (routers/axs_ext.py), which builds the same document TicketsData returns
-- (core/axs_ext_doc.py) and records it here. Nothing it reads is metered, so:
--
--   reader = 'extension'      a third reader beside 'db' (the pg_net cascade) and 'worker' (TicketsData from the web
--                             service). axs_watch_next hands events only to a caller whose worker id starts 'ext:'
--                             while the extension reads, and never to one while another reader does: the TicketsData
--                             worker idles, and the extension idles when it is switched back. Everything else in
--                             next() is 20261126004500's, the upstream hold bounded by upstream_errors_window included.
--   axs_queue_claim()         20261126030000's (the paced queue, which feeds the TicketsData worker), with one gate
--                             added: while the extension reads it hands out nothing, so switching the reader stops
--                             TicketsData whichever path its worker takes (axs_watch_next or the queue).
--   axs_watch_budget()        20261125205000's (the Eastern day, as td_credits_today()), with the extension's reads left
--                             out of fired_today; while the extension reads the cap is not the limit (daily_cap
--                             1,000,000 and 'unmetered' true). The pool figures are unchanged.
--   axs_watch_record_ext()    one read by the extension: settled by axs_watch_settle_one with p_charge false (no credit)
--                             and p_via 'the AXS page', written to axs_watch_poll with reader 'extension'; a repeat of
--                             the same (event, fired_at) returns the first record.
--   ext_lanes / ext_spacing_ms how the extension reads: 4 events at once (one container each), 4 s between opens at the
--                             least. A browser read of AXS takes ~45 s (TicketsData's own AXS reads: 12-15 s to the seat
--                             page through Queue-it, ~28 s more for the inventory), so 4 lanes make ~300 reads an hour.
--
--   axs_watch_pace()          20261125010000's, counting the extension's capacity: ext_lanes reads at once, ext_spacing_ms
--                             apart at the least, so a read costs (settle + 1 s) / ext_lanes; 45 s assumed until measured.
--                             Since 20261126053000 the hourly pacer sets cadence_scale from this function's usable_per_hour,
--                             so without the lanes it would count the extension at a quarter of its throughput and slow the
--                             watch for nothing.
--
-- Cadence: the bands of 20261125214500 / 20261126011500 (axs_watch_cadence) times cadence_scale, which the hourly pacer
-- (20261126053000) sets between cadence_scale_floor (1.0) and cadence_scale_max. To let the extension read more often than
-- the bands, lower the floor; the pacer then lowers the scale itself as far as the measured capacity allows.
--
-- Switch: UPDATE public.axs_watch_config SET reader = 'extension', cadence_scale_floor = 0.5 WHERE id;
-- Back:   UPDATE public.axs_watch_config SET reader = 'worker', cadence_scale_floor = 1.0 WHERE id;
-- rollback: the switch back, then re-apply axs_watch_budget() from 20261125205000 and axs_watch_next() from
--           20261126004500, axs_queue_claim() from 20261126030000 and axs_watch_pace() from 20261125010000; DROP FUNCTION axs_watch_record_ext(text, integer, jsonb, boolean, text, timestamptz);
--           the columns and checks can stay.

ALTER TABLE public.axs_watch_config DROP CONSTRAINT IF EXISTS axs_watch_config_reader_check;
ALTER TABLE public.axs_watch_config ADD CONSTRAINT axs_watch_config_reader_check CHECK (reader IN ('db', 'worker', 'extension'));
ALTER TABLE public.axs_watch_poll DROP CONSTRAINT IF EXISTS axs_watch_poll_reader_check;
ALTER TABLE public.axs_watch_poll ADD CONSTRAINT axs_watch_poll_reader_check CHECK (reader IN ('db', 'worker', 'extension'));
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS ext_lanes smallint NOT NULL DEFAULT 4 CHECK (ext_lanes BETWEEN 1 AND 8);
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS ext_spacing_ms integer NOT NULL DEFAULT 4000 CHECK (ext_spacing_ms BETWEEN 1000 AND 60000);
COMMENT ON COLUMN public.axs_watch_config.ext_lanes IS 'AXS extension: events read at once, one Firefox container each (mig 20261126060000)';
COMMENT ON COLUMN public.axs_watch_config.ext_spacing_ms IS 'AXS extension: least time between two page opens, across all lanes (mig 20261126060000)';

-- The budget (as 20261125205000): the extension's reads are not TicketsData's and spend nothing.
CREATE OR REPLACE FUNCTION public.axs_watch_budget()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH cfg AS (SELECT * FROM public.axs_watch_config),
  reading AS (SELECT u.quota_remaining, u.called_at
                FROM public.ticketsdata_credit_usage u
               WHERE u.quota_remaining IS NOT NULL AND u.called_at > now() - interval '6 hours'
               ORDER BY u.called_at DESC LIMIT 1),
  reset AS (SELECT CASE WHEN extract(day FROM current_date) < cfg.cycle_reset_day
                        THEN make_date(extract(year FROM current_date)::int, extract(month FROM current_date)::int, cfg.cycle_reset_day)
                        ELSE (make_date(extract(year FROM current_date)::int, extract(month FROM current_date)::int, cfg.cycle_reset_day) + interval '1 month')::date END AS next_reset
              FROM cfg),
  pool AS (SELECT coalesce((SELECT r.quota_remaining FROM reading r),
                           cfg.monthly_credits - (SELECT coalesce(sum(u.credits), 0) FROM public.ticketsdata_credit_usage u
                                                   WHERE u.called_at >= (reset.next_reset - interval '1 month'))) AS remaining,
                  (SELECT r.called_at FROM reading r) AS read_at
             FROM cfg, reset),
  -- the Eastern day, to match td_credits_today() (mig 20261125205000)
  today AS (SELECT count(*) AS fired FROM public.axs_watch_poll w
             WHERE w.fired_at >= date_trunc('day', now() AT TIME ZONE 'America/New_York') AT TIME ZONE 'America/New_York'
               AND w.reader <> 'extension')                -- the extension's reads spend no TicketsData credit (mig 20261126060000)
  SELECT jsonb_build_object(
           'pool_remaining', pool.remaining, 'pool_read_at', pool.read_at,
           'next_reset', reset.next_reset, 'days_left', greatest(reset.next_reset - current_date, 1),
           'daily_cap', CASE WHEN cfg.reader = 'extension' THEN 1000000
                             ELSE coalesce(cfg.daily_cap_override,
                                           greatest(floor((pool.remaining - cfg.reserve_credits)::numeric / greatest(reset.next_reset - current_date, 1))::integer, 0)) END,
           'unmetered', cfg.reader = 'extension',
           'fired_today', today.fired,
           'in_flight', (SELECT count(*) FROM public.axs_watch_poll w WHERE w.checked_at IS NULL AND w.fired_at > now() - cfg.stale_after),
           'enabled', cfg.enabled)
    FROM cfg, reset, pool, today
$function$;

-- The next reads (as 20261126004500), for the reader that is switched on; while the extension reads, its spacing and lanes.
CREATE OR REPLACE FUNCTION public.axs_watch_next(p_limit integer DEFAULT NULL, p_worker text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  v_budget jsonb; v_cap integer; v_fired_today integer; v_errors integer; v_newest text; v_due jsonb;
  v_n integer := 0; v_events jsonb := '[]'::jsonb; t record; v_ext boolean := coalesce(p_worker LIKE 'ext:%', false);
BEGIN
  -- the config row is locked for the call: two workers asking at once take turns, and only one gets the lease
  SELECT * INTO v_cfg FROM public.axs_watch_config FOR UPDATE;
  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'paused');
  END IF;
  IF v_cfg.reader = 'db' THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'the database reads (axs_watch_config.reader)');
  END IF;
  -- each reader is handed events only while it is the one switched on (mig 20261126060000)
  IF v_cfg.reader = 'extension' AND NOT v_ext THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'the extension reads (axs_watch_config.reader)');
  END IF;
  IF v_cfg.reader = 'worker' AND v_ext THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'the TicketsData worker reads (axs_watch_config.reader)');
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
  -- upstream trouble: three of the last ten reads IN THE LAST upstream_errors_window failed upstream and so did
  -- the newest of them; try again in a minute. The window is what makes the hold temporary (mig 20261126004500):
  -- while it holds, no read lands, so the window empties and the next call hands work out again.
  SELECT count(*) FILTER (WHERE x.outcome IN ('upstream_error', 'timeout', 'lost')), max(x.outcome) FILTER (WHERE x.rn = 1)
    INTO v_errors, v_newest
    FROM (SELECT p.outcome, row_number() OVER (ORDER BY p.checked_at DESC) AS rn
            FROM public.axs_watch_poll p
           WHERE p.checked_at IS NOT NULL AND p.checked_at > now() - v_cfg.upstream_errors_window
           ORDER BY p.checked_at DESC LIMIT 10) x;
  IF v_errors >= v_cfg.upstream_errors_max AND v_newest IN ('upstream_error', 'timeout', 'lost') THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'hold_s', 60, 'upstream_errors', v_errors,
                              'errors_window', v_cfg.upstream_errors_window,
                              'daily_cap', v_cap, 'fired_today', v_fired_today);
  END IF;
  v_due := public.primary_poll_due('axs', coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                                                      WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL), '[]'::jsonb));
  FOR t IN SELECT e.source_event_id, e.ticket_url, e.poll_interval, e.event_date
             FROM public.primary_poll_event e
            WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL
              AND e.source_event_id IN (SELECT jsonb_array_elements_text(v_due))
              AND NOT EXISTS (SELECT 1 FROM public.axs_watch_poll p WHERE p.axs_event_id = e.source_event_id AND p.checked_at IS NULL)
              -- not inside stop_before_start: the reads stop six hours before the start, not at tip-off (mig 20261125150000)
              AND (coalesce(e.start_utc, (e.event_date + 1)::timestamptz) IS NULL
                   OR coalesce(e.start_utc, (e.event_date + 1)::timestamptz) > now() + v_cfg.stop_before_start)
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
  RETURN jsonb_build_object('events', v_events,
                            'spacing_ms', CASE WHEN v_cfg.reader = 'extension' THEN v_cfg.ext_spacing_ms ELSE v_cfg.read_spacing_ms END,
                            'lanes', CASE WHEN v_cfg.reader = 'extension' THEN v_cfg.ext_lanes END,
                            'upstream_errors', v_errors,
                            'daily_cap', v_cap, 'fired_today', v_fired_today, 'pool_remaining', v_budget->'pool_remaining',
                            'lease_s', CASE WHEN p_worker IS NOT NULL THEN v_cfg.worker_lease_s END);
END $function$;

-- The queue's claim (as 20261126030000), gated on the reader.
CREATE OR REPLACE FUNCTION public.axs_queue_claim(p_worker text, p_limit integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  v_budget jsonb; v_cap integer; v_fired integer; v_errors integer; v_newest text;
  v_spacing interval; v_base timestamptz; v_room integer; v_in_flight integer;
  v_items jsonb := '[]'::jsonb; q record; v_n integer := 0;
BEGIN
  IF coalesce(p_worker, '') = '' THEN
    RAISE EXCEPTION 'axs_queue_claim: a worker id is required';
  END IF;
  -- the config row is the pacer's lock: every release in the system is allocated here, in turn
  SELECT * INTO v_cfg FROM public.axs_watch_config FOR UPDATE;
  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('items', '[]'::jsonb, 'reason', 'paused');
  END IF;
  IF NOT v_cfg.queue_enabled THEN
    RETURN jsonb_build_object('items', '[]'::jsonb, 'reason', 'the queue is off (axs_watch_config.queue_enabled)');
  END IF;
  -- the queue feeds the TicketsData worker; while the extension reads it hands out nothing (mig 20261126060000)
  IF v_cfg.reader = 'extension' THEN
    RETURN jsonb_build_object('items', '[]'::jsonb, 'reason', 'the extension reads (axs_watch_config.reader)');
  END IF;

  PERFORM public.axs_queue_reap();

  -- Self-feeding: when nothing is pending, top the queue up here rather than needing a cron.
  -- Gated on emptiness so the fill runs at most once per drained queue, not on every claim —
  -- which also means the ON CONFLICT DO NOTHING in the fill is doing almost no work in the
  -- steady state.
  IF NOT EXISTS (SELECT 1 FROM public.axs_read_queue WHERE resolved_at IS NULL AND claimed_at IS NULL) THEN
    PERFORM public.axs_queue_fill();
  END IF;

  -- upstream trouble, same rule and same window as axs_watch_next (mig 20261126004500)
  SELECT count(*) FILTER (WHERE x.outcome IN ('upstream_error', 'timeout', 'lost')),
         max(x.outcome) FILTER (WHERE x.rn = 1)
    INTO v_errors, v_newest
    FROM (SELECT p.outcome, row_number() OVER (ORDER BY p.checked_at DESC) AS rn
            FROM public.axs_watch_poll p
           WHERE p.checked_at IS NOT NULL AND p.checked_at > now() - v_cfg.upstream_errors_window
           ORDER BY p.checked_at DESC LIMIT 10) x;
  IF v_errors >= v_cfg.upstream_errors_max AND v_newest IN ('upstream_error', 'timeout', 'lost') THEN
    RETURN jsonb_build_object('items', '[]'::jsonb, 'hold_s', 60, 'upstream_errors', v_errors,
                              'errors_window', v_cfg.upstream_errors_window);
  END IF;

  v_budget := public.axs_watch_budget();
  v_cap    := (v_budget->>'daily_cap')::integer;
  v_fired  := (v_budget->>'fired_today')::integer;

  SELECT count(*) INTO v_in_flight FROM public.axs_read_queue
   WHERE resolved_at IS NULL AND claimed_at IS NOT NULL AND lease_until >= now();
  v_room := least(coalesce(p_limit, v_cfg.queue_lanes), v_cfg.queue_lanes) - v_in_flight;
  IF v_room <= 0 THEN
    RETURN jsonb_build_object('items', '[]'::jsonb, 'hold_s', 2, 'reason', 'all lanes busy',
                              'lanes', v_cfg.queue_lanes, 'in_flight', v_in_flight);
  END IF;

  v_spacing := make_interval(secs => coalesce(v_cfg.read_spacing_ms, 3000) / 1000.0);
  v_base    := greatest(coalesce(v_cfg.last_release_at, now()), now());

  FOR q IN SELECT * FROM public.axs_read_queue
            WHERE resolved_at IS NULL AND claimed_at IS NULL
            ORDER BY due_at, id
            LIMIT v_room
            FOR UPDATE SKIP LOCKED
  LOOP
    -- over the day's share: only an event on a hot cadence, and only up to the overrun
    IF v_fired + v_n >= v_cap THEN
      CONTINUE WHEN q.every_min IS NULL OR make_interval(mins => q.every_min) > v_cfg.hot_every;
      CONTINUE WHEN v_fired + v_n >= v_cap + (v_cap * v_cfg.hot_overrun_pct) / 100;
    END IF;
    v_base := v_base + v_spacing;
    UPDATE public.axs_read_queue
       SET claimed_at = now(), claimed_by = p_worker, release_at = v_base,
           lease_until = v_base + v_cfg.stale_after
     WHERE id = q.id;
    v_items := v_items || jsonb_build_object('queue_id', q.id, 'id', q.axs_event_id,
                 'url', q.event_url, 'every_min', q.every_min, 'release_at', v_base,
                 'attempts', q.attempts);
    v_n := v_n + 1;
  END LOOP;

  IF v_n > 0 THEN
    UPDATE public.axs_watch_config SET last_release_at = v_base WHERE id;
  END IF;

  RETURN jsonb_build_object('items', v_items, 'spacing_ms', v_cfg.read_spacing_ms,
                            'lanes', v_cfg.queue_lanes, 'in_flight', v_in_flight + v_n,
                            'daily_cap', v_cap, 'fired_today', v_fired,
                            'depth', public.axs_queue_depth());
END $function$;

-- The pace (as 20261125010000), with the extension's capacity.
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
  sp AS (SELECT CASE cfg.reader WHEN 'worker' THEN cfg.read_spacing_ms / 1000.0
                                WHEN 'extension' THEN cfg.ext_spacing_ms / 1000.0
                                ELSE 15.0 END AS spacing_s,
                CASE WHEN cfg.reader = 'extension' THEN cfg.ext_lanes ELSE 1 END AS lanes,
                -- unmeasured: 10 s a read, or 46 s for the extension (a browser read of AXS, TicketsData's own timings)
                CASE WHEN cfg.reader = 'extension' THEN 45.0 ELSE 9.0 END AS settle_guess
           FROM cfg),
  pace AS (SELECT m.n, m.settle_p50, m.settle_p90, m.response_p50, sp.spacing_s, sp.lanes,
                  -- a read takes its settle plus a second of overhead, shared by the lanes reading at once (the extension's
                  -- ext_lanes; one otherwise), never less than the spacing
                  greatest((coalesce(m.settle_p50, sp.settle_guess) + 1.0) / sp.lanes, sp.spacing_s) AS s_per_read
             FROM m, sp),
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
           'response_p50_s', round(cap.response_p50::numeric, 1), 'spacing_s', cap.spacing_s, 'lanes', cap.lanes,
           's_per_read', round(cap.s_per_read::numeric, 1),
           'reads_per_hour', cap.reads_per_hour, 'usable_per_hour', cap.usable_per_hour, 'target_pct', cfg.pace_target_pct,
           'daily_cap', cap.daily_cap,
           'events', (SELECT count(*) FROM ev), 'day_of_events', day_of.n,
           'day_of_fits', day_of.n * cap.s_per_read <= 600 * cfg.pace_target_pct / 100.0,
           'demand_per_hour', (SELECT jsonb_object_agg((extract(epoch FROM r.every) / 60)::integer || ' min', r.per_hour) FROM rungs r),
           'far_out_every', cfg.far_out_every::text, 'far_out_days', cfg.far_out_days)
    FROM cfg, cap, day_of
$function$;

-- One read by the extension: settled with no credit spent and written to the ledger as the extension's. A repeat of the
-- same (event, fired_at) — the extension retrying a send whose answer it lost — returns the first record.
CREATE OR REPLACE FUNCTION public.axs_watch_record_ext(p_event_id text, p_status_code integer, p_content jsonb, p_timed_out boolean DEFAULT false,
                                                        p_error_msg text DEFAULT NULL, p_fired_at timestamptz DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r jsonb; v_id bigint; prior record;
BEGIN
  IF p_fired_at IS NOT NULL THEN
    SELECT * INTO prior FROM public.axs_watch_poll p
     WHERE p.reader = 'extension' AND p.axs_event_id = p_event_id AND p.fired_at = p_fired_at
     ORDER BY p.request_id LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('outcome', prior.outcome, 'error', prior.error, 'response_s', prior.response_s, 'listings', prior.listings,
                                'request_id', prior.request_id, 'event_id', p_event_id, 'repeated', true);
    END IF;
  END IF;
  r := public.axs_watch_settle_one(p_event_id, p_status_code, p_content, p_timed_out, p_error_msg, false, 'the AXS page');
  v_id := nextval('public.axs_watch_worker_read_seq');
  INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, error, response_s, listings, quota_remaining, reader)
  VALUES (v_id, p_event_id, coalesce(p_fired_at, now()), now(), p_status_code, r->>'outcome', r->>'error',
          (r->>'response_s')::numeric, (r->>'listings')::integer, NULL, 'extension');
  RETURN r || jsonb_build_object('request_id', v_id, 'event_id', p_event_id);
END $function$;

REVOKE ALL ON FUNCTION public.axs_watch_budget() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_next(integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_queue_claim(text, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_pace() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_record_ext(text, integer, jsonb, boolean, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_budget() TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_next(integer, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_queue_claim(text, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_pace() TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_record_ext(text, integer, jsonb, boolean, text, timestamptz) TO service_role;
