-- Migration 20260831224658 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_matcher_events_authority_tier" (version 20260831224658) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831260500 — S4K matcher: `events` as the venue authority
-- Lane:     xref+macro
-- Touches:  s4k_match_to_aq_event_id (fn), events (R), aq_event_map (R)
-- Pre-reqs: 20260831260100
--
-- Tiers 1-3 all keyed the venue off aq_event_map.venue_name. The hub keeps its
-- own venue spellings, which are not the ones `events` uses, so a hub row can
-- exist for an event and still be unreachable from an S4K venue string.
-- Measured on the unmatched set: 1,237 groups (5,783 orders) resolve to
-- exactly ONE name-consistent event in `events`, and 861 of those groups
-- (5,113 orders) ALREADY have a hub row carrying that tevo_event_id. The
-- matcher was missing them purely on venue spelling.
--
-- New tier 1b resolves the event against `events` -- the venue authority --
-- and then looks the hub row up by tevo_event_id, using the hub as the key
-- registry it is rather than as a venue directory. Confidence 0.93: the event
-- identification is as strong as tier 1, with one extra hop to the hub key.
--
-- Runs only when tier 1 found nothing. Tier 1 ambiguity still goes to the
-- TicketsData tiebreak (tier 2) and stops there -- a venue+date collision is
-- not something a second venue spelling should be allowed to resolve.
--
-- The residual 376 groups (670 orders) have a unique event in `events` but NO
-- hub row at all. Those are the legitimate create_system_aq_event case (the
-- event is in our catalogue, it simply was never registered in the hub) and
-- are distinct from the catalogue-absent rows the operator declined to
-- synthesise. Left unmatched and reported, not synthesised unilaterally.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.s4k_match_to_aq_event_id(
  p_source text, p_event_name text, p_venue_name text, p_event_date date)
RETURNS TABLE(aq_short_event_id text, confidence numeric, match_method text)
LANGUAGE plpgsql STABLE SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_norm text; v_code text; v_id text; v_home text; v_n integer; v_cvenue text;
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

  -- ── Tier 1: hub, canonical venue + equal local date + name guard ─────────
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

  -- ── Tier 2: TicketsData platform tiebreak (the "when unsure" path) ───────
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

  -- ── Tier 1b: `events` is the venue authority; hub is the key registry ────
  IF v_n = 0 THEN
    WITH e AS (
      SELECT ev.id
        FROM public.events ev
       WHERE lower(regexp_replace(coalesce(ev.venue_name,''), '[^a-z0-9]+','','gi')) = v_cvenue
         AND ev.occurs_at_local IS NOT NULL
         AND left(ev.occurs_at_local, 10) = to_char(p_event_date, 'YYYY-MM-DD')
         AND public.aq_name_consistent(ev.name, v_norm)
    ), c AS (
      SELECT a.aq_short_event_id AS aq, a.tevo_event_id AS tevo
        FROM e JOIN public.aq_event_map a ON a.tevo_event_id = e.id
    )
    SELECT CASE WHEN (SELECT count(DISTINCT id) FROM e) = 1
                THEN (SELECT count(DISTINCT coalesce(tevo::text, aq)) FROM c)
                ELSE 0 END,
           (SELECT aq FROM c ORDER BY aq LIMIT 1)
      INTO v_n, v_id;
    IF v_n = 1 THEN
      RETURN QUERY SELECT v_id, 0.93::numeric(3,2), 's4k_event_date_name'::text; RETURN;
    END IF;
    v_n := 0;
  END IF;

  -- ── Tier 3: trigram venue on the hub ─────────────────────────────────────
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

  -- ── Tier 4: home performer -> home venue -> event ────────────────────────
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

  RETURN;
END;
$function$;
;
