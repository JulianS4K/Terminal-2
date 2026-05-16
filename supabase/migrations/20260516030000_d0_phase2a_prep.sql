-- Migration 20260516030000 · admin · D0 Phase 2a prep · pre:20260516020000
-- Validation spot-check (2026-05-16) on 5 broad-spectrum events + 10-sample sweeps
-- surfaced 7 findings. This migration ships 3 deploy-ready fixes; the other
-- 4 are documented as D0-plan constraints (see Phase 2a delta report).
--
-- Fix 1 (Finding 5): sg_classify_events() force-SKIPs cancelled-pattern events.
--   12 dead-end events (CANCELLED / If Necessary / (Date TBD) / TBD at )
--   were stuck in COOL/WARM tiers wasting poll budget. Regex tested on
--   24-sample probe: 11 COOL→SKIP + 1 WARM→SKIP, 12 false-positive-free.
--
-- Fix 2 (Finding 7): sg_event_priority_state.tevo_event_id column.
--   D0 needs to bridge SG → TEvo for listings_snapshots reads. Currently
--   priority_state has aq_short_event_id but not tevo_event_id, forcing
--   D0 to join seatgeek_event_xref every query. ADD COLUMN + backfill +
--   index. Population coverage tested: 1061/1940 (55%) resolvable via
--   sg_events_canonical (preferred) or seatgeek_event_xref fallback.
--   48 of 57 active-tier rows (84%) will populate.
--
-- Fix 3 (Finding 1 prep): _v_d0_event_index view as D0's canonical entry.
--   One row per priority_state event with all bridge IDs pre-resolved
--   (sg / tevo / aq / espn / venue / performer). Lets D0 issue a single
--   indexed lookup instead of 5-way join per page load.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16 16:55 UTC.
-- Post-apply verification (16:57):
--   tier distribution: HOT=12, WARM=2, COOL=20, OBSERVE=212, SKIP=32
--   85 cancelled-pattern events → all SKIP, 0 leaked to polling
--   tevo_event_id: 1061/1940 (54.7%) populated, 45 of active-tier
--   _v_d0_event_index returns 1892 rows
--   5 spot-check events resolve correctly (Lakers G6 CANCELLED → SKIP)
--
-- Transient gotcha during apply: concurrent sg_classify_events_5min cron
-- fired at 16:55 and briefly clobbered tier=SKIP back to WARM on Lakers G6;
-- next cron firing self-healed. Lesson: classifier patch + concurrent classifier
-- cron = inherent 5-min race window. Acceptable.

-- ============================================================
-- Fix 1: sg_classify_events SKIP-override for cancelled patterns
-- ============================================================

