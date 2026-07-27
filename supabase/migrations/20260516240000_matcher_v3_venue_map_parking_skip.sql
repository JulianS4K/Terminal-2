-- ============================================================================
-- Matcher v3 — date ±24h tolerance + parking skip + cross-source venue map
--
-- Context: A1 spot-check 2026-05-16 found 2,121 future SG events unlinked to
-- TEvo. Dry sim of current matcher: 0 fixable. Dry sim of v3 (±24h, parking
-- skip, soft venue): 11 fixable + 232 cleanly skipped as parking pseudo-events.
-- True residual gap (1,878) is "TEvo doesn't have the event row yet" — fixed
-- separately by Migration B (sg_to_tevo_search_autotrack via /v9/events).
--
-- This migration ships:
--   1. cross_source_venue_map (table) — denormalized TEvo↔SG↔TickPick↔Vivid
--      venue resolver. One row per TEvo venue, multi-source name aliases.
--   2. cross_source_venue_resolve(name TEXT, city TEXT, state TEXT) — returns
--      best tevo_venue_id. Uses normalized name + city/state + fuzzy match.
--   3. sg_attempt_event_xref_v3() — ±24h tolerance + venue map lookup +
--      ignores Parking pseudo-events. Returns tevo_event_id or NULL.
--   4. auto_match_sg_canonical_v3() — replaces auto_match_sg_canonical in the
--      cross_source_match_tick cron pipeline.
--
-- Idempotency: ON CONFLICT / IF NOT EXISTS / re-runnable.
-- Bible §4 RPCs updated separately.
-- ============================================================================

