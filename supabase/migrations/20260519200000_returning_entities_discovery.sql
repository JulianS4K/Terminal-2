-- Migration 20260519200000 · lane:A1 · writes:v_returning_entities,get_returning_entities,get_returning_entity_events · pre:20260519190000
--
-- Returning-entity discovery — companion to the blindspot detector.
--
-- INTENT (operator design 2026-05-19):
--   Surface performers + venues that had past activity, went dormant for
--   a meaningful gap, and now have upcoming events. Useful as a
--   discovery tool to spot tour comebacks, venue re-openings, and
--   inventory-sourcing opportunities for events brokers wouldn't
--   otherwise prioritize.
--
-- SOURCES + COVERAGE:
--   * TEvo performers (`events.primary_performer_id`) — full coverage
--   * TEvo venues (`events.venue_id`)                 — full coverage
--   * SG venues (`sg_events_canonical.sg_venue_id`)   — full coverage
--   * SG performers                                    — NOT YET. SG
--     event-to-performer link runs through `sg_event_name` parsing or
--     `v_sg_historic_per_performer.performer_headliner`. Both are
--     fuzzy; defer to v2. seatgeek_performer_xref only maps SG perf
--     NAMES to TEvo perf IDs — it's name-keyed, not event-keyed.
--
-- DEFINITION OF "RETURNING":
--   * Had at least 1 event in the past 2 years
--   * Most-recent past event is at least `p_min_gap_days` days ago
--     (default 90; RPC accepts override)
--   * Has at least 1 upcoming event in the next 365 days
--
-- POOL VALIDATION (run 2026-05-19, gap=90d):
--   tevo_performers: 3   tevo_venues: 4   sg_venues: 0
--   Pool grows as data ages — first cohort post-launch.

-- ============================================================
-- 1. Union view: one row per (source, entity_type, entity_id)
-- ============================================================
DROP VIEW IF EXISTS public.v_returning_entities;

CREATE VIEW public.v_returning_entities
WITH (security_invoker = on) AS
WITH tevo_perf AS (
  SELECT
    'tevo'                        AS source,
    'performer'                   AS entity_type,
    primary_performer_id::text    AS entity_id,
    max(primary_performer_name)   AS entity_name,
    NULL::text                    AS entity_location,
    max(occurs_at_local::timestamptz) FILTER (WHERE occurs_at_local::timestamptz <  now()) AS latest_past_at,
    min(occurs_at_local::timestamptz) FILTER (WHERE occurs_at_local::timestamptz >= now()) AS earliest_future_at,
    count(*) FILTER (WHERE occurs_at_local::timestamptz >= now())                          AS upcoming_count,
    count(*) FILTER (WHERE occurs_at_local::timestamptz <  now())                          AS past_count
  FROM public.events
  WHERE primary_performer_id IS NOT NULL
    AND occurs_at_local IS NOT NULL
    AND occurs_at_local::timestamptz >= now() - interval '2 years'
    AND occurs_at_local::timestamptz <= now() + interval '365 days'
  GROUP BY primary_performer_id
),
tevo_venue AS (
  SELECT
    'tevo', 'venue',
    venue_id::text,
    max(venue_name),
    max(venue_location),
    max(occurs_at_local::timestamptz) FILTER (WHERE occurs_at_local::timestamptz <  now()),
    min(occurs_at_local::timestamptz) FILTER (WHERE occurs_at_local::timestamptz >= now()),
    count(*) FILTER (WHERE occurs_at_local::timestamptz >= now()),
    count(*) FILTER (WHERE occurs_at_local::timestamptz <  now())
  FROM public.events
  WHERE venue_id IS NOT NULL
    AND occurs_at_local IS NOT NULL
    AND occurs_at_local::timestamptz >= now() - interval '2 years'
    AND occurs_at_local::timestamptz <= now() + interval '365 days'
  GROUP BY venue_id
),
sg_venue AS (
  SELECT
    'sg', 'venue',
    sg_venue_id::text,
    max(sg_venue_name),
    max(coalesce(sg_venue_city || ', ' || sg_venue_state, sg_venue_city)),
    max(sg_datetime_utc) FILTER (WHERE sg_datetime_utc <  now()),
    min(sg_datetime_utc) FILTER (WHERE sg_datetime_utc >= now()),
    count(*) FILTER (WHERE sg_datetime_utc >= now()),
    count(*) FILTER (WHERE sg_datetime_utc <  now())
  FROM public.sg_events_canonical
  WHERE sg_venue_id IS NOT NULL
    AND sg_datetime_utc >= now() - interval '2 years'
    AND sg_datetime_utc <= now() + interval '365 days'
  GROUP BY sg_venue_id
)
SELECT
  source, entity_type, entity_id, entity_name, entity_location,
  latest_past_at, earliest_future_at, upcoming_count, past_count,
  -- Gap in days between latest past event and earliest future event
  (earliest_future_at::date - latest_past_at::date) AS gap_days
