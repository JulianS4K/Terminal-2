-- ============================================================================
-- Migration 20260702134500 — terminal_search: exclude state='ignored' events
--
-- Lane:     A1
-- Touches:  public.terminal_search(text,int) — events-bucket WHERE clause only.
-- Pre-reqs: 20260702014500/20260702030000 (Sphere Wizard ignore + removal).
--
-- WHY (operator 2026-07-02: "i still see the wizard of oz events in terminal"):
--   The D0 topbar search calls the `terminal_search` SECDEF RPC directly (not
--   the Python /api search path), and its events bucket filtered only
--   `coalesce(state,'') <> 'past'` — so the 453 ignored Sphere Wizard events
--   still surfaced as suggestions. Every other terminal surface was already
--   clean (chart/movers/metrics via the data removal; portfolio + Python search
--   drop inactive via event_lifecycle, whose derive fn maps state='ignored' →
--   is_active=false).
--
--   FIX: events bucket now filters `coalesce(state,'') NOT IN ('past','ignored')`.
--   Applied via MCP — effective immediately, no app deploy needed. Verified:
--   0 Sphere Wizard rows visible to the RPC; the only remaining "wizard"
--   matches are King Gizzard and the Lizard Wizard concerts (legit, kept).
--
-- Idempotent: CREATE OR REPLACE. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

CREATE OR REPLACE FUNCTION public.terminal_search(p_q text, p_limit integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_q text; v_pat text; v_cap integer; v_evs jsonb; v_perfs jsonb; v_vens jsonb; v_mkt jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  v_q := trim(coalesce(p_q, ''));
  v_cap := greatest(1, least(coalesce(p_limit, 6), 20));
  IF length(v_q) < 2 THEN
    RETURN jsonb_build_object('q', v_q, 'events', '[]'::jsonb, 'performers', '[]'::jsonb,
                              'venues', '[]'::jsonb, 'marketplace', '[]'::jsonb);
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
  RETURN jsonb_build_object('q', v_q, 'limit', v_cap,
    'events', v_evs, 'performers', v_perfs, 'venues', v_vens, 'marketplace', v_mkt);
END $function$;
