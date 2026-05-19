-- Migration 20260520220000 · level:standard · lane:broadway (D3) · pre:20260520210000
--
-- Broadway listings pipeline — schema only (no cron schedules, no DML
-- mutations to existing tables). Schedules + edge function deploy ship
-- in follow-up PRs after operator approval (cron.* mutations).
--
-- Mirrors the canonical evo pattern from 20260424000000_listings_v2.sql:
--   raw snapshots (30d retention)  →  event_metrics (indefinite)
--                                  →  section_metrics (indefinite)
--
-- Design: docs/broadway-scale-plan.md
-- Lane: D3 (broadway-scraper-eChQ6) per LANE_DISCIPLINE.md:214-231
--
-- RULE 2 reminder: broadway_client.py is read-only against *.broadway.com.
-- These tables are written by the future broadway_collect edge function
-- and the BroadwayClient when db=<supabase client> is passed.

-- ============================================================================
-- (1) broadway_shows — stable show-level metadata (one row per show)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_shows (
  broadway_show_id     bigint      PRIMARY KEY,  -- show.aristotle_id
  internal_id          bigint,                   -- show.id (CMS id)
  slug                 text        NOT NULL UNIQUE,
  title                text        NOT NULL,
  bwy_title            text,                     -- "SIX: The Musical"
  venue_name           text,
  venue_slug           text,
  venue_address_1      text,
  venue_city           text,
  venue_state          text,
  venue_zip            text,
  venue_lat            numeric(10,7),
  venue_lon            numeric(10,7),
  opening_date         date,
  closing_date         date,
  preview_date         date,
  closing_soon         boolean,
  on_sale              boolean,
  has_seatmap          boolean,
  has_discount_events  boolean,
  max_discount_amount  numeric(12,2),
  pricing_from         numeric(12,2),   -- show.pricing (advertised "from" price)
  high_price           numeric(12,2),
  announcement         text,
  categories           text[],
  first_seen_at        timestamptz NOT NULL DEFAULT now(),
  last_seen_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_broadway_shows_slug ON public.broadway_shows (slug);
CREATE INDEX IF NOT EXISTS idx_broadway_shows_closing_date ON public.broadway_shows (closing_date) WHERE closing_date IS NOT NULL;

COMMENT ON TABLE public.broadway_shows IS
  'Show-level metadata from checkout.broadway.com payload.show. Upserted '
  'on every successful fetch; first_seen_at frozen, last_seen_at refreshed.';

-- ============================================================================
-- (2) broadway_event_xref — link broadway_event_id to canonical tevo_event_id
--     when classification surfaces a match. Many broadway events will have
--     tevo_event_id IS NULL until the canonical mapping pipeline catches them.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_event_xref (
  broadway_event_id  bigint      PRIMARY KEY,  -- payload.event_id (per performance)
  broadway_show_id   bigint      NOT NULL REFERENCES public.broadway_shows (broadway_show_id),
  broadway_slug      text        NOT NULL,
  performance_time   timestamptz,   -- local-tz parsed from payload.performance_time
  tevo_event_id      bigint,        -- canonical link, when known
  matched_at         timestamptz,   -- when the link was established
  match_confidence   numeric(3,2),  -- 0.00..1.00
  match_method       text,          -- 'manual'|'venue+date'|'slug+date'|...
  first_seen_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_broadway_event_xref_show ON public.broadway_event_xref (broadway_show_id);
CREATE INDEX IF NOT EXISTS idx_broadway_event_xref_perf ON public.broadway_event_xref (performance_time);
CREATE INDEX IF NOT EXISTS idx_broadway_event_xref_tevo ON public.broadway_event_xref (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

COMMENT ON TABLE public.broadway_event_xref IS
  'Per-performance xref. broadway_event_id = payload.event_id (unique per '
  'curtain). tevo_event_id is NULL until canonical matching attaches it.';

-- ============================================================================
-- (3) broadway_listings_snapshots — raw sections, 30-day retention
--     Parallels listings_snapshots (evo) and seatgeek_listings_snapshots (SG).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_listings_snapshots (
  broadway_event_id  bigint      NOT NULL,
  captured_at_utc    timestamptz NOT NULL,
  price_index        bigint      NOT NULL,   -- SectionListing.price_index (broadway's tier id)
  section_name       text        NOT NULL,   -- "Orchestra", "Mezzanine"
  ticket_type        text,                    -- "Standard" | "Premium"
  face_price         numeric(12,2) NOT NULL,
  fee                numeric(12,2) NOT NULL DEFAULT 0,
  splits             integer[],               -- SectionListing.quantities
  area_indexes       integer[],
  broadway_show_id   bigint,                  -- denormalized for fast joins
  PRIMARY KEY (broadway_event_id, captured_at_utc, price_index)
);

CREATE INDEX IF NOT EXISTS idx_bwy_listings_captured ON public.broadway_listings_snapshots (captured_at_utc);
CREATE INDEX IF NOT EXISTS idx_bwy_listings_event_time ON public.broadway_listings_snapshots (broadway_event_id, captured_at_utc DESC);
CREATE INDEX IF NOT EXISTS idx_bwy_listings_show ON public.broadway_listings_snapshots (broadway_show_id) WHERE broadway_show_id IS NOT NULL;

COMMENT ON TABLE public.broadway_listings_snapshots IS
  'Raw per-section pricing snapshots from checkout.broadway.com. '
  '30-day retention via sweep_old_broadway_listings(). Computed metrics '
  'land in broadway_event_metrics + broadway_section_metrics (indefinite '
  'retention).';

-- ============================================================================
-- (4) broadway_event_metrics — per-event aggregated, indefinite retention
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_event_metrics (
  broadway_event_id   bigint      NOT NULL,
  captured_at_utc     timestamptz NOT NULL,

  -- Inventory shape
  sections_count      integer,
  tier_count          integer,                 -- distinct ticket_type values
  total_splits_size   integer,                 -- sum(array_length(splits, 1))

  -- Face-price distribution (excludes fee)
  face_min            numeric(12,2),
  face_p25            numeric(12,2),
  face_median         numeric(12,2),
  face_mean           numeric(12,2),
  face_p75            numeric(12,2),
  face_p90            numeric(12,2),
  face_max            numeric(12,2),

  -- All-in (face + fee) distribution
  all_in_min          numeric(12,2),
  all_in_median       numeric(12,2),
  all_in_max          numeric(12,2),

  -- Premium-tier delta — useful signal for hot vs. cold shows
  premium_min         numeric(12,2),
  premium_max         numeric(12,2),
  standard_min        numeric(12,2),
  standard_max        numeric(12,2),

  -- Show-page advertised band (from payload.show.pricing / high_price)
  show_pricing_from   numeric(12,2),
  show_high_price     numeric(12,2),
  has_discount_events boolean,

  PRIMARY KEY (broadway_event_id, captured_at_utc)
);

CREATE INDEX IF NOT EXISTS idx_bwy_event_metrics_time ON public.broadway_event_metrics (broadway_event_id, captured_at_utc DESC);

COMMENT ON TABLE public.broadway_event_metrics IS
  'Per-performance metrics aggregated from broadway_listings_snapshots at '
  'collect time. Retained indefinitely (raw listings expire at 30d).';

-- ============================================================================
-- (5) broadway_section_metrics — per-(event, section), indefinite retention
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_section_metrics (
  broadway_event_id  bigint      NOT NULL,
  captured_at_utc    timestamptz NOT NULL,
  section_name       text        NOT NULL,
  tier_count         integer,                  -- # of price tiers in this section
  face_min           numeric(12,2),
  face_median        numeric(12,2),
  face_max           numeric(12,2),
  all_in_min         numeric(12,2),
  all_in_max         numeric(12,2),
  available_quantities int[],                  -- union of splits across tiers
  PRIMARY KEY (broadway_event_id, captured_at_utc, section_name)
);

CREATE INDEX IF NOT EXISTS idx_bwy_section_metrics_time ON public.broadway_section_metrics (broadway_event_id, captured_at_utc DESC);

-- ============================================================================
-- (6) broadway_pull_log — per-fetch diagnostic ledger, 30-day retention
--     Already referenced at broadway_client.py:288. Schema must match what
--     the client INSERTs:
--       endpoint, slug, show_id, event_id, http_status, rows_returned,
--       error_message, request_meta
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_pull_log (
  id                bigserial   PRIMARY KEY,
  endpoint          text        NOT NULL,        -- 'sections' | 'show_page'
  slug              text,
  show_id           bigint,
  event_id          bigint,
  http_status       integer,
  rows_returned     integer,
  error_message     text,
  request_meta      jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_bwy_pull_log_event ON public.broadway_pull_log (event_id, created_at DESC) WHERE event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_bwy_pull_log_status ON public.broadway_pull_log (http_status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bwy_pull_log_created ON public.broadway_pull_log (created_at);

COMMENT ON TABLE public.broadway_pull_log IS
  'Per-fetch ledger written by BroadwayClient._log_pull. Used for dedup '
  '(in pop_broadway_pulls), drift detection (200-no-payload errors), and '
  '429/503 rate-limit forensics. 30-day retention.';

-- ============================================================================
-- (7) broadway_pull_queue — work queue for the cron buckets
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_pull_queue (
  broadway_event_id  bigint      PRIMARY KEY,
  broadway_show_id   bigint      NOT NULL,
  broadway_slug      text        NOT NULL,
  performance_time   timestamptz NOT NULL,
  added_at           timestamptz NOT NULL DEFAULT now(),
  removed_at         timestamptz                -- set when performance is past
);

CREATE INDEX IF NOT EXISTS idx_bwy_queue_perf_time ON public.broadway_pull_queue (performance_time) WHERE removed_at IS NULL;

COMMENT ON TABLE public.broadway_pull_queue IS
  'Work queue for broadway_collect crons. Populated by discover_performances '
  'on its own daily sweep. Cron buckets (0-72h, 72h+) filter from here.';

-- ============================================================================
-- (8) sweep_old_broadway_listings() — 30d retention
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sweep_old_broadway_listings()
RETURNS TABLE (table_name text, deleted_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_listings_deleted integer;
  v_pull_log_deleted integer;
BEGIN
  DELETE FROM public.broadway_listings_snapshots
   WHERE captured_at_utc < now() - interval '30 days';
  GET DIAGNOSTICS v_listings_deleted = ROW_COUNT;

  DELETE FROM public.broadway_pull_log
   WHERE created_at < now() - interval '30 days';
  GET DIAGNOSTICS v_pull_log_deleted = ROW_COUNT;

  RETURN QUERY
    SELECT 'broadway_listings_snapshots'::text, v_listings_deleted
    UNION ALL
    SELECT 'broadway_pull_log'::text, v_pull_log_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.sweep_old_broadway_listings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sweep_old_broadway_listings() TO service_role;

COMMENT ON FUNCTION public.sweep_old_broadway_listings() IS
  'Daily retention sweep. Deletes broadway_listings_snapshots + '
  'broadway_pull_log rows older than 30 days. Returns deleted-row counts.';

-- ============================================================================
-- (9) pop_broadway_pulls(bucket, limit) — cadence-aware work selector
--     Matches the evo cron dedup pattern: pick events in the bucket whose
--     last successful sections fetch is older than the bucket's window.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pop_broadway_pulls(
  p_bucket text,
  p_limit  integer DEFAULT 50
) RETURNS TABLE (
  broadway_event_id bigint,
  broadway_slug     text,
  broadway_show_id  bigint,
  performance_time  timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_min_hours    int;
  v_max_hours    int;
  v_dedup_window interval;
BEGIN
  CASE p_bucket
    WHEN '0-72h' THEN
      v_min_hours := 0;
      v_max_hours := 72;
      v_dedup_window := interval '50 minutes';
    WHEN '72h+' THEN
      v_min_hours := 72;
      v_max_hours := 999999;
      v_dedup_window := interval '20 hours';
    ELSE
      RAISE EXCEPTION 'pop_broadway_pulls: unknown bucket %, expected 0-72h or 72h+', p_bucket;
  END CASE;

  RETURN QUERY
  SELECT q.broadway_event_id, q.broadway_slug, q.broadway_show_id, q.performance_time
  FROM public.broadway_pull_queue q
  WHERE q.removed_at IS NULL
    AND q.performance_time > now()
    AND EXTRACT(epoch FROM (q.performance_time - now())) / 3600
        BETWEEN v_min_hours AND v_max_hours
    AND NOT EXISTS (
      SELECT 1 FROM public.broadway_pull_log l
      WHERE l.event_id     = q.broadway_event_id
        AND l.endpoint     = 'sections'
        AND l.http_status  = 200
        AND l.created_at   > now() - v_dedup_window
    )
  ORDER BY q.performance_time
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.pop_broadway_pulls(text, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pop_broadway_pulls(text, integer) TO service_role;

COMMENT ON FUNCTION public.pop_broadway_pulls(text, integer) IS
  'Cadence-aware work selector. Bucket 0-72h dedup window = 50min '
  '(hourly cron); bucket 72h+ dedup window = 20h (daily cron). Filters '
  'past events. Returns up to p_limit rows ordered by performance_time.';

-- ============================================================================
-- (10) v_broadway_missed_snapshots — drift detection for P2 #9
-- ============================================================================

CREATE OR REPLACE VIEW public.v_broadway_missed_snapshots
WITH (security_invoker = true)
AS
WITH expected AS (
  SELECT
    q.broadway_event_id,
    q.broadway_slug,
    q.broadway_show_id,
    q.performance_time,
    EXTRACT(epoch FROM (q.performance_time - now())) / 3600 AS hours_to_event,
    CASE
      WHEN EXTRACT(epoch FROM (q.performance_time - now())) / 3600 < 72 THEN 'hourly'
      ELSE 'daily'
    END AS expected_cadence,
    CASE
      WHEN EXTRACT(epoch FROM (q.performance_time - now())) / 3600 < 72 THEN interval '90 minutes'
      ELSE interval '30 hours'
    END AS max_gap
  FROM public.broadway_pull_queue q
  WHERE q.removed_at IS NULL
    AND q.performance_time > now()
),
latest AS (
  SELECT broadway_event_id, max(captured_at_utc) AS last_snapshot_at
  FROM public.broadway_listings_snapshots
  GROUP BY broadway_event_id
)
SELECT
  e.broadway_event_id,
  e.broadway_slug,
  e.broadway_show_id,
  e.performance_time,
  e.hours_to_event,
  e.expected_cadence,
  l.last_snapshot_at,
  now() - l.last_snapshot_at AS gap,
  e.max_gap AS gap_threshold,
  CASE
    WHEN l.last_snapshot_at IS NULL THEN 'never_snapshotted'
    ELSE 'gap_exceeded'
  END AS miss_reason
FROM expected e
LEFT JOIN latest l USING (broadway_event_id)
WHERE l.last_snapshot_at IS NULL
   OR now() - l.last_snapshot_at > e.max_gap;

COMMENT ON VIEW public.v_broadway_missed_snapshots IS
  'Performances whose latest snapshot is older than the expected-cadence '
  'gap (90min for 0-72h bucket, 30h for 72h+ bucket) OR which have never '
  'been snapshotted. Backfill is not possible (broadway.com does not '
  'expose historical pricing) — this view is for drift detection and '
  'alerting only. P2 #9 from docs/broadway-scale-plan.md.';

-- ============================================================================
-- (11) RLS — anon revokes, service_role writes
--     Matches the pattern from 20260510210050_phase15_security_hardening.
-- ============================================================================

ALTER TABLE public.broadway_shows                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadway_event_xref           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadway_listings_snapshots   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadway_event_metrics        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadway_section_metrics      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadway_pull_log             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadway_pull_queue           ENABLE ROW LEVEL SECURITY;

-- Read for authenticated; write for service_role only.
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT unnest(ARRAY[
      'broadway_shows','broadway_event_xref','broadway_listings_snapshots',
      'broadway_event_metrics','broadway_section_metrics','broadway_pull_log',
      'broadway_pull_queue'
    ])
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I; '
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true);',
      t || '_read', t, t || '_read', t
    );
  END LOOP;
END $$;

-- ============================================================================
-- DONE. Follow-up PRs:
--   - edge function broadway_collect (writes through SectionsSnapshot
--     into broadway_listings_snapshots + computes metrics)
--   - cron schedules (broadway-collect-0-72h, broadway-collect-72h+,
--     broadway-retention-sweep-daily) — requires operator approval
--   - v_broadway_missed_snapshots dashboard wiring (D2 sub-PR)
-- ============================================================================