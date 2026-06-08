-- ============================================================================
-- MIG 20260608194500 — SG→TEvo matcher: name + league accept-guard (A1-OPS-23)
--
-- BUG: sg_attempt_event_xref_v3 finds a TEvo candidate by venue + date (±24h) +
-- a LOOSE team-token LIKE, with NO check that the matched event is actually the
-- same opponent/performer/league. The ±24h window + substring LIKE can bind a
-- DIFFERENT event in the same venue/day. Audit (2026-06-08) found 11 live
-- mislinks, e.g.:
--   • "Atlanta Braves at San Francisco Giants"  -> "Athletics at SF Giants"
--   • "Houston Astros at San Francisco Giants"   -> "Detroit Tigers at SF Giants"
--   • "TBD at Colorado Avalanche (NHL)"          -> "TBD at Denver Nuggets (NBA)"  (shared arena)
--   • "Salsa Spectacular ..."                    -> "Los Angeles Philharmonic ..."
-- aq_event_map was already shielded (mig 20260601184500); the SG layer itself
-- was still wrong, so every SG-keyed consumer was affected.
--
-- FIX (mirrors the guards already in backfill_aq_maps):
--   (1) Port aq_name_consistent() + aq_league_consistent() into the matcher's
--       ACCEPT criteria — reject the candidate (return NULL) if the names are
--       inconsistent or the leagues are known-and-different. Both guards are
--       permissive-by-default, so legitimate matches are unaffected.
--   (2) One-time cleanup of the 11 existing mislinks. NOTE: the matcher
--       early-returns an existing seatgeek_event_xref binding BEFORE the guard
--       runs, so the wrong xref rows must be DELETED first — otherwise nulling
--       sg_events_canonical.tevo_event_id alone would just re-bind to the same
--       wrong tevo on the next cron tick. The cleanup is self-selecting (the
--       same NOT aq_name_consistent(...) detector), so it only ever touches
--       genuinely-inconsistent rows.
--
-- Re-matching is left to the normal hourly auto_match_sg_canonical_v3 cron,
-- which now re-evaluates the unbound 11 under the new guard (correct match or
-- leave unmatched — never re-mislink). Not run inline to avoid broad side
-- effects during apply.
--
-- ✅ Already applied to prod  Applied via MCP 2026-06-08.
--    Post-apply verified: mislinked_remaining = 0 (detector), guard live on
--    sg_attempt_event_xref_v3. NOTE: applied without the outer BEGIN/COMMIT
--    (apply_migration manages the transaction); the wrapper is retained below
--    for documentation / db-reset fidelity.
-- ============================================================================

BEGIN;

