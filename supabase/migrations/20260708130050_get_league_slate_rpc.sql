-- ============================================================================
-- Migration 20260708130050 — get_league_slate(): per-league upcoming game slate
--
-- Lane:     A1 data plane (SECDEF read RPC; consumed by the D0 Leagues hub)
-- Touches:  get_league_slate (W/function)
-- Reads:    league_team_divisions, broadway_show_ref, events, latest_event_metrics
-- Pre:      20260708120000 (league_team_divisions)
--
-- Turns the hub's team-level demand ranking into an actual per-GAME slate: the
-- league's upcoming games (anchored on the home performer, then joined to
-- events.primary_performer_id), each enriched with the latest market + owned
-- metrics (get-in, market qty, owned qty/share/median). Keyed on tevo event id
-- so each row deep-links to the event page (EVO data). Read-only; email-gated.
--
-- Anchor set is league-shaped: sports leagues resolve through
-- league_team_divisions (home team, one game per row); Broadway resolves
-- through broadway_show_ref (the show as performer → its upcoming performances,
-- no conference/division). One CTE keeps both league families on the same
-- slate contract.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_league_slate(
  p_league text,
  p_days   integer DEFAULT 30,
  p_limit  integer DEFAULT 200
)
RETURNS TABLE (
  event_id            bigint,
  event_name          text,
  occurs_at_local     text,
  venue_name          text,
  performer_id        bigint,
  performer_name      text,
  conference          text,
  division            text,
  tickets_count       integer,
  retail_median       numeric,
  getin_price         numeric,
  owned_tickets_count integer,
  owned_share         numeric,
  owned_median_retail numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_days  integer := greatest(1, least(coalesce(p_days, 30), 400));
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 500));
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH anchor AS (
    -- Sports leagues: home team → one row per league game.
    SELECT ltd.tevo_performer_id, ltd.conference, ltd.division
    FROM public.league_team_divisions ltd
    WHERE ltd.league = p_league
    UNION ALL
    -- Broadway: the show as performer → its upcoming performances.
    SELECT DISTINCT bsr.tevo_performer_id, NULL::text, NULL::text
    FROM public.broadway_show_ref bsr
    WHERE p_league = 'Broadway' AND bsr.tevo_performer_id IS NOT NULL
  )
  SELECT e.id::bigint,
         e.name,
         e.occurs_at_local,
         e.venue_name,
         e.primary_performer_id::bigint,
         e.primary_performer_name,
         a.conference,
         a.division,
         lem.tickets_count::integer,
         lem.retail_median,
         lem.getin_price,
         lem.owned_tickets_count::integer,
         lem.owned_share,
         lem.owned_median_retail
  FROM anchor a
  JOIN public.events e
    ON e.primary_performer_id = a.tevo_performer_id
  LEFT JOIN public.latest_event_metrics lem
    ON lem.event_id = e.id
  WHERE e.occurs_at_local >= to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS')
    AND e.occurs_at_local <= to_char(now() + make_interval(days => v_days), 'YYYY-MM-DD"T"HH24:MI:SS')
    AND coalesce(e.state, '') NOT IN ('completed', 'cancelled', 'postponed')
  ORDER BY e.occurs_at_local
  LIMIT v_limit;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_league_slate(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_league_slate(text, integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_league_slate(text, integer, integer) IS
  'D0 Leagues hub — per-league upcoming slate. Sports: home-team-anchored via league_team_divisions. Broadway: show-anchored via broadway_show_ref. Joined to events.primary_performer_id + latest_event_metrics (market/owned). Keyed on tevo event id -> event-page deep link. Email-gated read-only.';
