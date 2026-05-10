-- ============================================================================
-- Phase 11: Match SG events to Tevo events by venue + date when the SG
--           performer name is unparseable (the "noisy parses" set).
--
-- The existing sg_attempt_event_xref() requires performer-name overlap to
-- guard against ghost matches; that gate prevents matching events like
-- "REFES DU SOL" or "Forged in Houston" where the SG event title doesn't
-- contain a recognizable team / artist name.
--
-- This phase adds:
--   1. v_sg_event_match_proposals — for every unmatched sg_events_canonical
--      row whose venue resolves to a Tevo venue, list candidate Tevo events
--      at the same venue on the same date with a token-overlap score.
--   2. sg_match_event_by_venue_date(sg_event_id) — relaxed matcher that
--      writes seatgeek_event_xref when there is exactly one TEvo event at
--      that venue/date OR when token-overlap with the SG name is >= 0.5.
--   3. auto_match_sg_canonical_relaxed(p_min_token_overlap, p_only_event_ids)
--      — loops through unmatched SG events and applies the relaxed matcher;
--      writes are mirrored to canonical_external_ids by Phase 4 triggers.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- v_sg_event_match_proposals
-- One row per (sg_event_id × candidate tevo_event_id) at the same venue/date.
-- The matcher uses these proposals; humans can inspect them too.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_sg_event_match_proposals CASCADE;
CREATE VIEW v_sg_event_match_proposals AS
WITH sg AS (
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_event_date, sg_category
    FROM sg_events_canonical
   WHERE tevo_event_id IS NULL
     AND sg_event_date IS NOT NULL
),
sg_tokens AS (
  SELECT sg_event_id,
         ARRAY(
           SELECT t FROM unnest(string_to_array(lower(
             regexp_replace(sg_event_name, '[^a-zA-Z0-9 ]', ' ', 'g')
           ), ' ')) AS t
            WHERE length(t) > 2
              AND t NOT IN ('the','and','with','presale','citi','only',
                            'saturday','sunday','session','stadium','weekend',
                            'parking','preseason','game','games','tour','live',
                            'evening','featuring','feat','for')
         ) AS tokens,
         sg_event_name, sg_venue_name, sg_event_date, sg_category
    FROM sg
),
tevo_candidates AS (
  -- For every SG event, find Tevo events on the same date at the same venue.
  -- Two paths to resolve venue: explicit seatgeek_venue_xref, or matching
  -- venue_name (case-insensitive equal/prefix).
  SELECT s.sg_event_id, s.sg_event_name, s.sg_venue_name, s.sg_event_date,
         s.sg_category, s.tokens AS sg_tokens,
         e.id AS tevo_event_id, e.name AS tevo_event_name,
         e.venue_id AS tevo_venue_id, e.venue_name AS tevo_venue_name,
         e.primary_performer_name,
         (e.occurs_at_local::timestamptz)::date AS tevo_event_date,
         e.event_type AS tevo_event_type
    FROM sg_tokens s
    JOIN events e
      ON (e.occurs_at_local::timestamptz)::date = s.sg_event_date
     AND (
            -- venue resolved via xref
            EXISTS (SELECT 1 FROM seatgeek_venue_xref svx
                     WHERE lower(svx.sg_venue_name) = lower(s.sg_venue_name)
                       AND svx.tevo_venue_id = e.venue_id)
         OR -- or by name (exact / prefix either direction)
            lower(trim(e.venue_name)) = lower(trim(s.sg_venue_name))
         OR lower(trim(e.venue_name)) LIKE lower(trim(s.sg_venue_name)) || '%'
         OR lower(trim(s.sg_venue_name)) LIKE lower(trim(e.venue_name)) || '%'
     )
),
scored AS (
  SELECT *,
         ARRAY(
           SELECT t FROM unnest(string_to_array(lower(
             regexp_replace(coalesce(tevo_event_name,'') || ' ' ||
                            coalesce(primary_performer_name,''),
                            '[^a-zA-Z0-9 ]', ' ', 'g')
           ), ' ')) AS t
            WHERE length(t) > 2
         ) AS tevo_tokens
    FROM tevo_candidates
),
final AS (
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_event_date, sg_category,
         tevo_event_id, tevo_event_name, tevo_venue_id, tevo_venue_name,
         tevo_event_date, primary_performer_name, tevo_event_type,
         sg_tokens, tevo_tokens,
         CASE WHEN cardinality(sg_tokens) = 0 OR cardinality(tevo_tokens) = 0
              THEN 0::numeric
              ELSE
                cardinality(ARRAY(SELECT unnest(sg_tokens) INTERSECT SELECT unnest(tevo_tokens)))::numeric
                / GREATEST(cardinality(sg_tokens), 1)
         END AS token_overlap,
         COUNT(*) OVER (PARTITION BY sg_event_id) AS candidates_at_venue_date
    FROM scored
)
SELECT * FROM final
 ORDER BY sg_event_id, token_overlap DESC NULLS LAST, tevo_event_id;

GRANT SELECT ON v_sg_event_match_proposals TO authenticated, anon, service_role;

