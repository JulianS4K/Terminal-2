-- Migration 20260915190515 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "evo_gt_pipeline_local_day_gate" (version 20260915190515) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

ALTER TABLE public.evo_gt_event_pair
  ADD COLUMN IF NOT EXISTS evo_local_date date,
  ADD COLUMN IF NOT EXISTS gt_local_date  date,
  ADD COLUMN IF NOT EXISTS same_local_day boolean;

COMMENT ON COLUMN public.evo_gt_event_pair.same_local_day IS
  'The gate that makes a +/-24h window safe. The window is the CANDIDATE filter the operator asked for; it is not the acceptance test, because 24h of raw UTC slack is precisely one night of a multi-night run. Measured on the first dry run: of the 14 accepted pairs furthest out in the window, 12 were the adjacent night of the same production -- Grinch at the Ed Mirvish matched Nov 12 to Nov 13, Blue Man Group matched Oct 8 to Oct 9, and Suicideboys took a 24h-away partner while a 0h-away one sat in the same candidate set. Comparing LOCAL DATES rejects all twelve. It also keeps the one real pair in that band: TEvo writes an unknown start time as 00:00 and GoTickets writes it as 23:59, so Penn State at Michigan reads as 23.98h apart while both sides plainly mean the same Saturday (mig 20260915230000).';

