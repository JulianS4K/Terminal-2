-- Split compound ESPN transactions into per-move parts.
--
-- A single transaction row often bundles several moves in one description
-- (e.g. "Optioned RHP X to AAA. Recalled RHP Y from AAA."). This adds a `moves`
-- array to get_espn_transactions so the TRANSACTIONS tab can render each move on
-- its own line with its own type tag + matched players, instead of one long run.
--
-- Moves are verb-initial (Signed/Optioned/Placed/…), so we split the description
-- at ". " immediately before a known transaction verb. Postgres POSIX regex has
-- no lookahead, so insert a control-char sentinel (chr(1)) before the verb, then
-- split on it. Robust against periods inside names/abbreviations ("Jr.", "St.").

CREATE OR REPLACE FUNCTION public._espn_txn_moves(p_description text, p_league text)
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  WITH parts AS (
    SELECT trim(m) AS mv, ord
    FROM unnest(string_to_array(
      regexp_replace(
        coalesce(p_description,''),
        '\. (Signed|Re-signed|Waived|Released|Traded|Acquired|Claimed|Optioned|Recalled|Reinstated|Activated|Placed|Sent|Selected|Designated|Transferred|Promoted|Agreed|Hired|Named|Assigned|Purchased|Renewed|Returned|Loaned|Outrighted)',
        '.' || chr(1) || '\1', 'g'),
      chr(1))) WITH ORDINALITY AS t(m, ord)
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'text', mv,
           'type', public._espn_txn_type(mv),
           'players', public._espn_txn_match_players(mv, p_league)
         ) ORDER BY ord), '[]'::jsonb)
  FROM parts WHERE mv <> '';
$function$;
COMMENT ON FUNCTION public._espn_txn_moves IS
  'Split a transaction description into per-move {text,type,players} parts (verb-initial split).';

DROP FUNCTION IF EXISTS public.get_espn_transactions(text, text, int);
CREATE OR REPLACE FUNCTION public.get_espn_transactions(
    p_league text DEFAULT NULL, p_search text DEFAULT NULL, p_limit int DEFAULT 60)
 RETURNS TABLE (id bigint, espn_league text, team text, team_abbr text,
                tevo_performer_id bigint, txn_date timestamptz, description text,
                move_type text, players jsonb, moves jsonb)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
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
         public._espn_txn_type(tx.description) AS move_type,
         public._espn_txn_match_players(tx.description, tx.espn_league) AS players,
         public._espn_txn_moves(tx.description, tx.espn_league) AS moves
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
  'Enriched ESPN transactions feed: team (+TEvo performer) + move_type + players + per-move split (moves). Email-gated. The TRANSACTIONS terminal tab.';
