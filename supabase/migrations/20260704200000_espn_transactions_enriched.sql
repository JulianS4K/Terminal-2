-- Map ESPN transactions onto our existing entity databases so they are
-- trackable at the team (TEvo performer) and player (espn_athletes) level, and
-- expose an enriched feed for the terminal.
--
-- Team mapping is exact: espn_transactions (espn_team_id, espn_league) ->
--   performer_espn_team_xref -> tevo_performer_id (verified 486/486 = 100%),
--   + espn_teams_canonical for the display name. Links a transaction to the
--   performer page.
-- Player mapping is by name: ESPN gives no structured athlete ref on a
--   transaction (only free-text `description`), so we match espn_athletes whose
--   full name appears (word-boundary, league-scoped) in the description. ~85% of
--   recent transactions resolve >=1 athlete (misses are minor-leaguers/draftees
--   not in espn_athletes). Duplicate athlete rows for one name are deduped to the
--   most-recently-seen id. Links each named player to the player page.

-- ---- player matcher (league-scoped, deduped, word-boundary) ------------------
CREATE OR REPLACE FUNCTION public._espn_txn_match_players(p_description text, p_league text)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'espn_athlete_id', espn_athlete_id, 'name', full_name, 'position', position_abbr)
         ORDER BY full_name), '[]'::jsonb)
  FROM (
    SELECT DISTINCT ON (lower(a.full_name))
           a.espn_athlete_id, a.full_name, a.position_abbr
    FROM public.espn_athletes a
    WHERE a.espn_league = p_league
      AND length(a.full_name) >= 6           -- avoid short/common-token false hits
      AND coalesce(p_description,'') ~* (
            '\m' || regexp_replace(a.full_name, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M')
    ORDER BY lower(a.full_name), a.last_seen_at DESC NULLS LAST   -- one canonical id per name
  ) m;
$function$;
COMMENT ON FUNCTION public._espn_txn_match_players IS
  'Athletes (espn_athletes) name-matched in a transaction description, league-scoped + deduped. Helper for the transactions feed.';

-- ---- enriched transactions feed (the TRANSACTIONS tab data source) ----------
CREATE OR REPLACE FUNCTION public.get_espn_transactions(
    p_league text DEFAULT NULL, p_search text DEFAULT NULL, p_limit int DEFAULT 60)
 RETURNS TABLE (id bigint, espn_league text, team text, team_abbr text,
                tevo_performer_id bigint, txn_date timestamptz, description text, players jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  RETURN QUERY
  SELECT tx.id, tx.espn_league,
         coalesce(c.display_name, tx.team_display_name, tx.team_abbr) AS team,
         coalesce(c.abbreviation, tx.team_abbr) AS team_abbr,
         x.tevo_performer_id, tx.txn_date, tx.description,
         public._espn_txn_match_players(tx.description, tx.espn_league) AS players
  FROM public.espn_transactions tx
  LEFT JOIN public.espn_teams_canonical c
    ON c.espn_team_id = tx.espn_team_id AND c.espn_league = tx.espn_league
  LEFT JOIN public.performer_espn_team_xref x
    ON x.espn_team_id = tx.espn_team_id AND x.espn_league = tx.espn_league
  WHERE coalesce(tx.description,'') <> ''
    AND (p_league IS NULL OR upper(tx.espn_league) = upper(p_league))
    AND (p_search IS NULL OR tx.description ILIKE '%'||p_search||'%'
         OR coalesce(c.display_name, tx.team_display_name,'') ILIKE '%'||p_search||'%')
  ORDER BY tx.txn_date DESC NULLS LAST
  LIMIT greatest(1, least(coalesce(p_limit, 60), 200));
END $function$;
COMMENT ON FUNCTION public.get_espn_transactions IS
  'Enriched ESPN transactions feed: team (+TEvo performer) + name-matched players. Email-gated. The TRANSACTIONS terminal tab.';

-- ---- per-player transactions (for the player page) --------------------------
CREATE OR REPLACE FUNCTION public.get_espn_player_transactions(
    p_athlete_id text, p_league text, p_limit int DEFAULT 20)
 RETURNS TABLE (txn_date timestamptz, team text, tevo_performer_id bigint, description text)
 LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_name text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  SELECT full_name INTO v_name FROM public.espn_athletes
   WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league LIMIT 1;
  IF v_name IS NULL OR length(v_name) < 6 THEN RETURN; END IF;
  RETURN QUERY
  SELECT tx.txn_date,
         coalesce(c.display_name, tx.team_display_name, tx.team_abbr) AS team,
         x.tevo_performer_id, tx.description
  FROM public.espn_transactions tx
  LEFT JOIN public.espn_teams_canonical c
    ON c.espn_team_id = tx.espn_team_id AND c.espn_league = tx.espn_league
  LEFT JOIN public.performer_espn_team_xref x
    ON x.espn_team_id = tx.espn_team_id AND x.espn_league = tx.espn_league
  WHERE tx.espn_league = p_league
    AND tx.description ~* ('\m' || regexp_replace(v_name, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M')
  ORDER BY tx.txn_date DESC NULLS LAST
  LIMIT greatest(1, least(coalesce(p_limit, 20), 100));
END $function$;
COMMENT ON FUNCTION public.get_espn_player_transactions IS
  'ESPN transactions mentioning a given athlete (name-matched), league-scoped. Player-page block. Email-gated.';