-- 1. cross_source_venue_map
CREATE TABLE IF NOT EXISTS public.cross_source_venue_map (
  tevo_venue_id      bigint PRIMARY KEY,
  tevo_venue_name    text NOT NULL,
  tevo_venue_location text,
  canonical_name     text GENERATED ALWAYS AS (lower(regexp_replace(tevo_venue_name, '[^a-z0-9]+', '', 'gi'))) STORED,
  city               text,
  state              text,
  country            text,
  -- Per-source aliases (jsonb arrays of strings — multiple variants possible)
  sg_aliases         jsonb DEFAULT '[]'::jsonb,
  sg_venue_id        bigint,
  tickpick_aliases   jsonb DEFAULT '[]'::jsonb,
  tickpick_venue_id  bigint,
  vivid_aliases      jsonb DEFAULT '[]'::jsonb,
  -- Stats
  sources_count      int GENERATED ALWAYS AS (
    1
    + (CASE WHEN jsonb_array_length(coalesce(sg_aliases,'[]'::jsonb)) > 0 THEN 1 ELSE 0 END)
    + (CASE WHEN jsonb_array_length(coalesce(tickpick_aliases,'[]'::jsonb)) > 0 THEN 1 ELSE 0 END)
    + (CASE WHEN jsonb_array_length(coalesce(vivid_aliases,'[]'::jsonb)) > 0 THEN 1 ELSE 0 END)
  ) STORED,
  created_at         timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_csvm_canonical_name ON public.cross_source_venue_map(canonical_name);
CREATE INDEX IF NOT EXISTS idx_csvm_city_state ON public.cross_source_venue_map(city, state);
CREATE INDEX IF NOT EXISTS idx_csvm_sg_venue_id ON public.cross_source_venue_map(sg_venue_id) WHERE sg_venue_id IS NOT NULL;

COMMENT ON TABLE public.cross_source_venue_map IS
  'Cross-source venue lookup: TEvo canonical anchor + name aliases from SG, TickPick, Vivid. Drives matcher v3 venue normalization. Refresh via refresh_cross_source_venue_map().';

-- 2. Refresh function — populates from existing events/sg/tickpick/vivid data
CREATE OR REPLACE FUNCTION public.refresh_cross_source_venue_map()
RETURNS TABLE(tevo_rows int, sg_links int, tickpick_links int, vivid_links int)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_tevo int; v_sg int; v_tp int; v_v int;
BEGIN
  -- (a) Upsert TEvo venues from events table
  INSERT INTO public.cross_source_venue_map (
    tevo_venue_id, tevo_venue_name, tevo_venue_location, city, state, country
  )
  SELECT DISTINCT ON (e.venue_id)
    e.venue_id, e.venue_name, e.venue_location,
    -- Parse city/state from venue_location ("City, ST")
    nullif(trim(split_part(e.venue_location, ',', 1)), ''),
    nullif(trim(split_part(e.venue_location, ',', 2)), ''),
    'US'
  FROM public.events e
  WHERE e.venue_id IS NOT NULL AND e.venue_name IS NOT NULL
  ORDER BY e.venue_id, e.last_seen DESC NULLS LAST
  ON CONFLICT (tevo_venue_id) DO UPDATE SET
    tevo_venue_name = EXCLUDED.tevo_venue_name,
    tevo_venue_location = EXCLUDED.tevo_venue_location,
    city = COALESCE(EXCLUDED.city, public.cross_source_venue_map.city),
    state = COALESCE(EXCLUDED.state, public.cross_source_venue_map.state),
    updated_at = now();
  GET DIAGNOSTICS v_tevo = ROW_COUNT;

  -- (b) Link SG aliases by canonical-name + city/state match
  WITH sg_unique AS (
    SELECT DISTINCT
      sg_venue_id,
      sg_venue_name,
      sg_venue_city,
      sg_venue_state,
      lower(regexp_replace(sg_venue_name, '[^a-z0-9]+', '', 'gi')) AS canonical
    FROM public.sg_events_canonical
    WHERE sg_venue_name IS NOT NULL
  ),
  matches AS (
    SELECT m.tevo_venue_id, s.sg_venue_id, s.sg_venue_name
    FROM sg_unique s
    JOIN public.cross_source_venue_map m
      ON m.canonical_name = s.canonical
     AND (
       (m.city IS NULL OR s.sg_venue_city IS NULL OR lower(m.city) = lower(s.sg_venue_city))
       AND (m.state IS NULL OR s.sg_venue_state IS NULL OR upper(m.state) = upper(s.sg_venue_state))
     )
  )
  UPDATE public.cross_source_venue_map m
  SET sg_venue_id = matches.sg_venue_id,
      sg_aliases = (
        SELECT jsonb_agg(DISTINCT name)
        FROM jsonb_array_elements_text(coalesce(m.sg_aliases,'[]'::jsonb) || to_jsonb(matches.sg_venue_name)) AS name
      ),
      updated_at = now()
  FROM matches
  WHERE m.tevo_venue_id = matches.tevo_venue_id;
  GET DIAGNOSTICS v_sg = ROW_COUNT;

  -- (c) Link TickPick aliases from raw->event->venue jsonb
  WITH tp_unique AS (
    SELECT DISTINCT
      (raw->'event'->'venue'->>'id')::bigint AS tp_venue_id,
      raw->'event'->'venue'->>'name' AS tp_venue_name,
      raw->'event'->'venue'->>'city' AS tp_city,
      raw->'event'->'venue'->>'state' AS tp_state,
      lower(regexp_replace(raw->'event'->'venue'->>'name', '[^a-z0-9]+', '', 'gi')) AS canonical
    FROM public.tickpick_orders
    WHERE raw IS NOT NULL AND raw->'event'->'venue'->>'name' IS NOT NULL
  ),
  matches AS (
    SELECT m.tevo_venue_id, t.tp_venue_id, t.tp_venue_name
    FROM tp_unique t
    JOIN public.cross_source_venue_map m
      ON m.canonical_name = t.canonical
     AND (m.state IS NULL OR t.tp_state IS NULL OR upper(m.state) = upper(t.tp_state))
  )
  UPDATE public.cross_source_venue_map m
  SET tickpick_venue_id = matches.tp_venue_id,
      tickpick_aliases = (
        SELECT jsonb_agg(DISTINCT name)
        FROM jsonb_array_elements_text(coalesce(m.tickpick_aliases,'[]'::jsonb) || to_jsonb(matches.tp_venue_name)) AS name
      ),
      updated_at = now()
  FROM matches
  WHERE m.tevo_venue_id = matches.tevo_venue_id;
  GET DIAGNOSTICS v_tp = ROW_COUNT;

  -- (d) Vivid is messier (single concatenated string); skip canonical match,
  -- store raw venue strings as aliases for direct equality only
  WITH v_unique AS (
    SELECT DISTINCT
      raw->>'venue' AS vivid_venue,
      lower(regexp_replace(split_part(raw->>'venue', ' - ', 1), '[^a-z0-9]+', '', 'gi')) AS canonical
    FROM public.vivid_orders
    WHERE raw->>'venue' IS NOT NULL
  ),
  matches AS (
    SELECT m.tevo_venue_id, v.vivid_venue
    FROM v_unique v
    JOIN public.cross_source_venue_map m ON m.canonical_name = v.canonical
  )
  UPDATE public.cross_source_venue_map m
  SET vivid_aliases = (
        SELECT jsonb_agg(DISTINCT name)
        FROM jsonb_array_elements_text(coalesce(m.vivid_aliases,'[]'::jsonb) || to_jsonb(matches.vivid_venue)) AS name
      ),
      updated_at = now()
  FROM matches
  WHERE m.tevo_venue_id = matches.tevo_venue_id;
  GET DIAGNOSTICS v_v = ROW_COUNT;

  RETURN QUERY SELECT v_tevo, v_sg, v_tp, v_v;
END $func$;

REVOKE EXECUTE ON FUNCTION public.refresh_cross_source_venue_map() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_cross_source_venue_map() TO service_role;

COMMENT ON FUNCTION public.refresh_cross_source_venue_map() IS
  'Rebuilds cross_source_venue_map from events/sg_events_canonical/tickpick_orders.raw/vivid_orders.raw. Idempotent. Used by matcher v3 + cross-source bridges.';

-- 3. Venue resolver function — any-source venue name → tevo_venue_id
CREATE OR REPLACE FUNCTION public.cross_source_venue_resolve(
  p_venue_name text,
  p_city       text DEFAULT NULL,
  p_state      text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_canonical text;
  v_id bigint;
BEGIN
  IF p_venue_name IS NULL OR p_venue_name = '' THEN RETURN NULL; END IF;
  v_canonical := lower(regexp_replace(p_venue_name, '[^a-z0-9]+', '', 'gi'));

  -- Tier 1: exact canonical_name + (optional) city/state match
  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE canonical_name = v_canonical
    AND (p_city IS NULL OR city IS NULL OR lower(city) = lower(p_city))
    AND (p_state IS NULL OR state IS NULL OR upper(state) = upper(p_state))
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- Tier 2: alias-array match across SG/TickPick/Vivid
  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE sg_aliases ? p_venue_name
     OR tickpick_aliases ? p_venue_name
     OR vivid_aliases ? p_venue_name
  LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  -- Tier 3: prefix match on canonical
  SELECT tevo_venue_id INTO v_id
  FROM public.cross_source_venue_map
  WHERE canonical_name LIKE v_canonical || '%'
     OR v_canonical LIKE canonical_name || '%'
  ORDER BY length(canonical_name) DESC  -- prefer longer matches
  LIMIT 1;
  RETURN v_id;
END $func$;

GRANT EXECUTE ON FUNCTION public.cross_source_venue_resolve(text, text, text) TO service_role, authenticated;

-- 4. sg_attempt_event_xref_v3 — improved matcher
CREATE OR REPLACE FUNCTION public.sg_attempt_event_xref_v3(
  p_sg_event_id      bigint,
  p_sg_event_name    text,
  p_sg_event_date    date,
  p_sg_datetime_utc  timestamptz,
  p_sg_venue         text,
  p_sg_venue_city    text DEFAULT NULL,
  p_sg_venue_state   text DEFAULT NULL,
  p_sg_category      text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_tevo_event_id bigint;
  v_existing      bigint;
  v_sg_team_a     text;
  v_sg_team_b     text;
  v_tevo_venue_id bigint;
BEGIN
  -- Skip parking pseudo-events outright (TEvo merges parking into main listing)
  IF p_sg_category IN ('Parking','parking') OR coalesce(p_sg_venue,'') ILIKE '%parking%' OR coalesce(p_sg_event_name,'') ILIKE '%parking%' THEN
    RETURN NULL;
  END IF;

  -- Already mapped? short-circuit
  SELECT tevo_event_id INTO v_existing FROM public.seatgeek_event_xref WHERE sg_event_id = p_sg_event_id LIMIT 1;
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;

  v_sg_team_a := trim(split_part(coalesce(p_sg_event_name,''), ' at ', 1));
  v_sg_team_b := trim(split_part(coalesce(p_sg_event_name,''), ' at ', 2));
  IF v_sg_team_b = '' THEN v_sg_team_b := v_sg_team_a; END IF;

  -- Resolve SG venue → TEvo venue_id via venue map
  v_tevo_venue_id := public.cross_source_venue_resolve(p_sg_venue, p_sg_venue_city, p_sg_venue_state);

  -- Match within ±24h of SG datetime, with venue + performer constraints
  SELECT e.id INTO v_tevo_event_id
  FROM public.events e
  LEFT JOIN public.event_lifecycle lc ON lc.event_id = e.id
  WHERE
    -- Date tolerance ±24h (handles UTC vs local mismatches and timezone shifts)
    e.occurs_at_local::timestamptz BETWEEN
      coalesce(p_sg_datetime_utc, p_sg_event_date::timestamptz) - interval '24 hours'
      AND coalesce(p_sg_datetime_utc, p_sg_event_date::timestamptz) + interval '24 hours'
    -- Venue: tevo_venue_id match (preferred) OR name fuzzy match (fallback)
    AND (
      (v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id)
      OR lower(trim(coalesce(e.venue_name,''))) = lower(trim(coalesce(p_sg_venue,'')))
      OR lower(trim(coalesce(e.venue_name,''))) LIKE lower(trim(coalesce(p_sg_venue,''))) || '%'
      OR lower(trim(coalesce(p_sg_venue,''))) LIKE lower(trim(coalesce(e.venue_name,''))) || '%'
    )
    -- Team-name overlap required (avoids ghost cross-events at multi-venue days)
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
    -- Closest in time first
    abs(extract(epoch FROM (e.occurs_at_local::timestamptz - coalesce(p_sg_datetime_utc, p_sg_event_date::timestamptz)))),
    -- Active (non-ghost) first
    CASE WHEN coalesce(lc.is_active, true) THEN 0 ELSE 1 END,
    -- Venue-id match wins over name match
    CASE WHEN v_tevo_venue_id IS NOT NULL AND e.venue_id = v_tevo_venue_id THEN 0 ELSE 1 END
  LIMIT 1;

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
END $func$;

REVOKE EXECUTE ON FUNCTION public.sg_attempt_event_xref_v3(bigint, text, date, timestamptz, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_attempt_event_xref_v3(bigint, text, date, timestamptz, text, text, text, text) TO service_role;

-- 5. auto_match_sg_canonical_v3 — sweeps all unlinked with v3
CREATE OR REPLACE FUNCTION public.auto_match_sg_canonical_v3()
RETURNS TABLE(attempted int, newly_matched int, parking_skipped int, still_unmatched int, needs_tevo_search int)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  r RECORD;
  v_match bigint;
  v_attempted int := 0;
  v_matched int := 0;
  v_parking int := 0;
  v_unmatched int := 0;
BEGIN
  FOR r IN
    SELECT sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc,
           sg_venue_name, sg_venue_city, sg_venue_state, sg_category
    FROM public.sg_events_canonical
    WHERE tevo_event_id IS NULL
      AND (sg_event_date IS NULL OR sg_event_date >= current_date - 30)
  LOOP
    v_attempted := v_attempted + 1;

    -- Pre-skip parking before calling matcher to track stat
    IF r.sg_category IN ('Parking','parking')
       OR coalesce(r.sg_venue_name,'') ILIKE '%parking%'
       OR coalesce(r.sg_event_name,'') ILIKE '%parking%' THEN
      v_parking := v_parking + 1;
      CONTINUE;
    END IF;

    v_match := public.sg_attempt_event_xref_v3(
      r.sg_event_id, r.sg_event_name, r.sg_event_date, r.sg_datetime_utc,
      r.sg_venue_name, r.sg_venue_city, r.sg_venue_state, r.sg_category
    );

    IF v_match IS NOT NULL THEN
      UPDATE public.sg_events_canonical SET
        tevo_event_id = v_match,
        match_method = 'matcher_v3_pm24h',
        match_confidence = 0.9,
        matched_at = now(),
        updated_at = now()
      WHERE sg_event_id = r.sg_event_id;
      v_matched := v_matched + 1;
    ELSE
      v_unmatched := v_unmatched + 1;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_attempted, v_matched, v_parking, v_unmatched,
    (SELECT count(*)::int FROM public.sg_events_canonical WHERE tevo_event_id IS NULL AND sg_datetime_utc > now());
END $func$;

REVOKE EXECUTE ON FUNCTION public.auto_match_sg_canonical_v3() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.auto_match_sg_canonical_v3() TO service_role;

COMMENT ON FUNCTION public.auto_match_sg_canonical_v3() IS
  'Matcher v3 sweep over all unlinked sg_events_canonical. ±24h tolerance, parking skip, venue map lookup. Replaces auto_match_sg_canonical in cross_source_match_tick. Residual needs_tevo_search count drives the search-autotrack queue.';
