-- Migration 20260831200652 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "event_mapping_queue" (version 20260831200652) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

CREATE TABLE IF NOT EXISTS public.event_mapping_queue (
  id               bigserial PRIMARY KEY,
  tevo_event_id    bigint      NOT NULL,
  target_source    text        NOT NULL CHECK (target_source IN ('GT','SG','TD_MATCH')),
  status           text        NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','resolved','abandoned')),
  attempts         int         NOT NULL DEFAULT 0,
  first_queued_at  timestamptz NOT NULL DEFAULT now(),
  next_eligible_at timestamptz NOT NULL DEFAULT now(),
  last_attempt_at  timestamptz,
  resolved_at      timestamptz,
  resolved_ref     text,
  match_method     text,
  match_confidence numeric,
  last_reason      text,
  UNIQUE (tevo_event_id, target_source)
);

CREATE INDEX IF NOT EXISTS idx_emq_due
  ON public.event_mapping_queue (target_source, next_eligible_at)
  WHERE status = 'pending';

COMMENT ON TABLE public.event_mapping_queue IS
  'Durable EVO-anchored cross-source mapping intents. A pending row is re-evaluated against current source data on every drain, so it resolves when the counterpart event appears (GT/SG legs) or when credits free up (TD_MATCH leg). Mig 20260831200000.';

