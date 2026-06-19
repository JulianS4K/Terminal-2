-- ============================================================================
-- Migration 20260619200000 — SG→TEvo matcher: exact-date guard (A1-OPS-24)
--
-- Lane:     xref+macro
-- Touches:  sg_attempt_event_xref_v3 (W, fn), seatgeek_event_xref (W),
--           sg_events_canonical (W), events (R), event_lifecycle (R)
-- Pre-reqs: 20260608194500 (A1-OPS-23 name/league guard must exist),
--           aq_name_consistent(), aq_league_consistent(), cross_source_venue_resolve()
--
-- BUG (event-mapping audit, 2026-06-19): sg_attempt_event_xref_v3 finds a TEvo
-- candidate inside a ±24h window ordered by abs(time-diff). For a MULTI-DATE
-- SERIES (same teams/performer at the same venue on consecutive days — MLB
-- series, playoff rounds, Savannah Bananas residencies, multi-night theater),
-- when the SAME-DATE TEvo event does not yet exist at match time (SG date stale/
-- rescheduled, or TEvo not yet published), the window binds the ADJACENT-day
-- sibling. The A1-OPS-23 name/league guard does NOT catch this — the opponent
-- names ARE consistent; only the calendar date is wrong. And because the matcher
-- early-returns an existing seatgeek_event_xref binding (before any guard runs),
-- the wrong-day bind NEVER self-corrects once the real same-date event appears.
--
-- A read-only sweep of live bindings found 57 OFF-DATE rows. 35 carry the
-- series signature (a same-venue, name-consistent sibling within ±3 days),
-- including egregious mis-binds where the same teams meet again later in the
-- season — e.g. "Tampa Bay Rays at New York Yankees" SG 2026-05-23 bound to the
-- 2026-09-22 game (122 days off), and "St. Louis Cardinals at Cincinnati Reds"
-- SG 2026-05-24 bound to 2026-08-17 (85 days off). The remaining 22 are lone
-- single events off by ±1 local day with NO sibling — plausibly correct
-- (timezone / TBD-placeholder boundary), so they are deliberately left alone.
--
-- FIX:
--   (1) Same-date-first ordering: add a leading ORDER BY key that ranks a
--       candidate on the SG event's own calendar date above any off-date
--       candidate, regardless of the local-as-UTC vs real-UTC time arithmetic
--       that abs(time-diff) is subject to.
--   (2) Off-date SERIES reject: after candidate selection, if the chosen event
--       is NOT on the SG event's date AND a same-venue, name-consistent sibling
--       exists within ±3 days (the series signature), reject the bind (return
--       NULL) and wait for the real same-date event. Permissive for lone events
--       (no sibling) — the ±24h timezone fallback stands, so single-event
--       off-by-one matches are unaffected.
--   (3) One-time corrective sweep — UNBIND-ONLY. Delete the xref row + null
--       sg_events_canonical for the 35 series-signature off-date binds, using
--       the SAME self-selecting detector as the guard. The hourly
--       auto_match_sg_canonical_v3 cron then re-evaluates each under the new
--       guard: a clean same-date sibling -> re-mapped correctly; no same-date
--       home -> left unmapped (never re-mislinked). Unbind-only is deliberate:
--       the xref PK is tevo_event_id with ON CONFLICT DO UPDATE, so writing a
--       re-map directly could STEAL an xref from a target already bound to its
--       own (correct) SG event — observed for 2 of the 12 re-map targets
--       (a doubleheader + a TBD playoff game). Letting the matcher re-bind
--       avoids the steal.
--
-- ⚠️ NOT YET APPLIED — operator-gated (CLAUDE.md §1: CREATE OR REPLACE is DDL;
--    the corrective sweep is UPDATE/DELETE on prod). Author-only commit. Apply
--    via apply_migration after operator review of the dry-run in the PR.
-- ============================================================================

BEGIN;

