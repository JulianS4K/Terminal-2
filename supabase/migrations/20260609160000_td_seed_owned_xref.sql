-- Migration 20260609160000 · lane:D0 (author) → A1 (apply) ·
--   writes (DDL): td_seed_owned_xref() ·
--   reads: aq_event_map, event_metrics ·
--   writes on run (p_apply=true): ticketsdata_event_xref (insert owned watchlist) ·
--   spends: nothing directly (enqueue/fetch happens via the tier crons) ·
--   pre: 20260527050000 (xref), 20260609150000 (tier crons)
--
-- ## NOT YET APPLIED — author-only migration file.
--    Pending A1 review + explicit operator apply (CLAUDE.md §1). Validate on a
--    Supabase branch first. The function itself DEFAULTS TO DRY-RUN.
--
-- WHAT ───────────────────────────────────────────────────────────────────────
-- Onboarding seed: bulk-add the EVO owned-ticket book (event_metrics
-- owned_tickets_count > 0, upcoming, mapped in aq_event_map) onto the TicketsData
-- watchlist (ticketsdata_event_xref) so the per-platform tier crons can poll it.
--
-- Seeds StubHub + VividSeats only — their /fetch URLs are CONSTRUCTIBLE from the
-- aq platform ids (verified live 2026-06-09: constructed URLs returned full
-- inventory, e.g. Dream@Sky SH 1,642 listings / VD 201):
--     SH  → https://www.stubhub.com/x/event/{sh_event_id}/
--     VD  → https://www.vividseats.com/production/{vivid_event_id}
-- GT (internal hex id) and TM (hex id + slug) are NOT constructible from the
-- numeric ids, so those platforms are left to /events discovery (Workstream B),
-- not this seed. SH+VD are the universal base of every tier anyway.
--
-- DRY-RUN by default. p_limit ranks by owned_tickets_count DESC so a small run
-- onboards the highest-value owned events first. ON CONFLICT DO NOTHING — never
-- clobbers an existing xref row (e.g. one already discovered with a real URL).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_seed_owned_xref(
  p_limit integer DEFAULT 100,
  p_apply boolean DEFAULT false
)
RETURNS TABLE (action text, platform text, n bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  -- Candidate owned events (highest-value first), expanded to SH + VD rows.
  -- event_metrics is a time-series (PK event_id, captured_at) — take the LATEST
  -- row per event via LATERAL so the owned filter + value are current, not summed.
  CREATE TEMP TABLE _seed ON COMMIT DROP AS
  WITH owned AS (
    SELECT a.aq_short_event_id, a.sh_event_id, a.vivid_event_id,
           m.owned_tickets_count, m.owned_median_retail
    FROM public.aq_event_map a
    JOIN LATERAL (
      SELECT em.owned_tickets_count, em.owned_median_retail
      FROM public.event_metrics em
      WHERE em.event_id = a.tevo_event_id
      ORDER BY em.captured_at DESC
      LIMIT 1
    ) m ON m.owned_tickets_count > 0
    WHERE a.tevo_event_id IS NOT NULL
      AND a.event_date >= now()
      AND (a.sh_event_id IS NOT NULL OR a.vivid_event_id IS NOT NULL)
    ORDER BY m.owned_tickets_count DESC NULLS LAST
    LIMIT GREATEST(p_limit, 0)
  )
  SELECT o.sh_event_id AS event_id, 'SH'::text AS platform,
         'https://www.stubhub.com/x/event/' || o.sh_event_id || '/' AS event_url,
         o.aq_short_event_id, o.owned_tickets_count, o.owned_median_retail
  FROM owned o WHERE o.sh_event_id IS NOT NULL
  UNION ALL
  SELECT o.vivid_event_id, 'VD',
         'https://www.vividseats.com/production/' || o.vivid_event_id,
         o.aq_short_event_id, o.owned_tickets_count, o.owned_median_retail
  FROM owned o WHERE o.vivid_event_id IS NOT NULL;

  IF p_apply THEN
    -- xref links to the canonical event via aq_short_event_id (no tevo/sg column).
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url,
       owned_tickets, median_retail_price, active, match_method, meta)
    SELECT s.event_id, s.platform, s.aq_short_event_id, s.event_url,
           s.owned_tickets_count, s.owned_median_retail,
           true, 'manual',
           jsonb_build_object('seed','owned_xref','seeded_at', now())
    FROM _seed s
    ON CONFLICT (event_id, platform) DO NOTHING;

    RETURN QUERY
      SELECT 'inserted'::text, x.platform, count(*)
      FROM public.ticketsdata_event_xref x
      WHERE x.match_method = 'manual'
        AND x.meta->>'seed' = 'owned_xref'
        AND x.created_at > now() - interval '1 minute'
      GROUP BY x.platform;
  ELSE
    -- Dry-run: what WOULD be newly inserted (excludes rows already present).
    RETURN QUERY
      SELECT 'would_insert'::text, s.platform, count(*)
      FROM _seed s
      WHERE NOT EXISTS (
        SELECT 1 FROM public.ticketsdata_event_xref x
        WHERE x.event_id = s.event_id AND x.platform = s.platform)
      GROUP BY s.platform;
  END IF;
END $fn$;
REVOKE ALL ON FUNCTION public.td_seed_owned_xref(integer,boolean) FROM anon, public;

-- ── Operator runbook ─────────────────────────────────────────────────────────
--   Preview top-50 owned events (no writes):  SELECT * FROM public.td_seed_owned_xref(50, false);
--   Onboard a small sample:                   SELECT * FROM public.td_seed_owned_xref(20, true);
--   Onboard the full owned book incrementally: SELECT * FROM public.td_seed_owned_xref(2200, true);
--   Then enable per-platform polling:         UPDATE public.cron_policy SET enabled=true WHERE jobname IN ('td_tier_enqueue_sh','td_tier_enqueue_vd');
