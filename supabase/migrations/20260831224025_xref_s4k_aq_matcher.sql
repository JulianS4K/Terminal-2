-- Migration 20260831224025 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_aq_matcher" (version 20260831224025) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


CREATE OR REPLACE FUNCTION public.s4k_normalize_event_name(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
           WHEN p_name IS NULL THEN NULL
           WHEN position(' vs. ' in p_name) > 0
             THEN split_part(p_name, ' vs. ', 2) || ' at ' || split_part(p_name, ' vs. ', 1)
           WHEN position(' vs ' in p_name) > 0
             THEN split_part(p_name, ' vs ', 2)  || ' at ' || split_part(p_name, ' vs ', 1)
           ELSE p_name
         END;
$function$;

COMMENT ON FUNCTION public.s4k_normalize_event_name(text) IS
  'Rewrites the S4K "HOME vs. AWAY" event-name convention into TEvo''s "AWAY at HOME" so aq_name_consistent''s away-side guard engages. Without it that guard is inert on S4K names and a single shared token matches.';

CREATE OR REPLACE FUNCTION public.s4k_match_to_aq_event_id(
  p_source text, p_event_name text, p_venue_name text, p_event_date date)
RETURNS TABLE(aq_short_event_id text, confidence numeric, match_method text)
LANGUAGE plpgsql STABLE SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_norm text; v_code text; v_id text; v_home text; v_n integer;
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

  IF coalesce(p_venue_name,'') <> '' THEN
  WITH c AS (
    SELECT a.aq_short_event_id AS aq, a.tevo_event_id AS tevo
      FROM public.aq_event_map a
     WHERE lower(regexp_replace(coalesce(a.venue_name,''), '[^a-z0-9]+','','gi'))
         = lower(regexp_replace(coalesce(p_venue_name,''), '[^a-z0-9]+','','gi'))
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
       WHERE lower(regexp_replace(coalesce(a.venue_name,''), '[^a-z0-9]+','','gi'))
           = lower(regexp_replace(coalesce(p_venue_name,''), '[^a-z0-9]+','','gi'))
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

CREATE OR REPLACE FUNCTION public.s4k_orders_match_sweep(p_max integer DEFAULT 5000)
RETURNS TABLE(table_name text, groups_examined integer, groups_matched integer,
              rows_stamped integer, groups_unmatched integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_aq text; v_vs text; v_ps text;
  v_ex integer := 0; v_m integer := 0; v_rows integer := 0; v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 's4k_orders_match_sweep: caller % not authorized', current_user;
  END IF;

  FOR r IN
    SELECT source, event_name, venue_name, event_date
      FROM public.s4k_marketplace_orders
     WHERE aq_short_event_id IS NULL
       AND event_date IS NOT NULL
       AND coalesce(event_name,'') <> ''
     GROUP BY source, event_name, venue_name, event_date
     LIMIT p_max
  LOOP
    v_ex := v_ex + 1; v_aq := NULL;

    SELECT m.aq_short_event_id INTO v_aq
      FROM public.s4k_match_to_aq_event_id(r.source, r.event_name, r.venue_name, r.event_date) m
     LIMIT 1;

    CONTINUE WHEN v_aq IS NULL;

    SELECT a.venue_short_id, a.performer_short_id INTO v_vs, v_ps
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq LIMIT 1;

    UPDATE public.s4k_marketplace_orders o
       SET aq_short_event_id  = v_aq,
           venue_short_id     = coalesce(o.venue_short_id, v_vs),
           performer_short_id = coalesce(o.performer_short_id, v_ps)
     WHERE o.source = r.source
       AND o.event_name IS NOT DISTINCT FROM r.event_name
       AND o.venue_name IS NOT DISTINCT FROM r.venue_name
       AND o.event_date = r.event_date
       AND o.aq_short_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    v_m := v_m + 1; v_rows := v_rows + v_n;
  END LOOP;

  RETURN QUERY SELECT 's4k_marketplace_orders'::text, v_ex, v_m, v_rows, v_ex - v_m;
END;
$function$;

REVOKE ALL ON FUNCTION public.s4k_orders_match_sweep(integer) FROM PUBLIC, anon, authenticated;
;
