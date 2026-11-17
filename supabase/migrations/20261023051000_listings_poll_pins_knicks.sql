-- Migration 20261023051000 · level:ops · lane:A1 (data plane — collectors) · writes:listings_poll_pins(new),v_listings_poll_pinned_events(new),pinned_listings_poll_tick()(new),cron:pinned_listings_poll_2min,cron 629/639 active · reads:events,gotickets_event,sg_events_canonical,collector_cadence · pre:20261023050000,20260917030000
--
-- ============================================================================
-- Migration 20261023051000 — pinned listing polls: every Knicks home game on
--   EVO + GoTickets + SeatGeek at the collector_cadence frequencies
--
-- Operator 2026-10-23: "start polling listings for all Knicks home games using
-- evo, gotix and sg using our new frequencies".
--
-- The fleet pollers (321 EVO, 628 GT, 355 SG) stay OFF — the operator's earlier
-- "don't resume evo" still holds for the broad scope. A pin is an explicit
-- (performer, venue) the operator asked for; only pinned events are polled here.
--
--   listings_poll_pins           one row per pin; sources ⊆ {evo,gt,sg}; enabled flag.
--                                Seeded: knicks_home = performer 16303 at Madison Square
--                                Garden (excludes the Westchester G-League team, 45000).
--   v_listings_poll_pinned_events upcoming events matching an enabled pin (+ hours to event).
--   pinned_listings_poll_tick(p_max_evo, p_max_gt, p_max_sg)
--     EVO  collect-listings edge fn (GET-only upstream), clock = evo_listings_poll_state,
--          band = collector_band('EVO','listings',h)
--     GT   GET /events/{id}/listings → gt_listings_inflight (drained by cron 629),
--          clock = gt_listings_poll_state, band = collector_band('GT','listings',h)
--     SG   GET brokerdata /listings → sg_broker_pending (processed by cron 639),
--          clock = last sg_broker_pending fire, band = collector_band('SG','listings',h,true)
--          (a pin is a tracked event → the 'owned' SG cadence); skipped when the shared
--          SG token reports < 3 requests remaining. SG needs an sg_events_canonical row.
--   cron pinned_listings_poll_2min; activates 629 (GT drain) and 639 (SG processor),
--   which only see what this tick fires while the fleet pollers are off.
--
-- Add another team: INSERT INTO public.listings_poll_pins (pin_key, performer_id, venue_name, note) VALUES (...).
-- Stop: set enabled = false on the pin (or cron.alter_job on pinned_listings_poll_2min).
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.listings_poll_pins (
  pin_key       text        PRIMARY KEY,
  performer_id  bigint      NOT NULL,
  venue_name    text,
  sources       text[]      NOT NULL DEFAULT ARRAY['evo','gt','sg']
                            CHECK (sources <@ ARRAY['evo','gt','sg']),
  enabled       boolean     NOT NULL DEFAULT true,
  note          text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.listings_poll_pins IS
  'Operator-pinned (performer, venue) listing polls on EVO/GT/SG at collector_cadence frequencies, independent of the fleet pollers (mig 20261023051000).';
ALTER TABLE public.listings_poll_pins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.listings_poll_pins FROM anon, authenticated;

INSERT INTO public.listings_poll_pins (pin_key, performer_id, venue_name, note)
VALUES ('knicks_home', 16303, 'Madison Square Garden',
        'Operator 2026-10-23: "start polling listings for all Knicks home games using evo, gotix and sg using our new frequencies".')
ON CONFLICT (pin_key) DO NOTHING;

CREATE OR REPLACE VIEW public.v_listings_poll_pinned_events
WITH (security_invoker = true) AS
SELECT DISTINCT ON (e.id)
       e.id AS tevo_event_id,
       p.pin_key,
       p.sources,
       e.occurs_at_local::timestamptz AS occurs_at,
       (EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now())) / 3600.0)::numeric AS hours_to_event
  FROM public.listings_poll_pins p
  JOIN public.events e
    ON e.primary_performer_id = p.performer_id
   AND (p.venue_name IS NULL OR e.venue_name = p.venue_name)
 WHERE p.enabled
   AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
   AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
   AND coalesce(e.state, 'shown') <> 'ignored'
 ORDER BY e.id, p.pin_key;
REVOKE ALL ON public.v_listings_poll_pinned_events FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.pinned_listings_poll_tick(
  p_max_evo integer DEFAULT 6, p_max_gt integer DEFAULT 6, p_max_sg integer DEFAULT 2)
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

  -- ---- EVO ----------------------------------------------------------------
  FOR r IN
    SELECT v.tevo_event_id
      FROM public.v_listings_poll_pinned_events v
      LEFT JOIN public.evo_listings_poll_state ps ON ps.event_id = v.tevo_event_id
      JOIN LATERAL public.collector_band('EVO', 'listings', v.hours_to_event) c ON true
     WHERE 'evo' = ANY (v.sources)
       AND (ps.last_polled_listings_at IS NULL
            OR ps.last_polled_listings_at < now() - make_interval(mins => c.required_min))
     ORDER BY ps.last_polled_listings_at ASC NULLS FIRST
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

  -- ---- GoTickets ----------------------------------------------------------
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
     ORDER BY gps.last_polled_listings_at ASC NULLS FIRST
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

  -- ---- SeatGeek (shared token: back off when it is nearly spent) -----------
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
        JOIN LATERAL public.collector_band('SG', 'listings', v.hours_to_event, true) c ON true
        LEFT JOIN LATERAL (SELECT max(p.fired_at) AS last_fired FROM public.sg_broker_pending p
                            WHERE p.sg_event_id = m.sg_event_id AND p.scope = 'listings') bp ON true
       WHERE 'sg' = ANY (v.sources)
         AND (bp.last_fired IS NULL OR bp.last_fired < now() - make_interval(mins => c.required_min))
       ORDER BY bp.last_fired ASC NULLS FIRST
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
REVOKE ALL ON FUNCTION public.pinned_listings_poll_tick(integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pinned_listings_poll_tick(integer, integer, integer) TO service_role;

SELECT cron.schedule('pinned_listings_poll_2min', '*/2 * * * *',
  $c$DO $b$ BEGIN IF NOT public.cron_try_lock('pinned_listings_poll') THEN RETURN; END IF; PERFORM public.pinned_listings_poll_tick(); END $b$;$c$);

-- GT drain + SG processor: they turn fired requests into rows.
SELECT cron.alter_job(job_id := 629, active := true);
SELECT cron.alter_job(job_id := 639, active := true);

-- ============================================================================
-- VERIFY (after ~10 min):
--   SELECT * FROM public.v_listings_poll_pinned_events ORDER BY occurs_at;
--   SELECT max(captured_at) FROM public.listings_snapshots WHERE event_id = 3465614;          -- EVO
--   SELECT max(captured_at) FROM public.gotickets_listings_snapshots WHERE tevo_event_id = 3465614; -- GT
--   SELECT max(captured_at) FROM public.seatgeek_listings_snapshots WHERE sg_event_id = 18494848;  -- SG
-- ROLLBACK: SELECT cron.unschedule('pinned_listings_poll_2min'); cron.alter_job 629/639 active := false.
-- ============================================================================
