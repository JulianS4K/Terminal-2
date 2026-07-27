-- Migration 20260517240000 · lane:A1 (fixup of #200) · writes:terminal_search · reads:events,aq_performer_map,aq_venue_map · pre:20260517230000 · auth:operator-approved 2026-05-17
--
-- A1 fixup for D0 PR #200: events.occurs_at_local is TEXT (not timestamptz),
-- so the filter `occurs_at_local >= now() - interval '6 hours'` raises
-- 42883 (operator does not exist) at runtime. Function compiled fine because
-- PL/pgSQL is parse-only at CREATE — runtime smoke test caught it.
--
-- Fix: cast via ::timestamptz with a regex guard against malformed strings
-- (same pattern used by sg_canonical_link_from_tevo_chunked + others —
-- see PROJECT_BIBLE §3 column landmines for the events.occurs_at_local row).
--
-- Migration applied to prod directly via apply_migration; this file aligns
-- git history with the live state.

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
      AND occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND occurs_at_local::timestamptz >= now() - interval '6 hours'
      AND coalesce(state, '') <> 'past'
    ORDER BY length(name) ASC, occurs_at_local ASC
    LIMIT v_cap
  ) e;

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
  'D0 terminal topbar search — returns matching events (upcoming) / performers / venues. Email-gated. Cap 20/section. A1 fixup 2026-05-17: occurs_at_local is text, cast via ::timestamptz + regex guard.';
