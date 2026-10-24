-- Migration 20261024010220 · level:ops · lane:A1 (data plane — collectors) · writes:_pinned_poll_priority()(new),pinned_listings_poll_tick()(replace) · reads:v_listings_poll_pinned_events,collector_cadence,evo/gt poll state,sg_broker_pending · pre:20261023054000
--
-- ============================================================================
-- Pinned listing polls: near games first, and the GoTickets cap of 55 actually live
--
-- 1. Priority fix. 20261023054000 ranked a never-polled game at 1e9 ("infinitely
--    overdue"), so the ~2,000 never-polled league games — mostly 5–6 months out — took
--    every SeatGeek slot (8/tick, the cap) ahead of games 1–3 days out that had not been
--    polled since 2026-09-27. Measured 2026-10-24 00:50 UTC: the old order's top 8 were
--    all ~3,700 h out; the new order's top 8 are 36–804 h out, last SG poll 27+ days ago.
--
--    priority = overdue / (1 + hours_to_event / 168)
--      overdue = age / band interval (>= 1 for every eligible row); never polled = 10
--    The 1-week divisor makes a game 0 h out worth ~27x one 6 months out at equal
--    overdue, so near games win when demand exceeds the cap (the stated intent of
--    054000), while a never-polled game still beats a just-due one at the same distance.
--    Applies to all three legs; EVO / GT are under their caps, so it only reorders.
--
-- 2. GoTickets cap 55. 054000 was applied to prod at 2026-10-23 21:39 with the 70
--    default; the 55 edit (commit 1a71820) landed in the file afterwards and never ran.
--    GoTickets returns 429 above 60 catalogue requests/minute and the tick fires as one
--    burst, so 55 keeps GT under 60.
--
-- Already applied to prod · via MCP 2026-10-24 (schema_migrations 20261024073308).
-- Verified 2026-10-24 20:41 UTC: 0 never-polled SG games (was 2,026), oldest SG poll
-- 23 h (was 27 days for games 1–3 days out); 394 ticks, 1 failure, 4.2 s avg.
--
-- ROLLBACK: re-run the function block of 20261023054000 (restores 1e9-first ordering).
-- ============================================================================

SET LOCAL lock_timeout = '10s';

-- Higher = poll sooner. NULL last-poll = never polled.
CREATE OR REPLACE FUNCTION public._pinned_poll_priority(
  p_last_polled timestamptz, p_required_min integer, p_hours_to_event numeric)
RETURNS numeric
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = public, pg_temp
AS $$
  SELECT (CASE WHEN p_last_polled IS NULL THEN 10::numeric
               ELSE (extract(epoch FROM now() - p_last_polled) / 60.0)::numeric
                    / nullif(p_required_min, 0) END)
         / (1 + greatest(coalesce(p_hours_to_event, 0), 0) / 168.0)
$$;

CREATE OR REPLACE FUNCTION public.pinned_listings_poll_tick(
  p_max_evo integer DEFAULT 70, p_max_gt integer DEFAULT 55, p_max_sg integer DEFAULT 8)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r           RECORD;
  v_evo       integer := 0;
  v_gt        integer := 0;
  v_sg        integer := 0;
  v_req       bigint;
  v_gt_token  text;
  v_sg_token  text;
  v_remaining integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: pinned_listings_poll_tick is service-only' USING ERRCODE='42501';
  END IF;

  -- ---- EVO (most overdue first: age / band interval) -------------------------
  FOR r IN
    SELECT v.tevo_event_id
      FROM public.v_listings_poll_pinned_events v
      LEFT JOIN public.evo_listings_poll_state ps ON ps.event_id = v.tevo_event_id
      JOIN LATERAL public.collector_band('EVO', 'listings', v.hours_to_event) c ON true
     WHERE 'evo' = ANY (v.sources)
       AND (ps.last_polled_listings_at IS NULL
            OR ps.last_polled_listings_at < now() - make_interval(mins => c.required_min))
     ORDER BY public._pinned_poll_priority(ps.last_polled_listings_at, c.required_min, v.hours_to_event) DESC NULLS LAST,
              v.hours_to_event
     LIMIT p_max_evo
  LOOP
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id=' || r.tevo_event_id::text,
      '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state (event_id, last_polled_listings_at, listings_polls_today, budget_day)
    VALUES (r.tevo_event_id, now(), 1, current_date)
    ON CONFLICT (event_id) DO UPDATE SET
      last_polled_listings_at = now(),
      listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                  THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
      budget_day = current_date;
    v_evo := v_evo + 1;
  END LOOP;

  -- ---- GoTickets --------------------------------------------------------------
  v_gt_token := public._gotickets_pro_token();
  FOR r IN
    SELECT gt.gt_event_id, v.tevo_event_id
      FROM public.v_listings_poll_pinned_events v
      JOIN public.gotickets_event gt ON gt.tevo_event_id = v.tevo_event_id AND gt.status = 'AS_SCHEDULED'
      LEFT JOIN public.gt_listings_poll_state gps ON gps.gt_event_id = gt.gt_event_id
      JOIN LATERAL public.collector_band('GT', 'listings', v.hours_to_event) c ON true
     WHERE 'gt' = ANY (v.sources)
       AND coalesce(gt.name, '') !~* 'parking'
       AND (gps.quarantined_until IS NULL OR gps.quarantined_until < now())
       AND (gps.cold_until IS NULL OR gps.cold_until < now())
       AND (gps.last_polled_listings_at IS NULL
            OR gps.last_polled_listings_at < now() - make_interval(mins => c.required_min))
     ORDER BY public._pinned_poll_priority(gps.last_polled_listings_at, c.required_min, v.hours_to_event) DESC NULLS LAST,
              v.hours_to_event
     LIMIT p_max_gt
  LOOP
    SELECT net.http_get(
      url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
      headers := jsonb_build_object('X-Broker-Api-Token', v_gt_token, 'Accept', 'application/json'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.gt_listings_inflight (request_id, gt_event_id, tevo_event_id, fired_at)
    VALUES (v_req, r.gt_event_id, r.tevo_event_id, now());
    INSERT INTO public.gt_listings_poll_state (gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
    VALUES (r.gt_event_id, now(), 1, current_date)
    ON CONFLICT (gt_event_id) DO UPDATE SET
      last_polled_listings_at = now(),
      listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                  THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
      budget_day = current_date;
    v_gt := v_gt + 1;
  END LOOP;

  -- ---- SeatGeek (shared token: back off when it is nearly spent) -------------
  v_sg_token := public.get_app_secret('SEATGEEK_API_TOKEN');
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
    FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
   WHERE h.headers ? 'ratelimit-remaining' AND h.created > now() - interval '10 seconds'
   ORDER BY h.id DESC LIMIT 1;
  IF coalesce(v_sg_token, '') <> '' AND coalesce(v_remaining, 99) >= 3 THEN
    FOR r IN
      SELECT m.sg_event_id
        FROM public.v_listings_poll_pinned_events v
        JOIN LATERAL (SELECT min(c.sg_event_id) AS sg_event_id FROM public.sg_events_canonical c
                       WHERE c.tevo_event_id = v.tevo_event_id) m ON m.sg_event_id IS NOT NULL
        JOIN LATERAL public.collector_band('SG', 'listings', v.hours_to_event, v.sg_owned) c ON true
        LEFT JOIN LATERAL (SELECT max(p.fired_at) AS last_fired FROM public.sg_broker_pending p
                            WHERE p.sg_event_id = m.sg_event_id AND p.scope = 'listings') bp ON true
       WHERE 'sg' = ANY (v.sources)
         AND (bp.last_fired IS NULL OR bp.last_fired < now() - make_interval(mins => c.required_min))
       ORDER BY public._pinned_poll_priority(bp.last_fired, c.required_min, v.hours_to_event) DESC NULLS LAST,
              v.hours_to_event
       LIMIT p_max_sg
    LOOP
      SELECT net.http_get(
        url := 'https://brokerdata.seatgeek.com/listings?token=' || v_sg_token || '&event_id=' || r.sg_event_id::text,
        timeout_milliseconds := 30000) INTO v_req;
      INSERT INTO public.sg_broker_pending (sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, now());
      v_sg := v_sg + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('evo', v_evo, 'gt', v_gt, 'sg', v_sg, 'sg_ratelimit_remaining', v_remaining);
END $$;

REVOKE ALL ON FUNCTION public._pinned_poll_priority(timestamptz, integer, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._pinned_poll_priority(timestamptz, integer, numeric) TO service_role;
REVOKE ALL ON FUNCTION public.pinned_listings_poll_tick(integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pinned_listings_poll_tick(integer, integer, integer) TO service_role;

-- ============================================================================
-- VERIFY: SELECT pg_get_function_arguments('public.pinned_listings_poll_tick(integer,integer,integer)'::regprocedure);
--           -- p_max_evo integer DEFAULT 70, p_max_gt integer DEFAULT 55, p_max_sg integer DEFAULT 8
--         SG fires in the next 10 min should be mostly games < 30 days out while the
--         never-polled backlog drains (sg_broker_pending JOIN sg_events_canonical).
-- ============================================================================
