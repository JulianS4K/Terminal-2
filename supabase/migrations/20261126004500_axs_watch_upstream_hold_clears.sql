-- Migration 20261126004500 · level:data-collection · lane:a1 (AXS watch reader) · writes:axs_watch_config(+upstream_errors_window),axs_watch_next()(replaced) · reads:axs_watch_poll
--
-- ============================================================================
-- Migration 20261126004500 — the upstream-trouble hold must be able to clear itself
--
-- Lane:     a1 (AXS watch reader)
-- Touches:  axs_watch_config (+upstream_errors_window), axs_watch_next() (REPLACED).
-- pre:      none. Built on the form applied as 20261125150000.
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes when the existing
-- reader is allowed to read.
--
-- ── THE BUG: A BREAKER THAT LATCHES OFF FOREVER ───────────────────────────
-- axs_watch_next() refuses to hand out work while "three of the last ten reads failed
-- upstream and so did the newest", and tells the worker to come back in 60 seconds. The
-- sample has NO TIME BOUND: it is the last ten rows of axs_watch_poll, whenever they were
-- made. So once the breaker trips, the only thing that could change the verdict is a new
-- read — and the breaker is what stops any new read being handed out. The condition is
-- its own cause. It never clears.
--
-- Observed on prod tonight. TicketsData degraded from 22:00Z (73 of 303 reads
-- "unavailable" in that hour, 32 of 101 in the next), then returned HTTP 502 eight times
-- in a row at 23:24Z. The last ten settled reads were those 8 upstream_errors and 2
-- unavailable, newest an upstream_error, so the breaker tripped — and the AXS watch made
-- NO READ AT ALL for the next 64 minutes, while the worker went on renewing its lease
-- every 30 seconds and TicketsData itself recovered (/match and /events?mode=all both
-- answered 200 at 00:01Z and 00:23Z). Nothing in the system would ever have restarted it:
-- not the fill, not the pace picker, not a new day. Only the 14-day ledger retention
-- ageing those ten rows out, or a human.
--
-- ── THE FIX: BOUND THE SAMPLE IN TIME ─────────────────────────────────────
-- The breaker is meant to say "upstream is in trouble RIGHT NOW". So only reads inside
-- axs_watch_config.upstream_errors_window (10 minutes) count. With the reader held and no
-- reads landing, the window empties on its own, v_errors falls to 0, and work is handed
-- out again — a self-clearing breaker rather than a latch.
--
-- On an upstream that is genuinely down this re-trips after upstream_errors_max (3) more
-- failures, so the cost of probing is about three reads every ten minutes: 0.3% of an
-- hour's throughput, against a poller that otherwise stays dark until someone notices.
-- The hold payload now reports the window, so the monitor can tell a breaker that is
-- holding from one that has cleared.
--
-- ⚠ COLLISION. 20261125210000 (another session, PR 1216, NOT APPLIED as of 00:45Z) also
-- replaces axs_watch_next(), to add the extension reader. That version carries the
-- unbounded sample. If it is applied after this, THE LATCH COMES BACK — it must take the
-- `AND p.checked_at > now() - v_cfg.upstream_errors_window` line and the column with it.
-- This migration deliberately does NOT reach into that change: ext_lanes / ext_spacing_ms
-- do not exist on prod yet, so referencing them here would fail, and taking over another
-- session's migration to add them is not this one's call.
-- ============================================================================

BEGIN;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS upstream_errors_window interval NOT NULL DEFAULT interval '10 minutes'
    CHECK (upstream_errors_window >= interval '1 minute' AND upstream_errors_window <= interval '1 hour');
COMMENT ON COLUMN public.axs_watch_config.upstream_errors_window IS
  'How recent a failed read has to be to count toward the upstream-trouble hold (mig 20261126004500). Bounding it in time is what lets the hold clear itself: with the reader held, no reads land, the window empties and reading resumes.';

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
  RETURN jsonb_build_object('events', v_events, 'spacing_ms', v_cfg.read_spacing_ms, 'upstream_errors', v_errors,
                            'daily_cap', v_cap, 'fired_today', v_fired_today, 'pool_remaining', v_budget->'pool_remaining',
                            'lease_s', CASE WHEN p_worker IS NOT NULL THEN v_cfg.worker_lease_s END);
END $function$;

COMMIT;
