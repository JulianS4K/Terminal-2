-- Migration 20260619163000 · lane:A1 (operator-directed) ·
--   writes (DDL): td_match_cron_budget_ok(), sg_match_map_tick(); cron 'sg-match-map-tick'
--   reads: aq_event_map, sg_events_canonical, td_match_queue/_results, ticketsdata_credit_usage
--   writes on run: td_match_queue (fires <=1 /match), td_match_results (drain), aq_event_map (COALESCE-fill)
--   spends: TicketsData /match = 12 credits + 1 report per tick that FIRES (<=1 in flight at a time)
--
-- ## Applied to prod 2026-06-19 via MCP apply_migration (operator-directed). Idempotent.
--
-- Operator-directed 2026-06-19: "create a cron to map unmapped SeatGeek events,
--   tie it against credits, and only use 50% for now."
--
-- WHY: /match is a SeatGeek-anchored cross-market resolver (proven 2026-06-19 —
--   feeding seatgeek.com/e/events/<id> returns sh/vivid/tm/tp/gt matches at ~84-88
--   'probable'; feeding StubHub/VividSeats bare URLs 500s "could not resolve
--   performer cluster", and Ticketmaster/Gametime URLs 500 "unsupported
--   marketplace"). This cron walks FUTURE SG-mapped aq rows missing their
--   StubHub/VividSeats id, fires ONE /match per tick on the SeatGeek URL, and
--   COALESCE-fills the result onto aq_event_map — consolidating the scattered
--   platform ids behind the A1-OPS-22 dup problem.
--
-- RATE LIMIT: /match is serialized per account (429 "Too many match requests",
--   retry_after 5s) and pg_net batches concurrent fires — so the tick fires at
--   most ONE /match and only when nothing is already in flight. 10-min cadence
--   keeps fires well outside the 5s window.
--
-- BUDGET (the "50%" cap): td_match_cron_budget_ok() = credits OK (td_budget_ok)
--   AND monthly /match reports < 300 (half of the 600 automated cap; plan = 2,000/mo).
--   When 300 is hit the cron idles until the next UTC month.

-- 1) Budget gate — ties the cron to credits + the 50% report cap.
CREATE OR REPLACE FUNCTION public.td_match_cron_budget_ok()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $$
  SELECT public.td_budget_ok() AND public.td_reports_this_month() < 300;  -- 300 = 50% of the 600 automated cap
$$;
REVOKE ALL ON FUNCTION public.td_match_cron_budget_ok() FROM anon, public;
COMMENT ON FUNCTION public.td_match_cron_budget_ok() IS
  'Gate for sg_match_map_tick: TD credit budget OK AND monthly /match reports < 300 (50% of the 600 automated cap). Operator-directed 2026-06-19.';

-- 2) The per-tick worker: reap-stale -> drain -> fill -> fire ONE (serialized).
CREATE OR REPLACE FUNCTION public.sg_match_map_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $fn$
DECLARE
  v_drained int := 0;
  v_fired   int := 0;
  v_req bigint; v_url text; v_tevo bigint; v_aq text;
  v_user text; v_pass text;
BEGIN
  -- (a) Reap stale in-flight rows (fired, no response after 30 min) to avoid deadlock.
  UPDATE public.td_match_queue q
  SET resolved_at = now(), status_code = -2, error_msg = 'timeout_no_response'
  WHERE q.resolved_at IS NULL AND q.request_id IS NOT NULL
    AND q.fired_at < now() - interval '30 minutes'
    AND NOT EXISTS (SELECT 1 FROM net._http_response r WHERE r.id = q.request_id);

  -- (b) Drain completed /match responses -> td_match_results, then COALESCE-fill NULLs.
  v_drained := public.td_match_drain(50);
  PERFORM 1 FROM public.td_match_apply(80, true);  -- NULL-fills only; CONFLICTs flagged, never overwritten

  -- (c) Fire ONE new /match, only if budget OK AND nothing is currently in flight (429 guard).
  IF public.td_match_cron_budget_ok()
     AND NOT EXISTS (SELECT 1 FROM public.td_match_queue q
                     WHERE q.request_id IS NOT NULL AND q.resolved_at IS NULL) THEN
    SELECT a.tevo_event_id, a.aq_short_event_id, sgc.sg_url
    INTO v_tevo, v_aq, v_url
    FROM public.aq_event_map a
    JOIN public.sg_events_canonical sgc
      ON sgc.sg_event_id = a.sg_event_id AND sgc.sg_url IS NOT NULL
    WHERE a.sg_event_id IS NOT NULL AND a.tevo_event_id IS NOT NULL
      AND a.event_date > now()
      AND (a.sh_event_id IS NULL OR a.vivid_event_id IS NULL)
      AND NOT EXISTS (SELECT 1 FROM public.td_match_results mr
                      WHERE mr.aq_short_event_id = a.aq_short_event_id
                        AND mr.created_at > now() - interval '14 days')
      AND NOT EXISTS (SELECT 1 FROM public.td_match_queue q
                      WHERE q.aq_short_event_id = a.aq_short_event_id AND q.resolved_at IS NULL)
    ORDER BY a.event_date   -- soonest unmapped first
    LIMIT 1;

    IF v_url IS NOT NULL THEN
      v_user := public.get_app_secret('TICKETSDATA_USERNAME');
      v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
      IF v_user IS NOT NULL AND v_pass IS NOT NULL THEN
        SELECT net.http_get(
          url := 'https://ticketsdata.com/match',
          params := jsonb_build_object('event_url', v_url, 'username', v_user, 'password', v_pass),
          headers := '{}'::jsonb, timeout_milliseconds := 45000) INTO v_req;
        INSERT INTO public.td_match_queue
          (tevo_event_id, aq_short_event_id, seed_platform, seed_event_url, purpose, request_id)
        VALUES (v_tevo, v_aq, 'SG', v_url, 'fill', v_req);
        v_fired := 1;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'drained', v_drained,
    'fired', v_fired,
    'reports_used_month', public.td_reports_this_month(),
    'budget_ok', public.td_match_cron_budget_ok());
END $fn$;
REVOKE ALL ON FUNCTION public.sg_match_map_tick() FROM anon, public;
COMMENT ON FUNCTION public.sg_match_map_tick() IS
  'Maps unmapped SeatGeek events via SG-anchored TicketsData /match: reap-stale -> drain -> COALESCE-fill -> fire ONE /match (serialized, budget-gated at 50%). Cron sg-match-map-tick every 10 min. Operator-directed 2026-06-19.';

-- 3) Schedule: every 10 minutes, behind the repo cron policy gate.
SELECT cron.unschedule('sg-match-map-tick')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sg-match-map-tick');

SELECT cron.schedule(
  'sg-match-map-tick',
  '*/10 * * * *',
  $cronbody$
    DO $b$ BEGIN
      IF NOT public.cron_should_fire('sg-match-map-tick') THEN RETURN; END IF;
      PERFORM public.sg_match_map_tick();
    END $b$;
  $cronbody$
);
