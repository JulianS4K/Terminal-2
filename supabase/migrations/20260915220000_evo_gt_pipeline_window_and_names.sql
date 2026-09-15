-- STEPS 3 and 4 of the four-step pipeline (steps 1 and 2 are mig 20260915210000):
--
--   "...then filter dates with +/- 24 hours and then map event names"
--
-- ============================================================================================
-- THE +/-24 HOUR WINDOW IS A CANDIDATE FILTER, NOT AN ACCEPTANCE TEST
-- ============================================================================================
-- Taken literally and used as the only date test, +/-24h is unsafe, because 24 hours of slack at
-- a single venue is EXACTLY one night of a multi-night run. The adjacent night of the same
-- production carries the same event name and the same performer, so nothing in a name score can
-- separate the two -- only the calendar can.
--
-- This is not a theoretical worry. It was measured. The first dry run applied the window with no
-- day test, and of the 14 accepted pairs furthest out in the window, TWELVE were the adjacent
-- night:
--
--   Grinch at the Ed Mirvish        EVO Nov 13 19:30  <-> GT Nov 12 19:30
--   Blue Man Group at the Luxor     EVO Oct 9  20:00  <-> GT Oct 8  20:00
--   Phantom at the Winspear         EVO Oct 31 19:30  <-> GT Oct 30 19:30
--   Jekyll and Hyde, Broadway Pl.   EVO Sep 15 19:00  <-> GT Sep 16 19:00
--   Bassem Youssef at the Wilbur    EVO Sep 19 19:00  <-> GT Sep 20 19:00
--   Operation Mincemeat, Royal Alex (twice), Sugar Skull, World of Warcraft, Sabaton, Romeo and
--   Juliet, and Suicideboys -- which took a partner 24h away while a 0h-away partner sat in its
--   own candidate set, because the far one scored fractionally higher on the name.
--
-- The 13th and 14th were right, and they are why the window still has to be 24 hours wide:
-- Penn State at Michigan, and every other TBD-kickoff college football game. TEvo writes an
-- unknown start time as 00:00 and GoTickets writes it as 23:59, so two rows that plainly mean the
-- same Saturday sit 23.983 hours apart. A window tight enough to exclude the adjacent night would
-- throw all of those away.
--
-- So: the window selects candidates, and same_local_day decides. Comparing LOCAL DATES -- the
-- EVO local date against the GoTickets instant rendered in the same venue's timezone -- rejects
-- all twelve wrong-night pairs and keeps every TBD-kickoff pair, because 00:00 and 23:59 on the
-- same date are the same date. MEASURED: 3,824 pairs rejected as different_local_day, and
-- accepted went UP, 6,703 -> 6,816, because genuine same-day candidates won slots that wrong-night
-- rivals had been taking.
--
-- The ranking order is same_local_day DESC, then score, then |delta|. Score-first is what let the
-- Suicideboys pair pick the wrong night.
--
-- ============================================================================================
-- STEP 4 -- names, with the guards that already exist
-- ============================================================================================
-- score = greatest(name_sim, performer_sim). Performer similarity is load-bearing: TEvo writes
-- the whole bill ("Steve Earle with Elizabeth Cook, Gillian Welch and David Rawlings, and Emmylou
-- Harris") where GoTickets writes the headliner ("Steve Earle"), and the name score alone is 0.16
-- on that pair. Every performer-driven acceptance that was read back was correct: headliner vs
-- full bill, or an alias ("LP" / "LP - Laura Pergolizzi", "Tusk" / "Tusk - The Ultimate Fleetwood
-- Mac Tribute", "David Arquette" / "Behind The Scream").
--
-- evo_gt_ordinals_agree and evo_gt_subtitle_agrees (migs 20260915150000, 20260915190000) are
-- reused rather than reimplemented. Acceptance also needs mutual-best both ways plus either a
-- score margin or a decisive time gap -- a tied score is accepted only when the winner is at
-- least p_time_decisive_hours closer, which is what separates a two-night run from a genuine
-- matinee/evening ambiguity. The ambiguity is left unmapped rather than guessed.
--
-- ============================================================================================
-- REJECTED PAIRS ARE STORED
-- ============================================================================================
-- evo_gt_event_pair keeps the losers with the reason they lost. A mapper that stores only its
-- winners cannot be audited, and every wrong mapping found in this project so far was found by
-- reading the losers.
--
-- ============================================================================================
-- THE WRITER NEVER OVERWRITES
-- ============================================================================================
-- It fills g.tevo_event_id only where it is NULL, and refuses when another GoTickets row already
-- claims that TEvo event, so the both-ways uniqueness holds against what is already stored and
-- not merely within this run.
--
-- That restraint matters, because the pipeline DISAGREES with 44 existing mappings, and on the
-- ones that were read back the existing mapping is the wrong one -- "UT Martin Skyhawks at
-- Memphis Tigers Football" is currently mapped to "Troy Trojans at Missouri Tigers Football"
-- (instant_performer, score 0.53: "Tigers" matched "Tigers"), and "Disney On Ice - Jump In" is
-- mapped to "Disney On Ice - Spotlight Magic". Those conflicts are recorded in evo_gt_event_pair
-- for an operator to decide. Silently correcting another matcher's output is not this function's
-- call to make.
--
-- Cross-validation, same run: 3,904 accepted pairs independently REPRODUCE mappings that other
-- matchers had already made, against 44 disagreements.
--
-- ============================================================================================
-- MATERIALISING THE TWO SIDES IS NOT AN OPTIMISATION, IT IS WHAT MAKES THIS RUN AT ALL
-- ============================================================================================
-- v_evo_us_ca_event and v_gt_us_ca_event recompute venue_norm(), the region test and two parking
-- regexes for every row they touch, and the candidate join touches them repeatedly. Against the
-- 20k-row mirror that was invisible. Against the full catalogue -- 107,341 EVO events and 108,751
-- GoTickets events, once the backfill finished -- the function ran past every timeout it was
-- given and was killed. Each side is now materialised once into a temp table with the index the
-- join actually uses, which is what "pull the full map for mapping" means in practice, and the
-- guards are evaluated only on pairs that survive the window rather than on all of them.
--
-- FULL-CATALOGUE RESULT: 75,744 EVO events at linked venues against 59,689 GoTickets events,
-- 57,709 candidate pairs inside the window, 22,783 accepted across 22,783 DISTINCT EVO events and
-- 22,783 DISTINCT GoTickets events -- the one-to-one holds exactly. 22,433 pairs were rejected as
-- different_local_day. Of the 998 accepted pairs at 12h or more, every one is same-local-day.
-- 18,732 were written; the rest were already mapped, 3,979 of them to the same TEvo event this
-- pipeline chose independently.
--
-- The no-double-claim guard held: of the 134 TEvo events in the table claimed by more than one
-- GoTickets row, NONE carry evo_gt_v2_venue1to1. They are pre-existing, and they are concentrated
-- in instant_performer (94) and matcher_v3_got (47) -- the same two matchers this pipeline
-- disagrees with above.

CREATE TABLE IF NOT EXISTS public.evo_gt_event_pair (
  tevo_event_id bigint  NOT NULL,
  gt_event_id   bigint  NOT NULL,
  tevo_venue_id bigint  NOT NULL,
  gt_venue_key  text    NOT NULL,
  delta_hours   numeric NOT NULL,
  name_sim      numeric NOT NULL,
  performer_sim numeric,
  score         numeric NOT NULL,
  ordinals_ok   boolean NOT NULL,
  subtitle_ok   boolean NOT NULL,
  rn_evo        int, rn_gt int,
  rivals_evo    int, rivals_gt int,
  runner_up_score numeric,
  runner_up_delta numeric,
  evo_local_date  date,
  gt_local_date   date,
  same_local_day  boolean,
  verdict       text    NOT NULL,
  built_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tevo_event_id, gt_event_id)
);
CREATE INDEX IF NOT EXISTS evo_gt_event_pair_verdict_idx ON public.evo_gt_event_pair (verdict);

COMMENT ON TABLE public.evo_gt_event_pair IS
  'STEPS 3 and 4 of the four-step pipeline, kept as one inspectable artifact: every candidate pair that survived the venue link and the +/-24h window, with the name score, the guards, and the reason it was or was not accepted. REJECTED PAIRS ARE KEPT ON PURPOSE -- a mapper that stores only its winners cannot be audited, and every wrong mapping this project has found was found by reading the losers (mig 20260915220000).';
COMMENT ON COLUMN public.evo_gt_event_pair.runner_up_delta IS
  'Hours-from-target of the SECOND-best candidate. This is what makes a +/-24h window safe. A 24h window admits the adjacent night, and on a multi-night residency the adjacent night carries the same event name and the same performer, so the name score cannot separate them -- only the clock can. A tied score is accepted only when the winner is at least 6h closer than the runner-up.';
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

  -- STEP 1, materialised. The views recompute venue_norm(), the region test and two parking
  -- regexes for every row they touch, and the candidate join touches them repeatedly. At 20k rows
  -- that was invisible; at 107k EVO against 108k GoTickets it is the whole runtime. Materialising
  -- each side once, with the indexes the join actually uses, is what "pull the full map for
  -- mapping" means in practice.
  DROP TABLE IF EXISTS _evo;
  CREATE TEMP TABLE _evo ON COMMIT DROP AS
  SELECT e.tevo_event_id, e.event_name, e.tevo_venue_id, e.local_ts::date AS evo_local_date,
         e.utc_ts, e.iana_tz, e.primary_performer_name,
         public.tevo_venue_search_norm(e.event_name) AS name_n,
         public.tevo_venue_search_norm(e.primary_performer_name) AS perf_n,
         l.gt_venue_key
    FROM public.v_evo_us_ca_event e
    JOIN public.evo_gt_venue_link l ON l.tevo_venue_id = e.tevo_venue_id
   WHERE e.utc_ts IS NOT NULL;
  CREATE INDEX ON _evo (gt_venue_key, utc_ts);
  ANALYZE _evo;

  DROP TABLE IF EXISTS _gt;
  CREATE TEMP TABLE _gt ON COMMIT DROP AS
  SELECT g.gt_event_id, g.event_name, g.gt_venue_key, g.utc_ts, g.performer,
         public.tevo_venue_search_norm(g.event_name) AS name_n,
         public.tevo_venue_search_norm(g.performer)  AS perf_n
    FROM public.v_gt_us_ca_event g
   WHERE EXISTS (SELECT 1 FROM public.evo_gt_venue_link l WHERE l.gt_venue_key = g.gt_venue_key);
  CREATE INDEX ON _gt (gt_venue_key, utc_ts);
  ANALYZE _gt;

  -- STEP 3: the +/-24h window selects candidates.
  DROP TABLE IF EXISTS _p;
  CREATE TEMP TABLE _p ON COMMIT DROP AS
  SELECT e.tevo_event_id, g.gt_event_id, e.tevo_venue_id, e.gt_venue_key,
         round((abs(extract(epoch FROM (g.utc_ts - e.utc_ts))) / 3600.0)::numeric, 3) AS delta_hours,
         e.evo_local_date,
         (g.utc_ts AT TIME ZONE e.iana_tz)::date AS gt_local_date,
         (e.evo_local_date = (g.utc_ts AT TIME ZONE e.iana_tz)::date) AS same_local_day,
         similarity(e.name_n, g.name_n)::numeric AS name_sim,
         CASE WHEN nullif(btrim(coalesce(e.perf_n,'')),'') IS NOT NULL
               AND nullif(btrim(coalesce(g.perf_n,'')),'') IS NOT NULL
              THEN similarity(e.perf_n, g.perf_n)::numeric END AS performer_sim,
         e.event_name AS evo_name, g.event_name AS gt_name
    FROM _evo e
    JOIN _gt g
      ON g.gt_venue_key = e.gt_venue_key
     AND g.utc_ts >= e.utc_ts - make_interval(secs => (p_window_hours * 3600)::double precision)
     AND g.utc_ts <= e.utc_ts + make_interval(secs => (p_window_hours * 3600)::double precision);

  ALTER TABLE _p ADD COLUMN score numeric;
  UPDATE _p SET score = greatest(name_sim, coalesce(performer_sim, 0));
  DELETE FROM _p WHERE score < p_rival_floor;

  -- STEP 4: the guards are evaluated only on what survived, because they are regex work and the
  -- window throws most candidates away.
  ALTER TABLE _p ADD COLUMN ordinals_ok boolean, ADD COLUMN subtitle_ok boolean;
  UPDATE _p SET ordinals_ok = public.evo_gt_ordinals_agree(evo_name, gt_name),
                subtitle_ok = public.evo_gt_subtitle_agrees(evo_name, gt_name);

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

  DELETE FROM public.evo_gt_event_pair;
  INSERT INTO public.evo_gt_event_pair
    (tevo_event_id, gt_event_id, tevo_venue_id, gt_venue_key, delta_hours, name_sim,
     performer_sim, score, ordinals_ok, subtitle_ok, rn_evo, rn_gt, rivals_evo, rivals_gt,
     runner_up_score, runner_up_delta, verdict, evo_local_date, gt_local_date, same_local_day)
  SELECT r.tevo_event_id, r.gt_event_id, r.tevo_venue_id, r.gt_venue_key, r.delta_hours, r.name_sim,
         r.performer_sim, r.score, r.ordinals_ok, r.subtitle_ok, r.rn_evo, r.rn_gt,
         r.rivals_evo, r.rivals_gt, r.runner_up_score, r.runner_up_delta,
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
         END,
         r.evo_local_date, r.gt_local_date, r.same_local_day
    FROM _r r;

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
           'evo_events_in', (SELECT count(*) FROM _evo),
           'gt_events_in', (SELECT count(*) FROM _gt),
           'venue_links_used', (SELECT count(*) FROM public.evo_gt_venue_link),
           'pairs_kept', (SELECT count(*) FROM public.evo_gt_event_pair),
           'by_verdict', (SELECT jsonb_object_agg(verdict, n) FROM (
               SELECT verdict, count(*) n FROM public.evo_gt_event_pair GROUP BY 1) z),
           'accepted_max_delta_hours',
             (SELECT max(delta_hours) FROM public.evo_gt_event_pair WHERE verdict='accepted'),
           'written', v_written,
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
