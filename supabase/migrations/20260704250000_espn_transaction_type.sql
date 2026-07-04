-- Classify each ESPN transaction by move type, for badges + filtering in the
-- TRANSACTIONS tab. ESPN gives only free text, so the type is derived from the
-- description's leading verb. Compound moves (multiple sentences) take the
-- highest-priority verb as the primary tag.
--
-- get_espn_transactions gains a `move_type` column (RETURNS TABLE change ->
-- DROP + CREATE; only transactions.js consumes it).

CREATE OR REPLACE FUNCTION public._espn_txn_type(p_description text)
 RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE
    WHEN p_description IS NULL THEN 'MOVE'
    WHEN p_description ILIKE '%re-signed%'                                   THEN 'RE-SIGN'
    WHEN p_description ILIKE '%signed%' OR p_description ILIKE '%agreed to terms%' THEN 'SIGN'
    WHEN p_description ILIKE '%traded%' OR p_description ILIKE '%acquired%'
      OR p_description ILIKE '%in exchange%'                                 THEN 'TRADE'
    WHEN p_description ILIKE '%claimed%'                                     THEN 'CLAIM'
    WHEN p_description ILIKE '%waived%'                                      THEN 'WAIVE'
    WHEN p_description ILIKE '%released%'                                    THEN 'RELEASE'
    WHEN p_description ILIKE '%designated%for assignment%'
      OR p_description ILIKE '%designated%for release%'                      THEN 'DFA'
    WHEN p_description ILIKE '%reinstated%' OR p_description ILIKE '%activated%' THEN 'ACTIVATE'
    WHEN p_description ILIKE '%placed%il%' OR p_description ILIKE '%injured list%'
      OR p_description ILIKE '%day il%'                                      THEN 'IL'
    WHEN p_description ILIKE '%optioned%'                                    THEN 'OPTION'
    WHEN p_description ILIKE '%recalled%' OR p_description ILIKE '%selected the contract%' THEN 'RECALL'
    WHEN p_description ILIKE '%rehab assignment%' OR p_description ILIKE '%assigned%' THEN 'ASSIGN'
    WHEN p_description ILIKE '%promoted%'                                    THEN 'PROMOTE'
    ELSE 'MOVE'
  END;
$function$;
COMMENT ON FUNCTION public._espn_txn_type IS
  'Primary move-type tag derived from an ESPN transaction description (SIGN/WAIVE/TRADE/IL/…).';

DROP FUNCTION IF EXISTS public.get_espn_transactions(text, text, int);
CREATE OR REPLACE FUNCTION public.get_espn_transactions(
    p_league text DEFAULT NULL, p_search text DEFAULT NULL, p_limit int DEFAULT 60)
 RETURNS TABLE (id bigint, espn_league text, team text, team_abbr text,
                tevo_performer_id bigint, txn_date timestamptz, description text,
                move_type text, players jsonb)
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
         public._espn_txn_type(tx.description) AS move_type,
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
  'Enriched ESPN transactions feed: team (+TEvo performer) + move_type + name-matched players. Email-gated. The TRANSACTIONS terminal tab.';