CREATE OR REPLACE FUNCTION public.event_mapping_enqueue(p_horizon_days int DEFAULT 180)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  n int := 0;
  us_states text[] := ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC'];
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'event_mapping_enqueue: caller % not authorized', current_user USING ERRCODE='42501';
  END IF;

  WITH evo AS (
    SELECT e.id
    FROM public.events e
    WHERE e.occurs_at_local::timestamp > (now() AT TIME ZONE 'UTC')
      AND e.occurs_at_local::timestamp < (now() AT TIME ZONE 'UTC') + make_interval(days => p_horizon_days)
      AND split_part(coalesce(e.venue_location,''), ', ', 2) = ANY(us_states)
  ),
  want AS (
    SELECT id AS tevo_event_id, 'GT'::text AS target_source FROM evo
     WHERE id NOT IN (SELECT tevo_event_id FROM public.gotickets_event WHERE tevo_event_id IS NOT NULL)
    UNION ALL
    SELECT id, 'SG' FROM evo
     WHERE id NOT IN (SELECT tevo_event_id FROM public.sg_events_canonical WHERE tevo_event_id IS NOT NULL)
  )
  INSERT INTO public.event_mapping_queue (tevo_event_id, target_source)
  SELECT tevo_event_id, target_source FROM want
  ON CONFLICT (tevo_event_id, target_source) DO NOTHING;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapping_enqueue(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapping_enqueue(int) TO service_role;

CREATE OR REPLACE FUNCTION public.event_mapping_drain(
  p_source        text,
  p_max           int DEFAULT 300,
  p_budget_secs   int DEFAULT 45
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  v_start timestamptz := clock_timestamp();
  r RECORD; v_ref text; v_resolved int := 0; v_missed int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'event_mapping_drain: caller % not authorized', current_user USING ERRCODE='42501';
  END IF;
  IF p_source NOT IN ('GT','SG') THEN
    RAISE EXCEPTION 'event_mapping_drain: unsupported source % (TD_MATCH drains via sg_match_map_tick)', p_source;
  END IF;

  FOR r IN
    SELECT q.id, q.tevo_event_id,
           e.occurs_at_local::timestamp AS local_ts,
           lower(regexp_replace(coalesce(e.venue_name,''),'[^a-z0-9]+','','gi')) AS cname,
           lower(coalesce(e.primary_performer_name,'') || ' ' || coalesce(e.name,'')) AS etext
      FROM public.event_mapping_queue q
      JOIN public.events e ON e.id = q.tevo_event_id
     WHERE q.status = 'pending' AND q.target_source = p_source
       AND q.next_eligible_at <= now()
     ORDER BY q.next_eligible_at
     LIMIT p_max
  LOOP
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_secs);
    v_ref := NULL;

    IF p_source = 'GT' THEN
      SELECT g.gt_event_id::text INTO v_ref
        FROM public.gotickets_event g
       WHERE g.tevo_event_id IS NULL
         AND lower(regexp_replace(coalesce(g.venue_name,''),'[^a-z0-9]+','','gi')) = r.cname
         AND (g.event_time_utc AT TIME ZONE 'UTC')
             BETWEEN r.local_ts - interval '24 hours' AND r.local_ts + interval '24 hours'
         AND coalesce(g.venue_name,'') !~* 'parking'
         AND coalesce(g.performer,'')  !~* 'parking'
         AND EXISTS (SELECT 1 FROM regexp_split_to_table(r.etext,'[^a-z0-9]+') w
                      WHERE length(w) >= 5
                        AND lower(coalesce(g.performer,'') || ' ' || coalesce(g.name,'')) LIKE '%'||w||'%')
       ORDER BY abs(extract(epoch FROM ((g.event_time_utc AT TIME ZONE 'UTC') - r.local_ts)))
       LIMIT 1;

      IF v_ref IS NOT NULL THEN
        UPDATE public.gotickets_event
           SET tevo_event_id = r.tevo_event_id, mapped_via = 'mapping_queue_v1',
               map_score = 0.80, mapped_at = now()
         WHERE gt_event_id = v_ref::bigint AND tevo_event_id IS NULL;
      END IF;

    ELSE
      SELECT s.sg_event_id::text INTO v_ref
        FROM public.sg_events_canonical s
       WHERE s.tevo_event_id IS NULL
         AND lower(regexp_replace(coalesce(s.sg_venue_name,''),'[^a-z0-9]+','','gi')) = r.cname
         AND (s.sg_datetime_utc AT TIME ZONE 'UTC')
             BETWEEN r.local_ts - interval '24 hours' AND r.local_ts + interval '24 hours'
         AND coalesce(s.sg_event_name,'') !~* 'parking'
         AND EXISTS (SELECT 1 FROM regexp_split_to_table(r.etext,'[^a-z0-9]+') w
                      WHERE length(w) >= 5
                        AND lower(coalesce(s.sg_event_name,'')) LIKE '%'||w||'%')
       ORDER BY abs(extract(epoch FROM ((s.sg_datetime_utc AT TIME ZONE 'UTC') - r.local_ts)))
       LIMIT 1;

      IF v_ref IS NOT NULL THEN
        UPDATE public.sg_events_canonical
           SET tevo_event_id = r.tevo_event_id, match_method = 'mapping_queue_v1',
               match_confidence = 0.80, matched_at = now()
         WHERE sg_event_id = v_ref::bigint AND tevo_event_id IS NULL;
      END IF;
    END IF;

    IF v_ref IS NOT NULL THEN
      UPDATE public.event_mapping_queue
         SET status='resolved', resolved_at=now(), resolved_ref=v_ref,
             match_method='mapping_queue_v1', match_confidence=0.80,
             attempts=attempts+1, last_attempt_at=now(), last_reason=NULL
       WHERE id = r.id;
      v_resolved := v_resolved + 1;
    ELSE
      UPDATE public.event_mapping_queue
         SET attempts = attempts + 1, last_attempt_at = now(),
             last_reason = 'no_counterpart',
             next_eligible_at = now() + least(make_interval(mins => 30 * (attempts + 1)), interval '12 hours')
       WHERE id = r.id;
      v_missed := v_missed + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('source', p_source, 'resolved', v_resolved,
                            'missed', v_missed,
                            'secs', round(extract(epoch FROM (clock_timestamp()-v_start))::numeric,1));
END $fn$;

REVOKE ALL ON FUNCTION public.event_mapping_drain(text,int,int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_mapping_drain(text,int,int) TO service_role;

INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, enabled, notes)
VALUES
  ('event_mapping_queue_tick', '{}', 30, 30, 48, true,
   'Enrolls EVO US upcoming events lacking a GT/SG link and drains the free legs. Mig 20260831200000.')
ON CONFLICT (jobname) DO UPDATE
  SET peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = EXCLUDED.enabled, notes = EXCLUDED.notes, updated_at = now();

SELECT cron.unschedule('event_mapping_queue_tick')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'event_mapping_queue_tick');

SELECT cron.schedule('event_mapping_queue_tick', '26,56 * * * *', $sched$
DO $b$ BEGIN
  IF NOT public.cron_should_fire('event_mapping_queue_tick') THEN RETURN; END IF;
  PERFORM public.event_mapping_enqueue(180);
  PERFORM public.event_mapping_drain('GT', 300, 45);
  PERFORM public.event_mapping_drain('SG', 300, 45);
END $b$;
$sched$);
;
