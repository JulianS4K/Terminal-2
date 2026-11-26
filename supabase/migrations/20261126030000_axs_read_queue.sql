-- Migration 20261126030000 · level:data-collection · lane:a1 (AXS watch reader) · writes:axs_read_queue(new),axs_watch_config(+queue_enabled,+queue_lanes,+last_release_at),axs_queue_fill()(new),axs_queue_claim()(new),axs_queue_ack()(new),axs_queue_reap()(new),axs_queue_depth()(new) · reads:primary_poll_event,primary_poll_config,axs_watch_poll
--
-- ============================================================================
-- Migration 20261126030000 — a real work queue for the AXS reads: dedup by
--   constraint, one global pacer, several reader processes
--
-- Lane:     a1 (AXS watch reader)
-- Touches:  axs_read_queue (new table), axs_watch_config (+queue_enabled, +queue_lanes,
--           +last_release_at), axs_queue_fill/claim/ack/reap/depth (new).
-- pre:      20261126023000 (the phase fix) — the queue makes bad scheduling cheap, it
--           does not make it correct, so the phase fix lands first.
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes which read the
-- existing reader is handed next and when it may send it.
--
-- SHIPS DARK. axs_watch_config.queue_enabled defaults FALSE and axs_queue_claim returns
-- nothing while it is false, so the live path (axs_watch_next / axs_watch_record) is
-- untouched by applying this. Turning it on is a one-column decision.
--
-- ── WHY A QUEUE, AND WHAT IT ACTUALLY BUYS ────────────────────────────────
-- Operator 2026-11-26: "what if we built a queue system", then "phase fix and test, then
-- queue and test".
--
-- Tonight produced two scheduling bugs of the same family: a hold that could latch ON for
-- ever (mig 20261126004500) and a phase that re-armed inside due_slack and re-read every
-- event about a dozen times a cycle (mig 20261126023000, 76% of all reads). Neither was
-- a dispatch bug. Both were arithmetic.
--
-- The queue does not make that arithmetic correct. It makes it CHEAP. The load-bearing
-- line in this migration is one index:
--
--     CREATE UNIQUE INDEX ... ON axs_read_queue (axs_event_id) WHERE resolved_at IS NULL
--
-- With it an event can have at most one unresolved read, whatever the scheduler thinks.
-- The phase loop would have fired twelve times and enqueued once. Any future scheduling
-- defect costs nothing instead of three quarters of the budget.
--
-- ⚠ THE LESSON FROM td_pull_queue, WHICH IS WHY THAT INDEX IS UNIQUE HERE. The existing
-- TicketsData queue (mig 20260527050000) has the right shape and an index commented
-- "Pileup guard: unresolved check per (event, platform)" — but all three of its indexes
-- are plain CREATE INDEX, so dedup lives in the enqueue function as a check-then-insert
-- race rather than in a constraint. That is the same mistake in a different place.
--
-- ── THE PACER: THE 3-SECOND RULE IS A RATE LIMIT, NOT A CONCURRENCY LIMIT ──
-- TicketsData (Alex, relayed by the operator 2026-11-26) requires 3 seconds between any
-- incoming requests. Measured: a read occupies 6.8 s (p50) healthy and 20.5 s during an
-- AXS flap, so a single sequential reader tops out at 529 and 176 reads/h respectively.
-- 300 events in one hour needs one start every 12 s, which the rule allows four times
-- over — but 300 x 20.5 s = 102 minutes of serial work, so the flap allowance cannot be
-- met by one process at all. Starts paced 3 s apart with several in flight hide the
-- latency and cap out at 1,200 reads/h regardless of how slow AXS is.
--
-- So the spacing is enforced ONCE, centrally: axs_queue_claim takes the config row FOR
-- UPDATE, hands each claimed item a release_at of last_release_at + read_spacing_ms, and
-- advances last_release_at. The worker must not send before its item's release_at. N
-- processes each spacing their own requests would send N requests per 3 s and break the
-- rule; this cannot, because the slots are allocated in one serialised place.
--
-- ⚠ queue_lanes DEFAULTS TO 1, i.e. it behaves exactly like today's one-at-a-time reader.
-- Raising it is a deliberate act and SHOULD WAIT for Alex to confirm what the rule means:
-- starts 3 s apart with several in flight, or genuinely one request at a time. He also
-- wrote that they "plan to increase concurrency over time", which reads as though
-- concurrency is currently 1. The operator's plan is to ask once there are results.
--
-- ── WHAT THE ENQUEUER DELIBERATELY DOES NOT USE ───────────────────────────
-- It does not call primary_poll_due. That function has a clause
--     OR (live.every < t.poll_interval AND t.poll_attempt_at + live.every <= now() + due_slack)
-- which bypasses next_poll_at wherever the shared box-office ladder is faster than the
-- event's AXS band — 67 of 88 events are in that state, which is why the watch still ran
-- at ~180 reads/h after the phase fix instead of the ~90 the three bands ask for. The
-- queue reads next_poll_at and poll_interval directly, so the operator's bands are in
-- force for AXS without touching a function the other three sources share.
--
-- The stop rules are unchanged and still applied here: ticket_url present,
-- stop_before_start (6 h before the start), and the event must be in primary_poll_event
-- (so the fill's keep_regex and horizon decisions stand).
-- ============================================================================

BEGIN;

-- ── the queue ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.axs_read_queue (
  id            bigserial   PRIMARY KEY,
  axs_event_id  text        NOT NULL,
  event_url     text        NOT NULL,
  every_min     integer,                             -- the band when enqueued, for the worker's log
  due_at        timestamptz NOT NULL,                -- the next_poll_at that put it here
  enqueued_at   timestamptz NOT NULL DEFAULT now(),
  claimed_at    timestamptz,
  claimed_by    text,
  release_at    timestamptz,                         -- the pacer's slot: do NOT send before this
  lease_until   timestamptz,
  attempts      integer     NOT NULL DEFAULT 0,
  resolved_at   timestamptz,
  outcome       text,
  error         text
);
COMMENT ON TABLE public.axs_read_queue IS
  'One pending AXS read per event, at most (mig 20261126030000). The unique partial index is the point: it makes a duplicate read impossible by construction, whatever the scheduler decides.';
COMMENT ON COLUMN public.axs_read_queue.release_at IS
  'The global pacer''s slot for this item. A worker must not send its request before this instant; the slots are allocated 3 s apart (axs_watch_config.read_spacing_ms) in one serialised place so several processes cannot together break TicketsData''s rule.';

-- THE load-bearing constraint. Everything else here is plumbing.
CREATE UNIQUE INDEX IF NOT EXISTS axs_read_queue_one_open
  ON public.axs_read_queue (axs_event_id) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS axs_read_queue_claimable
  ON public.axs_read_queue (due_at) WHERE resolved_at IS NULL AND claimed_at IS NULL;
CREATE INDEX IF NOT EXISTS axs_read_queue_leased
  ON public.axs_read_queue (lease_until) WHERE resolved_at IS NULL AND claimed_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS axs_read_queue_resolved
  ON public.axs_read_queue (resolved_at) WHERE resolved_at IS NOT NULL;

ALTER TABLE public.axs_read_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.axs_read_queue FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.axs_read_queue TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.axs_read_queue_id_seq TO service_role;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS queue_enabled   boolean  NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS queue_lanes     smallint NOT NULL DEFAULT 1 CHECK (queue_lanes BETWEEN 1 AND 6),
  ADD COLUMN IF NOT EXISTS last_release_at timestamptz;
COMMENT ON COLUMN public.axs_watch_config.queue_enabled IS
  'False (the default) means axs_queue_claim hands out nothing and the live axs_watch_next path is unaffected (mig 20261126030000).';
COMMENT ON COLUMN public.axs_watch_config.queue_lanes IS
  'How many AXS reads may be in flight at once. 1 = exactly today''s one-at-a-time behaviour. Raise it only once TicketsData confirms the 3-second rule is a gap between request STARTS rather than one request at a time (mig 20261126030000).';

-- ── enqueue: the bands, honoured directly ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.axs_queue_fill()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE; v_slack interval; v_added integer; v_pruned integer;
BEGIN
  SELECT * INTO v_cfg FROM public.axs_watch_config;
  SELECT c.due_slack INTO v_slack FROM public.primary_poll_config c;
  v_slack := coalesce(v_slack, interval '0');

  -- next_poll_at and poll_interval directly: NOT primary_poll_due, whose ladder clause
  -- would override the operator's bands (see the header).
  WITH ins AS (
    INSERT INTO public.axs_read_queue (axs_event_id, event_url, every_min, due_at)
    SELECT e.source_event_id, e.ticket_url,
           (extract(epoch FROM e.poll_interval) / 60)::integer,
           coalesce(e.next_poll_at, now())
      FROM public.primary_poll_event e
     WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL
       AND (e.next_poll_at IS NULL OR e.next_poll_at <= now() + v_slack)
       -- the reads stop six hours before the start, not at tip-off (mig 20261125150000)
       AND (coalesce(e.start_utc, (e.event_date + 1)::timestamptz) IS NULL
            OR coalesce(e.start_utc, (e.event_date + 1)::timestamptz) > now() + v_cfg.stop_before_start)
     ORDER BY e.next_poll_at NULLS FIRST, e.event_date NULLS LAST, e.source_event_id
    ON CONFLICT DO NOTHING                    -- the unique partial index: one open item per event
    RETURNING 1)
  SELECT count(*) INTO v_added FROM ins;

  WITH gone AS (
    DELETE FROM public.axs_read_queue
     WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '7 days'
    RETURNING 1)
  SELECT count(*) INTO v_pruned FROM gone;

  RETURN jsonb_build_object('enqueued', v_added, 'pruned', v_pruned,
                            'depth', public.axs_queue_depth());
END $function$;

-- ── reap: a worker that died leaves its claim behind ──────────────────────
CREATE OR REPLACE FUNCTION public.axs_queue_reap()
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH back AS (
    UPDATE public.axs_read_queue q
       SET claimed_at = NULL, claimed_by = NULL, release_at = NULL, lease_until = NULL,
           attempts = q.attempts + 1
     WHERE q.resolved_at IS NULL AND q.claimed_at IS NOT NULL AND q.lease_until < now()
    RETURNING 1)
  SELECT count(*)::integer FROM back;
$function$;

-- ── depth: one number that says whether we are keeping up ─────────────────
CREATE OR REPLACE FUNCTION public.axs_queue_depth()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'pending',      count(*) FILTER (WHERE resolved_at IS NULL AND claimed_at IS NULL),
    'in_flight',    count(*) FILTER (WHERE resolved_at IS NULL AND claimed_at IS NOT NULL AND lease_until >= now()),
    'expired',      count(*) FILTER (WHERE resolved_at IS NULL AND claimed_at IS NOT NULL AND lease_until < now()),
    'oldest_pending_age_s',
        round(extract(epoch FROM now() - min(enqueued_at) FILTER (WHERE resolved_at IS NULL AND claimed_at IS NULL))),
    'resolved_last_hour', count(*) FILTER (WHERE resolved_at > now() - interval '1 hour'),
    'retried',      count(*) FILTER (WHERE resolved_at IS NULL AND attempts > 0))
    FROM public.axs_read_queue;
