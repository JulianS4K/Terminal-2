-- ============================================================================
-- Migration 20260609190000 — force-track top-50 SG blind-spots (spine + SG book)
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-06-09
--   (operator-authorized: "do it").
--
-- Lane:     xref+macro (A1 domain) — D0 operator-directed via bot_chat override.
-- Touches:  sg_event_priority_state (W: +force_track,+force_track_since),
--           sg_refresh_force_track (W, fn), sg_listings_poll_tick (W, fn),
--           cron_policy (W), cron (W: sg_force_track_refresh)
-- Pre-reqs: v_sg_blindspot_evo_tracking (migs 20260609170000/180000),
--           collector_band / collector_cadence, cron_should_fire
--
-- WHY (operator): when an event enters the top-50 of the SG-selling/we're-not-in
--   list, give it full market tracking until it drops out of the top-50 (and once
--   owned>0 it leaves the list and the normal owned pipeline keeps tracking it —
--   seamless handoff). "Full market" = all TicketsData platform endpoints
--   (SH/VD/GT/TM/TP) EXCEPT Dice/Eventbrite/AXS — unless the event's PRIMARY
--   ticketing is AXS/Dice/Eventbrite, in which case include that one.
--
-- THIS MIGRATION = PHASE 1 (the spine + the concrete in-our-control gap):
--   (1) force_track lifecycle flag on sg_event_priority_state, maintained by
--       sg_refresh_force_track() against the top-50 view (enter on top-50, drop
--       on exit; owned events fall out of the view → handoff to owned poller).
--   (2) the live SG listings book — turned ON for force-tracked events in
--       sg_listings_poll_tick (today only owned events get it, per the
--       2026-06-08 owned-focus redesign; that is exactly why these blind-spots
--       had SG *sales* but no live book). EVO already tracks these (unlimited).
--
-- PHASE 2 (NOT in this migration — flagged for follow-up): expand TicketsData
--   coverage to the ~35/50 top events that have NO td xref row. That requires
--   per-platform performer-URL resolution (GT/TM/TP allowlists are keyed by
--   platform-specific performer URLs we don't generally have) + reconciling with
--   A1's in-flight TD cadence redesign (TP/TM enqueue disabled in 20260608193000)
--   + TD paid-budget sizing. The Dice/Eventbrite/AXS "unless primary" carve-out
--   also belongs there (those 3 are not integrated at all today).
--
-- ROLLBACK: restore sg_listings_poll_tick to its pre-force_track body;
--   cron.unschedule('sg_force_track_refresh'); DROP FUNCTION sg_refresh_force_track;
--   ALTER TABLE sg_event_priority_state DROP COLUMN force_track, DROP COLUMN force_track_since.
-- ============================================================================

-- 1) Lifecycle flag ----------------------------------------------------------
ALTER TABLE public.sg_event_priority_state
  ADD COLUMN IF NOT EXISTS force_track       boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS force_track_since timestamptz;

COMMENT ON COLUMN public.sg_event_priority_state.force_track IS
  'TRUE while the event is in the top-50 of v_sg_blindspot_evo_tracking (SG selling, we are not in). '
  'Maintained by sg_refresh_force_track(). Promotes the event to full market tracking '
  '(live SG listings book in sg_listings_poll_tick; Phase 2: all TD platforms except Dice/EB/AXS '
  'unless primary). Cleared when it drops out of the top-50; owned events leave the view and the '
  'normal owned pipeline takes over (handoff).';

