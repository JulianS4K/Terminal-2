-- Two defects, both found by checking the pipeline against the inventory we actually own rather
-- than against the catalogue at large. That check is the point: on the 4,066 US+CA forward events
-- where listings_snapshots.is_owned is true, mapping coverage was ALREADY 68% before mig
-- 20260915220000 ran, and everything that migration wrote added exactly 15 of them. The long tail
-- moved; the inventory that earns money did not.
--
-- (There is no listing-id bridge to lean on instead. Both candidates were tested and both return
-- zero for a reason, not for a mapping failure: gotickets_sales.external_ticket_id is 9-digit
-- (452462746) while TEvo ticket groups are 10-digit (6549885467) -- different id spaces -- and
-- gt_listing_id merely happens to fall in the same range, matching 0 of 5,431. Identity between
-- the two catalogues has to be inferred.)
--
-- ============================================================================================
-- DEFECT 1 -- a flat 1.0 for an alias let one bad crosswalk row delete a city's biggest arenas
-- ============================================================================================
-- mig 20260915210000 scored a crosswalk alias hit at 1.0 unconditionally, on the stated reasoning
-- that "an operator-confirmed identity is not a similarity question". The premise was wrong. These
-- aliases are not operator-confirmed; many were written by automation, and some are junk:
--
--   Intuit Dome   -> Crypto.com Arena, Peacock Theater - Los Angeles, Marine Stadium,
--                    Fairgrounds Cricket Stadium at The Fairplex, Intuit Dome
--   SoFi Stadium  -> Long Beach Convention Center, Long Beach Arena, Long Beach Climbing Theater,
--                    Long Beach Target Shooting Hall, Main Stadium at Dignity Health Sports Park,
--                    Whittier Narrows Clay Shooting Center, SoFi Stadium
--
-- They look like LA 2028 Olympic venue groupings. At a flat 1.0 each, Intuit Dome scored 1.0
-- against ITSELF and 1.0 against Crypto.com Arena; the margin test saw a tie and threw BOTH away.
-- The same tie killed Petco Park (against "Gallagher Square at PETCO Park") and Hard Rock Stadium
-- (against "Grandstand at Hard Rock Stadium").
--
-- MEASURED CONSEQUENCE, on owned inventory alone: 321 events where we hold tickets sat at venues
-- with no link at all -- Intuit Dome 24, Hard Rock Stadium 15, Ford Center At The Star 14,
-- Crypto.com Arena 9, SoFi Stadium 7, Petco Park 7 -- every one of them present in the GoTickets
-- catalogue with 18 to 131 forward events.
--
-- THE FIX: an alias is evidence, not an identity claim. It now BOOSTS the name score by a bounded
-- p_alias_boost rather than replacing it, capped at 1.0. A genuine alias still gets in, because a
-- genuine alias shares tokens with the real name ("Ballroom at Hard Rock Casino Cincinnati" vs
-- "Hard Rock Casino Cincinnati - Ballroom" already scores ~0.8); a junk alias lands at 0.25 and can
-- never clear the 0.72 bar, so it cannot tie with, or outrank, a true self-match.
--
-- VERIFIED after applying: Crypto.com Arena, Intuit Dome, SoFi Stadium, Petco Park and Hard Rock
-- Stadium all link to themselves at 1.000, with the junk aliases demoted to 0.250 (Intuit Dome's
-- Crypto.com claim) and 0.424 (SoFi's Long Beach claims). margin_too_thin fell 34 -> 17.
--
-- Coors Field stayed unlinked and SHOULD have: GoTickets carries no forward Coors Field inventory
-- at all, only "Coors Event Centre" in Saskatoon. The fix declined to invent that link.
--
-- ============================================================================================
-- DEFECT 2 -- "ambiguous" was measuring the wrong thing
-- ============================================================================================
-- The acceptance rule asked "are the two candidates far apart?" (runner_up_delta - delta_hours >=
-- p_time_decisive_hours) when the question that decides a same-day pair is "is the winner an exact
-- hit while the rival is not?". A matinee and an evening performance are about five hours apart, so
-- a pair matching to the MINUTE was still rejected as ambiguous:
--
--   & Juliet, Oct 25 13:00        winner 0.000h   runner-up 5.500h   -> rejected
--   Legally Blonde, Feb 13 19:30  winner 0.000h   runner-up 5.500h   -> rejected
--   Luis J. Gomez, Jan 2 20:00    winner 0.000h   runner-up 2.500h   -> rejected
--
-- An exact time hit against a rival hours away is now decisive on its own. Genuine ambiguity is
-- untouched: a 14:00 event with GoTickets candidates at 13:00 and 15:00 has no exact hit, so it
-- stays rejected rather than guessed.
--
-- MEASURED: ambiguous_sibling 5,119 -> 1,613; accepted 22,783 -> 26,612; 3,430 newly written.
--
-- ============================================================================================
-- VERIFIED ON APPLY, 2026-09-15
-- ============================================================================================
--   venue links 3,449 -> 3,460 · accepted pairs 26,612 across 26,612 DISTINCT EVO events and
--   26,612 DISTINCT GoTickets events, so the one-to-one still holds exactly · 0 accepted pairs on
--   a different local day · 0 accepted pairs beyond 12h that are not same-local-day · 10 randomly
--   sampled newly-written mappings read back by hand, every one an exact time match with its rival
--   2 to 5.5 hours away.
--
--   Conflicts with other matchers rose 63 -> 140, and NONE of them is against this pipeline's own
--   earlier output -- the improved venue map simply brought more events into scope and exposed more
--   of venue_24h_performer (58), instant_performer (35) and matcher_v3_got (24). Still not
--   corrected here: the writer fills NULLs only.
--
--   One thing this run surfaced that is NOT ours. Our writes landed at 19:34:21 and a scheduled
--   cron wrote at 19:35:00, 39 seconds later, claiming the same TEvo events on DIFFERENT GoTickets
--   rows -- Minnesota Orchestra, Joe Gatto, Rouge, Emo Night Brooklyn, Robert Morris hockey. Our
--   both-ways guard held; venue_24h_performer and tz_name_day_exact have no equivalent, so they
--   mint duplicate claims continuously. Total TEvo events claimed by more than one GoTickets row
--   is now 201. That is an operator call on another lane's matchers, not a silent fix here.

DROP FUNCTION IF EXISTS public.evo_gt_venue_link_build(boolean, numeric, numeric, numeric);

CREATE OR REPLACE FUNCTION public.evo_gt_venue_link_build(
  p_apply       boolean DEFAULT false,
  p_min_sim     numeric DEFAULT 0.72,
  p_rival_floor numeric DEFAULT 0.42,
  p_margin      numeric DEFAULT 0.08,
  p_alias_boost numeric DEFAULT 0.25)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_cand int; v_acc int; v_written int := 0;
  v_rej jsonb; v_cost jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'evo_gt_venue_link_build: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '600000', true);

  DROP TABLE IF EXISTS _evov;
  CREATE TEMP TABLE _evov ON COMMIT DROP AS
  SELECT v.tevo_venue_id, v.venue_name, v.venue_state AS st,
         public.venue_norm(v.venue_city)              AS city_n,
         public.tevo_venue_search_norm(v.venue_name)  AS name_n,
         count(*)::int                                AS n_events
    FROM public.v_evo_us_ca_event v
   GROUP BY 1,2,3,4,5;
  CREATE INDEX ON _evov (st, city_n);

  DROP TABLE IF EXISTS _gtv;
  CREATE TEMP TABLE _gtv ON COMMIT DROP AS
  SELECT g.gt_venue_key, min(g.venue_name) AS venue_name, min(g.venue_city) AS venue_city,
         g.venue_state AS st,
         public.venue_norm(min(g.venue_city))             AS city_n,
         public.venue_norm(min(g.venue_name))             AS name_key,
         public.tevo_venue_search_norm(min(g.venue_name)) AS name_n,
         count(*)::int                                    AS n_events
    FROM public.v_gt_us_ca_event g
   GROUP BY g.gt_venue_key, g.venue_state;
  CREATE INDEX ON _gtv (st, city_n);
  CREATE INDEX ON _gtv (st, name_key);

  DROP TABLE IF EXISTS _alias;
  CREATE TEMP TABLE _alias ON COMMIT DROP AS
  SELECT DISTINCT m.tevo_venue_id, upper(btrim(m.state)) AS st, public.venue_norm(a) AS name_key
    FROM public.cross_source_venue_map m
    CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(m.gotickets_aliases,'[]'::jsonb)) a
   WHERE m.tevo_venue_id IS NOT NULL AND nullif(btrim(m.state),'') IS NOT NULL;
  CREATE INDEX ON _alias (st, name_key);

  DROP TABLE IF EXISTS _cand;
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
  SELECT tevo_venue_id, venue_name, n_events AS evo_events,
         gt_venue_key, gt_name, gt_city, st, gt_events,
         max(score) AS score, bool_or(via_alias) AS via_alias
    FROM (
      SELECT e.tevo_venue_id, e.venue_name, e.n_events,
             g.gt_venue_key, g.venue_name AS gt_name, g.venue_city AS gt_city, g.st,
             g.n_events AS gt_events,
             least(1.0, similarity(e.name_n, g.name_n)::numeric + p_alias_boost) AS score,
             true AS via_alias
        FROM _evov e
        JOIN _alias a ON a.tevo_venue_id = e.tevo_venue_id AND a.st = e.st
        JOIN _gtv  g ON g.st = a.st AND g.name_key = a.name_key
      UNION ALL
      SELECT e.tevo_venue_id, e.venue_name, e.n_events,
             g.gt_venue_key, g.venue_name, g.venue_city, g.st,
             g.n_events, similarity(e.name_n, g.name_n)::numeric, false
        FROM _evov e
        JOIN _gtv g ON g.st = e.st AND g.city_n = e.city_n
       WHERE similarity(e.name_n, g.name_n) >= p_rival_floor
    ) u
   GROUP BY 1,2,3,4,5,6,7,8;

  SELECT count(*) INTO v_cand FROM _cand;

  DROP TABLE IF EXISTS _rank;
  CREATE TEMP TABLE _rank ON COMMIT DROP AS
  SELECT c.*,
         row_number() OVER (PARTITION BY tevo_venue_id ORDER BY score DESC, gt_venue_key) AS rn_evo,
         row_number() OVER (PARTITION BY gt_venue_key  ORDER BY score DESC, tevo_venue_id) AS rn_gt,
         count(*)     OVER (PARTITION BY tevo_venue_id) AS rivals_gt_side,
         count(*)     OVER (PARTITION BY gt_venue_key)  AS rivals_evo_side,
         lead(score)  OVER (PARTITION BY tevo_venue_id ORDER BY score DESC, gt_venue_key)  AS runner_up_evo,
         lead(score)  OVER (PARTITION BY gt_venue_key  ORDER BY score DESC, tevo_venue_id) AS runner_up_gt
    FROM _cand c;

  DROP TABLE IF EXISTS _acc;
  CREATE TEMP TABLE _acc ON COMMIT DROP AS
  SELECT * FROM _rank r
   WHERE r.rn_evo = 1 AND r.rn_gt = 1
     AND r.score >= p_min_sim
     AND (r.runner_up_evo IS NULL OR r.score - r.runner_up_evo >= p_margin)
     AND (r.runner_up_gt  IS NULL OR r.score - r.runner_up_gt  >= p_margin);

  SELECT count(*) INTO v_acc FROM _acc;

  SELECT jsonb_build_object(
           'not_mutual_best',  count(*) FILTER (WHERE rn_evo <> 1 OR rn_gt <> 1),
           'below_threshold',  count(*) FILTER (WHERE rn_evo = 1 AND rn_gt = 1 AND score < p_min_sim),
           'margin_too_thin',  count(*) FILTER (WHERE rn_evo = 1 AND rn_gt = 1 AND score >= p_min_sim
                                 AND ((runner_up_evo IS NOT NULL AND score - runner_up_evo < p_margin)
                                   OR (runner_up_gt  IS NOT NULL AND score - runner_up_gt  < p_margin))))
    INTO v_rej FROM _rank;

  SELECT jsonb_build_object(
           'gt_events_at_won_keys', coalesce(sum(a.gt_events),0),
           'gt_events_at_lost_siblings',
             coalesce((SELECT sum(g.n_events) FROM _gtv g
                        WHERE EXISTS (SELECT 1 FROM _acc a2
                                       WHERE a2.st = g.st
                                         AND a2.gt_venue_key <> g.gt_venue_key
                                         AND similarity(
                                               public.tevo_venue_search_norm(a2.gt_name),
                                               g.name_n) >= p_min_sim)),0))
    INTO v_cost FROM _acc a;

  IF p_apply THEN
    DELETE FROM public.evo_gt_venue_link;
    INSERT INTO public.evo_gt_venue_link
      (tevo_venue_id, tevo_venue_name, gt_venue_key, gt_venue_name, gt_venue_city,
       gt_venue_state, method, score, runner_up_evo, runner_up_gt,
       rivals_gt_side, rivals_evo_side, evo_future_events, gt_future_events)
    SELECT a.tevo_venue_id, a.venue_name, a.gt_venue_key, a.gt_name, a.gt_city, a.st,
           CASE WHEN a.via_alias THEN 'crosswalk_alias' ELSE 'city_name_similarity' END,
           a.score, a.runner_up_evo, a.runner_up_gt,
           a.rivals_gt_side, a.rivals_evo_side, a.evo_events, a.gt_events
      FROM _acc a;
    GET DIAGNOSTICS v_written = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'applied', p_apply,
    'evo_venues', (SELECT count(*) FROM _evov),
    'gt_venue_keys', (SELECT count(*) FROM _gtv),
    'candidates', v_cand,
    'accepted', v_acc,
    'written', v_written,
    'by_method', (SELECT jsonb_object_agg(k, n) FROM (
        SELECT CASE WHEN via_alias THEN 'crosswalk_alias' ELSE 'city_name_similarity' END AS k,
               count(*) AS n FROM _acc GROUP BY 1) z),
    'rejected', v_rej,
    'strictness_cost', v_cost,
    'thresholds', jsonb_build_object('min_sim',p_min_sim,'rival_floor',p_rival_floor,
                                     'margin',p_margin,'alias_boost',p_alias_boost));
