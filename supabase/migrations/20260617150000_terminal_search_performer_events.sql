-- Migration 20260617150000 · lane:D0 (author) → A1 (apply) ·
--   writes (DDL): terminal_search() (v4 — performers now carry upcoming events) ·
--   reads: events, aq_performer_map, aq_venue_map, v_td_unmatched_discovered_events,
--          sports_player_search() ·
--   pre: 20260617120000 (terminal_search v3 + sports_player_search)
--
-- ## NOT YET APPLIED — author-only migration file.
--    Pending A1 review + explicit operator apply (CLAUDE.md §1).
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- Unify how a PERFORMER and a PLAYER present in search: each should show its
-- upcoming events inline. Searching "Pearl Jam" should show Pearl Jam concerts
-- the same way searching a team (or a player → team) shows that team's games.
--
-- v3 already returns a `players` section (athlete → team performer → events).
-- This adds the symmetric piece: the `performers` section now carries an
-- `events` array per performer (up to 3 upcoming, via primary_performer_id OR
-- performer_ids[]). All other sections (events/venues/marketplace) unchanged.
--
-- NOTE (national teams / multi-team players): a player → *national team* link
-- (e.g. Messi → Argentina) is NOT yet possible from our data — ESPN carries no
-- nationality on the athlete, the "Argentina Mens National Soccer" performer
-- has a NULL tevo_performer_id, and we hold no upcoming Argentina-soccer events.
-- That needs a curated athlete→national-team map + performer mapping + event
-- ingest — tracked as a follow-up. sports_player_search already returns ALL
-- ESPN teams per athlete, so it lights up automatically once that data lands.
--
-- IDEMPOTENT: CREATE OR REPLACE (same (text,integer) signature). Re-runnable.
-- ─────────────────────────────────────────────────────────────────────────────

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
  v_now_s   text;
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
  v_now_s := to_char(now() - interval '6 hours', 'YYYY-MM-DD"T"HH24:MI:SS');

  -- PLAYERS — shared resolver (ESPN athlete → team performer → upcoming events)
  v_players := public.sports_player_search(v_q, v_cap);

  -- EVENTS (catalog, upcoming) — direct event-name matches.
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

  -- PERFORMERS — now each carries up to 3 upcoming events (Pearl Jam→concerts,
  -- a team→games), mirroring the players section.
  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.match_len, p.performer_name), '[]'::jsonb)
  INTO v_perfs
  FROM (
    SELECT pp.tevo_performer_id, pp.performer_short_id, pp.performer_name, pp.category, pp.match_len,
      (SELECT coalesce(jsonb_agg(ev ORDER BY ev.occurs_at_local), '[]'::jsonb)
         FROM (
           SELECT e.id AS tevo_event_id, e.name, e.venue_name, e.occurs_at_local
           FROM public.events e
           WHERE (e.primary_performer_id = pp.tevo_performer_id
                  OR pp.tevo_performer_id = ANY (e.performer_ids))
             AND coalesce(e.state, '') <> 'past'
             AND e.occurs_at_local >= v_now_s
           ORDER BY e.occurs_at_local ASC
           LIMIT 3
         ) ev) AS events
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
    ) pp
  ) p;

  -- VENUES
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

  -- MARKETPLACE (TicketsData /events discoveries we don't track locally)
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
  'D0 terminal search — players (sports_player_search) / events / performers '
  '(now with inline upcoming events) / venues / marketplace. Email-gated. '
  'v4 mig 20260617150000.';
