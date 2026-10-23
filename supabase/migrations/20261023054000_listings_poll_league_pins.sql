-- Migration 20261023054000 · level:ops · lane:A1 (data plane — collectors) · writes:listings_poll_league_pins(new),index sg_broker_pending_event_fired_idx,listings_poll_pins.sg_owned_cadence(new col),v_listings_poll_pinned_events(replace),pinned_listings_poll_tick()(replace) · reads:events,performer_espn_team_xref,collector_cadence · pre:20261023051000
--
-- ============================================================================
-- Migration 20261023054000 — pinned listing polls: every MLB, NFL, NBA and NHL game
--   on EVO + GoTickets + SeatGeek
--
-- Operator 2026-10-23: "Start polling MLB, NFL, NBA and NHL games for the 3 sources".
--
--   listings_poll_league_pins   one row per league: a game is in the league when its primary
--                               performer is a team in performer_espn_team_xref for it (so
--                               every game is caught once, at the home team). Seeded MLB,
--                               NFL, NBA, NHL. Scope 2026-10-23: 4,970 games (MLB 2,387 incl.
--                               the 2027 schedule, NBA 1,244, NHL 1,177, NFL 162).
--   listings_poll_pins.sg_owned_cadence  team pins (Knicks) keep the tracked/'owned' SG
--                               cadence; league pins use the non-owned SG cadence (daily), so
--                               the shared SeatGeek token is not flooded.
--   v_listings_poll_pinned_events  team pins ∪ league pins; a game in both keeps the team
--                               pin's SG cadence. New trailing column sg_owned.
--   pinned_listings_poll_tick   most-overdue-first (overdue = age / band interval) instead of
--                               oldest-first, so near games win when demand exceeds the cap;
--                               caps 70 EVO / 70 GT / 8 SG per 2-min tick.
--
-- Expected load (collector_cadence bands × games per band, 2026-10-23): ~45 k EVO and
-- ~40 k GT polls/day (~30/min each; caps allow 35/min), ~5 k SG/day (~3.5/min, token limit
-- ≈ 30/min shared). Comparable to the fleet poller before the 2026-09-17 scope gate.
-- Stop a league: UPDATE public.listings_poll_league_pins SET enabled = false WHERE league = 'MLB';
-- ============================================================================

SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.listings_poll_league_pins (
  league            text        PRIMARY KEY,
  sources           text[]      NOT NULL DEFAULT ARRAY['evo','gt','sg']
                                CHECK (sources <@ ARRAY['evo','gt','sg']),
  sg_owned_cadence  boolean     NOT NULL DEFAULT false,
  enabled           boolean     NOT NULL DEFAULT true,
  note              text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.listings_poll_league_pins IS
  'Operator-pinned leagues: every game whose primary performer is a team of the league (performer_espn_team_xref) is polled on EVO/GT/SG at collector_cadence frequencies (mig 20261023054000).';
ALTER TABLE public.listings_poll_league_pins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.listings_poll_league_pins FROM anon, authenticated;

INSERT INTO public.listings_poll_league_pins (league, note)
SELECT l, 'Operator 2026-10-23: "Start polling MLB, NFL, NBA and NHL games for the 3 sources".'
  FROM unnest(ARRAY['MLB','NFL','NBA','NHL']) AS l
ON CONFLICT (league) DO NOTHING;

-- The SG leg reads each game's last fire; sg_broker_pending (484 k rows) had no sg_event_id index.
CREATE INDEX IF NOT EXISTS sg_broker_pending_event_fired_idx
  ON public.sg_broker_pending (sg_event_id, fired_at DESC) WHERE scope = 'listings';

ALTER TABLE public.listings_poll_pins
  ADD COLUMN IF NOT EXISTS sg_owned_cadence boolean NOT NULL DEFAULT true;

CREATE OR REPLACE VIEW public.v_listings_poll_pinned_events
WITH (security_invoker = true) AS
SELECT DISTINCT ON (u.tevo_event_id)
       u.tevo_event_id, u.pin_key, u.sources, u.occurs_at, u.hours_to_event, u.sg_owned
  FROM (
    SELECT e.id AS tevo_event_id, p.pin_key, p.sources,
           e.occurs_at_local::timestamptz AS occurs_at,
           (EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now())) / 3600.0)::numeric AS hours_to_event,
           p.sg_owned_cadence AS sg_owned
      FROM public.listings_poll_pins p
      JOIN public.events e
        ON e.primary_performer_id = p.performer_id
       AND (p.venue_name IS NULL OR e.venue_name = p.venue_name)
     WHERE p.enabled
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
       AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
       AND coalesce(e.state, 'shown') <> 'ignored'
    UNION ALL
    SELECT e.id, 'league:' || lp.league, lp.sources,
           e.occurs_at_local::timestamptz,
           (EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now())) / 3600.0)::numeric,
           lp.sg_owned_cadence
      FROM public.listings_poll_league_pins lp
      JOIN public.performer_espn_team_xref x ON upper(x.espn_league) = lp.league
      JOIN public.events e ON e.primary_performer_id = x.tevo_performer_id
     WHERE lp.enabled
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
       AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
       AND coalesce(e.state, 'shown') <> 'ignored'
  ) u
 ORDER BY u.tevo_event_id, u.sg_owned DESC, u.pin_key;
REVOKE ALL ON public.v_listings_poll_pinned_events FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.pinned_listings_poll_tick(
  p_max_evo integer DEFAULT 70, p_max_gt integer DEFAULT 70, p_max_sg integer DEFAULT 8)
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
     ORDER BY CASE WHEN ps.last_polled_listings_at IS NULL THEN 1e9
                   ELSE extract(epoch FROM now() - ps.last_polled_listings_at) / 60.0
                        / nullif(c.required_min, 0) END DESC,
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
     ORDER BY CASE WHEN gps.last_polled_listings_at IS NULL THEN 1e9
                   ELSE extract(epoch FROM now() - gps.last_polled_listings_at) / 60.0
                        / nullif(c.required_min, 0) END DESC,
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
       ORDER BY CASE WHEN bp.last_fired IS NULL THEN 1e9
                     ELSE extract(epoch FROM now() - bp.last_fired) / 60.0
                          / nullif(c.required_min, 0) END DESC,
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

-- ============================================================================
-- VERIFY: SELECT pin_key, count(*) FROM public.v_listings_poll_pinned_events GROUP BY 1;
--         SELECT public.pinned_listings_poll_tick();   -- {"evo":70,"gt":70,"sg":8,...} while catching up
-- ROLLBACK: UPDATE public.listings_poll_league_pins SET enabled = false;  (team pins unaffected)
-- ============================================================================
