-- Migration 20261125020000 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) · writes:axs_watch_config(+worker_id,+worker_lease_until,+worker_lease_s),axs_watch_next()(replaced: + p_worker),axs_watch_record()(replaced: idempotent) · reads:axs_watch_poll · pre:20261125010000
--
-- ONE WORKER READS AT A TIME.
-- The web service runs two instances for a minute or two at each deploy (the new one starts before the old one
-- stops), and both ran the reader: at the 00:55Z and 01:03Z deploys of 2026-11-25 the ledger shows pairs of reads
-- 0.1 to 1.4 s apart, several of the same event, and the first two HTTP 429s since the worker took over
-- (TicketsData's three-second rule). So the batch hand-out now carries a lease:
--   axs_watch_next(limit, worker)   a worker names itself (host:pid). While another worker's lease is live the
--                                   caller gets no events and a short hold; otherwise it takes or renews the lease
--                                   for worker_lease_s (180 s: a batch of 20 at ~9 s a read) and reads. A worker
--                                   that stops lets its lease run out; the next caller takes over within it.
--   axs_watch_record(...)           the same read recorded twice (the database client retries a dropped connection
--                                   after the first record landed: two rows at 00:08Z and 00:51Z) now returns the
--                                   first row and settles nothing again.
-- A call without a worker name (the old signature) still works and takes no lease.
-- rollback: re-apply axs_watch_next() and axs_watch_record() from 20261125000000; the columns can stay.

ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS worker_id text;
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS worker_lease_until timestamptz;
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS worker_lease_s integer NOT NULL DEFAULT 180 CHECK (worker_lease_s BETWEEN 30 AND 3600);

DROP FUNCTION IF EXISTS public.axs_watch_next(integer);
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
    UPDATE public.axs_watch_config SET worker_id = p_worker, worker_lease_until = now() + make_interval(secs => v_cfg.worker_lease_s);
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

-- One read by the worker: settled at once and written to the ledger; the same read sent twice is recorded once.
CREATE OR REPLACE FUNCTION public.axs_watch_record(p_event_id text, p_status_code integer, p_content jsonb, p_timed_out boolean DEFAULT false,
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
     WHERE p.reader = 'worker' AND p.axs_event_id = p_event_id AND p.fired_at = p_fired_at
     ORDER BY p.request_id LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('outcome', prior.outcome, 'error', prior.error, 'response_s', prior.response_s, 'listings', prior.listings,
                                'quota_remaining', prior.quota_remaining, 'request_id', prior.request_id, 'event_id', p_event_id, 'repeated', true);
    END IF;
  END IF;
  r := public.axs_watch_settle_one(p_event_id, p_status_code, p_content, p_timed_out, p_error_msg);
  v_id := nextval('public.axs_watch_worker_read_seq');
  INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at, status_code, outcome, error, response_s, listings, quota_remaining, reader)
  VALUES (v_id, p_event_id, coalesce(p_fired_at, now()), now(), p_status_code, r->>'outcome', r->>'error',
          (r->>'response_s')::numeric, (r->>'listings')::integer, (r->>'quota_remaining')::bigint, 'worker');
  RETURN r || jsonb_build_object('request_id', v_id, 'event_id', p_event_id);
END $function$;

REVOKE ALL ON FUNCTION public.axs_watch_next(integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_watch_record(text, integer, jsonb, boolean, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_next(integer, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_watch_record(text, integer, jsonb, boolean, text, timestamptz) TO service_role;
