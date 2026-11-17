-- Restrict both sides of evo_gt_map to US + Canada, and stop a resident orchestra's performer
-- match from masking a different programme.
--
-- Operator: "filter evo and go tix to us/canada events only and map the two lists."
--
-- ============================================================================================
-- WHY ONE SHARED REGION TEST
-- ============================================================================================
-- GoTickets carries no country column at all -- only venue_state -- so on that side the region
-- code IS the country test. TEvo's mirror expresses it differently again, as the last segment of
-- events.venue_location ("Toronto, ON"), with venue_assets.country as a second opinion once the
-- new ingest has seen the venue. Three spellings of the same question.
--
-- is_us_ca_region() exists so the two lists cannot be filtered differently. A mapper whose left
-- side admits Puerto Rico and whose right side does not is comparing two different universes, and
-- the resulting "unmapped" count would be an artefact of the mismatch rather than a fact about
-- the catalogues.
--
-- US territories are IN (PR, VI, GU, AS, MP): TEvo lists Coliseo de Puerto Rico and GoTickets
-- lists the same building, so excluding PR would drop real inventory on a technicality. Blank or
-- unrecognised is OUT -- 300 GoTickets future events carry no state at all, and guessing at them
-- is how a mapper starts matching across continents.
--
-- MEASURED, and every exclusion was read rather than trusted:
--
--   EVO future        11,835 -> 11,731   104 excluded
--   GoTickets future 125,985 -> 108,042  17,943 excluded
--
-- The 104 EVO exclusions are O2 Arena London, Tottenham Hotspur Stadium, Estadio Azteca,
-- Maracana, Bernabeu, Stade de France, Allianz Arena, Accor Arena, Co-op Live Manchester,
-- Veikkaus Arena Helsinki, Autodromo Hermanos Rodriguez and PSD Bank Dome. The GoTickets
-- exclusions are ENGLAND (10,641), CDMX, SCOTLAND, VIC/NSW/QLD, OSLO, NRW, LOMBARDIA, AUCKLAND,
-- IDF, WALES, STOCKHOLMS LAN, ISTANBUL. No US or Canadian code appears in either excluded set.
--
-- ============================================================================================
-- THE RESIDENT-ORCHESTRA DEFECT
-- ============================================================================================
-- evo_gt_map scores a pair as greatest(name_similarity, performer_similarity). For a touring act
-- that is necessary -- "Kamelot with Visions of Atlantis and Frozen Crown" against "Kamelot", or
-- "Unsane" against "Unsane with CNTS", are the same show and only the performer agrees. But
-- greatest() also lets a matching PERFORMER completely mask a differing event NAME, and for a
-- resident ensemble that is exactly wrong. From the first US/CA dry run:
--
--   Vancouver Symphony Orchestra - Mozart, Sibelius and Debussy
--     vs Vancouver Symphony Orchestra - Ravel's Bolero          score 1.00, same hall, same night
--
-- Neither aq_name_consistent nor the ordinal guard catches it: there is no number in dispute and
-- the names are genuinely consistent as far as they overlap. What separates this from the
-- support-act case is WHERE the names diverge -- billing text extends one name, a programme
-- replaces the subtitle on both. So: if both sides carry a subtitle after the first ' - ' and
-- those subtitles disagree, decline.
--
-- ⚠ AND A CORRECTION TO MY OWN READ OF IT. I first reported TWO bad pairs, the second being
-- "Calgary Philharmonic Orchestra - Nordic ..." against "... - Naomi W ...". The full strings are
-- "Nordic Nights with Naomi Woo" and "Naomi Woo - Nordic Nights" -- the SAME concert with the
-- words reordered. I had been reading a 40-character truncation. The guard passes Calgary and
-- declines only Vancouver, which is the behaviour I wanted but not for the reason I first gave.
-- Checked against all 29 proposals before shipping: it declines exactly one and leaves 28 alone,
-- including the ones it could plausibly have broken -- "2026 Harvest Music Festival - Tuesday
-- (Joan Osborne)" against itself, and "Kamelot with ..." where GoTickets has no subtitle at all.
--
-- APPLIED: evo_gt_map(true, 12000, 400, true) wrote 29, taking evo_to_gt_v1 to 307 total.
-- After: EVO future US/CA 11,731 with 6,961 unmapped; GoTickets future US/CA 108,042 with
-- 103,295 unmapped. The GoTickets residue stays large because TEvo genuinely does not carry most
-- of that catalogue -- that asymmetry is a fact about the two books, not a matcher failure.