-- ── (1) Guard the matcher ──────────────────────────────────────────────────
-- Reproduces the live prod body verbatim (pg_get_functiondef 2026-06-08) with
-- only: a v_tevo_name capture + the name/league accept-guard added after the
-- candidate SELECT.
CREATE OR REPLACE FUNCTION public.sg_attempt_event_xref_v3(p_sg_event_id bigint, p_sg_event_name text, p_sg_event_date date, p_sg_datetime_utc timestamp with time zone, p_sg_venue text, p_sg_venue_city text DEFAULT NULL::text, p_sg_venue_state text DEFAULT NULL::text, p_sg_category text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tevo_event_id bigint;
  v_tevo_name     text;          -- A1-OPS-23: candidate name for the consistency guard
  v_existing      bigint;
  v_sg_team_a     text;
  v_sg_team_b     text;
  v_tevo_venue_id bigint;
BEGIN
  IF p_sg_category IN ('Parking','parking')
     OR coalesce(p_sg_venue,'') ILIKE '%parking%'
     OR coalesce(p_sg_event_name,'') ILIKE '%parking%' THEN
    RETURN NULL;
  END IF;

  SELECT tevo_event_id INTO v_existing FROM public.seatgeek_event_xref WHERE sg_event_id = p_sg_event_id LIMIT 1;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;

  v_sg_team_a := trim(split_part(coalesce(p_sg_event_name,''), ' at ', 1));
  v_sg_team_b := trim(split_part(coalesce(p_sg_event_name,''), ' at ', 2));
  IF v_sg_team_b = '' THEN v_sg_team_b := v_sg_team_a; END IF;

  v_tevo_venue_id := public.cross_source_venue_resolve(p_sg_venue, p_sg_venue_city, p_sg_venue_state);

  SELECT e.id, e.name INTO v_tevo_event_id, v_tevo_name
  FROM public.events e
  LEFT JOIN public.event_lifecycle lc ON lc.event_id = e.id
  WHERE
    e.occurs_at_local::timestamptz BETWEEN
      coalesce(p_sg_datetime_utc, p_sg_event_date::timestamptz) - interval '24 hours'
      AND coalesce(p_sg_datetime_utc, p_sg_event_date::timestamptz) + interval '24 hours'
    AND (
      (v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id)
      OR lower(trim(coalesce(e.venue_name,''))) = lower(trim(coalesce(p_sg_venue,'')))
      OR lower(trim(coalesce(e.venue_name,''))) LIKE lower(trim(coalesce(p_sg_venue,''))) || '%'
      OR lower(trim(coalesce(p_sg_venue,''))) LIKE lower(trim(coalesce(e.venue_name,''))) || '%'
    )
    AND (
      (v_sg_team_b <> '' AND (
        lower(coalesce(e.primary_performer_name,'')) LIKE '%' || lower(v_sg_team_b) || '%'
        OR lower(coalesce(e.name,'')) LIKE '%' || lower(v_sg_team_b) || '%'))
      OR
      (v_sg_team_a <> '' AND (
        lower(coalesce(e.primary_performer_name,'')) LIKE '%' || lower(v_sg_team_a) || '%'
        OR lower(coalesce(e.name,'')) LIKE '%' || lower(v_sg_team_a) || '%'))
    )
  ORDER BY
    abs(extract(epoch FROM (e.occurs_at_local::timestamptz - coalesce(p_sg_datetime_utc, p_sg_event_date::timestamptz)))),
    CASE WHEN coalesce(lc.is_active, true) THEN 0 ELSE 1 END,
    CASE WHEN v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id THEN 0 ELSE 1 END
  LIMIT 1;

  -- A1-OPS-23 ACCEPT GUARD: reject a venue+date candidate that bound the wrong
  -- opponent/performer (name) or a known-different league. Both guards are
  -- permissive-by-default (aq_league_consistent returns true unless both leagues
  -- are known and differ; aq_name_consistent returns true for consistent names),
  -- so legitimate matches are unaffected. Mirrors backfill_aq_maps.
  IF v_tevo_event_id IS NOT NULL
     AND ( NOT public.aq_name_consistent(v_tevo_name, p_sg_event_name)
           OR NOT public.aq_league_consistent(v_tevo_event_id, p_sg_category) ) THEN
    v_tevo_event_id := NULL;
  END IF;

  IF v_tevo_event_id IS NOT NULL THEN
    INSERT INTO public.seatgeek_event_xref (
      tevo_event_id, sg_event_id, sg_event_name, sg_event_type,
      sg_event_location, sg_start_data, match_method, match_confidence
    ) VALUES (
      v_tevo_event_id, p_sg_event_id, p_sg_event_name, p_sg_category,
      p_sg_venue,
      coalesce(p_sg_datetime_utc, make_timestamptz(
        EXTRACT(YEAR FROM p_sg_event_date)::int,
        EXTRACT(MONTH FROM p_sg_event_date)::int,
        EXTRACT(DAY FROM p_sg_event_date)::int, 0, 0, 0, 'UTC')),
      'matcher_v3_pm24h', 0.9
    )
    ON CONFLICT (tevo_event_id) DO UPDATE SET
      sg_event_id = EXCLUDED.sg_event_id,
      sg_event_name = EXCLUDED.sg_event_name,
      sg_event_location = EXCLUDED.sg_event_location,
      match_method = 'matcher_v3_pm24h',
      matched_at = NOW();
  END IF;
  RETURN v_tevo_event_id;
END $function$;

-- ── (2) One-time cleanup of the 11 existing mislinks ────────────────────────
-- Self-selecting via the same detector (NOT aq_name_consistent). Delete the
-- wrong xref rows FIRST (the matcher early-returns on an existing xref), then
-- unbind sg_events_canonical so the hourly cron re-evaluates them under the
-- new guard.
DELETE FROM public.seatgeek_event_xref x
USING public.sg_events_canonical sgc
JOIN public.events e ON e.id = sgc.tevo_event_id
WHERE x.sg_event_id = sgc.sg_event_id
  AND sgc.tevo_event_id IS NOT NULL
  AND NOT public.aq_name_consistent(e.name, sgc.sg_event_name);

UPDATE public.sg_events_canonical sgc
SET tevo_event_id    = NULL,
    match_method     = 'a1ops23_unbind',
    match_confidence = NULL,
    matched_at       = NULL,
    updated_at       = now()
FROM public.events e
WHERE e.id = sgc.tevo_event_id
  AND sgc.tevo_event_id IS NOT NULL
  AND NOT public.aq_name_consistent(e.name, sgc.sg_event_name);

COMMIT;
