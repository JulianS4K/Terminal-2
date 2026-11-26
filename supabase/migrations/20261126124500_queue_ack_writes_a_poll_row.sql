-- Migration 20261126124500 · level:data-collection · lane:a1 (AXS watch) · writes:axs_queue_ack()(patched: writes axs_watch_poll) · reads:axs_watch_config,axs_read_queue
--
-- ============================================================================
-- Migration 20261126124500 — the queue's ack writes a read row, like the worker's
--
-- Lane:     a1 (AXS watch)
-- pre:      20261126030000 (the queue), 20261126065000 (axs_watch_event_dead).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It records a read that has
-- already happened.
--
-- ── THE GAP ───────────────────────────────────────────────────────────────
-- axs_watch_poll is the read ledger. Only axs_watch_record (the due-list path) and
-- axs_watch_tick write it. axs_queue_ack calls axs_watch_settle_one directly and writes
-- NOTHING, so a read that arrives through the queue leaves no trace in the ledger.
--
-- Six functions read that ledger, and the first two are why this is a prerequisite for
-- switching the queue on rather than a tidy-up:
--
--   axs_watch_budget   fired_today = count(*) since Eastern midnight, and in_flight
--                      -> reads 0 forever. axs_watch_next AND axs_queue_claim both gate
--                         on fired_today >= daily_cap, so THE DAILY CREDIT CAP FAILS OPEN
--                         and the watch reads until the 250,000-credit cycle pool is dry.
--   axs_watch_pace     the last 300 rows' settle and response times -> s_per_read ->
--                      usable_per_hour
--                      -> no measurement, so the demand gauge and cadence_scale lose the
--                         denominator the whole brake is built on (20261126053000).
--   axs_queue_claim    the upstream-error hold, 3 of the last 10 in the window
--                      -> the QUEUE'S OWN hold reads rows the queue does not write, so it
--                         could never back off a failing upstream. AXS flapped three times
--                         in the small hours of 2026-11-26; that is not theoretical.
--   axs_watch_next     the same hold on the due-list path
--   axs_watch_fill     axs_watch_not_on_sale (last read) and the three-strikes
--                      (not_axs, expired) retire arm -> both blind
--   axs_watch_event_dead  SAFE — 20261126065000 reads primary_poll_event.poll_error first
--                         precisely because of this gap.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────
-- axs_queue_ack writes the same row axs_watch_record does, from what it already has:
-- the queue row carries the event and the timing, and settle_one returns the outcome.
--
--   request_id   nextval('axs_watch_worker_read_seq') — the same sequence, so ids stay
--                unique across both paths and nothing has to reconcile two id spaces.
--   reader       axs_watch_config.reader, NOT a literal 'queue'.
--                THIS IS THE SUBTLE ONE. axs_watch_pace filters WHERE p.reader =
--                cfg.reader. A row written as 'queue' would sit in the ledger and pace
--                would still measure nothing — the fix would look done and not be. The
--                config value is also the honest one: 'reader' selects the MODE (worker or
--                db), not the transport, and the queue is how the worker is handed work,
--                not a different reader. Reading the config rather than hardcoding
--                'worker' as axs_watch_record does means the rows follow if the mode flips.
--   fired_at     least(coalesce(release_at, claimed_at, now()), now()). release_at is when
--                the pacer permitted the send and the worker sleeps until it, so it is the
--                closest thing to when the request left — and settle_s (checked_at -
--                fired_at) is what pace measures, so this has to be the send, not the
--                enqueue.
--                THE least() IS NOT DECORATION. release_at is assigned as
--                last_release_at + read_spacing_ms and is routinely in the FUTURE — that
--                is the whole point of the pacer. An ack that lands before it (a fast
--                settle, or any caller acking without waiting) would write
--                fired_at > checked_at, and axs_watch_pace computes
--                extract(epoch FROM checked_at - fired_at), so it would take a NEGATIVE
--                settle time into its median: s_per_read nonsense, usable_per_hour
--                nonsense, and the brake acting on it. Caught by s21 section C, which
--                asserts fired_at <= checked_at rather than assuming it.
--   checked_at   now()
--
-- Idempotency comes free: axs_queue_ack already takes the queue row FOR UPDATE and returns
-- early when resolved_at IS NOT NULL, so a second ack of the same item cannot reach the
-- insert. One poll row per queue item, enforced by the lock that was already there.
--
-- The due-list path is untouched: axs_watch_record still writes its own row, and nothing
-- here runs on that path, so there is no double-write.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- Revert axs_queue_ack to the 20261126030000 body. The queue is dark
-- (axs_watch_config.queue_enabled = false), so this changes no live behaviour today.
-- ============================================================================

