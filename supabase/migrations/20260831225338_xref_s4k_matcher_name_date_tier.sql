-- Migration 20260831225338 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_matcher_name_date_tier" (version 20260831225338) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831260900 — S4K matcher tier 5: name + date, no venue
-- Lane:     xref+macro
-- Touches:  s4k_match_to_aq_event_id (fn), events (R), aq_event_map (R)
-- Pre-reqs: 20260831260600
--
-- Every tier so far needs either a venue string or a home performer. That
-- leaves venue-less single-act rows -- "Rush", "Katseye", "Gracie Abrams" --
-- with no path at all: no venue to resolve, and no " at " from which to derive
-- a home team. The interim matcher caught these with a name+date rule, and
-- the diff shows it was right to: of the 2,168 legacy matches this chain
-- initially dropped, a large share are exactly these, and spot-checking
-- confirms they were correct ("Rush" 2026-09-12 -> Rush at TD Garden).
--
-- So restore that path, but under the house guard rather than a raw token
-- ratio: aq_name_consistent against the whole day's events, a UNIQUE event
-- required, and a hub row required to stamp. Confidence 0.70 -- the weakest
-- tier, because a date plus a name is the least evidence any tier here rests
-- on. Runs last, so it only ever sees what all six stronger tiers refused.
-- Measured yield: 282 groups / 977 orders.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.s4k_match_to_aq_event_id(
  p_source text, p_event_name text, p_venue_name text, p_event_date date,
  p_venue_city text DEFAULT NULL, p_venue_state text DEFAULT NULL)
RETURNS TABLE(aq_short_event_id text, confidence numeric, match_method text)
LANGUAGE plpgsql STABLE SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_norm text; v_code text; v_id text; v_home text; v_n integer;
  v_cvenue text; v_vid bigint;