FROM (
  SELECT * FROM tevo_perf
  UNION ALL
  SELECT * FROM tevo_venue
  UNION ALL
  SELECT * FROM sg_venue
) u
WHERE latest_past_at     IS NOT NULL
  AND earliest_future_at IS NOT NULL;

COMMENT ON VIEW public.v_returning_entities IS
  'Performers + venues with a past activity → gap → future event pattern.
   Sources: TEvo performers, TEvo venues, SG venues. SG performer link
   deferred to v2 (fuzzy event-to-performer mapping). Underlying join
   keys are 2-year past + 365-day future windows. Used by
   get_returning_entities() + get_returning_entity_events() RPCs.';

REVOKE ALL ON public.v_returning_entities FROM PUBLIC;
GRANT SELECT ON public.v_returning_entities TO anon, authenticated, service_role;

-- ============================================================
-- 2. Discovery RPC — top N returning entities
-- ============================================================
DROP FUNCTION IF EXISTS public.get_returning_entities(int, text, text, int);

CREATE OR REPLACE FUNCTION public.get_returning_entities(
  p_min_gap_days int   DEFAULT 90,
  p_source       text  DEFAULT NULL,    -- 'tevo' | 'sg' | NULL (both)
  p_entity_type  text  DEFAULT NULL,    -- 'performer' | 'venue' | NULL (both)
  p_limit        int   DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  -- §6 caller guard — email-required
  v_email := nullif((select auth.jwt())->>'email', '');
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'email required' USING errcode = '42501';
  END IF;

  IF p_source IS NOT NULL AND p_source NOT IN ('tevo','sg') THEN
    RAISE EXCEPTION 'p_source must be tevo|sg|null' USING errcode = '22023';
  END IF;
  IF p_entity_type IS NOT NULL AND p_entity_type NOT IN ('performer','venue') THEN
    RAISE EXCEPTION 'p_entity_type must be performer|venue|null' USING errcode = '22023';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(r) ORDER BY r.gap_days DESC,
                                              r.upcoming_count DESC,
                                              r.earliest_future_at ASC),
                  '[]'::jsonb)
    INTO v_result
  FROM (
    SELECT *
    FROM public.v_returning_entities
    WHERE gap_days >= p_min_gap_days
      AND (p_source      IS NULL OR source      = p_source)
      AND (p_entity_type IS NULL OR entity_type = p_entity_type)
    LIMIT p_limit
  ) r;

  RETURN v_result;
END;
$$;

