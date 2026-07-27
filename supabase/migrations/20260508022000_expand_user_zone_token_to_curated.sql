-- 20260508022000_expand_user_zone_token_to_curated.sql
-- Captured from prod (copilot, applied as version 20260508170500).
-- Captured into git 2026-05-08 by code via audit-and-commit.
--
-- #106 fix: when a user gives a generic zone token like 'lowers' / '100 level',
-- expand to the actual curated zone names that hold the listings.
-- Example: Knicks @ MSG curated zones are '100 Corner / 100 End / 100 Garbage /
-- Risers 6-8 / Risers 9+'. User says 'lowers' → resolver returns
-- ['100 Corner','100 End','100 Garbage','Risers 6-8','Risers 9+'].
-- Falls back to canonical system-zone match if no curated zones exist.

CREATE OR REPLACE FUNCTION expand_user_zone_token_to_zones(
  p_performer_id bigint,
  p_venue_id bigint,
  p_user_token text
) RETURNS TABLE(zone_name text, source text) LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_canonical text;
  v_token text := lower(trim(p_user_token));
BEGIN
  SELECT display_name INTO v_canonical
  FROM chat_aliases
  WHERE alias_kind = 'zone' AND alias_norm = v_token
  LIMIT 1;

  IF v_canonical IS NULL THEN v_canonical := p_user_token; END IF;

  RETURN QUERY
  WITH curated AS (
    SELECT pz.name FROM performer_zones pz
    WHERE pz.performer_id = p_performer_id
      AND pz.venue_id = p_venue_id
      AND COALESCE(pz.source, 'curated') = 'curated'
  ),
  matched AS (
    SELECT c.name FROM curated c
    WHERE
      CASE
        WHEN v_canonical ILIKE '%Lower%' OR v_canonical ILIKE '%100%'
          THEN c.name ~* '(^|\s)(100|lower|riser)' OR c.name ~* '(courtside)' = false
             AND c.name ~* '(100|lower|riser)'
        WHEN v_canonical ILIKE '%Club%' OR v_canonical ILIKE '%200%'
          THEN c.name ~* '(^|\s)(200|club)'
        WHEN v_canonical ILIKE '%300%' OR v_canonical = 'Upper (300s)'
          THEN c.name ~* '(^|\s)(300|u3|upper.*3)'
        WHEN v_canonical ILIKE '%400%'
          THEN c.name ~* '(^|\s)(400|u4)'
        WHEN v_canonical ILIKE '%500%' OR v_canonical ILIKE '%Upper (500%'
          THEN c.name ~* '(500|u5|upper)'
        WHEN v_canonical ILIKE '%Upper%'
          THEN c.name ~* '(upper|u[1-9]|nosebleed|300|400|500)'
        WHEN v_canonical ILIKE '%Courtside%' OR v_canonical ILIKE '%Floor%' OR v_canonical = 'Floor / Pit / GA'
          THEN c.name ~* '(courtside|floor|pit|^ga$)'
        WHEN v_canonical ILIKE '%VIP%' OR v_canonical ILIKE '%Premium%'
          THEN c.name ~* '(vip|premium|club platinum|club gold|hospitality|suite)'
        WHEN v_canonical ILIKE '%Balcony%' THEN c.name ~* 'balcony'
        WHEN v_canonical ILIKE '%Lawn%' OR v_canonical ILIKE '%Terrace%' THEN c.name ~* '(lawn|terrace)'
        WHEN v_canonical ILIKE '%Bleach%' THEN c.name ~* 'bleach'
        WHEN v_canonical ILIKE '%Grandstand%' THEN c.name ~* '(grandstand|^gs)'
        ELSE FALSE
      END
  )
  SELECT m.name AS zone_name, 'curated'::text AS source FROM matched m;

  IF NOT FOUND THEN
    IF NOT EXISTS (
      SELECT 1 FROM performer_zones
      WHERE performer_id = p_performer_id AND venue_id = p_venue_id
        AND COALESCE(source,'curated') = 'curated'
    ) THEN
      RETURN QUERY SELECT v_canonical AS zone_name, 'system'::text AS source;
    END IF;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION expand_user_zone_token_to_zones(bigint, bigint, text)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION expand_user_zone_token_to_zones IS
  '#106 fix. User says lowers/100 level/courtsides → returns array of curated zone names that match the semantic family for this performer+venue. Knicks @ MSG: lowers → [100 Corner, 100 End, 100 Garbage, Risers 6-8, Risers 9+]. Falls back to canonical system zone name if no curated zones exist.';
