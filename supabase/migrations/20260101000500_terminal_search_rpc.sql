-- Migration 20260517230000 · lane:D0 (author) → A1 (apply) · writes:terminal_search · reads:events,aq_performer_map,aq_venue_map · pre:20260517220000 · auth:operator-approved 2026-05-17
--
-- D0 — global terminal search SECDEF RPC. Drives the topbar search input
-- on every terminal page (nav.js, shared topbar). Returns matching events,
-- performers, venues in a single round-trip.
--
-- Search semantics:
--   - Case-insensitive ILIKE on name fields with %q% wildcards
--   - Performer scoping: also matches against the `aliases` text[] (added in
--     mig 20260516290000 — Aces aliases like "Vegas Aces, LV Aces" are
--     populated there for retrieval to work even from the casual name)
--   - Events: only return UPCOMING events (occurs_at_local >= now() - 6h
--     so a game in progress still surfaces); operator dashboards focus
--     forward-looking
--   - Ordering: shorter names first (heuristic for "most relevant when
--     `q` is a short substring") then alphabetical
--   - Per-section cap defaults to 6, hard capped at 20
--
-- Email-gated to @s4kent.com (same pattern as v3 RPCs).
--
-- ## Pending operator apply via apply_migration

CREATE OR REPLACE FUNCTION public.terminal_search(
  p_q     text,
  p_limit integer DEFAULT 6
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_q     text;
  v_pat   text;
  v_cap   integer;
  v_evs   jsonb;
  v_perfs jsonb;
  v_vens  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  v_q   := trim(coalesce(p_q, ''));
  v_cap := greatest(1, least(coalesce(p_limit, 6), 20));
  IF length(v_q) < 2 THEN
    RETURN jsonb_build_object('q', v_q, 'events', '[]'::jsonb, 'performers', '[]'::jsonb, 'venues', '[]'::jsonb);
  END IF;
  v_pat := '%' || v_q || '%';

  -- Events: upcoming + name match. Exclude likely-stale 'past' state.
  -- Use length(name) ASC as a cheap relevance proxy: shorter matches rank higher.
  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.match_len, e.occurs_at_local), '[]'::jsonb)
  INTO v_evs
  FROM (
    SELECT
      id              AS tevo_event_id,
      name,
      venue_name,
      occurs_at_local,
      primary_performer_name,
      length(name)    AS match_len
    FROM public.events
    WHERE name ILIKE v_pat
      AND occurs_at_local >= now() - interval '6 hours'
      AND coalesce(state, '') <> 'past'
    ORDER BY length(name) ASC, occurs_at_local ASC
    LIMIT v_cap
  ) e;

  -- Performers: name OR alias match. aliases is text[]; use the @> ANY pattern via unnest.
  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.match_len, p.performer_name), '[]'::jsonb)
  INTO v_perfs
  FROM (
    SELECT DISTINCT ON (m.tevo_performer_id)
      m.tevo_performer_id,
      m.performer_short_id,
      m.performer_name,
      m.category,
      length(m.performer_name) AS match_len
    FROM public.aq_performer_map m
    WHERE m.tevo_performer_id IS NOT NULL
      AND (
        m.performer_name ILIKE v_pat
        OR EXISTS (
          SELECT 1 FROM unnest(coalesce(m.aliases, ARRAY[]::text[])) AS a(alias)
          WHERE a.alias ILIKE v_pat
        )
      )
    ORDER BY m.tevo_performer_id, length(m.performer_name) ASC
    LIMIT v_cap
  ) p;

  -- Venues: name + optional city match.
  SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY v.match_len, v.venue_name), '[]'::jsonb)
  INTO v_vens
  FROM (
    SELECT DISTINCT ON (m.tevo_venue_id)
      m.tevo_venue_id,
      m.venue_short_id,
      m.venue_name,
      m.city,
      m.state,
      length(m.venue_name) AS match_len
    FROM public.aq_venue_map m
    WHERE m.tevo_venue_id IS NOT NULL
      AND (m.venue_name ILIKE v_pat OR m.city ILIKE v_pat)
    ORDER BY m.tevo_venue_id, length(m.venue_name) ASC
    LIMIT v_cap
  ) v;

  RETURN jsonb_build_object(
    'q', v_q,
    'limit', v_cap,
    'events', v_evs,
    'performers', v_perfs,
    'venues', v_vens
  );
END $func$;

REVOKE ALL ON FUNCTION public.terminal_search(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.terminal_search(text, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.terminal_search(text, integer) IS
  'D0 terminal topbar search — returns matching events (upcoming) / performers / venues for a substring query. Email-gated. Cap 20/section.';
