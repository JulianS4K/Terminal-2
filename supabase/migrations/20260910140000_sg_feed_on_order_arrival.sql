-- ============================================================================
-- Migration 20260910140000 — turn the SeatGeek listings feed back on, driven
--                            ONLY by N2S order arrivals
--
-- Lane:     D0 (orders surface) over A1's SeatGeek plane
-- Touches:  sg_listings_pull_on_demand() (canonical guard), one cron.
--           Does NOT re-enable any of SG's broad polling crons.
-- Pre-reqs: 20260910130000
--
-- Upstream: GET brokerdata.seatgeek.com/listings only — a read. RULE 2 holds.
--
-- Operator direction 2026-09-09: "turn on sg feed and only poll when order
-- comes in."
--
-- ── ⚠ THE FEED WAS NOT RATE-LIMITED. IT WAS CRASHING ON A FOREIGN KEY ─────
-- The obvious read of the dead SG listings feed was rate limiting: the
-- listings crons (64, 236, 355, 407) are disabled and there is a disabled job
-- literally named sg_broker_429_health_check_15min sitting next to them. That
-- read is WRONG, and acting on it would have meant "wait for the rate limit to
-- clear" forever.
--
-- Measured instead, live: SeatGeek answers 200 with real listing bodies right
-- now, across 30 requests, with ZERO 429s. The only non-200s were 400
-- "event has expired" for games already under way, which is correct behaviour.
--
-- What actually kills it is sg_broker_listings_process() raising
--   23503 insert or update on "seatgeek_listings_snapshots" violates foreign
--   key "seatgeek_listings_snapshots_sg_event_id_fkey"
-- because that table's sg_event_id REFERENCES sg_events_canonical, and the
-- event is not in it. The processor has no per-row guard, so ONE such event
-- aborts the entire batch: 2 poisoned rows out of 30 took down all 30.
--
-- ── Where the bad sg_event_id comes from ───────────────────────────────────
-- sg_listings_pull_on_demand resolved the id as
--   sg_events_canonical  OR ELSE  aq_event_map.sg_event_id
-- That fallback is the bug. aq_event_map knows SeatGeek ids the canonical
-- mirror has never seen, and a listing for such an id CANNOT be persisted —
-- the FK forbids it. So the fallback bought an id that guarantees a crash on
-- write. The resolved id must now exist in sg_events_canonical; the fallback
-- is kept for events the canonical table maps under a different tevo id, but
-- its result is verified rather than trusted.
--
-- ⚠ THIS FILTERS AT QUEUE TIME, NOT AT WRITE TIME, ON PURPOSE. Skipping the
-- request entirely is strictly better than making it and discarding the
-- answer: it is one less upstream call for a row we could never keep.
--
-- ── "Only poll when an order comes in" ─────────────────────────────────────
-- The broad SG listings crons stay DISABLED — 64 (queue every 4 min), 236
-- (priority process), 355 (owned poll), 407 (catch-up). Nothing here re-enables
-- them, and they should not be re-enabled as a shortcut: they poll on a
-- schedule regardless of demand, which is exactly what was asked against.
--
-- The ONLY thing that queues SG listings now is n2s_pull_all_sources(), which
-- fires on order arrival. This migration adds a PROCESSOR cron, not a queuer:
-- it drains whatever order arrivals put there and does nothing when no orders
-- arrived. Demand-driven end to end.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sg_listings_pull_on_demand(
  p_tevo_event_ids bigint[],
  p_max_events     integer  DEFAULT 25,
  p_freshness      interval DEFAULT '00:30:00'::interval
)
RETURNS TABLE(queued integer, skipped_fresh integer, unmapped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  r       RECORD;
  v_req   bigint;
  v_q     int := 0;
  v_fresh int := 0;
  v_unmap int := 0;
BEGIN
  IF p_tevo_event_ids IS NULL OR cardinality(p_tevo_event_ids) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0; RETURN;
  END IF;
  IF v_token IS NULL OR v_token = '' THEN
    RAISE EXCEPTION 'SEATGEEK_API_TOKEN is not set - cannot pull SeatGeek listings';
  END IF;

  SELECT count(*) INTO v_unmap
    FROM unnest(p_tevo_event_ids) AS t(tevo_event_id)
   WHERE NOT EXISTS (
     SELECT 1 FROM public.sg_events_canonical c WHERE c.tevo_event_id = t.tevo_event_id)
     AND NOT EXISTS (
     SELECT 1 FROM public.aq_event_map a
      WHERE a.tevo_event_id = t.tevo_event_id AND a.sg_event_id IS NOT NULL);

  FOR r IN
    WITH want AS (SELECT DISTINCT x AS tevo_event_id FROM unnest(p_tevo_event_ids) AS x),
    resolved AS (
      SELECT w.tevo_event_id,
             COALESCE(
               (SELECT c.sg_event_id FROM public.sg_events_canonical c
                 WHERE c.tevo_event_id = w.tevo_event_id
                 ORDER BY c.sg_event_id LIMIT 1),
               (SELECT a.sg_event_id FROM public.aq_event_map a
                 WHERE a.tevo_event_id = w.tevo_event_id AND a.sg_event_id IS NOT NULL
                 ORDER BY a.sg_event_id LIMIT 1)
             ) AS sg_event_id
        FROM want w
    )
    SELECT rs.tevo_event_id, rs.sg_event_id,
           EXISTS (SELECT 1 FROM public.seatgeek_listings_snapshots s
                    WHERE s.tevo_event_id = rs.tevo_event_id
                      AND s.captured_at >= now() - p_freshness) AS is_fresh
      FROM resolved rs
     WHERE rs.sg_event_id IS NOT NULL
       -- ⚠ THE RESOLVED ID MUST BE CANONICAL OR THE WRITE CANNOT LAND.
       -- seatgeek_listings_snapshots.sg_event_id REFERENCES sg_events_canonical,
       -- and the aq_event_map fallback above knows ids that table has never
       -- seen. Queuing one guarantees a 23503 on write, and because the
       -- processor has no per-row guard that single row aborts the WHOLE batch.
       -- Verify the fallback's answer; never trust it.
       AND EXISTS (SELECT 1 FROM public.sg_events_canonical c
                    WHERE c.sg_event_id = rs.sg_event_id)
     ORDER BY rs.tevo_event_id
  LOOP
    IF r.is_fresh THEN
      v_fresh := v_fresh + 1;
      CONTINUE;
    END IF;
    EXIT WHEN v_q >= p_max_events;

    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token
             || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;

    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id)
    VALUES (v_req, 'listings', r.sg_event_id);
    v_q := v_q + 1;
  END LOOP;

  RETURN QUERY SELECT v_q, v_fresh, v_unmap;
END $function$;

REVOKE ALL ON FUNCTION public.sg_listings_pull_on_demand(bigint[],integer,interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sg_listings_pull_on_demand(bigint[],integer,interval) TO service_role;

-- Retire the already-queued poison rows. They were fired before the guard
-- existed, their events are not canonical, and their responses can never be
-- persisted — left unresolved they would abort every future batch forever.
UPDATE public.sg_broker_pending p
   SET resolved_at = now(), rows_persisted = 0
 WHERE p.scope = 'listings'
   AND p.resolved_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical c
                    WHERE c.sg_event_id = p.sg_event_id);

-- A PROCESSOR, not a queuer: it drains what order arrivals queued and does
-- nothing when none arrived. The broad SG crons (64, 236, 355, 407) stay off.
SELECT cron.schedule(
  'sg_listings_process_on_demand_2min', '1-59/2 * * * *',
  $cron$ SELECT public.sg_broker_listings_process(50); $cron$
);