-- 2) Lifecycle maintainer ----------------------------------------------------
CREATE OR REPLACE FUNCTION public.sg_refresh_force_track()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_added int; v_dropped int; v_total int;
BEGIN
  CREATE TEMP TABLE _ft ON COMMIT DROP AS
    SELECT sg_event_id FROM public.v_sg_blindspot_evo_tracking ORDER BY rank LIMIT 50;

  -- enter: events newly in the top-50
  UPDATE public.sg_event_priority_state s
     SET force_track = true,
         force_track_since = COALESCE(s.force_track_since, now())
   WHERE s.sg_event_id IN (SELECT sg_event_id FROM _ft)
     AND NOT s.force_track;
  GET DIAGNOSTICS v_added = ROW_COUNT;

  -- exit: previously tracked but no longer in the top-50 (incl. those now owned,
  -- which the view excludes → owned poller continues coverage = handoff)
  UPDATE public.sg_event_priority_state s
     SET force_track = false,
         force_track_since = NULL
   WHERE s.force_track
     AND s.sg_event_id NOT IN (SELECT sg_event_id FROM _ft);
  GET DIAGNOSTICS v_dropped = ROW_COUNT;

  SELECT count(*) INTO v_total FROM public.sg_event_priority_state WHERE force_track;
  RETURN jsonb_build_object('tracked', v_total, 'added', v_added,
                            'dropped', v_dropped, 'at', now());
END
$function$;

REVOKE ALL ON FUNCTION public.sg_refresh_force_track() FROM anon, authenticated, public;

-- 3) Turn the live SG book ON for force-tracked events -----------------------
--    Only change vs the prior body: force_track events count as "owned" for
--    BOTH the cadence band (tight horizon intervals) and the owned-kind gate,
--    so the active sg_listings_poll_owned_1min cron (p_owned_kind='owned')
--    picks them up. Everything else is byte-identical.
CREATE OR REPLACE FUNCTION public.sg_listings_poll_tick(p_max integer DEFAULT 20, p_min_remaining integer DEFAULT 3, p_owned_kind text DEFAULT NULL::text, p_rate_mult numeric DEFAULT 1)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_remaining int; r RECORD; v_req bigint; v_now timestamptz := clock_timestamp(); v_count int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
  FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
  WHERE h.headers ? 'ratelimit-remaining' AND h.created > v_now - interval '10 seconds'
  ORDER BY h.id DESC LIMIT 1;
  IF v_remaining IS NOT NULL AND v_remaining < p_min_remaining THEN RETURN 0; END IF;

  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    JOIN LATERAL public.collector_band('SG','listings',
           EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0,
           (coalesce(s.owned_count_last_7d,0) > 0 OR s.force_track)) c ON true
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      AND ( p_owned_kind IS NULL
            OR (coalesce(s.owned_count_last_7d,0) > 0 OR s.force_track) = (p_owned_kind = 'owned') )
      AND ( GREATEST(s.last_polled_listings_at, s.last_fired_listings_at) IS NULL
            OR GREATEST(s.last_polled_listings_at, s.last_fired_listings_at)
               < v_now - make_interval(mins => round(c.required_min * p_rate_mult)::int) )
      AND ( s.last_fired_listings_at IS NULL
            OR s.last_fired_listings_at < v_now - interval '90 seconds' )
    ORDER BY c.required_min ASC,
             GREATEST(s.last_polled_listings_at, s.last_fired_listings_at) ASC NULLS FIRST,
             s.sg_datetime_utc
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_fired_listings_at = v_now, listings_polls_today = listings_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;

-- 4) Gated refresh cron (every 15 min) ---------------------------------------
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_force_track_refresh',
   ARRAY[9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,0],
   15, 30, 96, true,
   'Maintain sg_event_priority_state.force_track = top-50 of v_sg_blindspot_evo_tracking (SG selling, we are not in). Enter on top-50, drop on exit; owned events hand off to the owned poller. Added 2026-06-09 (operator: full market tracking for top-50 blind-spots).')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et = EXCLUDED.peak_hours_et,
      peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = true,
      notes = EXCLUDED.notes,
      updated_at = now();

SELECT cron.schedule('sg_force_track_refresh', '7-59/15 * * * *', $cron$
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_force_track_refresh') THEN RETURN; END IF;
    PERFORM public.sg_refresh_force_track();
  END $body$;
$cron$);

-- 5) Seed the flag immediately so tracking starts now ------------------------
SELECT public.sg_refresh_force_track();
