-- Migration 20260619190000 · lane:A1 (operator-directed) ·
--   writes (DDL): CREATE OR REPLACE sg_match_map_tick() — failure-cooldown fix
--   ## Applied to prod 2026-06-19 via MCP (operator-directed). Idempotent.
--
-- BUG (found 2026-06-19): a failed /match (500 "could not resolve performer
-- cluster" / 429) does NOT write a td_match_results row, so the candidate filter
-- (which only excluded successfully-matched events via td_match_results) re-picked
-- the same un-matchable event every tick. Joji (SYS-6ef074c1cd) was retried 44x and
-- wedged the queue (it sorts first by date, blocking all other progress). No budget
-- cost (500s don't charge), but pointless churn + starvation of other candidates.
--
-- FIX: also exclude events with a recent FAILED attempt (any non-200 resolved
-- td_match_queue row in the last 14 days) — a cooldown symmetric to the 14-day
-- success exclusion. Everything else unchanged from 20260619170000.

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
    LEFT JOIN LATERAL (
      SELECT COALESCE(SUM(x.owned_tickets), 0) AS owned_qty
      FROM public.ticketsdata_event_xref x
      WHERE x.aq_short_event_id = a.aq_short_event_id AND x.active
    ) own ON true
    WHERE a.sg_event_id IS NOT NULL AND a.tevo_event_id IS NOT NULL
      AND a.event_date > now()
      AND (a.sh_event_id IS NULL OR a.vivid_event_id IS NULL)
      AND NOT EXISTS (SELECT 1 FROM public.td_match_results mr
                      WHERE mr.aq_short_event_id = a.aq_short_event_id
                        AND mr.created_at > now() - interval '14 days')
      -- cooldown: skip if in flight OR a FAILED attempt in the last 14 days (fixes retry loop)
      AND NOT EXISTS (SELECT 1 FROM public.td_match_queue q
                      WHERE q.aq_short_event_id = a.aq_short_event_id
                        AND (q.resolved_at IS NULL
                             OR (q.status_code IS DISTINCT FROM 200
                                 AND q.fired_at > now() - interval '14 days')))
    ORDER BY
      (own.owned_qty > 0)            DESC,   -- 1. owned events first
      (a.axs_event_id IS NOT NULL)   DESC,   -- 2. then AXS events
      own.owned_qty                  DESC,   -- 3. most owned tickets
      a.event_date                   ASC     -- 4. soonest unmapped
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

COMMENT ON FUNCTION public.sg_match_map_tick() IS
  'Maps unmapped SeatGeek events via SG-anchored TicketsData /match: reap-stale -> drain -> COALESCE-fill -> fire ONE /match (serialized, budget-gated at 50%). Target priority: owned -> AXS -> most-owned -> soonest. Skips events with a success OR failed attempt in the last 14 days (failure cooldown). Cron sg-match-map-tick every 10 min. Operator-directed 2026-06-19.';
