-- ============================================================
-- SG listings floor-sweep — guaranteed per-event refresh cadence
-- Authored by A1 (a1/td lane) 2026-05-29 per operator directive.
-- ============================================================
-- GOAL: every non-SKIP SeatGeek event refreshed on a floor cadence,
-- capped at <= hourly, FAIRLY (no tier starvation), and self-throttled
-- against the SHARED SeatGeek token (a separate prod program draws on
-- the same ~10 req/8s bucket — see ratelimit-remaining adaptive gate).
--
-- BANDS (derived from sg_event_priority_state.tier + hours_to_event):
--   * <= 7 days out, OR matched (tier NOT IN TRACK_BLINDSPOT/SKIP)  -> 8h interval  (3x/day)
--   * blindspot (tier = TRACK_BLINDSPOT) and > 7 days out           -> 24h interval (1x/day)
--   * SKIP (parking / cancelled / if-necessary / past)              -> excluded
--   Min interval 8h is comfortably under the <= hourly ceiling.
--   (v1 spaces the 3x evenly ~every 8h; "cluster at peak" is a later refinement.)
--
-- REPLACES the two selectors that caused starvation + 429 bursts:
--   - sg_broker_listings_queue      (nearest-8 hammer: 8 events @ ~288/day, the burst source)
--   - sg_priority_poll_tick         (HOT->COLD ordering starved COOL/COLD/blindspot tiers)
-- REUSES the existing processor: sg_broker_listings_process drains sg_broker_pending.
--
-- CADENCE (conservative v1 per operator): */2 x 4 = up to ~2,880 pulls/day.
--   This sits intentionally just under the ~3,526/day full floor — a gentle first
--   step given the 37% 429 + unknown external draw. Ramp to */1 x 5 (~7,200/day)
--   once v_sg_token_budget confirms headroom. Both knobs = one cron reschedule.
--   Fair ordering (last_polled ASC) guarantees no event is perpetually skipped.
--
-- REVERSAL:
--   SELECT cron.unschedule('sg_listings_floor_sweep');
--   DO $$ DECLARE jid int; BEGIN
--     FOR jid IN SELECT jobid FROM cron.job WHERE jobname IN
--       ('sg_broker_listings_queue_5min','sg_broker_listings_queue_5min_peak','sg_priority_poll_tick_5min')
--     LOOP PERFORM cron.alter_job(jid, active := true); END LOOP;
--   END $$;
-- ============================================================

-- 1) Read-only telemetry: live shared-token budget from SG response headers.
--    `ratelimit-remaining` reflects the EXTERNAL prod program's draw too,
--    because it's the same token. This is how we stop guessing.
CREATE OR REPLACE VIEW public.v_sg_token_budget AS
SELECT
  h.id                                          AS response_id,
  p.scope,
  p.sg_event_id,
  (h.headers->>'ratelimit-remaining')::int      AS remaining,
  (h.headers->>'ratelimit-limit')::int          AS limit_total,
  (h.headers->>'x-ratelimit-remaining-10')::int AS remaining_10
FROM public.sg_broker_pending p
JOIN net._http_response h ON h.id = p.request_id
WHERE h.headers ? 'ratelimit-remaining';

COMMENT ON VIEW public.v_sg_token_budget IS
  'Live SeatGeek shared-token budget parsed from broker /listings|/sales response headers (ratelimit-remaining). Reflects the external prod program''s draw. Added 2026-05-29 (sg_listings_floor_sweep).';

-- 2) Fair round-robin floor-sweep selector, adaptive-gated on shared-token budget.
CREATE OR REPLACE FUNCTION public.sg_listings_floor_sweep(
  p_max           int DEFAULT 4,
  p_min_remaining int DEFAULT 3
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  v_token     text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_remaining int;
  r           RECORD;
  v_req       bigint;
  v_now       timestamptz := clock_timestamp();
  v_count     int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;

  -- Adaptive gate: back off only on a FRESH low reading (rate window ~8s).
  -- A STALE low reading must NOT deadlock the sweep — if the latest reading is
  -- older than the window, that window has reset, so we ignore it and fire.
  SELECT (h.headers->>'ratelimit-remaining')::int
    INTO v_remaining
  FROM public.sg_broker_pending p
  JOIN net._http_response h ON h.id = p.request_id
  WHERE h.headers ? 'ratelimit-remaining'
    AND h.created > v_now - interval '10 seconds'
  ORDER BY h.id DESC
  LIMIT 1;

  IF v_remaining IS NOT NULL AND v_remaining < p_min_remaining THEN
    RAISE NOTICE 'sg_listings_floor_sweep: low shared-token budget (remaining=%) — skipping this tick', v_remaining;
    RETURN 0;
  END IF;

  -- Pick the most-OVERDUE due events first (fair; no tier starvation).
  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'   -- skip long-past
      AND (
        s.last_polled_listings_at IS NULL
        OR s.last_polled_listings_at < v_now -
             CASE WHEN s.hours_to_event <= 168 OR s.tier <> 'TRACK_BLINDSPOT'
                  THEN interval '8 hours'     -- near OR matched -> 3x/day
                  ELSE interval '24 hours'    -- blindspot >7d  -> 1x/day
             END
      )
    ORDER BY s.last_polled_listings_at ASC NULLS FIRST
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token
             || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;

    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, v_now);

    UPDATE public.sg_event_priority_state
      SET last_polled_listings_at = v_now,
          listings_polls_today    = listings_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END
$function$;

REVOKE ALL ON FUNCTION public.sg_listings_floor_sweep(int,int) FROM PUBLIC;

COMMENT ON FUNCTION public.sg_listings_floor_sweep(int,int) IS
  'Fair round-robin SG /listings selector. Bands: near(<=7d)/matched=8h(3x/day), blindspot>7d=24h(1x/day), SKIP excluded. Adaptive-gated on ratelimit-remaining. Replaces nearest-8 queue + priority poll tick. 2026-05-29.';

-- 3) Retire the starvation/burst-prone selectors (processor + sales pollers untouched).
--    Disabled (not dropped) so they are trivially reversible.
DO $$
DECLARE jid int;
BEGIN
  FOR jid IN
    SELECT jobid FROM cron.job
    WHERE jobname IN ('sg_broker_listings_queue_5min',
                      'sg_broker_listings_queue_5min_peak',
                      'sg_priority_poll_tick_5min')
  LOOP
    PERFORM cron.alter_job(jid, active := false);
  END LOOP;
END $$;

-- 4) Schedule the fair floor-sweep: every 2 min, small gated bursts of 4 (conservative v1).
SELECT cron.unschedule('sg_listings_floor_sweep')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sg_listings_floor_sweep');

SELECT cron.schedule(
  'sg_listings_floor_sweep',
  '*/2 * * * *',
  $cronbody$
    DO $b$ BEGIN
      IF NOT public.cron_should_fire('sg_listings_floor_sweep') THEN RETURN; END IF;
      PERFORM public.sg_listings_floor_sweep(4, 3);
    END $b$;
  $cronbody$
);

-- Verify (post-apply smoke):
--   SELECT jobname, schedule, active FROM cron.job
--   WHERE jobname IN ('sg_listings_floor_sweep','sg_broker_listings_queue_5min',
--                     'sg_broker_listings_queue_5min_peak','sg_priority_poll_tick_5min');
--   SELECT public.sg_listings_floor_sweep(4,3);          -- one manual tick
--   SELECT * FROM public.v_sg_token_budget ORDER BY response_id DESC LIMIT 5;
