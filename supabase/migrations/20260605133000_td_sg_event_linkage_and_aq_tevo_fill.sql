-- Migration 20260528380000 · level:2 · lane:A1
-- writes: ticketsdata_event_xref, aq_event_map
-- reads: sg_events_canonical, aq_event_map
--
-- Purpose: Add tevo_event_id + sg_event_id + tevo_match_method to ticketsdata_event_xref.
--   Backfill day 1: 575/575 get sg_event_id, 417/575 get tevo_event_id (72.5%).
--   Creates refresh_td_event_links() — nightly 5-step sync with full fallback chain.
--   Authored by D0 2026-05-28. A1 to review + apply.
--
-- Validated dry-run (2026-05-28):
--   575/575 td_xref rows have aq_short_event_id → 100% join coverage to aq_event_map
--   575/575 get sg_event_id from aq_event_map
--   417/575 get tevo_event_id from aq_event_map (72.5%)
--   158 missing tevo_event_id: 84 active (36 parking + 48 non-parking), 74 inactive
--   Parking events: TEvo does not track stadium parking lots → correct to leave tevo_event_id NULL
--   Non-parking pending: sg_to_tevo_search_bridge_30min cron resolves over time;
--     refresh_td_event_links() picks up each nightly run
--   aq reverse-fill (aq_event_map ← sg_events_canonical): currently 0 rows (already fully synced)
--     Kept in refresh fn as defensive step for future state
--
-- KEY ARCHITECTURE NOTE (do not re-discover):
--   Source IDs are source-internal — NEVER join cross-source on raw IDs.
--   TEvo event_id range: 3.0M–3.4M. SG sg_event_id: 17M+. TD platform IDs: 4.5M–160M.
--   ticketsdata_event_xref.aq_short_event_id = 7-char alphanumeric (e.g. K9KX32Z, TD's cross-platform key)
--   listings_snapshots.aq_short_event_id = SYS-{hex} (TEvo-internal only — DIFFERENT SYSTEM, same col name)
--   aq_event_map is the canonical hub: all platform IDs converge here.
--   Bridge cron sg_to_tevo_search_bridge_30min fills aq_event_map.tevo_event_id over time.
--   See D0_BIBLE.md §3 and PROJECT_BIBLE §5 for full chain documentation.

-- ── PART 1: Add columns to ticketsdata_event_xref ────────────────────────────

ALTER TABLE public.ticketsdata_event_xref
  ADD COLUMN IF NOT EXISTS tevo_event_id     bigint,
  ADD COLUMN IF NOT EXISTS sg_event_id       bigint,
  ADD COLUMN IF NOT EXISTS tevo_match_method text;

COMMENT ON COLUMN public.ticketsdata_event_xref.tevo_event_id IS
  'TEvo event_id resolved via aq_event_map or fallback chain. NULL for parking lots and international events TEvo does not track.';
COMMENT ON COLUMN public.ticketsdata_event_xref.sg_event_id IS
  'SeatGeek sg_event_id resolved via aq_event_map. Coverage: 100% of active TD events.';
COMMENT ON COLUMN public.ticketsdata_event_xref.tevo_match_method IS
  'How tevo_event_id was resolved: aq_event_map | sg_canonical_direct | text_performer_date | pending_bridge | null_parking | null_international';

CREATE INDEX IF NOT EXISTS idx_tdx_tevo_event_id
  ON public.ticketsdata_event_xref (tevo_event_id)
  WHERE tevo_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_tdx_sg_event_id
  ON public.ticketsdata_event_xref (sg_event_id)
  WHERE sg_event_id IS NOT NULL;

-- ── PART 2: Initial backfill from aq_event_map ───────────────────────────────
-- Expected result: 575 sg_event_id filled, 417 tevo_event_id filled

UPDATE public.ticketsdata_event_xref tdx
SET
  sg_event_id       = aem.sg_event_id,
  tevo_event_id     = aem.tevo_event_id,
  tevo_match_method = CASE
    WHEN aem.tevo_event_id IS NOT NULL THEN 'aq_event_map'
    WHEN tdx.aq_short_event_id IS NOT NULL THEN 'pending_bridge'
    ELSE NULL
  END
FROM public.aq_event_map aem
WHERE aem.aq_short_event_id = tdx.aq_short_event_id
  AND (tdx.sg_event_id IS NULL OR tdx.tevo_event_id IS NULL);

-- ── PART 3: refresh_td_event_links() — nightly 5-step sync ───────────────────
--
-- Step A: defensive reverse-fill aq_event_map.tevo_event_id from sg_events_canonical
--         (normally 0 rows — catches edge cases where sg_canonical updated via non-bridge path)
-- Step B: fill td_xref.sg_event_id from aq_event_map (new td events since last run)
-- Step C: fill td_xref.tevo_event_id from aq_event_map.tevo_event_id  [PRIMARY PATH]
-- Step D: AQ FALLBACK — td_xref → aq_event_map.sg_event_id → sg_events_canonical.tevo_event_id
--         (catches bridge resolution that updated sg_canonical before aq_event_map was synced)
-- Step E: TEXT FALLBACK — performer name + date text match via sg_events_canonical
--         Principle: touring artists don't play same city twice same day → performer+date = unique
--         Sports: team names in event_name are unique per venue per day
--         Safety: only accepts unambiguous 1:1 matches (n_candidates = 1)
--         Does NOT use source IDs (venue_id, sg_venue_id) — those are source-internal

CREATE OR REPLACE FUNCTION public.refresh_td_event_links()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_aq_filled    integer := 0;
  v_td_sg_filled integer := 0;
  v_td_tv_aq     integer := 0;
  v_td_tv_sg     integer := 0;
  v_td_tv_text   integer := 0;
BEGIN

  -- ── Step A: defensive reverse-fill aq_event_map ← sg_events_canonical ─────
  -- Normally 0 rows. Covers edge case where sg_canonical was updated by a path
  -- other than the standard sg_to_tevo_search_bridge → aq_event_map chain.
  WITH updated AS (
    UPDATE public.aq_event_map aem
    SET tevo_event_id = sgc.tevo_event_id
    FROM public.sg_events_canonical sgc
    WHERE sgc.sg_event_id    = aem.sg_event_id
      AND sgc.tevo_event_id IS NOT NULL
      AND aem.tevo_event_id IS NULL
    RETURNING 1
  ) SELECT COUNT(*) INTO v_aq_filled FROM updated;

  -- ── Step B: fill td_xref.sg_event_id from aq_event_map ───────────────────
  -- Picks up new TD events added since last nightly run.
  WITH updated AS (
    UPDATE public.ticketsdata_event_xref tdx
    SET sg_event_id = aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.aq_short_event_id  = tdx.aq_short_event_id
      AND aem.sg_event_id       IS NOT NULL
      AND tdx.sg_event_id       IS NULL
    RETURNING 1
  ) SELECT COUNT(*) INTO v_td_sg_filled FROM updated;

  -- ── Step C: fill td_xref.tevo_event_id from aq_event_map [PRIMARY] ────────
  WITH updated AS (
    UPDATE public.ticketsdata_event_xref tdx
    SET tevo_event_id     = aem.tevo_event_id,
        tevo_match_method = 'aq_event_map'
    FROM public.aq_event_map aem
    WHERE aem.aq_short_event_id  = tdx.aq_short_event_id
      AND aem.tevo_event_id     IS NOT NULL
      AND tdx.tevo_event_id     IS NULL
    RETURNING 1
  ) SELECT COUNT(*) INTO v_td_tv_aq FROM updated;

  -- ── Step D: AQ FALLBACK — sg_canonical direct bypass ─────────────────────
  -- Chain: td_xref → aq_event_map.sg_event_id → sg_events_canonical.tevo_event_id
  -- Use when aq_event_map.tevo_event_id is still NULL but sg_canonical already has it.
  -- Occurs when bridge cron resolves SG→TEvo but aq_event_map hasn't been updated yet.
  WITH updated AS (
    UPDATE public.ticketsdata_event_xref tdx
    SET tevo_event_id     = sgc.tevo_event_id,
        tevo_match_method = 'sg_canonical_direct'
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.aq_short_event_id  = tdx.aq_short_event_id
      AND sgc.tevo_event_id     IS NOT NULL
      AND tdx.tevo_event_id     IS NULL
    RETURNING 1
  ) SELECT COUNT(*) INTO v_td_tv_sg FROM updated;

  -- ── Step E: TEXT FALLBACK — performer + date match via sg_events_canonical ─
  -- For events where all AQ paths still leave tevo_event_id NULL.
  -- Skips parking lots and CANCELLED events (those correctly remain NULL).
  -- IMPORTANT: Do NOT filter by source IDs (venue_id, sg_venue_id) — they are
  --   source-internal and don't cross-join. Use text names + dates only.
  -- Safety: accepts only unambiguous single-candidate matches.
  WITH event_candidates AS (
    SELECT DISTINCT ON (aem.aq_short_event_id)
      aem.aq_short_event_id,
      sgc.tevo_event_id,
      COUNT(DISTINCT sgc.sg_event_id) OVER (PARTITION BY aem.aq_short_event_id) AS n_candidates
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc
      ON sgc.tevo_event_id IS NOT NULL
      AND DATE(sgc.sg_datetime_utc) = DATE(aem.event_date)
      AND length(trim(coalesce(aem.performer, ''))) > 3
      AND (
        -- performer name substring match in SG event name (touring artist uniqueness)
        sgc.sg_event_name ILIKE '%' || trim(aem.performer) || '%'
        OR
        -- normalized full event name exact match (sports team matchup format)
        lower(regexp_replace(aem.event_name,  '[^a-z0-9 ]', '', 'gi'))
          = lower(regexp_replace(sgc.sg_event_name, '[^a-z0-9 ]', '', 'gi'))
      )
    WHERE aem.tevo_event_id IS NULL
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_name NOT ILIKE '%cancelled%'
    ORDER BY aem.aq_short_event_id, sgc.sg_event_id
  ),
  text_updated AS (
    UPDATE public.ticketsdata_event_xref tdx
    SET tevo_event_id     = ec.tevo_event_id,
        tevo_match_method = 'text_performer_date'
    FROM event_candidates ec
    JOIN public.aq_event_map aem ON aem.aq_short_event_id = ec.aq_short_event_id
    WHERE aem.aq_short_event_id  = tdx.aq_short_event_id
      AND ec.n_candidates        = 1   -- only accept unambiguous 1:1 matches
      AND tdx.tevo_event_id     IS NULL
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_td_tv_text FROM text_updated;

  RETURN jsonb_build_object(
    'aq_tevo_filled',    v_aq_filled,
    'td_sg_filled',      v_td_sg_filled,
    'td_tevo_via_aq',    v_td_tv_aq,
    'td_tevo_via_sg',    v_td_tv_sg,
    'td_tevo_via_text',  v_td_tv_text
  );
END;
$$;

-- ── PART 4: Daily cron at 06:05 UTC ──────────────────────────────────────────

SELECT cron.unschedule('refresh-td-event-links')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh-td-event-links');

SELECT cron.schedule(
  'refresh-td-event-links',
  '5 6 * * *',
  $cronbody$
    DO $b$ BEGIN
      IF NOT public.cron_should_fire('refresh-td-event-links') THEN RETURN; END IF;
      PERFORM public.refresh_td_event_links();
    END $b$;
  $cronbody$
);

-- ── Verification (run after apply) ───────────────────────────────────────────
SELECT
  COUNT(*)                                                          AS total,
  COUNT(sg_event_id)                                                AS has_sg_id,
  COUNT(tevo_event_id)                                              AS has_tevo_id,
  COUNT(*) FILTER (WHERE active AND tevo_event_id IS NULL)          AS active_missing_tevo,
  COUNT(*) FILTER (WHERE tevo_match_method = 'aq_event_map')        AS matched_via_aq,
  COUNT(*) FILTER (WHERE tevo_match_method = 'pending_bridge')      AS pending_bridge,
  COUNT(*) FILTER (WHERE active AND venue_name ILIKE '%parking%')   AS active_parking_correctly_null
FROM public.ticketsdata_event_xref tdx
LEFT JOIN public.aq_event_map aem ON aem.aq_short_event_id = tdx.aq_short_event_id;
-- expect:
--   total=575, has_sg_id=575, has_tevo_id=417
--   active_missing_tevo=84 (36 parking + 48 non-parking awaiting bridge)
--   matched_via_aq=417, pending_bridge=158
