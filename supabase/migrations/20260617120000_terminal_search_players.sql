-- Migration 20260617120000 · lane:D0 (author) → A1 (apply) ·
--   writes (DDL): terminal_search() (v3 — adds a 'players' section),
--                 events_primary_performer_id_idx (new), events_performer_ids_gin (new) ·
--   reads: espn_athletes, performer_espn_team_xref, espn_teams_canonical,
--          espn_injuries_snapshots, aq_performer_map, events,
--          aq_venue_map, v_td_unmatched_discovered_events ·
--   pre: 20260609130000 (terminal_search v2 — events/performers/venues/marketplace)
--
-- ## NOT YET APPLIED — author-only migration file.
--    Pending A1 review + explicit operator apply (CLAUDE.md §1). Validate on a
--    Supabase branch (copy-on-write fork) before any prod apply.
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- Make the terminal search a *sports* search: typing a player's name ("messi",
-- "lebron") should surface that player's TEAM and the team's upcoming event
-- info — not just literal event/performer/venue name matches.
--
-- terminal_search v2 only matched on event / performer / venue NAMES, so a
-- player name returned nothing (no event is literally named "LeBron"). This
-- adds a 'players' section that layers in our ESPN athlete data:
--
--     espn_athletes (name)                       -- "LeBron James"
--       → performer_espn_team_xref (team→tevo)   -- LA Lakers performer 16328
--       → events (upcoming for that performer)   -- the team's games
--
-- and returns, per matched player: the athlete (position/jersey/status/headshot
-- + latest injury) + their mapped TEvo team performer + up to 3 upcoming events.
-- The frontend renders these as a PLAYERS section whose rows deep-link to the
-- team's performer page and to each upcoming event page.
--
-- This composes with — does not replace — the existing API-search-fed sections:
-- events/performers/venues come from our TEvo-search-populated catalog and the
-- 'marketplace' section from TicketsData /events discovery (v2). Players is the
-- ESPN layer that ties a person to the ticketed team event.
--
-- LANDMINES OBSERVED (PROJECT_BIBLE §3) ──────────────────────────────────────
--   * espn_team_id COLLIDES across leagues (id "13" = NBA Lakers AND an MLB
--     team). The legacy get_player_info()/team_xref join on espn_team_id ALONE,
--     so they mis-label LeBron's team as "Texas Rangers". This RPC joins
--     performer_espn_team_xref + espn_teams_canonical on (espn_team_id,
--     espn_league) BOTH — verified league-correct (LeBron→Lakers, Messi→Inter
--     Miami CF). latest_injury is likewise espn_league-scoped.
--   * events.occurs_at_local is TEXT (offset-bearing) — compare against a
--     formatted string cutoff, never a timestamptz (same fix as v2).
--   * events link to a performer via primary_performer_id OR performer_ids[]
--     (array) — both checked.
--
-- IDEMPOTENT: CREATE OR REPLACE (same (text,integer) signature → no new
-- overload) + CREATE INDEX IF NOT EXISTS. Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────

-- Supporting indexes for the per-player upcoming-events lookup (events is small,
-- ~9.4k rows, but these keep the lookup index-driven as the catalog grows).
CREATE INDEX IF NOT EXISTS events_primary_performer_id_idx
  ON public.events (primary_performer_id)
  WHERE primary_performer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS events_performer_ids_gin
  ON public.events USING gin (performer_ids);