BEGIN
  IF p_event_date IS NULL OR coalesce(p_event_name,'') = '' THEN RETURN; END IF;

  v_norm := public.s4k_normalize_event_name(p_event_name);
  v_home := trim(regexp_replace(
              regexp_replace(split_part(v_norm, ' at ', 2), '\s*\(.*\)$', '', 'g'),
              '\s+(Football|Basketball|Baseball|Hockey|Soccer)$', '', 'gi'));
  v_code := CASE p_source
              WHEN 'StubHub' THEN 'SH' WHEN 'SeatGeek' THEN 'SG'
              WHEN 'Gametime' THEN 'GT' WHEN 'Vivid Seats' THEN 'VD'
              WHEN 'TickPick' THEN 'TP' ELSE NULL END;
  v_cvenue := lower(regexp_replace(coalesce(p_venue_name,''), '[^a-z0-9]+','','gi'));

  IF coalesce(p_venue_name,'') <> '' THEN

  WITH c AS (
    SELECT a.aq_short_event_id AS aq, a.tevo_event_id AS tevo
      FROM public.aq_event_map a
     WHERE lower(regexp_replace(coalesce(a.venue_name,''), '[^a-z0-9]+','','gi')) = v_cvenue
       AND a.event_date::date = p_event_date
       AND public.aq_name_consistent(a.event_name, v_norm)
       AND NOT EXISTS (SELECT 1 FROM public.events he
              WHERE he.id = a.tevo_event_id AND he.occurs_at_local IS NOT NULL
                AND left(he.occurs_at_local, 10) <> to_char(p_event_date, 'YYYY-MM-DD'))
  )
  SELECT (SELECT count(DISTINCT coalesce(tevo::text, aq)) FROM c),
         (SELECT aq FROM c ORDER BY (tevo IS NULL), aq LIMIT 1)
    INTO v_n, v_id;
  IF v_n = 1 THEN
    RETURN QUERY SELECT v_id, 0.95::numeric(3,2), 's4k_venue_date_name'::text; RETURN;
  END IF;

  IF v_n > 1 AND v_code IS NOT NULL THEN
    WITH c AS (
      SELECT a.aq_short_event_id AS aq, a.tevo_event_id AS tevo
        FROM public.aq_event_map a
       WHERE lower(regexp_replace(coalesce(a.venue_name,''), '[^a-z0-9]+','','gi')) = v_cvenue
         AND a.event_date::date = p_event_date
         AND public.aq_name_consistent(a.event_name, v_norm)
         AND NOT EXISTS (SELECT 1 FROM public.events he
                WHERE he.id = a.tevo_event_id AND he.occurs_at_local IS NOT NULL
                  AND left(he.occurs_at_local, 10) <> to_char(p_event_date, 'YYYY-MM-DD'))
         AND EXISTS (SELECT 1 FROM public.ticketsdata_event_xref x
                WHERE x.platform = v_code AND x.aq_short_event_id = a.aq_short_event_id)
    )
    SELECT (SELECT count(DISTINCT coalesce(tevo::text, aq)) FROM c),
           (SELECT aq FROM c ORDER BY (tevo IS NULL), aq LIMIT 1)
      INTO v_n, v_id;
    IF v_n = 1 THEN
      RETURN QUERY SELECT v_id, 0.85::numeric(3,2), 's4k_td_platform'::text; RETURN;
    END IF;
    RETURN;
  END IF;

  IF v_n = 0 THEN
    WITH e AS (
      SELECT ev.id FROM public.events ev
       WHERE lower(regexp_replace(coalesce(ev.venue_name,''), '[^a-z0-9]+','','gi')) = v_cvenue
         AND ev.occurs_at_local IS NOT NULL
         AND left(ev.occurs_at_local, 10) = to_char(p_event_date, 'YYYY-MM-DD')
         AND public.aq_name_consistent(ev.name, v_norm)
    ), c AS (
      SELECT a.aq_short_event_id AS aq FROM e JOIN public.aq_event_map a ON a.tevo_event_id = e.id
    )
    SELECT CASE WHEN (SELECT count(DISTINCT id) FROM e) = 1
                THEN (SELECT count(DISTINCT aq) FROM c) ELSE 0 END,
           (SELECT aq FROM c ORDER BY aq LIMIT 1)
      INTO v_n, v_id;
    IF v_n = 1 THEN
      RETURN QUERY SELECT v_id, 0.93::numeric(3,2), 's4k_event_date_name'::text; RETURN;
    END IF;
    v_n := 0;
  END IF;

  IF v_n = 0 THEN
    v_vid := public.cross_source_venue_resolve(p_venue_name, p_venue_city, p_venue_state);
    IF v_vid IS NOT NULL THEN
      WITH e AS (
        SELECT ev.id FROM public.events ev
         WHERE ev.venue_id = v_vid
           AND ev.occurs_at_local IS NOT NULL
           AND left(ev.occurs_at_local, 10) = to_char(p_event_date, 'YYYY-MM-DD')
           AND public.aq_name_consistent(ev.name, v_norm)
      ), c AS (
        SELECT a.aq_short_event_id AS aq FROM e JOIN public.aq_event_map a ON a.tevo_event_id = e.id
      )
      SELECT CASE WHEN (SELECT count(DISTINCT id) FROM e) = 1
                  THEN (SELECT count(DISTINCT aq) FROM c) ELSE 0 END,
             (SELECT aq FROM c ORDER BY aq LIMIT 1)
        INTO v_n, v_id;
      IF v_n = 1 THEN
        RETURN QUERY SELECT v_id, 0.92::numeric(3,2), 's4k_venue_id_date'::text; RETURN;
      END IF;
      v_n := 0;
    END IF;
  END IF;

  IF v_n = 0 THEN
    WITH c AS (
      SELECT a.aq_short_event_id AS aq, a.tevo_event_id AS tevo
        FROM public.aq_event_map a
       WHERE a.event_date::date = p_event_date
         AND coalesce(a.venue_name,'') <> ''
         AND similarity(lower(a.venue_name), lower(p_venue_name)) >= 0.7
         AND public.aq_name_consistent(a.event_name, v_norm)
         AND NOT EXISTS (SELECT 1 FROM public.events he
                WHERE he.id = a.tevo_event_id AND he.occurs_at_local IS NOT NULL
                  AND left(he.occurs_at_local, 10) <> to_char(p_event_date, 'YYYY-MM-DD'))
    )
    SELECT (SELECT count(DISTINCT coalesce(tevo::text, aq)) FROM c),
           (SELECT aq FROM c ORDER BY (tevo IS NULL), aq LIMIT 1)
      INTO v_n, v_id;
    IF v_n = 1 THEN
      RETURN QUERY SELECT v_id, 0.80::numeric(3,2), 's4k_venue_fuzzy_date'::text; RETURN;
    END IF;
  END IF;
  END IF;

  -- ── Tier 4: home performer -> home venue ─────────────────────────────────
  IF coalesce(v_home,'') <> '' THEN
    WITH pv AS (
      SELECT performer_name, venue_id FROM public.performer_home_venues WHERE venue_id IS NOT NULL
      UNION
      SELECT p.tevo_performer_name, v.vid
        FROM public.entity_performer_map p, LATERAL unnest(p.home_venue_ids) v(vid)
       WHERE p.tevo_performer_name IS NOT NULL
    ), c AS (
      SELECT a.aq_short_event_id AS aq, a.tevo_event_id AS tevo
        FROM pv
        JOIN public.events e ON e.venue_id = pv.venue_id
         AND e.occurs_at_local IS NOT NULL
         AND left(e.occurs_at_local, 10) = to_char(p_event_date, 'YYYY-MM-DD')
         AND public.aq_name_consistent(e.name, v_norm)
        JOIN public.aq_event_map a ON a.tevo_event_id = e.id
       WHERE lower(trim(pv.performer_name)) = lower(v_home)
    )
    SELECT (SELECT count(DISTINCT coalesce(tevo::text, aq)) FROM c),
           (SELECT aq FROM c ORDER BY (tevo IS NULL), aq LIMIT 1)
      INTO v_n, v_id;
    IF v_n = 1 THEN
      RETURN QUERY SELECT v_id, 0.75::numeric(3,2), 's4k_home_venue'::text; RETURN;
    END IF;
  END IF;

  -- ── Tier 5: name + date only (last resort; venue-less single acts) ───────
  WITH e AS (
    SELECT ev.id FROM public.events ev
     WHERE ev.occurs_at_local IS NOT NULL
       AND left(ev.occurs_at_local, 10) = to_char(p_event_date, 'YYYY-MM-DD')
       AND public.aq_name_consistent(ev.name, v_norm)
  ), c AS (
    SELECT a.aq_short_event_id AS aq FROM e JOIN public.aq_event_map a ON a.tevo_event_id = e.id
  )
  SELECT CASE WHEN (SELECT count(DISTINCT id) FROM e) = 1
              THEN (SELECT count(DISTINCT aq) FROM c) ELSE 0 END,
         (SELECT aq FROM c ORDER BY aq LIMIT 1)
    INTO v_n, v_id;
  IF v_n = 1 THEN
    RETURN QUERY SELECT v_id, 0.70::numeric(3,2), 's4k_name_date'::text; RETURN;
  END IF;

  RETURN;
END;
$function$;

UPDATE public.s4k_marketplace_orders
   SET map_attempts = 0, map_last_attempt_at = NULL
 WHERE aq_short_event_id IS NULL AND map_attempts > 0;
;
