-- Migration 20260901000735 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_evo_gt_mapper_fix_tier_ambiguity" (version 20260901000735) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration — fix ambiguous `tier` reference in evo_map_events_to_gotickets
--
-- Lane:     xref+macro
-- Touches:  evo_map_events_to_gotickets (fn)
-- Pre-reqs: xref_evo_to_gotickets_event_mapper (full rationale lives there)
--
-- The final tally read `count(*) FILTER (WHERE tier = ...)` against
-- _evo_gt_pick while `tier` is also the function's OUT parameter, so plpgsql
-- could not tell the column from the variable. Qualified with the table alias.
-- Behaviour is otherwise identical.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.evo_map_events_to_gotickets(
  p_max   integer DEFAULT 5000,
  p_apply boolean DEFAULT true)
RETURNS TABLE(tier text, matched integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  n1 int := 0; n2 int := 0; n3 int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'evo_map_events_to_gotickets: caller % not authorized', current_user;
  END IF;

  CREATE TEMP TABLE _evo_gt_pick (
    tevo_event_id bigint,
    gt_event_id   bigint,
    pick_tier     text,
    score         numeric
  ) ON COMMIT DROP;

  CREATE TEMP TABLE _evo_gt_cand ON COMMIT DROP AS
  WITH evo AS (
    SELECT e.id,
           e.primary_performer_name AS pn,
           e.occurs_at_local::timestamptz AS utc_ts,
           left(e.occurs_at_local, 10) AS local_date,
           (substr(e.occurs_at_local, 12, 5) = '00:00') AS evo_tbd,
           lower(regexp_replace(coalesce(e.venue_name,''), '[^a-z0-9]+','','gi')) AS cv
      FROM public.events e
     WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
       AND e.occurs_at_local::timestamptz > now()
       AND e.primary_performer_name IS NOT NULL
       AND coalesce(e.name,'')       !~* 'parking'
       AND coalesce(e.venue_name,'') !~* 'parking'
       AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2
                        WHERE g2.tevo_event_id = e.id)
     ORDER BY e.occurs_at_local
     LIMIT greatest(p_max, 1)
  )
  SELECT v.id AS tevo_event_id,
         g.gt_event_id,
         extract(epoch FROM (g.event_time_utc - v.utc_ts))/60.0 AS delta_min,
         similarity(lower(g.performer), lower(v.pn)) AS psim,
         v.evo_tbd,
         (extract(minute FROM g.event_time_utc)::int = 59) AS gt_tbd,
         v.local_date,
         to_char(g.event_time_utc, 'YYYY-MM-DD') AS gt_utc_date
    FROM evo v
    JOIN public.gotickets_event g
      ON g.tevo_event_id IS NULL
     AND g.status = 'AS_SCHEDULED'
     AND coalesce(g.performer,'')  !~* 'parking'
     AND coalesce(g.name,'')       !~* 'parking'
     AND coalesce(g.venue_name,'') !~* 'parking'
     AND lower(regexp_replace(coalesce(g.venue_name,''), '[^a-z0-9]+','','gi')) = v.cv
     AND g.event_time_utc >= v.utc_ts - interval '30 hours'
     AND g.event_time_utc <  v.utc_ts + interval '30 hours';

  CREATE INDEX ON _evo_gt_cand (tevo_event_id);
  CREATE INDEX ON _evo_gt_cand (gt_event_id);

  -- Tier 1: same venue, same minute (+/-1), performer agrees
  INSERT INTO _evo_gt_pick (tevo_event_id, gt_event_id, pick_tier, score)
  SELECT c.tevo_event_id, min(c.gt_event_id), 'evo_gt_exact', 0.95
    FROM _evo_gt_cand c
   WHERE abs(c.delta_min) <= 1 AND c.psim >= 0.45
   GROUP BY c.tevo_event_id
  HAVING count(DISTINCT c.gt_event_id) = 1;

  -- Tier 2: same venue, within 2h, stronger performer agreement
  INSERT INTO _evo_gt_pick (tevo_event_id, gt_event_id, pick_tier, score)
  SELECT c.tevo_event_id, min(c.gt_event_id), 'evo_gt_near', 0.88
    FROM _evo_gt_cand c
   WHERE abs(c.delta_min) <= 120 AND c.psim >= 0.60
     AND NOT EXISTS (SELECT 1 FROM _evo_gt_pick p WHERE p.tevo_event_id = c.tevo_event_id)
   GROUP BY c.tevo_event_id
  HAVING count(DISTINCT c.gt_event_id) = 1;

  -- Tier 3: placeholder time on either side -> reconcile by local date
  INSERT INTO _evo_gt_pick (tevo_event_id, gt_event_id, pick_tier, score)
  SELECT c.tevo_event_id, min(c.gt_event_id), 'evo_gt_tbd', 0.72
    FROM _evo_gt_cand c
   WHERE (c.evo_tbd OR c.gt_tbd)
     AND c.psim >= 0.60
     AND abs((c.gt_utc_date)::date - (c.local_date)::date) <= 1
     AND NOT EXISTS (SELECT 1 FROM _evo_gt_pick p WHERE p.tevo_event_id = c.tevo_event_id)
   GROUP BY c.tevo_event_id
  HAVING count(DISTINCT c.gt_event_id) = 1;

  -- Uniqueness the other way: drop any GT row two EVO events both claim
  DELETE FROM _evo_gt_pick p
   WHERE EXISTS (SELECT 1 FROM _evo_gt_pick q
                  WHERE q.gt_event_id = p.gt_event_id
                    AND q.tevo_event_id <> p.tevo_event_id);

  IF p_apply THEN
    UPDATE public.gotickets_event g
       SET tevo_event_id = p.tevo_event_id,
           mapped_via    = p.pick_tier,
           map_score     = p.score,
           mapped_at     = now(),
           updated_at    = now()
      FROM _evo_gt_pick p
     WHERE g.gt_event_id = p.gt_event_id
       AND g.tevo_event_id IS NULL;
  END IF;

  SELECT count(*) FILTER (WHERE p.pick_tier = 'evo_gt_exact'),
         count(*) FILTER (WHERE p.pick_tier = 'evo_gt_near'),
         count(*) FILTER (WHERE p.pick_tier = 'evo_gt_tbd')
    INTO n1, n2, n3
    FROM _evo_gt_pick p;

  tier := 'evo_gt_exact'; matched := n1; RETURN NEXT;
  tier := 'evo_gt_near';  matched := n2; RETURN NEXT;
  tier := 'evo_gt_tbd';   matched := n3; RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.evo_map_events_to_gotickets(integer, boolean)
  FROM PUBLIC, anon, authenticated;
;
