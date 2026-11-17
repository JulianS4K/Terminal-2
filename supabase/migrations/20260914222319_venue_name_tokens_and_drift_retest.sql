-- Migration 20260914222319 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "venue_name_tokens_and_drift_retest" (version 20260914222319) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

CREATE OR REPLACE FUNCTION public.venue_name_tokens(p_name text)
RETURNS text[]
LANGUAGE sql IMMUTABLE
AS $fn$
  SELECT coalesce(array_agg(t), '{}'::text[])
  FROM (
    SELECT DISTINCT t
    FROM unnest(regexp_split_to_array(lower(coalesce(p_name,'')), '[^a-z0-9]+')) AS t
    WHERE t <> ''
      AND length(t) > 1
      -- Generic venue furniture carries no identity: two unrelated venues both being a
      -- "center" must not count as agreement (mig 20260914230000).
      AND t NOT IN ('the','at','of','and','a','an','on','in','for',
                    'center','centre','theatre','theater','stadium','arena','amphitheatre',
                    'amphitheater','hall','park','field','music','family','live','hotel',
                    'casino','pavilion','coliseum','auditorium','complex','grounds','venue',
                    'club','room','lounge','bowl','dome','forum','plaza','house')
  ) q
$fn$;
COMMENT ON FUNCTION public.venue_name_tokens(text) IS
  'Identity tokens of a venue name: lowercased, split on non-alphanumerics, 1-char and generic venue words dropped. Two names AGREE when their token sets overlap. A plain containment test does not work — "Centre Bell"/"Bell Centre", "Thomas & Mack"/"Thomas and Mack" and "Cellairis Amphitheatre at Lakewood"/"Lakewood Amphitheatre" are all the same venue and all fail containment (390 false positives on the first drift run). D0 mig 20260914230000.';

DO $do$
DECLARE
  v_def text; v_cnt int;
  v_old text := $a$    WHERE nt <> '' AND (
        (ns <> '' AND position(nt in ns) = 0 AND position(ns in nt) = 0)
     OR (ng <> '' AND position(nt in ng) = 0 AND position(ng in nt) = 0))),$a$;
  v_new text := $b$    WHERE array_length(nt,1) IS NOT NULL AND (
        (array_length(ns,1) IS NOT NULL AND NOT (nt && ns))
     OR (array_length(ng,1) IS NOT NULL AND NOT (nt && ng)))),$b$;
  v_old2 text := $c$           lower(regexp_replace(coalesce(tevo_venue,''), '[^a-zA-Z0-9]', '', 'g')) AS nt,
           lower(regexp_replace(coalesce(sg_venue,''),   '[^a-zA-Z0-9]', '', 'g')) AS ns,
           lower(regexp_replace(coalesce(gt_venue,''),   '[^a-zA-Z0-9]', '', 'g')) AS ng$c$;
  v_new2 text := $d$           public.venue_name_tokens(tevo_venue) AS nt,
           public.venue_name_tokens(sg_venue)   AS ns,
           public.venue_name_tokens(gt_venue)   AS ng$d$;
BEGIN
  SELECT p.prosrc INTO v_def FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='event_catalogue_drift_scan';

  v_cnt := (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2);
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'venue normaliser matched % times (expected 1)', v_cnt; END IF;
  v_def := replace(v_def, v_old2, v_new2);

  v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'venue predicate matched % times (expected 1)', v_cnt; END IF;
  v_def := replace(v_def, v_old, v_new);

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.event_catalogue_drift_scan(p_days_ahead integer DEFAULT 400) '
    || 'RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER '
    || 'SET search_path TO ''public'', ''pg_temp'' AS %L', v_def);
END
$do$;

DELETE FROM public.event_catalogue_drift WHERE drift_kind = 'venue';
;
