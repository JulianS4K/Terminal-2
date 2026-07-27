-- Migration 20260704170045 · lane:A1 (data plane — TicketsData /match TM-discovery sweep)
--   writes (DDL): sg_match_map_tick() [CREATE OR REPLACE — broaden candidate pool]
--   reads/writes on run: same as before (td_match_queue/_results, fires /match)
--   pre: 20260619190000 (last sg_match_map_tick body), 20260704160040 (td_gt_tm_enroll_from_match)
--   auth: operator directive 2026-07-04 (julian@s4kent.com — "just poll existing events
--         for tm once and any that gives data back continue polling")
--
-- ## Applied to prod 2026-07-04 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- TicketsData has no venue-level Ticketmaster feed (tested: /events?platform=
-- ticketmaster&venue_url → 0 items). The only TM-id source is /match, which
-- returns an authoritative tm_url when — and only when — the event is on
-- Ticketmaster. sg_match_map_tick fires that /match, but ONLY for events still
-- missing sh/vivid — so events already mapped (via SG-discovery + backfill_aq_maps,
-- never through /match) were never TM-probed, and never got a tm_url.
--
-- This broadens the /match candidate pool to also include any mapped event that
-- has NEVER been /match'd (no td_match_results row). Effect: every eligible event
-- (has an sg_url anchor) is /match-probed exactly ONCE —
--   * responders (tm_url present) → td_gt_tm_enroll_from_match (mig 20260704160040,
--     hourly) enrolls them → they CONTINUE polling on Ticketmaster;
--   * non-responders → get a td_match_results row from the 200, so the new
--     `never-probed` predicate turns false and they are NOT re-probed (probe-once).
-- Hard failures (non-200, no result row) still retry on the existing 14-day
-- cooldown. Only the WHERE candidate clause changes; drain/apply/fire/ordering
-- (owned-first, then soonest) are untouched.
--
-- Throughput: still one serialized /match per tick, bounded by td_match_cron_budget_ok
-- (600 reports/mo). The mapped-event backlog sweeps within that budget over time,
-- interleaved with the remaining sh/vivid gap-fills. Raise the report cap to sweep
-- faster. Rollback: restore the mig 20260619190000 body (candidate = sh/vivid-null only).
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sg_match_map_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
      -- probe events still missing sh/vivid (gap-fill) OR any event never yet
      -- /match'd (one-time TM discovery sweep — mig 20260704170000)
      AND ( a.sh_event_id IS NULL OR a.vivid_event_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM public.td_match_results mr2
                           WHERE mr2.aq_short_event_id = a.aq_short_event_id) )
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
      a.event_date                   ASC     -- 4. soonest
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
END $function$;