END $fn$;

REVOKE ALL ON FUNCTION public.evo_gt_venue_link_build(boolean, numeric, numeric, numeric, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_venue_link_build(boolean, numeric, numeric, numeric, numeric)
  TO service_role;

DROP FUNCTION IF EXISTS public.evo_gt_pipeline_match(boolean, numeric, numeric, numeric, numeric, numeric);

CREATE OR REPLACE FUNCTION public.evo_gt_pipeline_match(
  p_apply        boolean DEFAULT false,
  p_window_hours numeric DEFAULT 24,
  p_min_score    numeric DEFAULT 0.55,
  p_rival_floor  numeric DEFAULT 0.30,
  p_margin       numeric DEFAULT 0.05,
  p_time_decisive_hours numeric DEFAULT 6,
  p_exact_hours  numeric DEFAULT 0.5,
  p_rival_min_hours numeric DEFAULT 2.0)
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
            AND NOT (r.delta_hours <= p_exact_hours
                     AND r.runner_up_delta >= p_rival_min_hours)
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
               'margin', p_margin, 'time_decisive_hours', p_time_decisive_hours,
               'exact_hours', p_exact_hours, 'rival_min_hours', p_rival_min_hours))
    INTO v_out;
  RETURN v_out;
END $fn$;

REVOKE ALL ON FUNCTION public.evo_gt_pipeline_match(boolean, numeric, numeric, numeric, numeric, numeric, numeric, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_pipeline_match(boolean, numeric, numeric, numeric, numeric, numeric, numeric, numeric)
  TO service_role;