CREATE OR REPLACE FUNCTION public.terminal_search(
  p_q     text,
  p_limit integer DEFAULT 6
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email   text;
  v_q       text;
  v_pat     text;
  v_re      text;   -- regex-safe token for word-boundary (\m) ranking
  v_now_s   text;   -- formatted "upcoming" cutoff (occurs_at_local is TEXT)
  v_cap     integer;
  v_evs     jsonb;
  v_perfs   jsonb;
  v_vens    jsonb;
  v_mkt     jsonb;
  v_players jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_q   := trim(coalesce(p_q, ''));
  v_cap := greatest(1, least(coalesce(p_limit, 6), 20));
  IF length(v_q) < 2 THEN
    RETURN jsonb_build_object('q', v_q, 'players', '[]'::jsonb, 'events', '[]'::jsonb,
                              'performers', '[]'::jsonb, 'venues', '[]'::jsonb,
                              'marketplace', '[]'::jsonb);
  END IF;
  v_pat   := '%' || v_q || '%';
  -- strip regex metacharacters so the \m word-boundary match can't error / inject
  v_re    := regexp_replace(v_q, '[^[:alnum:][:space:]]', '', 'g');
  v_now_s := to_char(now() - interval '6 hours', 'YYYY-MM-DD"T"HH24:MI:SS');

  -- ── PLAYERS (ESPN) — athlete → mapped TEvo team performer → upcoming events ──
  WITH cand AS (
    SELECT a.espn_athlete_id, a.full_name, a.display_name, a.position_abbr,
           a.jersey, a.status, a.espn_league, a.espn_team_id, a.headshot_url,
           a.last_seen_at,
           CASE
             WHEN lower(a.full_name) = lower(v_q) OR lower(a.display_name) = lower(v_q) THEN 100
             -- whole-word hit (surname etc): "messi"→"Lionel Messi" beats "Messick"/"Messiah"
             WHEN a.full_name ~* ('\m' || v_re || '\M') OR a.display_name ~* ('\m' || v_re || '\M') THEN 90
             WHEN a.full_name ~* ('\m' || v_re) OR a.display_name ~* ('\m' || v_re) THEN 85
             WHEN a.full_name ILIKE v_q || '%' OR a.display_name ILIKE v_q || '%' THEN 80
             ELSE 60
           END AS match_strength
    FROM public.espn_athletes a
    WHERE a.full_name ILIKE v_pat
       OR a.display_name ILIKE v_pat
       OR coalesce(a.short_name, '') ILIKE v_pat
  ),
  m AS (
    SELECT DISTINCT ON (c.espn_athlete_id)
      c.espn_athlete_id, c.full_name, c.display_name, c.position_abbr,
      c.jersey, c.status, c.espn_league, c.headshot_url, c.last_seen_at,
      c.match_strength,
      ptx.tevo_performer_id,
      -- league-scoped team name (NOT the collision-prone team_xref)
      coalesce(tc.display_name,
               (SELECT apm.performer_name FROM public.aq_performer_map apm
                 WHERE apm.tevo_performer_id = ptx.tevo_performer_id LIMIT 1)) AS team_name,
      (SELECT coalesce(jsonb_agg(ev ORDER BY ev.occurs_at_local), '[]'::jsonb)
         FROM (
           SELECT e.id AS tevo_event_id, e.name, e.venue_name, e.occurs_at_local
           FROM public.events e
           WHERE (e.primary_performer_id = ptx.tevo_performer_id
                  OR ptx.tevo_performer_id = ANY (e.performer_ids))
             AND coalesce(e.state, '') <> 'past'
             AND e.occurs_at_local >= v_now_s
           ORDER BY e.occurs_at_local ASC
           LIMIT 3
         ) ev) AS events,
      EXISTS (
        SELECT 1 FROM public.events e2
        WHERE (e2.primary_performer_id = ptx.tevo_performer_id
               OR ptx.tevo_performer_id = ANY (e2.performer_ids))
          AND coalesce(e2.state, '') <> 'past'
          AND e2.occurs_at_local >= v_now_s
      ) AS has_events
    FROM cand c
    JOIN public.performer_espn_team_xref ptx
      ON ptx.espn_team_id = c.espn_team_id AND ptx.espn_league = c.espn_league
    LEFT JOIN public.espn_teams_canonical tc
      ON tc.espn_team_id = c.espn_team_id AND tc.espn_league = c.espn_league
    ORDER BY c.espn_athlete_id, c.match_strength DESC
  )
  SELECT coalesce(
           jsonb_agg(
             jsonb_build_object(
               'espn_athlete_id',   q.espn_athlete_id,
               'full_name',         q.full_name,
               'display_name',      q.display_name,
               'position_abbr',     q.position_abbr,
               'jersey',            q.jersey,
               'status',            q.status,
               'espn_league',       q.espn_league,
               'headshot_url',      q.headshot_url,
               'tevo_performer_id', q.tevo_performer_id,
               'team_name',         q.team_name,
               'latest_injury', (
                 SELECT jsonb_build_object('status', i.status,
                                           'injury_type', i.injury_type,
                                           'short_comment', i.short_comment)
                 FROM public.espn_injuries_snapshots i
                 WHERE i.athlete_id = q.espn_athlete_id
                   AND i.espn_league = q.espn_league
                 ORDER BY i.captured_at DESC LIMIT 1),
               'events', q.events
             )
             ORDER BY q.has_events DESC, q.match_strength DESC, q.last_seen_at DESC
           ), '[]'::jsonb)
  INTO v_players
  FROM (
    SELECT * FROM m
    ORDER BY m.has_events DESC, m.match_strength DESC, m.last_seen_at DESC
    LIMIT v_cap
  ) q;

  -- ── EVENTS (catalog, upcoming) ──────────────────────────────────────────────
  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.match_len, e.occurs_at_local), '[]'::jsonb)
  INTO v_evs
  FROM (
    SELECT id AS tevo_event_id, name, venue_name, occurs_at_local,
           primary_performer_name, length(name) AS match_len
    FROM public.events
    WHERE name ILIKE v_pat
      AND occurs_at_local >= v_now_s
      AND coalesce(state, '') <> 'past'
    ORDER BY length(name) ASC, occurs_at_local ASC
    LIMIT v_cap
  ) e;

  -- ── PERFORMERS ──────────────────────────────────────────────────────────────
  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.match_len, p.performer_name), '[]'::jsonb)
  INTO v_perfs
  FROM (
    SELECT DISTINCT ON (m2.tevo_performer_id)
      m2.tevo_performer_id, m2.performer_short_id, m2.performer_name, m2.category,
      length(m2.performer_name) AS match_len
    FROM public.aq_performer_map m2
    WHERE m2.tevo_performer_id IS NOT NULL
      AND ( m2.performer_name ILIKE v_pat
            OR EXISTS (SELECT 1 FROM unnest(coalesce(m2.aliases, ARRAY[]::text[])) AS a(alias)
                       WHERE a.alias ILIKE v_pat) )
    ORDER BY m2.tevo_performer_id, length(m2.performer_name) ASC
    LIMIT v_cap
  ) p;

  -- ── VENUES ──────────────────────────────────────────────────────────────────
  SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY v.match_len, v.venue_name), '[]'::jsonb)
  INTO v_vens
  FROM (
    SELECT DISTINCT ON (m3.tevo_venue_id)
      m3.tevo_venue_id, m3.venue_short_id, m3.venue_name, m3.city, m3.state,
      length(m3.venue_name) AS match_len
    FROM public.aq_venue_map m3
    WHERE m3.tevo_venue_id IS NOT NULL
      AND (m3.venue_name ILIKE v_pat OR m3.city ILIKE v_pat)
    ORDER BY m3.tevo_venue_id, length(m3.venue_name) ASC
    LIMIT v_cap
  ) v;

  -- ── MARKETPLACE (TicketsData /events discoveries we don't track locally) ─────
  SELECT coalesce(jsonb_agg(to_jsonb(k) ORDER BY k.event_date), '[]'::jsonb)
  INTO v_mkt
  FROM (
    SELECT DISTINCT ON (lower(event_name), event_date, platform)
      platform, td_event_id, event_url, event_name, event_date, venue_name, city
    FROM public.v_td_unmatched_discovered_events
    WHERE (event_name ILIKE v_pat OR performer_label ILIKE v_pat OR venue_name ILIKE v_pat)
    ORDER BY lower(event_name), event_date, platform
    LIMIT v_cap
  ) k;

  RETURN jsonb_build_object(
    'q', v_q, 'limit', v_cap,
    'players', v_players,
    'events', v_evs, 'performers', v_perfs, 'venues', v_vens,
    'marketplace', v_mkt
  );
END $func$;

REVOKE ALL ON FUNCTION public.terminal_search(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.terminal_search(text, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.terminal_search(text, integer) IS
  'D0 terminal topbar search — players (ESPN athlete→team performer→upcoming '
  'events) / events / performers / venues / marketplace (TicketsData-discovered). '
  'Email-gated. Cap 20/section. v3 mig 20260617120000 (adds players section; '
  'team mapping is league-scoped to avoid the espn_team_id cross-league collision).';