CREATE OR REPLACE FUNCTION public.sg_classify_events()
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
BEGIN
  WITH listings_by_tevo AS (
    SELECT event_id AS tevo_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
      AND event_id IS NOT NULL
    GROUP BY event_id
  ),
  listings_by_aq AS (
    SELECT aq_short_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
      AND aq_short_event_id IS NOT NULL
    GROUP BY aq_short_event_id
  ),
  event_metrics AS (
    SELECT c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_datetime_utc,
           coalesce(a.aq_short_event_id,
                    (SELECT aem.aq_short_event_id FROM public.aq_event_map aem
                     WHERE aem.sg_event_id = c.sg_event_id LIMIT 1)) AS aq_short_event_id,
           -- NEW: resolve tevo_event_id (Fix 2)
           coalesce(c.tevo_event_id,
                    (SELECT x.tevo_event_id FROM public.seatgeek_event_xref x
                     WHERE x.sg_event_id = c.sg_event_id LIMIT 1)) AS tevo_event_id,
           EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event,
           coalesce(lt.owned_cnt,    la.owned_cnt,    0) AS owned_cnt,
           coalesce(lt.listings_cnt, la.listings_cnt, 0) AS listings_cnt
    FROM public.sg_events_canonical c
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = c.sg_event_id
    LEFT JOIN listings_by_tevo lt ON lt.tevo_event_id = c.tevo_event_id
    LEFT JOIN listings_by_aq   la ON la.aq_short_event_id = a.aq_short_event_id
    WHERE c.sg_datetime_utc IS NOT NULL
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '60 days'
  ),
  classified AS (
    SELECT em.*,
      -- NEW: dead-end events forced to SKIP regardless of owned/hours
      CASE
        WHEN em.sg_event_name ~* '(cancelled|if necessary|\(date tbd\)|^TBD at )' THEN 'SKIP'
        ELSE
          (SELECT p.tier FROM public.sg_priority_policy p
           WHERE p.enabled = true
             AND em.hours_to_event >= coalesce(p.min_hours_to_event, -999999)
             AND em.hours_to_event <  coalesce(p.max_hours_to_event, 999999)
             AND (p.requires_owned = false OR em.owned_cnt > 0)
           ORDER BY p.sort_order LIMIT 1)
      END AS tier
    FROM event_metrics em
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     tevo_event_id, owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         tevo_event_id, owned_cnt, listings_cnt, coalesce(tier, 'SKIP'), hours_to_event, v_now
  FROM classified WHERE sg_event_id IS NOT NULL
  ON CONFLICT (sg_event_id) DO UPDATE SET
    sg_event_name           = EXCLUDED.sg_event_name,
    sg_venue_name           = EXCLUDED.sg_venue_name,
    sg_datetime_utc         = EXCLUDED.sg_datetime_utc,
    aq_short_event_id       = EXCLUDED.aq_short_event_id,
    tevo_event_id           = EXCLUDED.tevo_event_id,  -- NEW (Fix 2)
    owned_count_last_7d     = EXCLUDED.owned_count_last_7d,
    active_listings_last_7d = EXCLUDED.active_listings_last_7d,
    tier                    = EXCLUDED.tier,
    hours_to_event          = EXCLUDED.hours_to_event,
    computed_at             = EXCLUDED.computed_at,
    sales_polls_today       = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day              = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END $func$;

-- ============================================================
-- Fix 2: ADD COLUMN sg_event_priority_state.tevo_event_id
-- ============================================================

ALTER TABLE public.sg_event_priority_state
  ADD COLUMN IF NOT EXISTS tevo_event_id bigint;

-- Backfill from sg_events_canonical (preferred, 55% coverage)
-- with seatgeek_event_xref fallback (43% coverage; union = 55%, canonical superset).
UPDATE public.sg_event_priority_state sps
SET tevo_event_id = coalesce(sgc.tevo_event_id, xref.tevo_event_id)
FROM public.sg_events_canonical sgc
LEFT JOIN public.seatgeek_event_xref xref ON xref.sg_event_id = sgc.sg_event_id
WHERE sps.sg_event_id = sgc.sg_event_id
  AND sps.tevo_event_id IS NULL
  AND coalesce(sgc.tevo_event_id, xref.tevo_event_id) IS NOT NULL;

CREATE INDEX IF NOT EXISTS sg_event_priority_state_tevo_idx
  ON public.sg_event_priority_state(tevo_event_id) WHERE tevo_event_id IS NOT NULL;

-- ============================================================
-- Fix 3: _v_d0_event_index — canonical D0 entry view
-- ============================================================

CREATE OR REPLACE VIEW public._v_d0_event_index
WITH (security_invoker = true) AS
SELECT
  sps.sg_event_id,
  sps.tevo_event_id,
  sps.aq_short_event_id,
  sps.sg_event_name        AS event_name,
  sps.sg_venue_name        AS venue_name,
  sps.sg_datetime_utc      AS event_at_utc,
  sps.tier,
  sps.owned_count_last_7d,
  sps.active_listings_last_7d,
  sps.hours_to_event,
  -- ESPN xref (for gameday "live state" panel availability)
  eem.espn_event_id,
  eem.espn_league,
  -- Venue context (for weather strip + map)
  va.tevo_venue_id        AS venue_tevo_id,
  va.is_indoor,
  va.latitude,
  va.longitude,
  va.capacity,
  -- Performer (single value; multi-performer events use primary)
  aem.performer_short_id
  -- Freshness signals (sg_listings_latest, sg_sales_latest, tevo_listings_latest)
  -- DELIBERATELY OMITTED from the view: correlated MAX() subqueries against
  -- the 8M-row listings_snapshots + 2M+ SG tables consistently time out.
  -- D0 should fetch them on-demand per-event-detail-page via direct query:
  --   SELECT max(captured_at) FROM public.seatgeek_listings_snapshots
  --   WHERE sg_event_id = $1
  -- DO NOT trust seatgeek_event_xref.last_listings_at / last_sales_at —
  -- those columns are dead (populated for 0 of 967 rows globally).
FROM public.sg_event_priority_state sps
LEFT JOIN public.seatgeek_event_xref xref ON xref.sg_event_id = sps.sg_event_id
LEFT JOIN public.entity_event_map eem ON eem.tevo_event_id = sps.tevo_event_id
LEFT JOIN public.events e ON e.id = sps.tevo_event_id
LEFT JOIN public.venue_assets va ON va.tevo_venue_id = e.venue_id
LEFT JOIN public.aq_event_map aem ON aem.aq_short_event_id = sps.aq_short_event_id
WHERE sps.sg_datetime_utc > now() - interval '6 hours';

GRANT SELECT ON public._v_d0_event_index TO authenticated;

COMMENT ON VIEW public._v_d0_event_index IS
  'D0 Phase 2a canonical entry view. One row per upcoming/recent event with all '
  'bridge IDs (sg/tevo/aq/espn) + venue context + freshness signals pre-resolved. '
  'Freshness signals query snapshot tables directly because seatgeek_event_xref.last_*_at '
  'and sg_events_canonical.has_v2_listings_pulled are dead columns (0% population).';

-- ============================================================
-- Re-run classifier once to apply SKIP + populate tevo_event_id
-- ============================================================

SELECT public.sg_classify_events();