BEGIN;

DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_queue_ack';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_queue_ack not found'; END IF;
  v_new := v_src;

  -- (a) a local for the configured reader
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    '  q public\.axs_read_queue%ROWTYPE; v_settled jsonb;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ack DECLARE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    '  q public.axs_read_queue%ROWTYPE; v_settled jsonb;',
    '  q public.axs_read_queue%ROWTYPE; v_settled jsonb; v_reader text; v_request_id bigint;');

  -- (b) the ledger row, between the settle and the queue update
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'  UPDATE public\\.axs_read_queue\\n     SET resolved_at = now\\(\\), outcome = v_settled->>''outcome'', error = v_settled->>''error''', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ack queue UPDATE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'  UPDATE public.axs_read_queue\n     SET resolved_at = now(), outcome = v_settled->>''outcome'', error = v_settled->>''error''',
    E'  -- The read ledger (mig 20261126124500). Six functions read axs_watch_poll, and\n'
    || E'  -- axs_watch_budget''s fired_today and axs_watch_pace''s measurement are two of them,\n'
    || E'  -- so without this row the daily credit cap fails open and the brake has no\n'
    || E'  -- denominator. reader comes from the config because axs_watch_pace filters on it.\n'
    || E'  SELECT c.reader INTO v_reader FROM public.axs_watch_config c;\n'
    || E'  v_request_id := nextval(''public.axs_watch_worker_read_seq'');\n'
    || E'  INSERT INTO public.axs_watch_poll (request_id, axs_event_id, fired_at, checked_at,\n'
    || E'          status_code, outcome, error, response_s, listings, quota_remaining, reader)\n'
    || E'  VALUES (v_request_id, q.axs_event_id,\n'
    || E'          least(coalesce(q.release_at, q.claimed_at, now()), now()), now(),\n'
    || E'          p_status_code, v_settled->>''outcome'', v_settled->>''error'',\n'
    || E'          (v_settled->>''response_s'')::numeric, (v_settled->>''listings'')::integer,\n'
    || E'          (v_settled->>''quota_remaining'')::bigint, coalesce(v_reader, ''worker''));\n'
    || E'\n'
    || E'  UPDATE public.axs_read_queue\n     SET resolved_at = now(), outcome = v_settled->>''outcome'', error = v_settled->>''error''');

  -- (c) hand the request_id back, as the worker path does
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'RETURN v_settled \|\| jsonb_build_object\(''queue_id'', p_queue_id\);', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'ack RETURN: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'RETURN v_settled || jsonb_build_object(''queue_id'', p_queue_id);',
    'RETURN v_settled || jsonb_build_object(''queue_id'', p_queue_id, ''request_id'', v_request_id);');

  IF v_new = v_src THEN RAISE EXCEPTION 'axs_queue_ack unchanged — surgery did nothing'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_queue_ack';
  IF v_src !~ 'INSERT INTO public\.axs_watch_poll'
     OR v_src !~ 'axs_watch_worker_read_seq'
     OR v_src !~ 'c\.reader INTO v_reader'
     OR v_src !~ 'least\(coalesce\(q\.release_at, q\.claimed_at, now\(\)\), now\(\)\)' THEN
    RAISE EXCEPTION 'axs_queue_ack did not come back with the ledger write';
  END IF;
END $surgery$;

COMMIT;
