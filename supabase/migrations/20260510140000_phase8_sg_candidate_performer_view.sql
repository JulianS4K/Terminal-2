-- ============================================================================
-- Migration 20260510140000 — Phase 8: SG candidate-performer view
--
-- Lane:     canonical
-- Touches:  v_sg_unmatched_candidate_performers (CREATE VIEW),
--           record_sg_performer_match() (CREATE FUNCTION);
--           reads sg_events_canonical, seatgeek_listings_snapshots,
--           seatgeek_sales_snapshots, seatgeek_orders, seatgeek_performer_xref
-- Pre-reqs: 20260509150000 (sg_events_canonical)
--
-- Candidate-performer extraction from unmatched SeatGeek data.
-- 35K SG listings + sales + orders collapse to ~228 distinct sg_events_canonical
-- rows that are still not linked to a Tevo event. From those event names we can
-- extract a small set (~168) of distinct performer-name candidates which the
-- match-sg-performers-to-tevo Edge Function will run through Tevo's
-- /v9/performers/search. Successful matches go into seatgeek_performer_xref,
-- which the Phase 4 trigger pipeline then mirrors into performer_external_ids
-- and canonical_external_ids.
-- ============================================================================

DROP VIEW IF EXISTS v_sg_unmatched_candidate_performers CASCADE;
CREATE VIEW v_sg_unmatched_candidate_performers AS
WITH src AS (
  SELECT sg_event_id,
         sg_category,
         sg_venue_name,
         -- strip parenthetical suffixes like "(Bobblehead Giveaway)"
         regexp_replace(sg_event_name, '\s*\([^)]*\)\s*$', '', 'g') AS clean_name
    FROM sg_events_canonical
   WHERE tevo_event_id IS NULL
),
sides AS (
  -- Sports: split on " at ", " vs.? "; everything else stays whole
  SELECT sg_event_id, sg_category, sg_venue_name,
         CASE
           WHEN clean_name ~* '\s+at\s+'   THEN regexp_split_to_array(clean_name, '\s+at\s+')
           WHEN clean_name ~* '\s+vs\.?\s+' THEN regexp_split_to_array(clean_name, '\s+vs\.?\s+')
           ELSE ARRAY[clean_name]
         END AS sides
    FROM src
),
exploded AS (
  SELECT sg_event_id, sg_category, sg_venue_name,
         trim(s) AS raw_perf
    FROM sides, unnest(sides) AS s
),
co_split AS (
  -- Concerts/comedy: split co-headliners on " with ", " feat ", " ft ", " & "
  SELECT sg_event_id, sg_category, sg_venue_name,
         CASE
           WHEN sg_category IN ('mlb','nhl','nba','mls','wnba','ncaa_football',
                                 'ncaa_basketball','nfl','nascar','nfl_preseason')
             THEN ARRAY[raw_perf]
           ELSE regexp_split_to_array(raw_perf, '\s+(with|feat\.?|ft\.?)\s+|\s+&\s+')
         END AS perfs
    FROM exploded
),
final AS (
  SELECT sg_event_id, sg_category, sg_venue_name,
         -- strip "Festival Name: " prefix
         trim(regexp_replace(p, '^.*?:\s*', '')) AS performer_name
    FROM co_split, unnest(perfs) AS p
)
SELECT performer_name,
       COUNT(DISTINCT sg_event_id) AS event_count,
       array_agg(DISTINCT sg_category)   AS categories,
       array_agg(DISTINCT sg_venue_name) AS venues,
       (array_agg(sg_event_id))[1]       AS sample_sg_event_id
  FROM final
 WHERE length(performer_name) > 1
   AND NOT EXISTS (
         SELECT 1 FROM seatgeek_performer_xref x
          WHERE lower(x.sg_performer_name) = lower(final.performer_name))
 GROUP BY performer_name
 ORDER BY event_count DESC, performer_name;

GRANT SELECT ON v_sg_unmatched_candidate_performers
  TO authenticated, anon, service_role;

-- ----------------------------------------------------------------------------
-- record_sg_performer_match(sg_performer_name text, tevo_performer_id bigint,
--                           confidence numeric, meta jsonb)
--
-- Convenience RPC the matcher Edge Function calls once per accepted hit.
-- All cascade work is handled by the existing seatgeek_perf_xref_pei_sync /
-- performer_external_ids_cei_sync triggers from Phase 4.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION record_sg_performer_match(
  p_sg_name      text,
  p_tevo_perf_id bigint,
  p_confidence   numeric DEFAULT NULL,
  p_match_method text    DEFAULT 'tevo_search_lookup',
  p_meta         jsonb   DEFAULT '{}'::jsonb
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO seatgeek_performer_xref (
      tevo_performer_id, sg_performer_name, match_method, match_confidence,
      matched_at, meta)
  VALUES (p_tevo_perf_id, p_sg_name, p_match_method, p_confidence,
          NOW(), p_meta)
  ON CONFLICT (tevo_performer_id) DO UPDATE
    SET sg_performer_name = EXCLUDED.sg_performer_name,
        match_method      = EXCLUDED.match_method,
        match_confidence  = EXCLUDED.match_confidence,
        matched_at        = EXCLUDED.matched_at,
        meta              = EXCLUDED.meta;
END;
$$;

GRANT EXECUTE ON FUNCTION record_sg_performer_match(text, bigint, numeric, text, jsonb)
  TO authenticated, service_role;
