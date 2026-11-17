-- STEPS 1 and 2 of the four-step EVO -> GoTickets pipeline the operator specified:
--
--   "pull the full evo us-canada map for mapping, then map the venue 1-1, then filter dates
--    with +/- 24 hours and then map event names"
--
-- Steps 3 and 4 are mig 20260915220000. Each step is a separate, readable artifact on purpose:
-- the existing evo_gt_map does venue resolution, day arithmetic and name scoring inside one
-- four-stage function, and when it is wrong there is nothing to look at. Here the venue map is a
-- table you can read, and the candidate pairs are a table you can read.
--
-- ============================================================================================
-- STEP 1 -- the two catalogues, filtered the same way
-- ============================================================================================
-- v_evo_us_ca_event and v_gt_us_ca_event are the two lists. Both go through is_us_ca_region()
-- (mig 20260915190000) so they cannot be filtered differently, and both drop parking.
--
-- THE PARKING GUARD IS NOT COSMETIC. GoTickets lists "St. James Theatre New York Parking" as a
-- venue in its own right, with 417 forward events, and on the first build it BEAT the real
-- St. James Theatre to the one-to-one slot -- 0.765 similarity against the real theatre's lower
-- score, because "Parking" is a short suffix on an otherwise identical string. New Amsterdam,
-- Lyric, Walnut Street, Davies Symphony Hall, Mystere at Treasure Island and eight comedy clubs
-- did the same thing. The token is 'parking|shuttle', matching what evo_gt_map already uses;
-- this is not a new rule, it is the existing rule finally applied on the GoTickets side.
--
-- MEASURED effect of the guard: GoTickets venue keys 12,274 -> 8,670 (3,604 of the "venues" were
-- parking), accepted links 1,991 -> 2,292, and the cost of strictness (see below) fell from
-- 14,362 events to 1,263.
--
-- utc_ts is NULL where the venue has no derived timezone. That is left visible rather than
-- guessed at, and the step-3 function reports the count it had to skip.
--
-- ============================================================================================
-- STEP 2 -- "map the venue 1-1", enforced by the schema
-- ============================================================================================
-- GoTickets has no venue id. Its venue identity is the (name, city, state) triple, normalised --
-- gt_venue_key. So the one-to-one is EVO venue id <-> GoTickets venue key, and it is enforced by
-- PRIMARY KEY (tevo_venue_id) plus UNIQUE (gt_venue_key). A second link on either side is an
-- error the database raises, not a duplicate a query is trusted to have excluded.
--
-- Two ways in:
--   crosswalk_alias       -- cross_source_venue_map.gotickets_aliases, which stores RAW GoTickets
--                            names, so both sides are pushed through venue_norm() before
--                            comparison. State must agree. Scores 1.0: an operator-confirmed
--                            identity is not a similarity question.
--   city_name_similarity  -- same state, same normalised city, trigram name similarity.
--
-- Acceptance is mutual-best plus a margin, and RIVALS ARE COUNTED AT p_rival_floor (0.42), NOT
-- at p_min_sim (0.72). That ordering is the whole point. Counting rivals at the acceptance
-- threshold is what manufactured 45 bogus "unique" aliases in the alias backfill earlier the same
-- day: raise the bar high enough and every match looks unique, because the rivals were filtered
-- out before anyone counted them.
--
-- THE COST OF STRICTNESS IS MEASURED, NOT ASSUMED AWAY. A strict 1-1 means that when GoTickets
-- carries two spellings of one building, only one of them gets mapped and the other's inventory
-- is orphaned. strictness_cost reports exactly how many forward GoTickets events sit at those
-- losing siblings. Post-parking-guard it is 1,550 against 51,896 at winning keys -- about 3%, so
-- the operator's instruction holds up. It was reported before the guard as 14,362, and that
-- number was wrong: almost all of it was parking.

CREATE OR REPLACE VIEW public.v_evo_us_ca_event AS
SELECT e.id                                                   AS tevo_event_id,
       e.name                                                 AS event_name,
       e.venue_id                                             AS tevo_venue_id,
       e.venue_name,
       btrim(split_part(e.venue_location, ',', 1))            AS venue_city,
       upper(btrim(split_part(e.venue_location, ',', 2)))     AS venue_state,
       e.occurs_at_local::timestamp                           AS local_ts,
       t.iana_tz,
       CASE WHEN t.iana_tz IS NOT NULL
            THEN e.occurs_at_local::timestamp AT TIME ZONE t.iana_tz END AS utc_ts,
       e.primary_performer_name,
       e.event_type,
       e.state
  FROM public.events e
  LEFT JOIN public.venue_timezone t ON t.tevo_venue_id = e.venue_id
 WHERE e.occurs_at_local::timestamp >= current_date
   AND e.state <> 'ignored'
   AND public.is_us_ca_region(btrim(split_part(e.venue_location, ',', 2)))
   AND coalesce(e.name, '')       !~* 'parking|shuttle'
   AND coalesce(e.venue_name, '') !~* 'parking|shuttle';