CREATE OR REPLACE FUNCTION public.evo_gt_pipeline_match(
  p_apply        boolean DEFAULT false,
  p_window_hours numeric DEFAULT 24,
  p_min_score    numeric DEFAULT 0.55,
  p_rival_floor  numeric DEFAULT 0.30,
  p_margin       numeric DEFAULT 0.05,
  p_time_decisive_hours numeric DEFAULT 6)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_written int := 0; v_out jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'evo_gt_pipeline_match: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '900000', true);

  DROP TABLE IF EXISTS _p;
  CREATE TEMP TABLE _p ON COMMIT DROP AS
  SELECT e.tevo_event_id, g.gt_event_id, l.tevo_venue_id, l.gt_venue_key,
         round((abs(extract(epoch FROM (g.utc_ts - e.utc_ts))) / 3600.0)::numeric, 3) AS delta_hours,
         e.local_ts::date                              AS evo_local_date,
         (g.utc_ts AT TIME ZONE e.iana_tz)::date       AS gt_local_date,
         (e.local_ts::date = (g.utc_ts AT TIME ZONE e.iana_tz)::date) AS same_local_day,
         similarity(public.tevo_venue_search_norm(e.event_name),
                    public.tevo_venue_search_norm(g.event_name))::numeric AS name_sim,
         CASE WHEN nullif(btrim(coalesce(e.primary_performer_name,'')),'') IS NOT NULL
               AND nullif(btrim(coalesce(g.performer,'')),'') IS NOT NULL
              THEN similarity(public.tevo_venue_search_norm(e.primary_performer_name),
                              public.tevo_venue_search_norm(g.performer))::numeric END AS performer_sim,
         public.evo_gt_ordinals_agree(e.event_name, g.event_name)  AS ordinals_ok,
         public.evo_gt_subtitle_agrees(e.event_name, g.event_name) AS subtitle_ok
    FROM public.evo_gt_venue_link l
    JOIN public.v_evo_us_ca_event e
      ON e.tevo_venue_id = l.tevo_venue_id AND e.utc_ts IS NOT NULL
    JOIN public.v_gt_us_ca_event g
      ON g.gt_venue_key = l.gt_venue_key
     AND g.utc_ts >= e.utc_ts - make_interval(secs => (p_window_hours * 3600)::double precision)
     AND g.utc_ts <= e.utc_ts + make_interval(secs => (p_window_hours * 3600)::double precision);

  ALTER TABLE _p ADD COLUMN score numeric;
  UPDATE _p SET score = greatest(name_sim, coalesce(performer_sim, 0));
  DELETE FROM _p WHERE score < p_rival_floor;

  DROP TABLE IF EXISTS _r;
  CREATE TEMP TABLE _r ON COMMIT DROP AS
  SELECT p.*,
         row_number() OVER w_evo AS rn_evo,
         row_number() OVER w_gt  AS rn_gt,
         count(*)     OVER (PARTITION BY tevo_event_id) AS rivals_gt,
         count(*)     OVER (PARTITION BY gt_event_id)   AS rivals_evo,
         lead(score)       OVER w_evo AS runner_up_score,
         lead(delta_hours) OVER w_evo AS runner_up_delta
    FROM _p p
  WINDOW w_evo AS (PARTITION BY tevo_event_id
                   ORDER BY same_local_day DESC, score DESC, delta_hours ASC, gt_event_id),
         w_gt  AS (PARTITION BY gt_event_id
                   ORDER BY same_local_day DESC, score DESC, delta_hours ASC, tevo_event_id);

  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v ON COMMIT DROP AS
  SELECT r.*,
         CASE
           WHEN NOT coalesce(r.same_local_day, false) THEN 'different_local_day'
           WHEN NOT r.ordinals_ok                     THEN 'guard_ordinals'
           WHEN NOT r.subtitle_ok                     THEN 'guard_subtitle'
           WHEN r.rn_evo <> 1 OR r.rn_gt <> 1         THEN 'not_mutual_best'
           WHEN r.score < p_min_score                 THEN 'below_threshold'
           WHEN r.runner_up_score IS NOT NULL
            AND (r.score - r.runner_up_score) < p_margin
            AND (r.runner_up_delta - r.delta_hours) < p_time_decisive_hours
                                                      THEN 'ambiguous_sibling'
           ELSE 'accepted'
         END AS verdict
    FROM _r r;

  DELETE FROM public.evo_gt_event_pair;
  INSERT INTO public.evo_gt_event_pair
    (tevo_event_id, gt_event_id, tevo_venue_id, gt_venue_key, delta_hours, name_sim,
     performer_sim, score, ordinals_ok, subtitle_ok, rn_evo, rn_gt, rivals_evo, rivals_gt,
     runner_up_score, runner_up_delta, verdict, evo_local_date, gt_local_date, same_local_day)
  SELECT tevo_event_id, gt_event_id, tevo_venue_id, gt_venue_key, delta_hours, name_sim,
         performer_sim, score, ordinals_ok, subtitle_ok, rn_evo, rn_gt, rivals_evo, rivals_gt,
         runner_up_score, runner_up_delta, verdict, evo_local_date, gt_local_date, same_local_day
    FROM _v;

  IF p_apply THEN
    WITH w AS (
      UPDATE public.gotickets_event g
         SET tevo_event_id = v.tevo_event_id,
             mapped_via    = 'evo_gt_v2_venue1to1',
             map_score     = v.score,
             mapped_at     = now(),
             updated_at    = now()
        FROM public.evo_gt_event_pair v
       WHERE g.gt_event_id = v.gt_event_id
         AND v.verdict = 'accepted'
         AND g.tevo_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.gotickets_event g2
                          WHERE g2.tevo_event_id = v.tevo_event_id
                            AND g2.gt_event_id <> v.gt_event_id)
      RETURNING 1)
    SELECT count(*) INTO v_written FROM w;
  END IF;

  SELECT jsonb_build_object(
           'applied', p_apply,
           'window_hours', p_window_hours,
           'venue_links_used', (SELECT count(*) FROM public.evo_gt_venue_link),
           'pairs_in_window', (SELECT count(*) FROM public.evo_gt_event_pair),
           'by_verdict', (SELECT jsonb_object_agg(verdict, n) FROM (
               SELECT verdict, count(*) n FROM public.evo_gt_event_pair GROUP BY 1) z),
           'accepted_max_delta_hours',
             (SELECT max(delta_hours) FROM public.evo_gt_event_pair WHERE verdict='accepted'),
           'written', v_written,
           'evo_events_at_linked_venues',
             (SELECT count(*) FROM public.v_evo_us_ca_event e
               JOIN public.evo_gt_venue_link l ON l.tevo_venue_id = e.tevo_venue_id),
           'evo_events_at_linked_venues_no_tz',
             (SELECT count(*) FROM public.v_evo_us_ca_event e
               JOIN public.evo_gt_venue_link l ON l.tevo_venue_id = e.tevo_venue_id
              WHERE e.utc_ts IS NULL),
           'thresholds', jsonb_build_object(
               'min_score', p_min_score, 'rival_floor', p_rival_floor,
               'margin', p_margin, 'time_decisive_hours', p_time_decisive_hours))
    INTO v_out;
  RETURN v_out;
END $fn$;

REVOKE ALL ON FUNCTION public.evo_gt_pipeline_match(boolean, numeric, numeric, numeric, numeric, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_pipeline_match(boolean, numeric, numeric, numeric, numeric, numeric)
  TO service_role;
;