-- ── (1)+(2) Guard the matcher ──────────────────────────────────────────────
-- Reproduces the live prod body (pg_get_functiondef 2026-06-19) verbatim, with
-- only: a v_cand_date capture, the same-date-first ORDER BY key, and the
-- off-date series reject added after the A1-OPS-23 name/league guard.
CREATE OR REPLACE FUNCTION public.sg_attempt_event_xref_v3(p_sg_event_id bigint, p_sg_event_name text, p_sg_event_date date, p_sg_datetime_utc timestamp with time zone, p_sg_venue text, p_sg_venue_city text DEFAULT NULL::text, p_sg_venue_state text DEFAULT NULL::text, p_sg_category text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tevo_event_id bigint;
  v_tevo_name     text;
  v_existing      bigint;
  v_sg_team_a     text;
  v_sg_team_b     text;
  v_tevo_venue_id bigint;
  v_cand_date     date;          -- A1-OPS-24: chosen candidate's local date for the exact-date guard
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
    -- A1-OPS-24: same-date candidates always outrank off-date ones (robust to the
    -- local-as-UTC vs real-UTC skew that abs(time-diff) alone can be fooled by).
    CASE WHEN e.occurs_at_local::date = coalesce(p_sg_event_date, p_sg_datetime_utc::date) THEN 0 ELSE 1 END,
    abs(extract(epoch FROM (e.occurs_at_local::timestamptz - coalesce(p_sg_datetime_utc, p_sg_event_date::timestamptz)))),
    CASE WHEN coalesce(lc.is_active, true) THEN 0 ELSE 1 END,
    CASE WHEN v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id THEN 0 ELSE 1 END
  LIMIT 1;

  -- A1-OPS-23 ACCEPT GUARD (mirrors backfill_aq_maps; both guards permissive-by-default)
  IF v_tevo_event_id IS NOT NULL
     AND ( NOT public.aq_name_consistent(v_tevo_name, p_sg_event_name)
           OR NOT public.aq_league_consistent(v_tevo_event_id, p_sg_category) ) THEN
    v_tevo_event_id := NULL;
  END IF;

  -- A1-OPS-24 EXACT-DATE GUARD: the ±24h window can bind an adjacent-day game of
  -- a multi-date series (same teams/venue on consecutive days). Because the
  -- matcher early-returns an existing xref, such a wrong-day bind never
  -- self-corrects. Reject an OFF-DATE candidate when a same-venue,
  -- name-consistent SERIES sibling exists within ±3 days — wait unmapped for the
  -- real same-date event rather than mis-bind the wrong game. Permissive for
  -- lone events (no sibling): the ±24h timezone fallback stands.
  IF v_tevo_event_id IS NOT NULL THEN
    SELECT e.occurs_at_local::date INTO v_cand_date FROM public.events e WHERE e.id = v_tevo_event_id;
    IF v_cand_date IS DISTINCT FROM p_sg_event_date
       AND EXISTS (
         SELECT 1 FROM public.events e2
         WHERE e2.id <> v_tevo_event_id
           AND ( (v_tevo_venue_id IS NOT NULL AND e2.venue_id = v_tevo_venue_id)
                 OR lower(trim(coalesce(e2.venue_name,''))) = lower(trim(coalesce(p_sg_venue,''))) )
           AND e2.occurs_at_local::date BETWEEN p_sg_event_date - 3 AND p_sg_event_date + 3
           AND public.aq_name_consistent(e2.name, p_sg_event_name)
       ) THEN
      v_tevo_event_id := NULL;
    END IF;
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

-- ── (3) One-time corrective sweep — UNBIND-ONLY, self-selecting ─────────────
-- Detector = the guard's own signature: OFF-DATE bind WITH a same-venue,
-- name-consistent sibling within ±3 days. Delete the xref FIRST (the matcher
-- early-returns on an existing xref), then null sg_events_canonical so the
-- hourly cron re-binds under the new guard.
DELETE FROM public.seatgeek_event_xref x
USING public.sg_events_canonical sgc
JOIN public.events e ON e.id = sgc.tevo_event_id
WHERE x.sg_event_id = sgc.sg_event_id
  AND sgc.tevo_event_id IS NOT NULL
  AND e.occurs_at_local::date <> sgc.sg_event_date
  AND EXISTS (
    SELECT 1 FROM public.events e2
    WHERE e2.id <> sgc.tevo_event_id
      AND ( e2.venue_id = e.venue_id
            OR lower(trim(coalesce(e2.venue_name,''))) = lower(trim(coalesce(sgc.sg_venue_name,''))) )
      AND e2.occurs_at_local::date BETWEEN sgc.sg_event_date - 3 AND sgc.sg_event_date + 3
      AND public.aq_name_consistent(e2.name, sgc.sg_event_name)
  );

UPDATE public.sg_events_canonical sgc
SET tevo_event_id    = NULL,
    match_method     = 'a1ops24_exactdate_unbind',
    match_confidence = NULL,
    matched_at       = NULL,
    updated_at       = now()
FROM public.events e
WHERE e.id = sgc.tevo_event_id
  AND sgc.tevo_event_id IS NOT NULL
  AND e.occurs_at_local::date <> sgc.sg_event_date
  AND EXISTS (
    SELECT 1 FROM public.events e2
    WHERE e2.id <> sgc.tevo_event_id
      AND ( e2.venue_id = e.venue_id
            OR lower(trim(coalesce(e2.venue_name,''))) = lower(trim(coalesce(sgc.sg_venue_name,''))) )
      AND e2.occurs_at_local::date BETWEEN sgc.sg_event_date - 3 AND sgc.sg_event_date + 3
      AND public.aq_name_consistent(e2.name, sgc.sg_event_name)
  );

COMMIT;