COMMENT ON VIEW public.v_evo_us_ca_event IS
  'STEP 1 of the four-step EVO->GoTickets pipeline: the full TEvo US+CA forward catalogue, one row per event, with the venue timezone resolved so a UTC instant exists for the +/-24h window in step 3. utc_ts is NULL where the venue has no derived timezone -- that is a reportable gap, not something to paper over (mig 20260915210000).';

CREATE OR REPLACE VIEW public.v_gt_us_ca_event AS
SELECT g.gt_event_id,
       g.name                                AS event_name,
       g.performer,
       g.venue_name,
       g.venue_city,
       upper(btrim(g.venue_state))           AS venue_state,
       public.venue_norm(g.venue_name) || '|' || public.venue_norm(g.venue_city)
         || '|' || upper(btrim(g.venue_state)) AS gt_venue_key,
       g.event_time_utc                      AS utc_ts,
       g.status,
       g.tevo_event_id
  FROM public.gotickets_event g
 WHERE g.event_time_utc >= now()
   AND coalesce(g.status, 'AS_SCHEDULED') IN ('AS_SCHEDULED', 'RESCHEDULED')
   AND public.is_us_ca_region(g.venue_state)
   AND coalesce(g.name, '')       !~* 'parking|shuttle'
   AND coalesce(g.venue_name, '') !~* 'parking|shuttle';

COMMENT ON VIEW public.v_gt_us_ca_event IS
  'STEP 1, right-hand side: the GoTickets US+CA forward catalogue. CANCELLED, MERGED and POSTPONED are excluded -- a merged GoTickets event is a duplicate that already points elsewhere, and mapping to it would manufacture a second owner for one TEvo event. GoTickets carries no venue id, so gt_venue_key (normalised name|city|state) IS the venue identity on this side. Parking and shuttle rows are excluded with the same token evo_gt_map already uses: GoTickets lists "St. James Theatre New York Parking" as a venue in its own right, 417 forward events of it, and it beat the real theatre to the one-to-one slot (mig 20260915210000 / parking guard).';

CREATE TABLE IF NOT EXISTS public.evo_gt_venue_link (
  tevo_venue_id     bigint  PRIMARY KEY,
  tevo_venue_name   text    NOT NULL,
  gt_venue_key      text    NOT NULL UNIQUE,
  gt_venue_name     text    NOT NULL,
  gt_venue_city     text,
  gt_venue_state    text    NOT NULL,
  method            text    NOT NULL,
  score             numeric NOT NULL,
  runner_up_evo     numeric,
  runner_up_gt      numeric,
  rivals_gt_side    int     NOT NULL DEFAULT 0,
  rivals_evo_side   int     NOT NULL DEFAULT 0,
  evo_future_events int,
  gt_future_events  int,
  built_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.evo_gt_venue_link IS
  'STEP 2 of the four-step pipeline: a STRICT one-to-one venue map, EVO venue <-> GoTickets venue. The 1-1 is enforced by the schema, not by the query that fills it: PRIMARY KEY on tevo_venue_id and UNIQUE on gt_venue_key make a second link on either side an error rather than a silently-kept duplicate (mig 20260915210000).';
COMMENT ON COLUMN public.evo_gt_venue_link.rivals_gt_side IS
  'How many GoTickets venue keys cleared the RIVAL FLOOR for this EVO venue -- counted at the wider floor, never at the acceptance threshold. Counting rivals at the acceptance threshold is what manufactured 45 bogus "unique" aliases in the 2026-09-15 alias backfill: raise the bar high enough and everything looks unique.';
COMMENT ON COLUMN public.evo_gt_venue_link.gt_future_events IS
  'Forward GoTickets events at the WINNING key only. A strict 1-1 leaves any sibling spelling of the same building unmapped; comparing this against the city total is how that cost is measured rather than assumed away.';

CREATE OR REPLACE FUNCTION public.evo_gt_venue_link_build(
  p_apply       boolean DEFAULT false,
  p_min_sim     numeric DEFAULT 0.72,
  p_rival_floor numeric DEFAULT 0.42,
  p_margin      numeric DEFAULT 0.08)
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
             g.n_events AS gt_events, 1.0::numeric AS score, true AS via_alias
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
    'thresholds', jsonb_build_object('min_sim',p_min_sim,'rival_floor',p_rival_floor,'margin',p_margin));
END $fn$;

REVOKE ALL ON FUNCTION public.evo_gt_venue_link_build(boolean, numeric, numeric, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.evo_gt_venue_link_build(boolean, numeric, numeric, numeric)
  TO service_role;
