-- ============================================================================
-- Migration 20260630180000 — Seed SH/VD enrollment for the full AQ-mapped universe
--
-- Lane:     A1
-- Touches:  td_seed_mapped_xref (NEW fn), ticketsdata_event_xref (W, seeded rows).
-- Pre-reqs: td_seed_owned_xref (20260609160000) — this generalizes it; aq_event_map; event_metrics.
--
-- WHY: Measured 2026-06-30 — of 1,800 owned EVO events only 115 were enrolled in TD secondary polling,
-- and only 602 distinct events total were active in ticketsdata_event_xref, while ~3,253 upcoming events
-- are AQ-mapped (and ~2,200 carry an sh_event_id/vivid_event_id, so their TD /fetch URL is templatable
-- exactly like td_seed_owned_xref does). Budget is NOT the constraint: live caps are 50k/day · 600k/mo
-- recorded and current burn is ~8k/day · ~22k/mo — covering the mapped universe on SH+VD lands ~12k/day
-- (~24% of cap), and td_enqueue_peak already gates on td_budget_ok() so enqueue auto-throttles before any
-- cap. This generalizes td_seed_owned_xref to ALL mapped upcoming events (owned-first ordering) and seeds
-- the backlog. GT/TM/TP enrollment stays on the discovery track (no URL template) — out of scope here.
--
-- Idempotent (CREATE OR REPLACE + ON CONFLICT (event_id,platform) DO NOTHING) -> apply-before-PR; re-apply
-- only seeds newly-mapped events. URL templates + types mirror td_seed_owned_xref verbatim.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.td_seed_mapped_xref(
  p_limit integer DEFAULT 10000, p_apply boolean DEFAULT false, p_owned_only boolean DEFAULT false)
 RETURNS TABLE(action text, platform text, n bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
  CREATE TEMP TABLE _seed ON COMMIT DROP AS
  WITH cand AS (
    SELECT a.aq_short_event_id, a.sh_event_id, a.vivid_event_id,
           coalesce(m.owned_tickets_count, 0) AS owned_tickets_count, m.owned_median_retail
    FROM public.aq_event_map a
    LEFT JOIN LATERAL (
      SELECT em.owned_tickets_count, em.owned_median_retail
      FROM public.event_metrics em
      WHERE em.event_id = a.tevo_event_id
      ORDER BY em.captured_at DESC LIMIT 1
    ) m ON true
    WHERE a.tevo_event_id IS NOT NULL AND a.event_date >= now()
      AND (a.sh_event_id IS NOT NULL OR a.vivid_event_id IS NOT NULL)
      AND (NOT p_owned_only OR coalesce(m.owned_tickets_count, 0) > 0)
    ORDER BY coalesce(m.owned_tickets_count, 0) DESC NULLS LAST   -- owned-first
    LIMIT GREATEST(p_limit, 0)
  )
  SELECT c.sh_event_id AS event_id, 'SH'::text AS platform,
         'https://www.stubhub.com/x/event/' || c.sh_event_id || '/' AS event_url,
         c.aq_short_event_id, c.owned_tickets_count, c.owned_median_retail
  FROM cand c WHERE c.sh_event_id IS NOT NULL
  UNION ALL
  SELECT c.vivid_event_id, 'VD',
         'https://www.vividseats.com/production/' || c.vivid_event_id,
         c.aq_short_event_id, c.owned_tickets_count, c.owned_median_retail
  FROM cand c WHERE c.vivid_event_id IS NOT NULL;

  IF p_apply THEN
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, owned_tickets, median_retail_price, active, match_method, meta)
    SELECT s.event_id, s.platform, s.aq_short_event_id, s.event_url,
           s.owned_tickets_count, s.owned_median_retail, true, 'seed',
           jsonb_build_object('seed','mapped_xref','seeded_at', now())
    FROM _seed s
    ON CONFLICT (event_id, platform) DO NOTHING;

    RETURN QUERY
      SELECT 'inserted'::text, x.platform, count(*)
      FROM public.ticketsdata_event_xref x
      WHERE x.match_method = 'seed' AND x.meta->>'seed' = 'mapped_xref'
        AND x.created_at > now() - interval '2 minutes'
      GROUP BY x.platform;
  ELSE
    RETURN QUERY
      SELECT 'would_insert'::text, s.platform, count(*)
      FROM _seed s
      WHERE NOT EXISTS (SELECT 1 FROM public.ticketsdata_event_xref x
        WHERE x.event_id = s.event_id AND x.platform = s.platform)
      GROUP BY s.platform;
  END IF;
END $function$;

REVOKE EXECUTE ON FUNCTION public.td_seed_mapped_xref(integer,boolean,boolean) FROM public, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.td_seed_mapped_xref(integer,boolean,boolean) TO service_role;

-- Seed the current backlog (owned-first, all mapped). Idempotent; budget-gate-protected at enqueue time.
DO $do$ BEGIN PERFORM public.td_seed_mapped_xref(10000, true, false); END $do$;