CREATE OR REPLACE FUNCTION public.is_us_ca_region(p_code text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  SELECT upper(btrim(coalesce(p_code,''))) = ANY (ARRAY[
    'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA',
    'ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK',
    'OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC',
    'PR','VI','GU','AS','MP',
    'ON','QC','BC','AB','MB','SK','NS','NB','NL','PE','NT','YT','NU'
  ]);
$fn$;

COMMENT ON FUNCTION public.is_us_ca_region(text) IS
  'US state / territory or Canadian province code test. Blank or unknown is false. Shared by the EVO and GoTickets sides of evo_gt_map so the two lists are filtered identically (mig 20260915190000).';

REVOKE ALL ON FUNCTION public.is_us_ca_region(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_us_ca_region(text) TO service_role;

CREATE OR REPLACE FUNCTION public.evo_gt_subtitle_agrees(p_a text, p_b text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $fn$
  WITH s AS (
    SELECT nullif(btrim(substring(lower(public.unaccent(coalesce(p_a,''))) from ' - (.*)$')),'') AS sa,
           nullif(btrim(substring(lower(public.unaccent(coalesce(p_b,''))) from ' - (.*)$')),'') AS sb
  )
  SELECT CASE
           WHEN sa IS NULL OR sb IS NULL THEN true
           ELSE similarity(sa, sb) >= 0.45
         END
  FROM s;
$fn$;

COMMENT ON FUNCTION public.evo_gt_subtitle_agrees(text, text) IS
  'False when both names carry a differing subtitle after the first " - ". Stops a resident orchestra''s performer match from masking a different programme on the same night (mig 20260915190000).';

REVOKE ALL ON FUNCTION public.evo_gt_subtitle_agrees(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_subtitle_agrees(text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.evo_gt_map(
  p_apply boolean DEFAULT false, p_limit int DEFAULT 2000,
  p_horizon_days int DEFAULT 400, p_fuzzy_venue boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
DECLARE
  v_written int := 0; v_s1 int := 0; v_s2 int := 0; v_s3 int := 0; v_tot int := 0;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _egt (
    tevo_event_id bigint, gt_event_id bigint, stage text, score numeric,
    tevo_ld date, gt_ld date, tevo_name text, gt_name text, venue_name text,
    gt_venue text, tevo_local_ts timestamp, gt_utc timestamptz) ON COMMIT DROP;
  DELETE FROM _egt;
  CREATE TEMP TABLE IF NOT EXISTS _va (tevo_venue_id bigint, nm text, city text, st text) ON COMMIT DROP;
  DELETE FROM _va;
  INSERT INTO _va
  SELECT DISTINCT v.tevo_venue_id, lower(trim(x.nm)), lower(trim(v.city)), upper(trim(v.state))
  FROM public.cross_source_venue_map v
  CROSS JOIN LATERAL (SELECT v.canonical_name AS nm UNION ALL SELECT v.tevo_venue_name
    UNION ALL SELECT jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(v.gotickets_aliases)='array' THEN v.gotickets_aliases ELSE '[]'::jsonb END)) x
  WHERE x.nm IS NOT NULL AND btrim(x.nm) <> '' AND v.tevo_venue_id IS NOT NULL;

  CREATE TEMP TABLE IF NOT EXISTS _t (
    id bigint PRIMARY KEY, name text, venue_id bigint, venue_name text, performer text,
    ld date, local_ts timestamp, city text, st text, tz text, siblings int) ON COMMIT DROP;
  DELETE FROM _t;
  INSERT INTO _t
  SELECT e.id, e.name, e.venue_id, e.venue_name, e.primary_performer_name,
         left(e.occurs_at_local,10)::date, left(e.occurs_at_local,19)::timestamp,
         lower(nullif(trim(split_part(e.venue_location,',',1)),'')),
         upper(trim(split_part(e.venue_location,',',array_length(string_to_array(e.venue_location,','),1)))),
         vt.iana_tz,
         (SELECT count(*) FROM public.events e2 WHERE e2.venue_id=e.venue_id AND e2.state<>'ignored'
            AND e2.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
            AND left(e2.occurs_at_local,10)::date BETWEEN left(e.occurs_at_local,10)::date-1
                                                      AND left(e.occurs_at_local,10)::date+1)::int
  FROM public.events e
  LEFT JOIN public.venue_timezone vt ON vt.tevo_venue_id = e.venue_id
  LEFT JOIN public.venue_assets va ON va.tevo_venue_id = e.venue_id
  WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
    AND left(e.occurs_at_local,10) >= current_date::text
    AND left(e.occurs_at_local,10) <  (current_date + p_horizon_days)::text
    AND e.state <> 'ignored'
    AND coalesce(e.name,'') !~* 'parking|shuttle' AND coalesce(e.venue_name,'') !~* 'parking'
    AND coalesce(e.name,'') !~* '\(date tbd\)|\btbd\b|if necessary'
    AND (public.is_us_ca_region(
           split_part(e.venue_location,',',array_length(string_to_array(e.venue_location,','),1)))
         OR va.country IN ('US','CA'))
    AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g WHERE g.tevo_event_id = e.id)
  ORDER BY left(e.occurs_at_local,10)::date LIMIT p_limit;

  CREATE TEMP TABLE IF NOT EXISTS _g (
    gt_event_id bigint PRIMARY KEY, name text, performer text, venue_name text,
    city text, st text, utc timestamptz) ON COMMIT DROP;
  DELETE FROM _g;
  INSERT INTO _g
  SELECT g.gt_event_id, g.name, g.performer, g.venue_name,
         lower(trim(g.venue_city)), upper(trim(g.venue_state)), g.event_time_utc
  FROM public.gotickets_event g
  WHERE g.tevo_event_id IS NULL AND g.status='AS_SCHEDULED' AND g.event_time_utc IS NOT NULL
    AND g.event_time_utc >= now() - interval '2 days'
    AND g.event_time_utc <  now() + (p_horizon_days || ' days')::interval
    AND coalesce(g.name,'') !~* 'parking|shuttle' AND coalesce(g.venue_name,'') !~* 'parking'
    AND coalesce(g.name,'') !~* '\(date tbd\)|\btbd\b|if necessary'
    AND public.is_us_ca_region(g.venue_state);

  CREATE INDEX IF NOT EXISTS _g_utc_idx ON _g (utc);
  CREATE INDEX IF NOT EXISTS _g_city_idx ON _g (city, st, utc);
  CREATE INDEX IF NOT EXISTS _va_key_idx ON _va (nm, city, st);
  ANALYZE _g; ANALYZE _t; ANALYZE _va;

  CREATE TEMP TABLE IF NOT EXISTS _gx (gt_event_id bigint, tevo_venue_id bigint) ON COMMIT DROP;
  DELETE FROM _gx;
  INSERT INTO _gx SELECT DISTINCT g.gt_event_id, va.tevo_venue_id
  FROM _g g JOIN _va va ON va.nm = lower(trim(g.venue_name)) AND va.city = g.city AND va.st = g.st;
  CREATE INDEX IF NOT EXISTS _gx_v_idx ON _gx (tevo_venue_id);
  ANALYZE _gx;

  CREATE TEMP TABLE IF NOT EXISTS _p (
    tevo_event_id bigint, gt_event_id bigint, stage text, score numeric,
    tevo_ld date, gt_ld date) ON COMMIT DROP;
  DELETE FROM _p;

  INSERT INTO _p
  SELECT t.id, g.gt_event_id, c.stage, ev.score, t.ld, ev.gt_ld
  FROM _t t
  JOIN _gx x ON x.tevo_venue_id = t.venue_id
  JOIN _g  g ON g.gt_event_id = x.gt_event_id
            AND g.utc >= (t.ld - 1)::timestamptz AND g.utc < (t.ld + 2)::timestamptz
  CROSS JOIN LATERAL (
    SELECT greatest(
        coalesce(similarity(lower(public.unaccent(g.name)),      lower(public.unaccent(t.name))), 0),
        coalesce(similarity(lower(public.unaccent(g.performer)), lower(public.unaccent(t.performer))), 0)) AS score,
      CASE WHEN t.tz IS NOT NULL THEN (g.utc AT TIME ZONE t.tz)::date END AS gt_ld,
      (t.tz IS NOT NULL AND (g.utc AT TIME ZONE t.tz)::time BETWEEN '00:30' AND '23:30') AS decidable) ev
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN ev.decidable AND ev.gt_ld = t.ld AND ev.score >= 0.60 THEN '1_xwalk_day'
      WHEN t.tz IS NOT NULL AND t.local_ts::time <> '00:00'::time
           AND (g.utc AT TIME ZONE t.tz) = t.local_ts AND ev.score >= 0.45 THEN '2_xwalk_minute'
      WHEN NOT ev.decidable AND ev.score >= 0.80 AND t.siblings = 1 THEN '4_xwalk_window'
    END AS stage) c
  WHERE c.stage IS NOT NULL
    AND public.aq_name_consistent(public.unaccent(t.name), public.unaccent(g.name))
    AND public.evo_gt_ordinals_agree(t.name, g.name)
    AND public.evo_gt_subtitle_agrees(t.name, g.name);

  IF p_fuzzy_venue THEN
    INSERT INTO _p
    SELECT t.id, g.gt_event_id, '3_fuzzy_day', ev.score, t.ld, ev.gt_ld
    FROM _t t
    JOIN _g g ON g.city = t.city AND g.st = t.st
             AND g.utc >= (t.ld - 1)::timestamptz AND g.utc < (t.ld + 2)::timestamptz
    CROSS JOIN LATERAL (
      SELECT greatest(
          coalesce(similarity(lower(public.unaccent(g.name)),      lower(public.unaccent(t.name))), 0),
          coalesce(similarity(lower(public.unaccent(g.performer)), lower(public.unaccent(t.performer))), 0)) AS score,
        CASE WHEN t.tz IS NOT NULL THEN (g.utc AT TIME ZONE t.tz)::date END AS gt_ld,
        (t.tz IS NOT NULL AND (g.utc AT TIME ZONE t.tz)::time BETWEEN '00:30' AND '23:30') AS decidable) ev
    WHERE t.city IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM _p q WHERE q.tevo_event_id = t.id)
      AND similarity(lower(public.unaccent(g.venue_name)), lower(public.unaccent(t.venue_name))) >= 0.60
      AND ev.decidable AND ev.gt_ld = t.ld AND ev.score >= 0.70
      AND public.aq_name_consistent(public.unaccent(t.name), public.unaccent(g.name))
      AND public.evo_gt_ordinals_agree(t.name, g.name)
      AND public.evo_gt_subtitle_agrees(t.name, g.name);
  END IF;

  CREATE INDEX IF NOT EXISTS _p_t_idx ON _p (tevo_event_id);
  CREATE INDEX IF NOT EXISTS _p_g_idx ON _p (gt_event_id);
  ANALYZE _p;

  INSERT INTO _egt
  SELECT p.tevo_event_id, p.gt_event_id, p.stage, p.score, p.tevo_ld, p.gt_ld,
         t.name, g.name, t.venue_name, g.venue_name, t.local_ts, g.utc
  FROM _p p JOIN _t t ON t.id = p.tevo_event_id JOIN _g g ON g.gt_event_id = p.gt_event_id
  WHERE NOT EXISTS (SELECT 1 FROM _p q WHERE q.tevo_event_id = p.tevo_event_id AND q.gt_event_id <> p.gt_event_id)
    AND NOT EXISTS (SELECT 1 FROM _p q WHERE q.gt_event_id = p.gt_event_id AND q.tevo_event_id <> p.tevo_event_id);

  SELECT count(*) FILTER (WHERE stage='1_xwalk_day'), count(*) FILTER (WHERE stage='2_xwalk_minute'),
         count(*) FILTER (WHERE stage='3_fuzzy_day'), count(*)
    INTO v_s1, v_s2, v_s3, v_tot FROM _egt;

  DELETE FROM public.evo_gt_map_candidates;
  INSERT INTO public.evo_gt_map_candidates
    (tevo_event_id, gt_event_id, stage, score, tevo_local_day, gt_local_day,
     tevo_name, gt_name, tevo_venue, gt_venue, tevo_local_ts, gt_utc)
  SELECT tevo_event_id, gt_event_id, stage, score, tevo_ld, gt_ld,
         tevo_name, gt_name, venue_name, gt_venue, tevo_local_ts, gt_utc FROM _egt;

  IF p_apply THEN
    WITH w AS (
      UPDATE public.gotickets_event g
         SET tevo_event_id = e.tevo_event_id, mapped_via = 'evo_to_gt_v1',
             map_score = e.score, mapped_at = now()
        FROM _egt e WHERE g.gt_event_id = e.gt_event_id AND g.tevo_event_id IS NULL
      RETURNING g.gt_event_id)
    INSERT INTO public.evo_gt_map_log
      (gt_event_id, tevo_event_id, stage, score, tevo_local_day, gt_local_day, tevo_name, gt_name, venue_name)
    SELECT e.gt_event_id, e.tevo_event_id, e.stage, e.score, e.tevo_ld, e.gt_ld,
           e.tevo_name, e.gt_name, e.venue_name
    FROM _egt e JOIN w ON w.gt_event_id = e.gt_event_id
    ON CONFLICT (gt_event_id) DO NOTHING;
    GET DIAGNOSTICS v_written = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object('applied', p_apply,
    'tevo_candidates_considered', (SELECT count(*) FROM _t), 'gt_pool', (SELECT count(*) FROM _g),
    'pairs', (SELECT count(*) FROM _p), 'proposed', v_tot,
    'by_stage', jsonb_build_object('1_xwalk_day', v_s1, '2_xwalk_minute', v_s2,
      '3_fuzzy_day', v_s3, '4_xwalk_window', v_tot - v_s1 - v_s2 - v_s3),
    'written', v_written);
END $fn$;
