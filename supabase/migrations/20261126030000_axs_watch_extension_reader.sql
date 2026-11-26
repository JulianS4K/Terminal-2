-- Migration 20261126030000 · level:data-collection · lane:A1 (data plane: the AXS watch, routed to this session by the operator) · writes:axs_watch_config(reader +'extension',+ext_lanes,+ext_spacing_ms),axs_watch_poll(reader +'extension'),axs_watch_budget()(replaced),axs_watch_next()(replaced),axs_watch_record_ext()(new) · reads:primary_poll_event,ticketsdata_credit_usage · pre:20261126004500 (the next() this re-creates),20261125205000 (the budget() this re-creates),20261125214500 (settle_one() with p_charge / p_via, used as is)
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
-- Cadence is unchanged: the bands of 20261125214500 / 20261126011500 (axs_watch_cadence) times cadence_scale. To read
-- more often with the extension, lower the scale.
--
-- Switch: UPDATE public.axs_watch_config SET reader = 'extension' WHERE id;   -- then, to read more often, cadence_scale < 1
-- Back:   UPDATE public.axs_watch_config SET reader = 'worker' WHERE id;
-- rollback: the switch back, then re-apply axs_watch_budget() from 20261125205000 and axs_watch_next() from
--           20261126004500; DROP FUNCTION axs_watch_record_ext(text, integer, jsonb, boolean, text, timestamptz);
--           the columns and checks can stay.

ALTER TABLE public.axs_watch_config DROP CONSTRAINT IF EXISTS axs_watch_config_reader_check;
ALTER TABLE public.axs_watch_config ADD CONSTRAINT axs_watch_config_reader_check CHECK (reader IN ('db', 'worker', 'extension'));
ALTER TABLE public.axs_watch_poll DROP CONSTRAINT IF EXISTS axs_watch_poll_reader_check;
ALTER TABLE public.axs_watch_poll ADD CONSTRAINT axs_watch_poll_reader_check CHECK (reader IN ('db', 'worker', 'extension'));
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS ext_lanes smallint NOT NULL DEFAULT 4 CHECK (ext_lanes BETWEEN 1 AND 8);
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS ext_spacing_ms integer NOT NULL DEFAULT 4000 CHECK (ext_spacing_ms BETWEEN 1000 AND 60000);
COMMENT ON COLUMN public.axs_watch_config.ext_lanes IS 'AXS extension: events read at once, one Firefox container each (mig 20261126030000)';
COMMENT ON COLUMN public.axs_watch_config.ext_spacing_ms IS 'AXS extension: least time between two page opens, across all lanes (mig 20261126030000)';

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
               AND w.reader <> 'extension')                -- the extension's reads spend no TicketsData credit (mig 20261126030000)
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
  -- each reader is handed events only while it is the one switched on (mig 20261126030000)
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
REVOKE ALL ON FUNCTION public.axs_watch_record_ext(text, integer, jsonb, boolean, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_budget() TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_next(integer, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_record_ext(text, integer, jsonb, boolean, text, timestamptz) TO service_role;
