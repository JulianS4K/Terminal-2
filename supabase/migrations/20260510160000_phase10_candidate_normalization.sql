-- ============================================================================
-- Migration 20260510160000 — Phase 10: candidate-performer normalization
--
-- Lane:     canonical
-- Touches:  v_sg_unmatched_candidate_performers (DROP + CREATE VIEW);
--           reads sg_events_canonical, seatgeek_performer_xref
-- Pre-reqs: 20260510140000 (Phase 8 — initial candidate view)
--
-- The Phase 8 view exposed 168 distinct candidate names; the Phase 8 matcher
-- accepted 44 outright. The 35 skips fall into four recoverable classes and
-- one genuinely-noisy class:
--   * 6  parking ("Parking X" / "X Parking" / "Nate Sib and Corbin"-style)
--   * 3  theater-touring ("X the Musical CITY", "X CITY")
--   * 11 preseason ("X Preseason" + duplicated "X X Preseason" tokens)
--   * 3  alias-mismatch  (Oakland Athletics, LA Galaxy, Atlanta United FC)
--   * 5  suffix-strippable (Citi Presale, Weekend N, Saturday Only, etc.)
--   * 7  genuine noise — left for manual overrides
--
-- This migration rebuilds v_sg_unmatched_candidate_performers to:
--   1. exclude parking + theater-tour up front (they are not real performers)
--   2. strip preseason + presale + weekend/session suffixes
--   3. collapse "X X"-style duplicated tokens
--   4. expose an aliases text[] column the matcher tries on no-hit
-- ============================================================================

DROP VIEW IF EXISTS v_sg_unmatched_candidate_performers CASCADE;

CREATE VIEW v_sg_unmatched_candidate_performers AS
WITH src AS (
  SELECT sg_event_id, sg_category, sg_venue_name,
         regexp_replace(sg_event_name, '\s*\([^)]*\)\s*$', '', 'g') AS clean_name
    FROM sg_events_canonical
   WHERE tevo_event_id IS NULL
),
sides AS (
  SELECT sg_event_id, sg_category, sg_venue_name,
         CASE
           WHEN clean_name ~* '\s+at\s+'    THEN regexp_split_to_array(clean_name, '\s+at\s+')
           WHEN clean_name ~* '\s+vs\.?\s+' THEN regexp_split_to_array(clean_name, '\s+vs\.?\s+')
           ELSE ARRAY[clean_name]
         END AS sides
    FROM src
),
exploded AS (
  SELECT sg_event_id, sg_category, sg_venue_name, trim(s) AS raw_perf
    FROM sides, unnest(sides) AS s
),
co_split AS (
  SELECT sg_event_id, sg_category, sg_venue_name,
         CASE
           WHEN sg_category IN ('mlb','nhl','nba','mls','wnba','ncaa_football',
                                 'ncaa_basketball','nfl','nascar','nfl_preseason')
             THEN ARRAY[raw_perf]
           ELSE regexp_split_to_array(raw_perf, '\s+(with|feat\.?|ft\.?)\s+|\s+&\s+')
         END AS perfs
    FROM exploded
),
raw_candidates AS (
  SELECT sg_event_id, sg_category, sg_venue_name,
         trim(regexp_replace(p, '^.*?:\s*', '')) AS raw_name
    FROM co_split, unnest(perfs) AS p
),
classified AS (
  SELECT sg_event_id, sg_category, sg_venue_name, raw_name,
         CASE
           -- Parking passes are not real performers
           WHEN raw_name ~* '^Parking '       THEN 'parking'
           WHEN raw_name ~* '\sParking$'      THEN 'parking'
           WHEN sg_category = 'parking'       THEN 'parking'
           -- Theater touring shows: "X the Musical Y" or "Show CITY" patterns
           -- (we leave them out — caller can build their own theater overlay)
           WHEN raw_name ~* '\sthe\s+Musical\b' THEN 'theater_tour'
           WHEN raw_name ~* '^(Dear\s+Evan\s+Hansen|The\s+Book\s+of\s+Mormon|Hamilton|Wicked|The\s+Lion\s+King|Hadestown|Six)\s+\w+$'
                                             THEN 'theater_tour'
           ELSE 'normal'
         END AS skip_reason
    FROM raw_candidates
),
normalized AS (
  SELECT sg_event_id, sg_category, sg_venue_name, raw_name,
         (
           -- Step 1: strip "Preseason" suffix
           regexp_replace(
             -- Step 2: collapse "X X" (e.g. "Melbourne United Melbourne United")
             regexp_replace(
               -- Step 3: strip suffixes like "- Citi Presale", "- Saturday Only",
               -- "Weekend N", "Saturday Evening Session - Stadium 1" etc.
               regexp_replace(
                 raw_name,
                 '\s*-\s*(Citi\s+Presale|Saturday\s+Only|Sunday\s+Only|Saturday(?:\s+Evening)?(?:\s+Session)?(?:\s*-\s*Stadium\s*\d+)?|Sunday\s*-\s*Stadium\s*\d+)\s*$',
                 '', 'i'),
               '^(.+)\s+\1$', '\1', 'i'),
             '\s+Preseason$', '', 'i')
         ) AS step_a
    FROM classified
   WHERE skip_reason = 'normal'
),
final AS (
  SELECT sg_event_id, sg_category, sg_venue_name,
         -- Step 4: drop "Weekend N" trailing tag (Coachella Music Festival Weekend 1)
         regexp_replace(step_a, '\s+Weekend\s+\d+$', '', 'i') AS performer_name
    FROM normalized
)
SELECT
  performer_name,
  COUNT(DISTINCT sg_event_id)        AS event_count,
  array_agg(DISTINCT sg_category)    AS categories,
  array_agg(DISTINCT sg_venue_name)  AS venues,
  (array_agg(sg_event_id))[1]        AS sample_sg_event_id,
  -- Known alias map: TEvo's catalog name where it differs from SG's
  CASE lower(performer_name)
    WHEN 'oakland athletics'  THEN ARRAY['Athletics']
    WHEN 'la galaxy'          THEN ARRAY['Los Angeles Galaxy']
    WHEN 'atlanta united fc'  THEN ARRAY['Atlanta United']
    WHEN 'coachella music festival' THEN ARRAY['Coachella']
    ELSE ARRAY[]::text[]
  END AS aliases
FROM final
WHERE length(performer_name) > 1
  AND performer_name <> 'many more'
  AND NOT EXISTS (
        SELECT 1 FROM seatgeek_performer_xref x
         WHERE lower(x.sg_performer_name) = lower(performer_name))
GROUP BY performer_name
ORDER BY event_count DESC, performer_name;

GRANT SELECT ON v_sg_unmatched_candidate_performers
  TO authenticated, anon, service_role;
