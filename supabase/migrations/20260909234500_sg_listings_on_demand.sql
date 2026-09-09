-- ============================================================================
-- Migration 20260909234500 — SeatGeek listings ON DEMAND (no poller restart)
--
-- Lane:     A1 (SeatGeek data plane) — on-demand counterpart to the cron poller
-- Touches:  sg_listings_pull_on_demand() (CREATE FUNCTION),
--           sg_listings_on_demand_ready() (CREATE FUNCTION, read-only),
--           writes public.sg_broker_pending (the existing queue table)
--           reads sg_events_canonical, aq_event_map, seatgeek_listings_snapshots
-- Pre-reqs: sg_broker_listings_queue/_process (the existing pair this reuses)
--
-- READ-ONLY UPSTREAM (RULE 2): the only outbound call is net.http_get against
-- brokerdata.seatgeek.com/listings, already an allowlisted read host. Nothing
-- is pushed to SeatGeek; no order, hold, price or inventory mutation exists
-- here or may be added.
--
-- WHY THIS EXISTS. `seatgeek_listings_snapshots` last captured 2026-06-26 --
-- crons 355 `sg_listings_poll_owned_1min`, 236 and 64 are all inactive, so the
-- SeatGeek arm of `s4kcs_sub_candidates()` returns nothing. Operator direction
-- (2026-09-09) is to pull SeatGeek ON DEMAND rather than restart a 4-minute
-- poller across ~4.9k future events. This queues only the events actually asked
-- about, so the SeatGeek arm can be filled for a specific question and then go
-- quiet again.
--
-- ── It reuses the existing pipeline, deliberately ───────────────────────────
-- The enqueue shape is copied from `sg_broker_listings_queue()`: same URL, same
-- `sg_broker_pending(request_id, scope='listings', sg_event_id)` row, so the
-- EXISTING `sg_broker_listings_process()` drains it with no change. Do not add
-- a second drain -- the parser, the dedupe and the column mapping all live in
-- that one function and a copy would drift.
--
-- ⚠ ON DEMAND IS NOT SYNCHRONOUS. pg_net dispatches from a shared background
-- worker whose queue was measured 7,210 deep while this was written, with the
-- newest served response ~180 ids behind a request made at that moment. So the
-- contract is ENQUEUE, then DRAIN A MOMENT LATER -- never "call it and read the
-- results in the same breath". `sg_listings_on_demand_ready()` reports when a
-- batch has actually landed, so a caller polls that instead of guessing.
--
-- ⚠ THE PENDING TABLE HAS A DEAD BACKLOG. `sg_broker_pending` holds 191,110
-- unresolved `listings` rows whose newest request_id is 1,438,508, against a
-- live counter around 14.68 MILLION -- they are 75+ days old and their
-- `net._http_response` rows were pruned long ago. They are harmless to
-- correctness because `sg_broker_listings_process()` INNER JOINs the response
-- table, so a row with no response cannot be selected and cannot consume the
-- LIMIT. They are NOT harmless to cost: every drain sorts past them. Cleaning
-- them is a prod DELETE and therefore an operator decision, not taken here.
--
-- ⚠ THE SEATGEEK TOKEN TRAVELS IN THE URL. SeatGeek's broker API takes
-- `?token=`, so the secret lands in plaintext in `net.http_request_queue.url`
-- and in anything that reads it. That is inherited from the existing
-- `sg_broker_listings_queue()`, not introduced here, but it means the token is
-- readable by anything with access to that table and should be treated as
-- exposed. Flagged to the operator 2026-09-09.
-- ============================================================================

