-- Migration 20261028210000 · level:feature · lane:A1 (data plane — ML training data) · writes:_ml_nba_team_id()(new),_ml_team_form()(new),_ml_team_out()(new),v_ml_knicks_form_train(new),v_ml_knicks_form_predict(new) · reads:espn_team_snapshots,espn_injuries_snapshots,espn_teams_canonical,performer_espn_team_xref,listings_poll_pins,v_ml_knicks_sales_train,v_ml_knicks_predict_input · pre:20261027050000
--
-- Team form + injuries for the Knicks price model (operator 2026-10-28: "build pipeline for 3, use
-- existing but need to turn on later"). Read-only views; the training script reads them only when
-- ML_FORM_FEATURES=1, so nothing changes until that is set.
--
-- As of any moment (a sale's time when training, now() when predicting), for the Knicks and the
-- opponent:
--   win_pct, games, streak  latest ESPN standings snapshot at or before that moment (daily since
--                           2026-05). Before opening night it still shows LAST season's final record,
--                           then resets to 0-0 — `games` lets the model tell the two apart.
--                           streak: W3 → +3, L2 → -2.
--   players_out             players whose latest ESPN injury status at that moment is Out / Injured
--                           Reserve / Suspension and who were still listed within 2 days of it.
-- ESPN team ids repeat across leagues (18 is the Knicks in the NBA and other teams elsewhere), so
-- every lookup filters espn_league = 'NBA'.
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public._ml_nba_team_id(p_name text)
RETURNS text LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT c.espn_team_id FROM public.espn_teams_canonical c
   WHERE c.espn_league = 'NBA'
     AND lower(c.display_name) = lower(btrim(regexp_replace(coalesce(p_name, ''), '^NBA Cup\s*-\s*', '', 'i')))
   LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public._ml_team_form(p_team text, p_as_of timestamptz)
RETURNS TABLE (win_pct numeric, games integer, streak integer)
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT t.win_pct::numeric,
         (coalesce(t.wins, 0) + coalesce(t.losses, 0))::int,
         CASE WHEN t.streak ~ '^[WL][0-9]+$'
              THEN (CASE WHEN left(t.streak, 1) = 'W' THEN 1 ELSE -1 END) * substr(t.streak, 2)::int END
    FROM public.espn_team_snapshots t
   WHERE t.espn_team_id = p_team AND t.espn_league = 'NBA' AND t.captured_at <= p_as_of
   ORDER BY t.captured_at DESC
   LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public._ml_team_out(p_team text, p_as_of timestamptz)
RETURNS integer LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
  SELECT count(*)::int
    FROM (SELECT DISTINCT ON (i.athlete_id) i.status, i.last_seen_at
            FROM public.espn_injuries_snapshots i
           WHERE i.espn_team_id = p_team AND i.espn_league = 'NBA' AND i.captured_at <= p_as_of
           ORDER BY i.athlete_id, i.captured_at DESC) x
   WHERE x.status IN ('Out', 'Injured Reserve', 'Suspension')
     AND x.last_seen_at >= p_as_of - interval '2 days'
$$;

REVOKE ALL ON FUNCTION public._ml_nba_team_id(text), public._ml_team_form(text, timestamptz),
                       public._ml_team_out(text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._ml_nba_team_id(text), public._ml_team_form(text, timestamptz),
                          public._ml_team_out(text, timestamptz) TO service_role;

-- one row per training sale (join on source + sale_key)
CREATE OR REPLACE VIEW public.v_ml_knicks_form_train
WITH (security_invoker = true) AS
WITH k AS (
  SELECT x.espn_team_id FROM public.performer_espn_team_xref x
    JOIN public.listings_poll_pins p ON p.performer_id = x.tevo_performer_id
   WHERE p.pin_key = 'knicks_home' AND upper(x.espn_league) = 'NBA'
   LIMIT 1)
SELECT s.source, s.sale_key,
       kf.win_pct AS knicks_win_pct, kf.games AS knicks_games, kf.streak AS knicks_streak,
       public._ml_team_out(k.espn_team_id, s.sale_at) AS knicks_out,
       ofm.win_pct AS opp_win_pct, ofm.games AS opp_games, ofm.streak AS opp_streak,
       CASE WHEN o.id IS NOT NULL THEN public._ml_team_out(o.id, s.sale_at) END AS opp_out
  FROM public.v_ml_knicks_sales_train s
  CROSS JOIN k
  LEFT JOIN LATERAL (SELECT public._ml_nba_team_id(s.opponent) AS id) o ON true
  LEFT JOIN LATERAL public._ml_team_form(k.espn_team_id, s.sale_at) kf ON true
  LEFT JOIN LATERAL public._ml_team_form(o.id, s.sale_at) ofm ON true;

-- one row per upcoming game, as of now (join on sg_event_id)
CREATE OR REPLACE VIEW public.v_ml_knicks_form_predict
WITH (security_invoker = true) AS
WITH k AS (
  SELECT x.espn_team_id FROM public.performer_espn_team_xref x
    JOIN public.listings_poll_pins p ON p.performer_id = x.tevo_performer_id
   WHERE p.pin_key = 'knicks_home' AND upper(x.espn_league) = 'NBA'
   LIMIT 1),
g AS (SELECT DISTINCT sg_event_id, opponent FROM public.v_ml_knicks_predict_input)
SELECT g.sg_event_id,
       kf.win_pct AS knicks_win_pct, kf.games AS knicks_games, kf.streak AS knicks_streak,
       public._ml_team_out(k.espn_team_id, now()) AS knicks_out,
       ofm.win_pct AS opp_win_pct, ofm.games AS opp_games, ofm.streak AS opp_streak,
       CASE WHEN o.id IS NOT NULL THEN public._ml_team_out(o.id, now()) END AS opp_out
  FROM g
  CROSS JOIN k
  LEFT JOIN LATERAL (SELECT public._ml_nba_team_id(g.opponent) AS id) o ON true
  LEFT JOIN LATERAL public._ml_team_form(k.espn_team_id, now()) kf ON true
  LEFT JOIN LATERAL public._ml_team_form(o.id, now()) ofm ON true;

REVOKE ALL ON public.v_ml_knicks_form_train, public.v_ml_knicks_form_predict FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_ml_knicks_form_train, public.v_ml_knicks_form_predict TO service_role;

-- VERIFY:
--   SELECT count(*), count(knicks_win_pct), count(opp_win_pct), avg(knicks_out), avg(opp_out) FROM v_ml_knicks_form_train;
--   SELECT * FROM v_ml_knicks_form_predict ORDER BY sg_event_id LIMIT 5;
-- ROLLBACK: DROP VIEW v_ml_knicks_form_predict, v_ml_knicks_form_train;
--           DROP FUNCTION _ml_team_out(text,timestamptz), _ml_team_form(text,timestamptz), _ml_nba_team_id(text);