REVOKE ALL    ON FUNCTION public.get_returning_entities(int, text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_returning_entities(int, text, text, int) TO anon, authenticated;

COMMENT ON FUNCTION public.get_returning_entities(int, text, text, int) IS
  'Discovery tool: lists performers + venues with past activity → gap →
   upcoming events. Sources: TEvo (events table) + SG (sg_events_canonical).
   Default min_gap_days=90 (3 months dormant). Sort: largest gap first,
   ties by upcoming_count DESC, then earliest_future_at ASC.';

-- ============================================================
-- 3. Drill-down RPC — events for a specific returning entity
-- ============================================================
DROP FUNCTION IF EXISTS public.get_returning_entity_events(text, text, text, int);

CREATE OR REPLACE FUNCTION public.get_returning_entity_events(
  p_source       text,                  -- 'tevo' | 'sg'
  p_entity_type  text,                  -- 'performer' | 'venue'
  p_entity_id    text,                  -- the id from v_returning_entities
  p_limit        int  DEFAULT 25
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  v_email := nullif((select auth.jwt())->>'email', '');
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'email required' USING errcode = '42501';
  END IF;
  IF p_source NOT IN ('tevo','sg') THEN
    RAISE EXCEPTION 'p_source must be tevo|sg' USING errcode = '22023';
  END IF;
  IF p_entity_type NOT IN ('performer','venue') THEN
    RAISE EXCEPTION 'p_entity_type must be performer|venue' USING errcode = '22023';
  END IF;

  IF p_source = 'tevo' AND p_entity_type = 'performer' THEN
    SELECT coalesce(jsonb_agg(row_to_json(e) ORDER BY e.occurs_at_local), '[]'::jsonb)
      INTO v_result
    FROM (
      SELECT id AS event_id, name, occurs_at_local,
             venue_id, venue_name, venue_location
      FROM public.events
      WHERE primary_performer_id = p_entity_id::bigint
        AND occurs_at_local::timestamptz >= now()
        AND occurs_at_local::timestamptz <= now() + interval '365 days'
      LIMIT p_limit
    ) e;
  ELSIF p_source = 'tevo' AND p_entity_type = 'venue' THEN
    SELECT coalesce(jsonb_agg(row_to_json(e) ORDER BY e.occurs_at_local), '[]'::jsonb)
      INTO v_result
    FROM (
      SELECT id AS event_id, name, occurs_at_local,
             primary_performer_id, primary_performer_name
      FROM public.events
      WHERE venue_id = p_entity_id::bigint
        AND occurs_at_local::timestamptz >= now()
        AND occurs_at_local::timestamptz <= now() + interval '365 days'
      LIMIT p_limit
    ) e;
  ELSIF p_source = 'sg' AND p_entity_type = 'venue' THEN
    SELECT coalesce(jsonb_agg(row_to_json(e) ORDER BY e.sg_datetime_utc), '[]'::jsonb)
      INTO v_result
    FROM (
      SELECT sg_event_id, sg_event_name, sg_datetime_utc,
             sg_venue_name, sg_venue_city, sg_venue_state
      FROM public.sg_events_canonical
      WHERE sg_venue_id = p_entity_id::bigint
        AND sg_datetime_utc >= now()
        AND sg_datetime_utc <= now() + interval '365 days'
      LIMIT p_limit
    ) e;
  ELSE
    -- p_source='sg' AND p_entity_type='performer' — see v_returning_entities
    -- comment: SG performer link deferred to v2.
    RETURN '[]'::jsonb;
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL    ON FUNCTION public.get_returning_entity_events(text, text, text, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_returning_entity_events(text, text, text, int) TO anon, authenticated;

COMMENT ON FUNCTION public.get_returning_entity_events(text, text, text, int) IS
  'Drill-down for v_returning_entities: lists upcoming events (next 365d)
   for a given (source, entity_type, entity_id) tuple. SG performer
   drill-down returns empty array — SG performer link deferred to v2.';

-- ============================================================
-- VERIFICATION (operator runs after apply):
--
--   -- 1. View population by source + entity_type
--   SELECT source, entity_type, count(*) FILTER (WHERE gap_days >= 90) AS gap_90d
--   FROM public.v_returning_entities GROUP BY source, entity_type ORDER BY 1,2;
--   -- Baseline 2026-05-19: tevo_performer=3, tevo_venue=4, sg_venue=0
--
--   -- 2. RPC smoke
--   SELECT public.get_returning_entities();                    -- all sources, 90d gap
--   SELECT public.get_returning_entities(180);                 -- 6-month gap
--   SELECT public.get_returning_entities(90, 'tevo', 'venue'); -- TEvo venues only
--
--   -- 3. Drill-down smoke
--   SELECT public.get_returning_entity_events('tevo','performer','<id>');
-- ============================================================
