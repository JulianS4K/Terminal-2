-- Migration 20260517250000 · lane:A1 · writes:auto_match_sg_canonical+sg_attempt_event_xref+trg_sgec_to_seatgeek_event_xref+seatgeek_event_xref+sg_events_canonical · reads:sg_events_canonical · pre:20260517240000 · auth:operator-approved 2026-05-17
--
-- A1 — parking-bridge pollution fix (bot_chat #293 from D0).
--
-- BACKGROUND
-- ---------
-- Operator caught: tevo_event_id 3348214 (Spurs Game 3) mapped to SG 18068272
-- which is the *Parking* event ("Frost Bank Center Parking"), not the real
-- game (SG 18068270 at "Frost Bank Center"). Symptom: PR #196 SG Listings /
-- SG Sales tabs surface parking lot inventory instead of seat inventory for
-- the affected events.
--
-- SCOPE (pre-cleanup, 2026-05-17 22:30 UTC)
-- -----------------------------------------
--   public.sg_events_canonical: 738 parking rows, 531 with tevo_event_id set
--   public.seatgeek_event_xref: 519 polluted xref rows
--     all match_method=auto_canonical_loop, conf 0.90
--   Of those 519:
--     515 have a clean non-parking SG sibling on same date+venue
--         and that clean sibling is NOT yet in xref → UPDATE swap
--     1   has a clean sibling already in xref → DELETE the parking row
--     3   are parking-only orphans → DELETE the parking row
--
-- ROOT CAUSE
-- ----------
-- D0's initial diagnosis ("no new pollution accruing") was incorrect. The
-- active cron cross_source_match_tick_30min (@ :09,:39) calls
-- cross_source_match_tick() → sg_canonical_auto_match_tick() FIRST,
-- which calls auto_match_sg_canonical() (v1, NO parking filter), THEN
-- auto_match_sg_canonical_v3() (v3, WITH parking filter). v1 grabs the
-- rows first so v3 never sees them. New pollution was accruing every 30
-- minutes until this migration's Part 1 stopped the bleeding.
--
-- THREE-PART FIX
-- --------------
-- Part 1: stop the bleeding. Add parking guards to:
--   - auto_match_sg_canonical()       — exclude parking in loop predicate
--   - sg_attempt_event_xref()         — return NULL early if parking
--   - trg_sgec_to_seatgeek_event_xref — defense-in-depth: trigger skips parking
--
-- Part 2: NULL out sg_events_canonical.tevo_event_id on parking rows.
--         Otherwise the trigger re-mirrors them to xref on any update.
--
-- Part 3: Clean seatgeek_event_xref:
--   3a UPDATE polluted rows to point at the clean sibling (515 cases)
--   3b DELETE catch-all for the remaining 4 + any leakage during txn

-- ============================================================
-- Part 1a: auto_match_sg_canonical() — skip parking in iter loop
-- ============================================================
CREATE OR REPLACE FUNCTION public.auto_match_sg_canonical()
 RETURNS TABLE(attempted integer, newly_matched integer, still_unmatched integer, needs_tevo_search integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_match bigint;
  v_attempted int := 0;
  v_matched int := 0;
  v_unmatched int := 0;
BEGIN
  FOR r IN
    SELECT sg_event_id, sg_event_name, sg_event_date, sg_venue_name
    FROM sg_events_canonical
    WHERE tevo_event_id IS NULL
      AND (sg_event_date IS NULL OR sg_event_date >= current_date - 30)
      -- A1 parking guard 2026-05-17: never auto-match parking pseudo-events.
      -- TEvo merges parking into the main listing; SG splits them out.
      AND coalesce(sg_event_name, '') NOT ILIKE '%parking%'
      AND coalesce(sg_venue_name, '') NOT ILIKE '%parking%'
  LOOP
    v_attempted := v_attempted + 1;
    v_match := sg_attempt_event_xref(
      r.sg_event_id, r.sg_event_name, r.sg_event_date, r.sg_venue_name
    );
    IF v_match IS NOT NULL THEN
      UPDATE sg_events_canonical SET
        tevo_event_id = v_match,
        match_method = 'auto_canonical_loop',
        match_confidence = 0.9,
        matched_at = now(),
        updated_at = now()
      WHERE sg_event_id = r.sg_event_id;
      v_matched := v_matched + 1;
    ELSE
      v_unmatched := v_unmatched + 1;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_attempted, v_matched, v_unmatched,
    (SELECT count(*)::int FROM sg_events_canonical WHERE tevo_event_id IS NULL);
END;
$function$;

-- ============================================================
-- Part 1b: sg_attempt_event_xref() — return NULL early if parking
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_attempt_event_xref(p_sg_event_id bigint, p_sg_event_name text, p_sg_event_date date, p_sg_venue text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_tevo_event_id bigint;
  v_existing      bigint;
  v_sg_team_a     text;
  v_sg_team_b     text;
BEGIN
  -- A1 parking guard 2026-05-17: never bridge parking pseudo-events.
  IF coalesce(p_sg_event_name, '') ILIKE '%parking%'
     OR coalesce(p_sg_venue, '')      ILIKE '%parking%' THEN
    RETURN NULL;
  END IF;

  SELECT tevo_event_id INTO v_existing
  FROM seatgeek_event_xref WHERE sg_event_id = p_sg_event_id LIMIT 1;
  IF v_existing IS NOT NULL THEN
    UPDATE seatgeek_event_xref
       SET sg_event_name = COALESCE(p_sg_event_name, sg_event_name),
           sg_event_location = COALESCE(p_sg_venue, sg_event_location)
     WHERE sg_event_id = p_sg_event_id;
    RETURN v_existing;
  END IF;

  v_sg_team_a := trim(split_part(COALESCE(p_sg_event_name, ''), ' at ', 1));
  v_sg_team_b := trim(split_part(COALESCE(p_sg_event_name, ''), ' at ', 2));
  IF v_sg_team_b = '' THEN v_sg_team_b := v_sg_team_a; END IF;

  SELECT e.id INTO v_tevo_event_id
  FROM events e
  LEFT JOIN event_lifecycle lc ON lc.event_id = e.id
  WHERE e.occurs_at_local::date = p_sg_event_date
    AND (
      lower(trim(e.venue_name)) = lower(trim(COALESCE(p_sg_venue, '')))
      OR lower(trim(e.venue_name)) LIKE lower(trim(COALESCE(p_sg_venue, ''))) || '%'
      OR lower(trim(COALESCE(p_sg_venue, ''))) LIKE lower(trim(e.venue_name)) || '%'
    )
    AND (
      v_sg_team_b <> '' AND (
        lower(e.primary_performer_name) LIKE '%' || lower(v_sg_team_b) || '%'
        OR lower(e.name) LIKE '%' || lower(v_sg_team_b) || '%'
      )
      OR
      v_sg_team_a <> '' AND (
        lower(e.primary_performer_name) LIKE '%' || lower(v_sg_team_a) || '%'
        OR lower(e.name) LIKE '%' || lower(v_sg_team_a) || '%'
      )
    )
  ORDER BY
    CASE WHEN COALESCE(lc.is_active, true) THEN 0 ELSE 1 END,
    CASE WHEN lower(trim(e.venue_name)) = lower(trim(COALESCE(p_sg_venue, ''))) THEN 0 ELSE 1 END,
    CASE WHEN v_sg_team_b <> '' AND lower(e.primary_performer_name) LIKE '%' || lower(v_sg_team_b) || '%' THEN 0 ELSE 1 END
  LIMIT 1;

  IF v_tevo_event_id IS NOT NULL THEN
    INSERT INTO seatgeek_event_xref (
      tevo_event_id, sg_event_id, sg_event_name, sg_event_type,
      sg_event_location, sg_start_data, match_method, match_confidence
    ) VALUES (
      v_tevo_event_id, p_sg_event_id, p_sg_event_name, NULL,
      p_sg_venue,
      make_timestamptz(
        EXTRACT(YEAR FROM p_sg_event_date)::int,
        EXTRACT(MONTH FROM p_sg_event_date)::int,
        EXTRACT(DAY FROM p_sg_event_date)::int, 0, 0, 0, 'UTC'),
      'auto_seller_inline_v2', 0.9
    )
    ON CONFLICT (tevo_event_id) DO UPDATE
      SET sg_event_id = EXCLUDED.sg_event_id,
          sg_event_name = EXCLUDED.sg_event_name,
          sg_event_location = EXCLUDED.sg_event_location,
          match_method = 'auto_seller_inline_v2',
          matched_at = NOW();
  END IF;
  RETURN v_tevo_event_id;
END $function$;

-- ============================================================
-- Part 1c: trg_sgec_to_seatgeek_event_xref — defense-in-depth
-- ============================================================
CREATE OR REPLACE FUNCTION public.trg_sgec_to_seatgeek_event_xref()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.tevo_event_id IS NULL THEN
    RETURN NEW;
  END IF;
  -- A1 parking guard 2026-05-17: never mirror parking pseudo-events to xref.
  -- Defense-in-depth — Part 1a + 1b already block via auto_match_sg_canonical
  -- and sg_attempt_event_xref, but a manual UPDATE of sg_events_canonical
  -- setting tevo_event_id on a parking row would otherwise propagate here.
  IF coalesce(NEW.sg_event_name, '') ILIKE '%parking%'
     OR coalesce(NEW.sg_venue_name, '') ILIKE '%parking%' THEN
    RETURN NEW;
  END IF;
  INSERT INTO seatgeek_event_xref (
      tevo_event_id, sg_event_id, sg_event_name, sg_event_type, sg_event_location,
      sg_start_data, matched_at, match_method, match_confidence, meta)
  VALUES (NEW.tevo_event_id, NEW.sg_event_id, NEW.sg_event_name, NEW.sg_category,
          NULLIF(concat_ws(', ', NEW.sg_venue_name, NEW.sg_venue_city, NEW.sg_venue_state), ''),
          NEW.sg_datetime_utc, COALESCE(NEW.matched_at, NOW()),
          COALESCE(NEW.match_method, 'sg_canonical_auto'),
          NEW.match_confidence,
          jsonb_build_object('origin','sg_events_canonical'))
  ON CONFLICT (tevo_event_id) DO UPDATE
    SET sg_event_id=EXCLUDED.sg_event_id, sg_event_name=EXCLUDED.sg_event_name,
        sg_event_type=EXCLUDED.sg_event_type, sg_event_location=EXCLUDED.sg_event_location,
        sg_start_data=EXCLUDED.sg_start_data, match_method=EXCLUDED.match_method,
        match_confidence=EXCLUDED.match_confidence, matched_at=EXCLUDED.matched_at,
        meta=EXCLUDED.meta;
  RETURN NEW;
END;
$function$;

-- ============================================================
-- Part 2: NULL out tevo_event_id on parking rows in sg_events_canonical
-- ============================================================
UPDATE public.sg_events_canonical
SET tevo_event_id = NULL,
    match_method = 'parking_cleanup_2026_05_17',
    match_confidence = NULL,
    updated_at = now()
WHERE (sg_event_name ILIKE '%parking%' OR sg_venue_name ILIKE '%parking%')
  AND tevo_event_id IS NOT NULL;

-- ============================================================
-- Part 3a: UPDATE xref polluted rows to clean sibling (when free)
-- ============================================================
WITH polluted AS (
  SELECT x.tevo_event_id, x.sg_event_id AS bad_sg, sc.sg_event_date,
         regexp_replace(sc.sg_venue_name, ' Parking$', '') AS clean_venue
  FROM public.seatgeek_event_xref x
  JOIN public.sg_events_canonical sc ON sc.sg_event_id = x.sg_event_id
  WHERE sc.sg_event_name ILIKE '%parking%' OR sc.sg_venue_name ILIKE '%parking%'
), remap AS (
  SELECT p.tevo_event_id, p.bad_sg,
         (SELECT sg_event_id FROM public.sg_events_canonical sc2
          WHERE sc2.sg_event_date = p.sg_event_date
            AND sc2.sg_venue_name = p.clean_venue
            AND sc2.sg_event_name NOT ILIKE '%parking%'
            AND sc2.sg_venue_name NOT ILIKE '%parking%'
          LIMIT 1) AS clean_sg
  FROM polluted p
)
UPDATE public.seatgeek_event_xref x
SET sg_event_id = r.clean_sg,
    sg_event_name = (SELECT sg_event_name FROM public.sg_events_canonical WHERE sg_event_id = r.clean_sg),
    sg_event_location = (SELECT sg_venue_name FROM public.sg_events_canonical WHERE sg_event_id = r.clean_sg),
    match_method = 'parking_remap_2026_05_17',
    match_confidence = 0.95,
    matched_at = now()
FROM remap r
WHERE x.tevo_event_id = r.tevo_event_id
  AND x.sg_event_id = r.bad_sg
  AND r.clean_sg IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.seatgeek_event_xref x2 WHERE x2.sg_event_id = r.clean_sg);

-- ============================================================
-- Part 3b: catch-all DELETE remaining xrefs pointing at parking SG ids
--          Covers: the 1 case where clean target was already mapped, the 3
--          parking-only orphans, plus any new pollution that snuck in
--          between rows during the transaction.
-- ============================================================
DELETE FROM public.seatgeek_event_xref
WHERE sg_event_id IN (
  SELECT sg_event_id FROM public.sg_events_canonical
  WHERE sg_event_name ILIKE '%parking%' OR sg_venue_name ILIKE '%parking%'
);

-- ============================================================
-- Verification (assertions — migration fails if cleanup incomplete)
-- ============================================================
DO $verify$
DECLARE v_parking_xrefs int; v_parking_canonical_with_tevo int;
BEGIN
  SELECT count(*) INTO v_parking_xrefs
  FROM public.seatgeek_event_xref x
  JOIN public.sg_events_canonical sc ON sc.sg_event_id = x.sg_event_id
  WHERE sc.sg_event_name ILIKE '%parking%' OR sc.sg_venue_name ILIKE '%parking%';

  SELECT count(*) INTO v_parking_canonical_with_tevo
  FROM public.sg_events_canonical
  WHERE (sg_event_name ILIKE '%parking%' OR sg_venue_name ILIKE '%parking%')
    AND tevo_event_id IS NOT NULL;

  IF v_parking_xrefs > 0 THEN
    RAISE EXCEPTION 'parking cleanup incomplete: % polluted xref rows remain', v_parking_xrefs;
  END IF;
  IF v_parking_canonical_with_tevo > 0 THEN
    RAISE EXCEPTION 'parking cleanup incomplete: % canonical parking rows still have tevo_event_id', v_parking_canonical_with_tevo;
  END IF;

  RAISE NOTICE 'parking cleanup verified: 0 polluted xrefs, 0 canonical parking rows with tevo';
END $verify$;

COMMENT ON FUNCTION public.auto_match_sg_canonical() IS
  'Legacy v1 matcher loop. A1 2026-05-17: added parking guard in loop predicate. Newer cross_source_match_tick path (v3) is preferred but this is still called via sg_canonical_auto_match_tick → cross_source_match_tick cron.';
COMMENT ON FUNCTION public.sg_attempt_event_xref(bigint, text, date, text) IS
  'Legacy v1 SG→TEvo bridge. A1 2026-05-17: added parking guard at top — returns NULL for any name/venue containing the word parking.';