-- ----------------------------------------------------------------------------
-- sg_match_event_by_venue_date
-- For one SG event, accept a Tevo match when:
--   (a) exactly one Tevo event at that venue/date          → confidence 0.85
--   (b) multiple, but best token_overlap >= p_min_overlap  → confidence 0.75
--   (c) otherwise, return NULL (caller can review proposals)
-- The Phase 4 trigger on sg_events_canonical fans out to seatgeek_event_xref
-- and canonical_external_ids automatically.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sg_match_event_by_venue_date(
  p_sg_event_id     bigint,
  p_min_overlap     numeric DEFAULT 0.5
) RETURNS TABLE (matched_tevo_event_id bigint, method text, confidence numeric)
LANGUAGE plpgsql AS $$
DECLARE
  v_count    int;
  v_tevo_id  bigint;
  v_overlap  numeric;
BEGIN
  SELECT MAX(candidates_at_venue_date) INTO v_count
    FROM v_sg_event_match_proposals
   WHERE sg_event_id = p_sg_event_id;

  IF v_count IS NULL OR v_count = 0 THEN
    RETURN QUERY SELECT NULL::bigint, 'no_candidates'::text, 0::numeric;
    RETURN;
  END IF;

  IF v_count = 1 THEN
    SELECT tevo_event_id, token_overlap
      INTO v_tevo_id, v_overlap
      FROM v_sg_event_match_proposals
     WHERE sg_event_id = p_sg_event_id
     LIMIT 1;
    UPDATE sg_events_canonical
       SET tevo_event_id    = v_tevo_id,
           match_method     = 'venue_date_unique',
           match_confidence = 0.85,
           matched_at       = NOW(),
           updated_at       = NOW()
     WHERE sg_event_id = p_sg_event_id;
    RETURN QUERY SELECT v_tevo_id, 'venue_date_unique'::text, 0.85::numeric;
    RETURN;
  END IF;

  -- multiple candidates: pick best by token overlap, gate on threshold
  SELECT tevo_event_id, token_overlap
    INTO v_tevo_id, v_overlap
    FROM v_sg_event_match_proposals
   WHERE sg_event_id = p_sg_event_id
   ORDER BY token_overlap DESC NULLS LAST, tevo_event_id
   LIMIT 1;

  IF v_overlap >= p_min_overlap THEN
    UPDATE sg_events_canonical
       SET tevo_event_id    = v_tevo_id,
           match_method     = 'venue_date_token_overlap',
           match_confidence = LEAST(0.85, 0.55 + v_overlap),
           matched_at       = NOW(),
           updated_at       = NOW()
     WHERE sg_event_id = p_sg_event_id;
    RETURN QUERY SELECT v_tevo_id, 'venue_date_token_overlap'::text,
                        LEAST(0.85, 0.55 + v_overlap);
    RETURN;
  END IF;

  RETURN QUERY SELECT NULL::bigint, 'multi_low_overlap'::text, COALESCE(v_overlap, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION sg_match_event_by_venue_date(bigint, numeric)
  TO authenticated, service_role;

-- ----------------------------------------------------------------------------
-- auto_match_sg_canonical_relaxed
-- Loops through every still-unmatched sg_events_canonical row and runs the
-- relaxed matcher on it. Returns counts.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION auto_match_sg_canonical_relaxed(
  p_min_overlap     numeric DEFAULT 0.5,
  p_dry_run         boolean DEFAULT false
) RETURNS TABLE (
  attempted        int,
  unique_matches   int,
  overlap_matches  int,
  unmatched        int,
  remaining        int
) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD;
  v_attempted int := 0;
  v_unique    int := 0;
  v_overlap   int := 0;
  v_unmatched int := 0;
  v_method    text;
  v_match     bigint;
BEGIN
  -- Save a checkpoint we can roll back if dry_run is true.
  IF p_dry_run THEN
    -- just iterate over proposals + count what would happen
    FOR r IN
      SELECT DISTINCT ON (sg_event_id) sg_event_id,
             candidates_at_venue_date AS n_cand,
             token_overlap            AS top_overlap
        FROM v_sg_event_match_proposals
       ORDER BY sg_event_id, token_overlap DESC NULLS LAST
    LOOP
      v_attempted := v_attempted + 1;
      IF r.n_cand = 1 THEN
        v_unique := v_unique + 1;
      ELSIF r.top_overlap >= p_min_overlap THEN
        v_overlap := v_overlap + 1;
      ELSE
        v_unmatched := v_unmatched + 1;
      END IF;
    END LOOP;
    RETURN QUERY SELECT v_attempted, v_unique, v_overlap, v_unmatched,
      (SELECT COUNT(*)::int FROM sg_events_canonical WHERE tevo_event_id IS NULL);
    RETURN;
  END IF;

  -- Real run
  FOR r IN
    SELECT sg_event_id FROM sg_events_canonical
     WHERE tevo_event_id IS NULL AND sg_event_date IS NOT NULL
  LOOP
    v_attempted := v_attempted + 1;
    SELECT matched_tevo_event_id, method
      INTO v_match, v_method
      FROM sg_match_event_by_venue_date(r.sg_event_id, p_min_overlap)
     LIMIT 1;
    IF v_match IS NULL THEN
      v_unmatched := v_unmatched + 1;
    ELSIF v_method = 'venue_date_unique' THEN
      v_unique := v_unique + 1;
    ELSE
      v_overlap := v_overlap + 1;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_attempted, v_unique, v_overlap, v_unmatched,
    (SELECT COUNT(*)::int FROM sg_events_canonical WHERE tevo_event_id IS NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION auto_match_sg_canonical_relaxed(numeric, boolean)
  TO authenticated, service_role;