-- ── 1. Enqueue listings pulls for specific events ───────────────────────────
CREATE OR REPLACE FUNCTION public.sg_listings_pull_on_demand(
  p_tevo_event_ids bigint[],
  p_max_events     integer  DEFAULT 25,          -- burst cap IS the rate limiter
  p_freshness      interval DEFAULT interval '30 minutes'
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
  -- The upstream queue returns 0 silently on a missing token; be loud instead.
  IF v_token IS NULL OR v_token = '' THEN
    RAISE EXCEPTION 'SEATGEEK_API_TOKEN is not set — cannot pull SeatGeek listings';
  END IF;

  -- how many of the asked-for events have no SeatGeek id at all
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
      -- prefer the canonical catalogue; fall back to the hub
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
     ORDER BY rs.tevo_event_id
  LOOP
    -- don't burn an API call on an event we already have a fresh book for
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

    -- same row shape sg_broker_listings_queue() writes, so the EXISTING
    -- sg_broker_listings_process() drains it unchanged
    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id)
    VALUES (v_req, 'listings', r.sg_event_id);
    v_q := v_q + 1;
  END LOOP;

  RETURN QUERY SELECT v_q, v_fresh, v_unmap;
END $function$;

COMMENT ON FUNCTION public.sg_listings_pull_on_demand(bigint[],integer,interval) IS
  'Queue SeatGeek listings pulls for specific TEvo events, instead of running '
  'the 4-minute poller (crons 355/236/64, all inactive since 2026-06-26). '
  'Resolves tevo->sg via sg_events_canonical then aq_event_map, skips events '
  'already fresher than p_freshness, and caps the burst at p_max_events (the '
  'burst cap is the rate limiter -- pg_sleep does NOT pace pg_net). Writes the '
  'same sg_broker_pending rows the cron path writes, so the existing '
  'sg_broker_listings_process() drains them with no change -- never add a '
  'second drain. NOT SYNCHRONOUS: pg_net dispatches from a shared worker '
  '(queue measured 7,210 deep), so enqueue, then drain a moment later; poll '
  'sg_listings_on_demand_ready() to see when a batch has landed. RULE 2: GET '
  'only, read-only against brokerdata.seatgeek.com.';

REVOKE ALL ON FUNCTION public.sg_listings_pull_on_demand(bigint[],integer,interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sg_listings_pull_on_demand(bigint[],integer,interval) TO service_role;

-- ── 2. Has the batch landed yet? ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sg_listings_on_demand_ready(
  p_tevo_event_ids bigint[],
  p_since          interval DEFAULT interval '15 minutes'
)
RETURNS TABLE(
  tevo_event_id  bigint,
  sg_event_id    bigint,
  responded      boolean,
  status_code    integer,
  drained        boolean,
  listings_now   bigint,
  captured_at    timestamptz
)
LANGUAGE sql STABLE
SET search_path TO 'public','pg_temp'
AS $function$
  SELECT a.tevo_event_id,
         p.sg_event_id,
         (h.id IS NOT NULL)        AS responded,
         h.status_code,
         (p.resolved_at IS NOT NULL) AS drained,
         (SELECT count(*) FROM public.seatgeek_listings_snapshots s
           WHERE s.sg_event_id = p.sg_event_id
             AND s.captured_at >= now() - p_since) AS listings_now,
         (SELECT max(s.captured_at) FROM public.seatgeek_listings_snapshots s
           WHERE s.sg_event_id = p.sg_event_id)    AS captured_at
    FROM public.sg_broker_pending p
    LEFT JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN LATERAL (
      SELECT c.tevo_event_id FROM public.sg_events_canonical c
       WHERE c.sg_event_id = p.sg_event_id LIMIT 1) a ON TRUE
   WHERE p.scope = 'listings'
     AND p.fired_at >= now() - p_since
     AND (p_tevo_event_ids IS NULL OR a.tevo_event_id = ANY(p_tevo_event_ids))
   ORDER BY p.fired_at DESC;
$function$;

COMMENT ON FUNCTION public.sg_listings_on_demand_ready(bigint[],interval) IS
  'Status of a recent sg_listings_pull_on_demand() batch: did pg_net respond, '
  'with what status, has sg_broker_listings_process() drained it, and how many '
  'listing rows landed. p_since is deliberately short so the 191k-row dead '
  'backlog in sg_broker_pending (request ids from an era 13M lower, responses '
  'long pruned) never appears here.';

REVOKE ALL ON FUNCTION public.sg_listings_on_demand_ready(bigint[],interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sg_listings_on_demand_ready(bigint[],interval) TO authenticated, service_role;
