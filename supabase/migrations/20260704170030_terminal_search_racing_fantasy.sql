-- terminal_search v5 — add `racing` (drivers) + `fantasy` (leagues) sections.
--
-- The topbar search (nav.js) renders whatever sections the RPC returns, so this
-- adds two sports surfaces to the existing events/performers/venues/marketplace:
--   * racing  — espn_racing_standings by driver name → racing.html?series=…
--   * fantasy — fantasy_leagues by name             → fantasy.html?league=…
--
-- NB: this builds on the CURRENT prod body (20260702134500). It does NOT add a
-- `players` section — sports_player_search() is a separate author-only migration
-- (20260617120000) that has not been applied to prod, so calling it here would
-- error. Restoring players is out of scope for this change. Existing keys
-- unchanged (forward-compat). Email-gated SECDEF, cap 20/section.

CREATE OR REPLACE FUNCTION public.terminal_search(p_q text, p_limit integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_q text; v_pat text; v_cap integer;
        v_evs jsonb; v_perfs jsonb; v_vens jsonb; v_mkt jsonb; v_racing jsonb; v_fantasy jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  v_q := trim(coalesce(p_q, ''));
  v_cap := greatest(1, least(coalesce(p_limit, 6), 20));
  IF length(v_q) < 2 THEN
    RETURN jsonb_build_object('q', v_q, 'events', '[]'::jsonb, 'performers', '[]'::jsonb,
      'venues', '[]'::jsonb, 'marketplace', '[]'::jsonb, 'racing', '[]'::jsonb, 'fantasy', '[]'::jsonb);
  END IF;
  v_pat := '%' || v_q || '%';

  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.match_len, e.occurs_at_local), '[]'::jsonb) INTO v_evs
  FROM (
    SELECT id AS tevo_event_id, name, venue_name, occurs_at_local, primary_performer_name, length(name) AS match_len
    FROM public.events
    WHERE name ILIKE v_pat
      AND occurs_at_local >= to_char(now() - interval '6 hours', 'YYYY-MM-DD"T"HH24:MI:SS')
      AND coalesce(state, '') NOT IN ('past', 'ignored')
    ORDER BY length(name) ASC, occurs_at_local ASC LIMIT v_cap
  ) e;

  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.match_len, p.performer_name), '[]'::jsonb) INTO v_perfs
  FROM (
    SELECT DISTINCT ON (m.tevo_performer_id)
      m.tevo_performer_id, m.performer_short_id, m.performer_name, m.category, length(m.performer_name) AS match_len
    FROM public.aq_performer_map m
    WHERE m.tevo_performer_id IS NOT NULL
      AND ( m.performer_name ILIKE v_pat
            OR EXISTS (SELECT 1 FROM unnest(coalesce(m.aliases, ARRAY[]::text[])) AS a(alias) WHERE a.alias ILIKE v_pat) )
    ORDER BY m.tevo_performer_id, length(m.performer_name) ASC LIMIT v_cap
  ) p;

  SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY v.match_len, v.venue_name), '[]'::jsonb) INTO v_vens
  FROM (
    SELECT DISTINCT ON (m.tevo_venue_id)
      m.tevo_venue_id, m.venue_short_id, m.venue_name, m.city, m.state, length(m.venue_name) AS match_len
    FROM public.aq_venue_map m
    WHERE m.tevo_venue_id IS NOT NULL AND (m.venue_name ILIKE v_pat OR m.city ILIKE v_pat)
    ORDER BY m.tevo_venue_id, length(m.venue_name) ASC LIMIT v_cap
  ) v;

  SELECT coalesce(jsonb_agg(to_jsonb(k) ORDER BY k.event_date), '[]'::jsonb) INTO v_mkt
  FROM (
    SELECT DISTINCT ON (lower(event_name), event_date, platform)
      platform, td_event_id, event_url, event_name, event_date, venue_name, city
    FROM public.v_td_unmatched_discovered_events
    WHERE (event_name ILIKE v_pat OR performer_label ILIKE v_pat OR venue_name ILIKE v_pat)
    ORDER BY lower(event_name), event_date, platform LIMIT v_cap
  ) k;

  -- RACING — drivers across all series (name match), best-ranked first.
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.points DESC NULLS LAST), '[]'::jsonb) INTO v_racing
  FROM (
    SELECT DISTINCT ON (s.series, s.espn_athlete_id)
      s.series, s.driver_name, s.driver_abbr, s.country, s.rank, s.points
    FROM public.espn_racing_standings s
    WHERE s.driver_name ILIKE v_pat OR s.driver_abbr ILIKE v_pat
    ORDER BY s.series, s.espn_athlete_id, s.points DESC NULLS LAST
    LIMIT v_cap
  ) r;

  -- FANTASY — leagues by name (+ sport tag).
  SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.name), '[]'::jsonb) INTO v_fantasy
  FROM (
    SELECT l.id, l.name, l.espn_league, count(t.id)::int AS team_count
    FROM public.fantasy_leagues l
    LEFT JOIN public.fantasy_teams t ON t.league_id = l.id
    WHERE l.name ILIKE v_pat OR l.espn_league ILIKE v_pat
    GROUP BY l.id, l.name, l.espn_league
    ORDER BY l.name LIMIT v_cap
  ) f;

  RETURN jsonb_build_object('q', v_q, 'limit', v_cap,
    'events', v_evs, 'performers', v_perfs, 'venues', v_vens, 'marketplace', v_mkt,
    'racing', v_racing, 'fantasy', v_fantasy);
END $function$;

REVOKE ALL ON FUNCTION public.terminal_search(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.terminal_search(text, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.terminal_search(text, integer) IS
  'D0 terminal topbar search — events / performers / venues / marketplace / '
  'racing (drivers) / fantasy (leagues). Email-gated. Cap 20/section. '
  'v5 mig 20260704170000 (adds racing + fantasy).';
