-- Migration 20260901004300 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_evo_gt_mapper_us_only" (version 20260901004300) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration — evo_map_events_to_gotickets: US venues only
--
-- Lane:     xref+macro
-- Touches:  gotickets_event (W), aq_event_map (W), events (R)
-- Pre-reqs: 20260901001309
--
-- Operator directive 2026-09-01: only poll US GoTickets events.
--
-- gt_listings_poll_tick ALREADY enforces this -- it carries the 50-state + DC
-- list and has done so effectively since mid-August (the 146 non-US rows in
-- gt_listings_poll_state were all last polled 2026-08-25 or earlier, most on
-- 2026-08-11; nothing recent). So polling itself needed no change.
--
-- The mapper did. evo_map_events_to_gotickets had no geography filter, and
-- 257 of the 362 links it created (71%) are non-US -- overwhelmingly Canadian
-- (AB/QC/BC/ON), which is also where the +60/+120 minute timezone discrepancy
-- lives. Those links are factually correct but INERT: the poller will never
-- fetch listings for them, so they buy no data and occupy a
-- gotickets_event_id slot on the hub.
--
-- This aligns the mapper with the poller by reusing gt_listings_poll_tick's
-- exact state list, so the two cannot drift apart. A GoTickets link is now only
-- created where the poller would actually act on it.
--
-- NOT DONE, deliberately: the 257 existing non-US links are left in place.
-- They are correct mappings, and deleting accurate data to satisfy a polling
-- policy trades a real fact for a cosmetic one. They are reported instead --
-- if they should go, that is a separate explicit call.
--
-- Side effect worth noting: this removes the population that produced the
-- Canadian-venue timezone finding (bot_chat #3512). The discrepancy is still
-- real and still unexplained; it just stops being reachable through this
-- mapper. That open question is unaffected.
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
  n1 int := 0; n2 int := 0; n3 int := 0; nh int := 0;
  -- identical to gt_listings_poll_tick's list, so the mapper and the poller
  -- cannot disagree about what "US" means
  us_states text[] := ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC'];
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
     AND upper(btrim(coalesce(g.venue_state,''))) = ANY(us_states)   -- US only
     AND coalesce(g.performer,'')  !~* 'parking'
     AND coalesce(g.name,'')       !~* 'parking'
     AND coalesce(g.venue_name,'') !~* 'parking'
     AND lower(regexp_replace(coalesce(g.venue_name,''), '[^a-z0-9]+','','gi')) = v.cv
     AND g.event_time_utc >= v.utc_ts - interval '30 hours'
     AND g.event_time_utc <  v.utc_ts + interval '30 hours';

  CREATE INDEX ON _evo_gt_cand (tevo_event_id);
  CREATE INDEX ON _evo_gt_cand (gt_event_id);

  INSERT INTO _evo_gt_pick (tevo_event_id, gt_event_id, pick_tier, score)
  SELECT c.tevo_event_id, min(c.gt_event_id), 'evo_gt_exact', 0.95
    FROM _evo_gt_cand c
   WHERE abs(c.delta_min) <= 1 AND c.psim >= 0.45
   GROUP BY c.tevo_event_id
  HAVING count(DISTINCT c.gt_event_id) = 1;

  INSERT INTO _evo_gt_pick (tevo_event_id, gt_event_id, pick_tier, score)
  SELECT c.tevo_event_id, min(c.gt_event_id), 'evo_gt_near', 0.88
    FROM _evo_gt_cand c
   WHERE abs(c.delta_min) <= 120 AND c.psim >= 0.60
     AND NOT EXISTS (SELECT 1 FROM _evo_gt_pick p WHERE p.tevo_event_id = c.tevo_event_id)
   GROUP BY c.tevo_event_id
  HAVING count(DISTINCT c.gt_event_id) = 1;

  INSERT INTO _evo_gt_pick (tevo_event_id, gt_event_id, pick_tier, score)
  SELECT c.tevo_event_id, min(c.gt_event_id), 'evo_gt_tbd', 0.72
    FROM _evo_gt_cand c
   WHERE (c.evo_tbd OR c.gt_tbd)
     AND c.psim >= 0.60
     AND abs((c.gt_utc_date)::date - (c.local_date)::date) <= 1
     AND NOT EXISTS (SELECT 1 FROM _evo_gt_pick p WHERE p.tevo_event_id = c.tevo_event_id)
   GROUP BY c.tevo_event_id
  HAVING count(DISTINCT c.gt_event_id) = 1;

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

    WITH gt AS (
      SELECT tevo_event_id, min(gt_event_id) AS gt_id
        FROM public.gotickets_event
       WHERE tevo_event_id IS NOT NULL
       GROUP BY tevo_event_id
      HAVING count(*) = 1
    )
    UPDATE public.aq_event_map a
       SET gotickets_event_id = gt.gt_id
      FROM gt
     WHERE a.tevo_event_id = gt.tevo_event_id
       AND a.gotickets_event_id IS NULL;
    GET DIAGNOSTICS nh = ROW_COUNT;
  END IF;

  SELECT count(*) FILTER (WHERE p.pick_tier = 'evo_gt_exact'),
         count(*) FILTER (WHERE p.pick_tier = 'evo_gt_near'),
         count(*) FILTER (WHERE p.pick_tier = 'evo_gt_tbd')
    INTO n1, n2, n3
    FROM _evo_gt_pick p;

  tier := 'evo_gt_exact';   matched := n1; RETURN NEXT;
  tier := 'evo_gt_near';    matched := n2; RETURN NEXT;
  tier := 'evo_gt_tbd';     matched := n3; RETURN NEXT;
  tier := 'hub_ids_synced'; matched := nh; RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.evo_map_events_to_gotickets(integer, boolean)
  FROM PUBLIC, anon, authenticated;
;