$function$;

-- ── claim: the gates, the lanes, and the one global pacer ─────────────────
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

-- ── ack: resolve the item AND settle the read ─────────────────────────────
CREATE OR REPLACE FUNCTION public.axs_queue_ack(
         p_queue_id bigint, p_status_code integer, p_content jsonb,
         p_timed_out boolean DEFAULT false, p_error_msg text DEFAULT NULL,
         p_charge boolean DEFAULT true, p_via text DEFAULT 'TicketsData')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  q public.axs_read_queue%ROWTYPE; v_settled jsonb;
BEGIN
  SELECT * INTO q FROM public.axs_read_queue WHERE id = p_queue_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'no such queue item', 'queue_id', p_queue_id);
  END IF;
  IF q.resolved_at IS NOT NULL THEN
    -- a worker retrying a send whose answer it lost: the first ack stands, and no second
    -- credit is charged
    RETURN jsonb_build_object('already_resolved', true, 'queue_id', p_queue_id, 'outcome', q.outcome);
  END IF;

  v_settled := public.axs_watch_settle_one(q.axs_event_id, p_status_code, p_content,
                                           p_timed_out, p_error_msg, p_charge, p_via);
  UPDATE public.axs_read_queue
     SET resolved_at = now(), outcome = v_settled->>'outcome', error = v_settled->>'error'
   WHERE id = p_queue_id;
  RETURN v_settled || jsonb_build_object('queue_id', p_queue_id);
END $function$;

REVOKE ALL ON FUNCTION public.axs_queue_fill() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_queue_reap() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_queue_depth() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_queue_claim(text, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_queue_ack(bigint, integer, jsonb, boolean, text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_queue_fill() TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_queue_reap() TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_queue_depth() TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_queue_claim(text, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.axs_queue_ack(bigint, integer, jsonb, boolean, text, boolean, text) TO service_role;

COMMIT;
