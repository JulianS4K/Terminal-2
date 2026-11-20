-- Migration 20260831201604 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "gt_antiphase_fix_rate_neutral" (version 20260831201604) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

-- Migration 20260831211000 — correct the GT phase-lock to be genuinely rate-neutral
-- Supersedes the rule shipped in 20260831210000, which was defective.
CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(p_max integer DEFAULT 120)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_n int := 0; v_req bigint; v_token text;
  v_daily_cap int := 1000000;
  us_states text[] := ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC'];
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  IF (SELECT coalesce(sum(listings_polls_today),0) FROM public.gt_listings_poll_state
        WHERE budget_day = current_date) >= v_daily_cap THEN
    RETURN 0;
  END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      SELECT g.gt_event_id, g.tevo_event_id, g.event_time_utc,
             EXTRACT(epoch FROM (g.event_time_utc - now()))/3600.0 AS hte,
             ps.last_polled_listings_at, ps.event_median_price,
             evo.last_polled_listings_at AS evo_last_polled,
             (e.id IS NOT NULL AND EXISTS (
                SELECT 1 FROM public.performer_zones pz
                 WHERE pz.performer_id = e.primary_performer_id
                   AND pz.venue_id = e.venue_id AND pz.source='curated')) AS has_curated_zone
      FROM public.gotickets_event g
      LEFT JOIN public.events e ON e.id = g.tevo_event_id
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
      LEFT JOIN public.evo_listings_poll_state evo ON evo.event_id = g.tevo_event_id
      WHERE g.status = 'AS_SCHEDULED'
        AND g.event_time_utc > now() - interval '3 hours'
        AND upper(btrim(coalesce(g.venue_state,''))) = ANY(us_states)
        AND coalesce(g.name,'')       !~* 'parking'
        AND coalesce(g.venue_name,'')  !~* 'parking'
        AND coalesce(g.performer,'')   !~* 'parking'
        AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
        AND (ps.cold_until       IS NULL OR ps.cold_until       < now())
        AND g.tevo_event_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM public.evo_listings_poll_state v
                     WHERE v.event_id = g.tevo_event_id)
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at, ev.evo_last_polled,
             CASE WHEN ev.has_curated_zone
                       AND ev.event_time_utc >= now() + interval '14 days'
                       AND coalesce(ev.event_median_price, 9999) >= 25 THEN 10
                  ELSE (SELECT required_min FROM public.collector_band('GT','listings', ev.hte)) END AS req_min
      FROM ev
    )
    SELECT gt_event_id, tevo_event_id FROM due
    WHERE
      -- never polled: seed immediately
      last_polled_listings_at IS NULL
      -- INTERLEAVE: exactly one GT poll per EVO poll, at least half a band
      -- interval after it. Rate equals EVO's rate, never exceeds it, and the
      -- phase converges to the midpoint instead of being frozen wherever it began.
      OR ( evo_last_polled IS NOT NULL
           AND last_polled_listings_at < evo_last_polled
           AND now() >= evo_last_polled + make_interval(mins => GREATEST((req_min / 2)::int, 1)) )
      -- EVO absent for this event: fall back to GT's own band
      OR ( evo_last_polled IS NULL
           AND last_polled_listings_at < now() - make_interval(mins => req_min) )
      -- EVO stalled: never let GT starve behind a dead metronome
      OR ( last_polled_listings_at < now() - make_interval(mins => req_min * 2) )
    ORDER BY last_polled_listings_at NULLS FIRST
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
      headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept','application/json'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.gt_listings_inflight(request_id, gt_event_id, tevo_event_id, fired_at)
      VALUES (v_req, r.gt_event_id, r.tevo_event_id, now());
    INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.gt_event_id, now(), 1, current_date)
      ON CONFLICT (gt_event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

COMMENT ON FUNCTION public.gt_listings_poll_tick(int) IS
  'GoTickets listings poll tick. Scoped to the EVO poll set (mig 20260831190000). Phase-locked to EVO: one GT poll per EVO poll, at least half a band interval after it, so the two interleave without GT ever exceeding EVO''s rate (mig 20260831211000, correcting the rate-inflating 0.8*I rule in 20260831210000). Falls back to GT''s own band when EVO has no clock, and to 2*band if EVO stalls.';
;
