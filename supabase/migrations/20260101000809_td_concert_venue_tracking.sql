-- ============================================================================
-- MIG 20260605140000 — TD listings for concert venues
--
-- The td_target_events() focus set currently tracks only:
--   • Yankees: next 20 home games (SH + VD)
--   • Knicks: remaining playoff games (SH + VD)
--
-- This migration expands it to also include all future events at the 15
-- concert venues added to the watchlist in mig 20260605120000:
--   Red Rocks (1290), Forest Hills (520), Ryman (1366), MGM Grand (996),
--   Pechanga (8000), T-Mobile Center KC (4603), Allstate (33), BOK (5118),
--   CFG Bank (103), Bert Ogden (33737), Sames Auto (2407), Save Mart (2839),
--   Maine Savings (7425), Moody Center ATX (38485), Carlson Center (228)
--
-- Coverage as of 2026-06-05: 41 events have sh_event_id, 42 have
-- vivid_event_id in aq_event_map (out of 63 total future events).
-- Remaining ~20 events have no aq_event_map entry yet; they'll join
-- automatically once the AQ mapper resolves them.
--
-- Cadence: always_on=true so td_enqueue_peak picks them up regardless
-- of horizon (concerts are months out; the 7-day gate would otherwise
-- exclude them). Budget: LIMIT 33/fire × 4 fires = 132 credits/day <
-- 300 daily cap — the per-fire limit is the binding ceiling regardless
-- of how many active pairs exist.
--
-- Platforms: SH + VD only (direct IDs via aq_event_map).
-- GT/TP/TM require performer-based discovery (Yankees/Knicks-scoped);
-- out of scope here.
-- ============================================================================

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1) Expand td_target_events() — add concert_venues CTE
--    Preserves the existing yankees + knicks logic verbatim.
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_target_events()
 RETURNS TABLE(aq_short_event_id text, sh_event_id bigint, vivid_event_id bigint, sg_event_id bigint)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH yankees AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%at New York Yankees%'
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_date > now()
    ORDER BY aem.event_date ASC
    LIMIT 20
  ),
  knicks AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%knicks%'
      AND aem.event_date > now()
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_name NOT ILIKE '%season ticket%'
      AND ( aem.event_name ILIKE '%finals%'
         OR aem.event_name ILIKE '%playoff%'
         OR aem.event_name ILIKE '%round %'
         OR aem.event_name ILIKE '%conference%'
         OR aem.event_name ILIKE '%if necessary%'
         OR aem.event_name ~* 'game [0-9]' )
  ),
  -- Events at the 15 concert-specific venues added in mig 20260605120000.
  -- Joined via sg_events_canonical → tevo_event_id so we pick up events
  -- the SG matcher has already resolved. always_on=true in td_apply_targets
  -- ensures they're enqueued even when the event is months out.
  concert_venues AS (
    SELECT DISTINCT
      aem.aq_short_event_id,
      aem.sh_event_id,
      aem.vivid_event_id,
      aem.sg_event_id
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    JOIN public.events e                ON e.id = sgc.tevo_event_id
    WHERE e.venue_id IN (1290,520,1366,996,8000,4603,33,5118,103,33737,2407,2839,7425,38485,228)
      AND e.occurs_at_local IS NOT NULL
      AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  )
  SELECT y.aq_short_event_id, y.sh_event_id, y.vivid_event_id, y.sg_event_id FROM yankees y
  UNION
  SELECT k.aq_short_event_id, k.sh_event_id, k.vivid_event_id, k.sg_event_id FROM knicks k
  UNION
  SELECT cv.aq_short_event_id, cv.sh_event_id, cv.vivid_event_id, cv.sg_event_id FROM concert_venues cv;
$function$;

REVOKE ALL ON FUNCTION public.td_target_events() FROM PUBLIC;
COMMENT ON FUNCTION public.td_target_events() IS
  'Returns the canonical TD tracking target set: Yankees (next 20 home), '
  'Knicks (playoff/finals), + all future events at the 15 concert venues '
  'added 2026-06-05. td_watchlist_refresh() delegates to td_apply_targets() '
  'which reads this view each morning.';

-- ───────────────────────────────────────────────────────────────────────────
-- 2) Activate the concert venue xref rows immediately (no waiting for the
--    09:00 UTC cron). td_apply_targets() also preserves active Yankees/Knicks
--    rows and deactivates anything not in the expanded target set.
-- ───────────────────────────────────────────────────────────────────────────
SELECT public.td_apply_targets();

-- ───────────────────────────────────────────────────────────────────────────
-- 3) Seed td_pull_queue for immediate first pulls of the concert events.
--    td_pull_drain() fires every minute and will fire these within seconds.
-- ───────────────────────────────────────────────────────────────────────────
INSERT INTO public.td_pull_queue
  (event_id, platform, event_url, interval_tag, created_at)
SELECT x.event_id, x.platform, x.event_url, 'concert_venue_seed', now()
FROM public.ticketsdata_event_xref x
JOIN public.aq_event_map aem        ON aem.aq_short_event_id = x.aq_short_event_id
JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
JOIN public.events e                ON e.id = sgc.tevo_event_id
WHERE e.venue_id IN (1290,520,1366,996,8000,4603,33,5118,103,33737,2407,2839,7425,38485,228)
  AND x.active     = true
  AND x.event_url  IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.td_pull_queue q
    WHERE q.event_id   = x.event_id
      AND q.platform   = x.platform
      AND q.resolved_at IS NULL
  );

COMMIT;
