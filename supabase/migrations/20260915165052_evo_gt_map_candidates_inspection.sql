-- Migration 20260915165052 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "evo_gt_map_candidates_inspection" (version 20260915165052) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


CREATE UNLOGGED TABLE IF NOT EXISTS public.evo_gt_map_candidates (
  tevo_event_id  bigint,
  gt_event_id    bigint,
  stage          text,
  score          numeric,
  tevo_local_day date,
  gt_local_day   date,
  tevo_name      text,
  gt_name        text,
  tevo_venue     text,
  gt_venue       text,
  tevo_local_ts  timestamp,
  gt_utc         timestamptz,
  computed_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.evo_gt_map_candidates IS
  'Scratch: what the last evo_gt_map() run proposed, apply or dry-run. Replaced each run. Durable write record is evo_gt_map_log (mig 20260915150000).';

CREATE OR REPLACE FUNCTION public.evo_gt_map(
  p_apply         boolean DEFAULT false,
  p_limit         int     DEFAULT 2000,
  p_horizon_days  int     DEFAULT 400,
  p_fuzzy_venue   boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_written int := 0;
  v_s1 int := 0; v_s2 int := 0; v_s3 int := 0; v_tot int := 0;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS _egt (
    tevo_event_id bigint, gt_event_id bigint, stage text, score numeric,
    tevo_ld date, gt_ld date, tevo_name text, gt_name text, venue_name text,
    gt_venue text, tevo_local_ts timestamp, gt_utc timestamptz
  ) ON COMMIT DROP;
  DELETE FROM _egt;

  CREATE TEMP TABLE IF NOT EXISTS _va (
    tevo_venue_id bigint, nm text, city text, st text
  ) ON COMMIT DROP;
  DELETE FROM _va;

  INSERT INTO _va
  SELECT DISTINCT v.tevo_venue_id, lower(trim(x.nm)), lower(trim(v.city)), upper(trim(v.state))
  FROM public.cross_source_venue_map v
  CROSS JOIN LATERAL (
    SELECT v.canonical_name AS nm
    UNION ALL SELECT v.tevo_venue_name
    UNION ALL SELECT jsonb_array_elements_text(
      CASE WHEN jsonb_typeof(v.gotickets_aliases) = 'array' THEN v.gotickets_aliases ELSE '[]'::jsonb END)
  ) x
  WHERE x.nm IS NOT NULL AND btrim(x.nm) <> '' AND v.tevo_venue_id IS NOT NULL;

  CREATE TEMP TABLE IF NOT EXISTS _t (
    id bigint PRIMARY KEY, name text, venue_id bigint, venue_name text, performer text,
    ld date, local_ts timestamp, city text, st text, tz text, siblings int
  ) ON COMMIT DROP;
  DELETE FROM _t;

  INSERT INTO _t
  SELECT e.id, e.name, e.venue_id, e.venue_name, e.primary_performer_name,
         left(e.occurs_at_local,10)::date,
         left(e.occurs_at_local,19)::timestamp,
         lower(nullif(trim(split_part(e.venue_location,',',1)),'')),
         upper(trim(split_part(e.venue_location,',',
               array_length(string_to_array(e.venue_location,','),1)))),
         vt.iana_tz,
         (SELECT count(*) FROM public.events e2
           WHERE e2.venue_id = e.venue_id AND e2.state <> 'ignored'
             AND e2.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
             AND left(e2.occurs_at_local,10)::date
                 BETWEEN left(e.occurs_at_local,10)::date - 1
                     AND left(e.occurs_at_local,10)::date + 1)::int
  FROM public.events e
  LEFT JOIN public.venue_timezone vt ON vt.tevo_venue_id = e.venue_id
  WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
    AND left(e.occurs_at_local,10) >= current_date::text
    AND left(e.occurs_at_local,10) <  (current_date + p_horizon_days)::text
    AND e.state <> 'ignored'
    AND coalesce(e.name,'')       !~* 'parking|shuttle'
    AND coalesce(e.venue_name,'') !~* 'parking'
    AND coalesce(e.name,'')       !~* '\(date tbd\)|\btbd\b|if necessary'
    AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g WHERE g.tevo_event_id = e.id)
  ORDER BY left(e.occurs_at_local,10)::date
  LIMIT p_limit;

  CREATE TEMP TABLE IF NOT EXISTS _g (
    gt_event_id bigint PRIMARY KEY, name text, performer text, venue_name text,
    city text, st text, utc timestamptz
  ) ON COMMIT DROP;
  DELETE FROM _g;

  INSERT INTO _g
  SELECT g.gt_event_id, g.name, g.performer, g.venue_name,
         lower(trim(g.venue_city)), upper(trim(g.venue_state)), g.event_time_utc
  FROM public.gotickets_event g
  WHERE g.tevo_event_id IS NULL
    AND g.status = 'AS_SCHEDULED'
    AND g.event_time_utc IS NOT NULL
    AND g.event_time_utc >= now() - interval '2 days'
    AND g.event_time_utc <  now() + (p_horizon_days || ' days')::interval
    AND coalesce(g.name,'')       !~* 'parking|shuttle'
    AND coalesce(g.venue_name,'') !~* 'parking'
    AND coalesce(g.name,'')       !~* '\(date tbd\)|\btbd\b|if necessary';

  CREATE INDEX IF NOT EXISTS _g_utc_idx ON _g (utc);
  CREATE INDEX IF NOT EXISTS _g_city_idx ON _g (city, st, utc);
  CREATE INDEX IF NOT EXISTS _va_key_idx ON _va (nm, city, st);
  ANALYZE _g; ANALYZE _t; ANALYZE _va;

  CREATE TEMP TABLE IF NOT EXISTS _gx (
    gt_event_id bigint, tevo_venue_id bigint
  ) ON COMMIT DROP;
  DELETE FROM _gx;

  INSERT INTO _gx
  SELECT DISTINCT g.gt_event_id, va.tevo_venue_id
  FROM _g g
  JOIN _va va ON va.nm = lower(trim(g.venue_name)) AND va.city = g.city AND va.st = g.st;

  CREATE INDEX IF NOT EXISTS _gx_v_idx ON _gx (tevo_venue_id);
  ANALYZE _gx;

  CREATE TEMP TABLE IF NOT EXISTS _p (
    tevo_event_id bigint, gt_event_id bigint, stage text, score numeric,
    tevo_ld date, gt_ld date
  ) ON COMMIT DROP;
  DELETE FROM _p;

  INSERT INTO _p
  SELECT t.id, g.gt_event_id, c.stage, ev.score, t.ld, ev.gt_ld
  FROM _t t
  JOIN _gx x ON x.tevo_venue_id = t.venue_id
  JOIN _g  g ON g.gt_event_id = x.gt_event_id
            AND g.utc >= (t.ld - 1)::timestamptz AND g.utc < (t.ld + 2)::timestamptz
  CROSS JOIN LATERAL (
    SELECT
      greatest(
        coalesce(similarity(lower(public.unaccent(g.name)),      lower(public.unaccent(t.name))), 0),
        coalesce(similarity(lower(public.unaccent(g.performer)), lower(public.unaccent(t.performer))), 0)
      ) AS score,
      CASE WHEN t.tz IS NOT NULL THEN (g.utc AT TIME ZONE t.tz)::date END AS gt_ld,
      (t.tz IS NOT NULL
        AND (g.utc AT TIME ZONE t.tz)::time BETWEEN '00:30' AND '23:30') AS decidable
  ) ev
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN ev.decidable AND ev.gt_ld = t.ld AND ev.score >= 0.60 THEN '1_xwalk_day'
      WHEN t.tz IS NOT NULL AND t.local_ts::time <> '00:00'::time
           AND (g.utc AT TIME ZONE t.tz) = t.local_ts AND ev.score >= 0.45 THEN '2_xwalk_minute'
      WHEN NOT ev.decidable AND ev.score >= 0.80 AND t.siblings = 1 THEN '4_xwalk_window'
    END AS stage
  ) c
  WHERE c.stage IS NOT NULL
    AND public.aq_name_consistent(public.unaccent(t.name), public.unaccent(g.name))
    AND (regexp_match(lower(t.name), '(?:home )?game\s*(\d+)'))[1]
        IS NOT DISTINCT FROM (regexp_match(lower(g.name), '(?:home )?game\s*(\d+)'))[1]
    AND (regexp_match(lower(t.name), 'session\s*(\d+)'))[1]
        IS NOT DISTINCT FROM (regexp_match(lower(g.name), 'session\s*(\d+)'))[1];

  IF p_fuzzy_venue THEN
    INSERT INTO _p
    SELECT t.id, g.gt_event_id, '3_fuzzy_day', ev.score, t.ld, ev.gt_ld
    FROM _t t
    JOIN _g g ON g.city = t.city AND g.st = t.st
             AND g.utc >= (t.ld - 1)::timestamptz AND g.utc < (t.ld + 2)::timestamptz
    CROSS JOIN LATERAL (
      SELECT
        greatest(
          coalesce(similarity(lower(public.unaccent(g.name)),      lower(public.unaccent(t.name))), 0),
          coalesce(similarity(lower(public.unaccent(g.performer)), lower(public.unaccent(t.performer))), 0)
        ) AS score,
        CASE WHEN t.tz IS NOT NULL THEN (g.utc AT TIME ZONE t.tz)::date END AS gt_ld,
        (t.tz IS NOT NULL
          AND (g.utc AT TIME ZONE t.tz)::time BETWEEN '00:30' AND '23:30') AS decidable
    ) ev
    WHERE t.city IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM _p q WHERE q.tevo_event_id = t.id)
      AND similarity(lower(public.unaccent(g.venue_name)), lower(public.unaccent(t.venue_name))) >= 0.60
      AND ev.decidable AND ev.gt_ld = t.ld AND ev.score >= 0.70
      AND public.aq_name_consistent(public.unaccent(t.name), public.unaccent(g.name))
      AND (regexp_match(lower(t.name), '(?:home )?game\s*(\d+)'))[1]
          IS NOT DISTINCT FROM (regexp_match(lower(g.name), '(?:home )?game\s*(\d+)'))[1]
      AND (regexp_match(lower(t.name), 'session\s*(\d+)'))[1]
          IS NOT DISTINCT FROM (regexp_match(lower(g.name), 'session\s*(\d+)'))[1];
  END IF;

  CREATE INDEX IF NOT EXISTS _p_t_idx ON _p (tevo_event_id);
  CREATE INDEX IF NOT EXISTS _p_g_idx ON _p (gt_event_id);
  ANALYZE _p;

  INSERT INTO _egt
  SELECT p.tevo_event_id, p.gt_event_id, p.stage, p.score, p.tevo_ld, p.gt_ld,
         t.name, g.name, t.venue_name, g.venue_name, t.local_ts, g.utc
  FROM _p p
  JOIN _t t ON t.id = p.tevo_event_id
  JOIN _g g ON g.gt_event_id = p.gt_event_id
  WHERE NOT EXISTS (SELECT 1 FROM _p q WHERE q.tevo_event_id = p.tevo_event_id
                      AND q.gt_event_id <> p.gt_event_id)
    AND NOT EXISTS (SELECT 1 FROM _p q WHERE q.gt_event_id = p.gt_event_id
                      AND q.tevo_event_id <> p.tevo_event_id);

  SELECT count(*) FILTER (WHERE stage='1_xwalk_day'),
         count(*) FILTER (WHERE stage='2_xwalk_minute'),
         count(*) FILTER (WHERE stage='3_fuzzy_day'),
         count(*)
    INTO v_s1, v_s2, v_s3, v_tot
  FROM _egt;

  DELETE FROM public.evo_gt_map_candidates;
  INSERT INTO public.evo_gt_map_candidates
    (tevo_event_id, gt_event_id, stage, score, tevo_local_day, gt_local_day,
     tevo_name, gt_name, tevo_venue, gt_venue, tevo_local_ts, gt_utc)
  SELECT tevo_event_id, gt_event_id, stage, score, tevo_ld, gt_ld,
         tevo_name, gt_name, venue_name, gt_venue, tevo_local_ts, gt_utc
  FROM _egt;

  IF p_apply THEN
    WITH w AS (
      UPDATE public.gotickets_event g
         SET tevo_event_id = e.tevo_event_id,
             mapped_via    = 'evo_to_gt_v1',
             map_score     = e.score,
             mapped_at     = now()
        FROM _egt e
       WHERE g.gt_event_id = e.gt_event_id
         AND g.tevo_event_id IS NULL
      RETURNING g.gt_event_id
    )
    INSERT INTO public.evo_gt_map_log
      (gt_event_id, tevo_event_id, stage, score, tevo_local_day, gt_local_day,
       tevo_name, gt_name, venue_name)
    SELECT e.gt_event_id, e.tevo_event_id, e.stage, e.score, e.tevo_ld, e.gt_ld,
           e.tevo_name, e.gt_name, e.venue_name
    FROM _egt e JOIN w ON w.gt_event_id = e.gt_event_id
    ON CONFLICT (gt_event_id) DO NOTHING;
    GET DIAGNOSTICS v_written = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'applied', p_apply,
    'tevo_candidates_considered', (SELECT count(*) FROM _t),
    'gt_pool', (SELECT count(*) FROM _g),
    'pairs', (SELECT count(*) FROM _p),
    'proposed', v_tot,
    'by_stage', jsonb_build_object(
      '1_xwalk_day', v_s1, '2_xwalk_minute', v_s2, '3_fuzzy_day', v_s3,
      '4_xwalk_window', v_tot - v_s1 - v_s2 - v_s3),
    'written', v_written
  );
END $fn$;
;
