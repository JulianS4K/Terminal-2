-- ============================================================================
-- Migration 20260910410000 — n2s_zone_of(): an UNAMBIGUOUS zone resolver
--
-- Lane: D7 · Level: data-collection · reads A1's zone surface, writes nothing.
--
-- WHY NOT match_performer_zone() DIRECTLY: it ends `order by display_order
-- limit 1`, so when a section+row falls in two curated zones it silently picks
-- one by an ordering that carries no semantics. Measured on live obligations
-- that is 4 of 48 lookups. For a classifier whose entire product IS the label,
-- a confidently wrong zone is worse than no zone, so this returns NULL on
-- ambiguity and lets the caller fall through to a lower gate.
--
-- ⚠ ZONES ARE SECTION *AND* ROW SCOPED — p_row is not optional. 436 of 5,524
-- rules carry row bounds and they are not geography, they are PRICE TIERS
-- stacked inside one section:
--     sections 121-124 → Metro Gold/Plat [rows 1-6] · Metro Silver [7-12]
--                        Metro Bronze [13-22]       · Metro Box [23-35]
-- Resolving on section alone would let a Gold seat match a Silver seat.
--
-- EXCLUSIONS (operator, 2026-09-10):
--   source = 'curated'      — system_placeholder zones are auto-generated
--                             groupings, not curated meaning (36 rows / 9 pairs).
--   name NOT ILIKE '%fifa%' — the same stadium is zoned differently for a World
--                             Cup fixture and nothing in the data says which
--                             config is in force. 2 zones on 1 pair. Unfixable
--                             by cleaning, so excluded rather than guessed.
--                             Excluding it also RESCUES a case: section 335 was
--                             ambiguous between `u1` and `U1 FIFA`, and now
--                             resolves cleanly to `u1`.
--
-- The composite (performer_id, venue_id) key self-selects the home side: of the
-- 66 live obligations whose venue has curated zones, ALL 66 have exactly one
-- zone-owning performer in events.performer_ids. No precedence rule is needed.
--
-- ⚠ This is the OBLIGATION-side resolver and the readable reference. The bulk
-- listing-side path in n2s_cover_candidates() unrolls the same logic as a
-- set-based join for performance; do not push this function back into that
-- path — per-row invocation there timed out at 60s.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.n2s_zone_of(
  p_performer_id bigint, p_venue_id bigint, p_section text, p_row text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path TO 'public','pg_temp'
AS $function$
  SELECT CASE WHEN count(DISTINCT z.name) = 1 THEN min(z.name) END
    FROM public.performer_zones z
    JOIN public.performer_zone_rules r ON r.zone_id = z.id
   WHERE z.performer_id = p_performer_id
     AND z.venue_id     = p_venue_id
     AND z.source       = 'curated'
     AND z.name NOT ILIKE '%fifa%'
     AND ( (public._sec_norm(r.section_from) = public._sec_norm(r.section_to)
            AND public._sec_norm(p_section)  = public._sec_norm(r.section_from))
        OR (r.section_from ~ '^[0-9]+$' AND r.section_to ~ '^[0-9]+$'
            AND p_section ~ '^[0-9]+$'
            AND p_section::int BETWEEN r.section_from::int AND r.section_to::int)
        OR (public._sec_prefix(r.section_from) <> ''
            AND public._sec_prefix(r.section_from) = public._sec_prefix(r.section_to)
            AND public._sec_prefix(r.section_from) = public._sec_prefix(p_section)
            AND public._sec_suffix(r.section_from) IS NOT NULL
            AND public._sec_suffix(r.section_to)   IS NOT NULL
            AND public._sec_suffix(p_section)      IS NOT NULL
            AND public._sec_suffix(p_section)
                BETWEEN public._sec_suffix(r.section_from) AND public._sec_suffix(r.section_to)) )
     AND ( (r.row_from IS NULL AND r.row_to IS NULL)
        OR (lower(coalesce(r.row_from,'')) = lower(coalesce(r.row_to,''))
            AND lower(coalesce(p_row,'')) = lower(coalesce(r.row_from,'')))
        OR (r.row_from ~ '^[0-9]+$' AND r.row_to ~ '^[0-9]+$' AND p_row ~ '^[0-9]+$'
            AND p_row::int BETWEEN r.row_from::int AND r.row_to::int) )
$function$;

COMMENT ON FUNCTION public.n2s_zone_of(bigint,bigint,text,text) IS
  'Curated zone for a (performer,venue,section,row), or NULL when the lookup is AMBIGUOUS. Unlike match_performer_zone() this never breaks a tie by display_order: for the N2S gate cascade a wrong zone label is worse than none, so ambiguity falls through to a lower gate. Excludes system_placeholder and FIFA overlay zones. Row is required — 436 rules are row-bound price tiers within a section (Gold/Silver/Bronze), so a section-only match would pair different tiers.';

REVOKE ALL ON FUNCTION public.n2s_zone_of(bigint,bigint,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_zone_of(bigint,bigint,text,text) TO service_role, authenticated;
