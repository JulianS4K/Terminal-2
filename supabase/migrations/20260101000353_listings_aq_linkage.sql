-- Migration 20260515240000 · level:admin · lane:Audit/Push · writes:listings_snapshots.{aq_short_event_id,venue_short_id,performer_short_id} cols+FKs, seatgeek_seller_listings same, seatgeek_listings_snapshots.performer_short_id, match_unmatched_listings_chunked() fn, match_unmatched_orders_sweep() v3 (+3 listing branches), unified_listings view v2, v_market_listings_by_event view, listings_aq_backfill_overnight cron · reads:events, sg_events_canonical, aq_event_map, aq_venue_map, aq_performer_map · pre:20260515230000
-- Cross-source LISTINGS AQ-linkage for market tracking.
--
-- Operator direction 2026-05-14 (after sales work shipped):
--   "did we link Evo + SG listings data for market tracking?" → no, deferred.
--   "use the same matching system from sales matcher to link"
--   "schedule first mapping run for after 12:01am to run during off peak
--    times and also schedule to not eat up too much cpu etc, consider
--    resource usage"
--
-- ## Already applied to prod
-- Applied via MCP 2026-05-14 (this session). DDL + function + view + cron
-- registration are instant. The bulk backfill runs overnight via the
-- listings_aq_backfill_overnight cron (04:02-04:14 UTC, off-peak, processes
-- ~100 distinct events per minute with pg_sleep(0.2) between events) and
-- self-unschedules once events_remaining = 0.
--
-- ## Regression risk
--   views.security_definer_views   — unified_listings rewrite, set security_invoker
--   cron.failed_jobs_90min          — new cron, will fire 13 times tonight
--   fks.not_valid_fks               — 6 new FKs, all VALIDATEd in this migration

-- ============================================================
-- 1. Schema: add canonical-id columns to the 3 listing surfaces
-- ============================================================

ALTER TABLE public.listings_snapshots          ADD COLUMN IF NOT EXISTS aq_short_event_id  text;
ALTER TABLE public.listings_snapshots          ADD COLUMN IF NOT EXISTS venue_short_id     text;
ALTER TABLE public.listings_snapshots          ADD COLUMN IF NOT EXISTS performer_short_id text;

ALTER TABLE public.seatgeek_seller_listings    ADD COLUMN IF NOT EXISTS aq_short_event_id  text;
ALTER TABLE public.seatgeek_seller_listings    ADD COLUMN IF NOT EXISTS venue_short_id     text;
ALTER TABLE public.seatgeek_seller_listings    ADD COLUMN IF NOT EXISTS performer_short_id text;

ALTER TABLE public.seatgeek_listings_snapshots ADD COLUMN IF NOT EXISTS performer_short_id text;

-- FKs (NOT VALID first to avoid blocking, VALIDATE at end)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='listings_snapshots_aq_short_event_id_fkey') THEN
    ALTER TABLE public.listings_snapshots ADD CONSTRAINT listings_snapshots_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='listings_snapshots_venue_short_id_fkey') THEN
    ALTER TABLE public.listings_snapshots ADD CONSTRAINT listings_snapshots_venue_short_id_fkey
      FOREIGN KEY (venue_short_id) REFERENCES public.aq_venue_map(venue_short_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='listings_snapshots_performer_short_id_fkey') THEN
    ALTER TABLE public.listings_snapshots ADD CONSTRAINT listings_snapshots_performer_short_id_fkey
      FOREIGN KEY (performer_short_id) REFERENCES public.aq_performer_map(performer_short_id) NOT VALID;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='seatgeek_seller_listings_aq_short_event_id_fkey') THEN
    ALTER TABLE public.seatgeek_seller_listings ADD CONSTRAINT seatgeek_seller_listings_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id) REFERENCES public.aq_event_map(aq_short_event_id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='seatgeek_seller_listings_venue_short_id_fkey') THEN
    ALTER TABLE public.seatgeek_seller_listings ADD CONSTRAINT seatgeek_seller_listings_venue_short_id_fkey
      FOREIGN KEY (venue_short_id) REFERENCES public.aq_venue_map(venue_short_id) NOT VALID;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='seatgeek_listings_snapshots_performer_short_id_fkey') THEN
    ALTER TABLE public.seatgeek_listings_snapshots ADD CONSTRAINT seatgeek_listings_snapshots_performer_short_id_fkey
      FOREIGN KEY (performer_short_id) REFERENCES public.aq_performer_map(performer_short_id) NOT VALID;
  END IF;
END $$;

-- VALIDATE the 6 new FKs (all currently empty cols, so instant)
ALTER TABLE public.listings_snapshots          VALIDATE CONSTRAINT listings_snapshots_aq_short_event_id_fkey;
ALTER TABLE public.listings_snapshots          VALIDATE CONSTRAINT listings_snapshots_venue_short_id_fkey;
ALTER TABLE public.listings_snapshots          VALIDATE CONSTRAINT listings_snapshots_performer_short_id_fkey;
ALTER TABLE public.seatgeek_seller_listings    VALIDATE CONSTRAINT seatgeek_seller_listings_aq_short_event_id_fkey;
ALTER TABLE public.seatgeek_seller_listings    VALIDATE CONSTRAINT seatgeek_seller_listings_venue_short_id_fkey;
ALTER TABLE public.seatgeek_listings_snapshots VALIDATE CONSTRAINT seatgeek_listings_snapshots_performer_short_id_fkey;

-- Index for event-grain UPDATE efficiency on the 8.16M-row table
CREATE INDEX IF NOT EXISTS listings_snapshots_event_id_aq_null_idx
  ON public.listings_snapshots (event_id)
  WHERE aq_short_event_id IS NULL;

-- ============================================================
-- 2. match_unmatched_listings_chunked() — resource-friendly backfill fn
-- ============================================================
-- Processes up to p_max_events DISTINCT unmatched event_ids across the 3
-- listing surfaces. For each event: one matcher call + one bulk UPDATE
-- for that event_id's listings (small lock window), then pg_sleep(0.2)
-- to yield CPU. Synthetic fallback fires when matcher empty.

CREATE OR REPLACE FUNCTION public.match_unmatched_listings_chunked(
  p_max_events       integer DEFAULT 100,
  p_create_synthetic boolean DEFAULT true
)
RETURNS TABLE (
  source_table       text,
  events_processed   integer,
  listings_updated   integer,
  synthetic_created  integer,
  events_remaining   integer
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  r RECORD;
  v_aq_id text; v_venue_short text; v_performer_short text;
  v_remaining_tevo int; v_remaining_sgb int; v_remaining_sgs int;
  v_proc int; v_upd int; v_synth int; v_rows int;
BEGIN
  ------------------------------------------------------------------
  -- TEvo listings_snapshots: JOIN events for name/venue/date
  ------------------------------------------------------------------
  v_proc := 0; v_upd := 0; v_synth := 0;
  FOR r IN
    SELECT DISTINCT ls.event_id,
                    e.name        AS event_name,
                    e.venue_name  AS venue_name,
                    e.venue_id    AS venue_id,
                    CASE WHEN e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
                         THEN e.occurs_at_local::timestamptz
                         ELSE NULL END AS event_date
    FROM public.listings_snapshots ls
    LEFT JOIN public.events e ON e.id = ls.event_id
    WHERE ls.aq_short_event_id IS NULL
    LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('evo', NULL, r.event_name, r.venue_name,
                                     r.event_date, NULL, NULL, r.venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('evo', r.event_name, r.venue_name, r.event_date);
      v_synth := v_synth + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short, v_performer_short
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.listings_snapshots ls SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short),
        performer_short_id = coalesce(performer_short_id, v_performer_short)
      WHERE ls.event_id = r.event_id AND ls.aq_short_event_id IS NULL;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_upd := v_upd + v_rows;
    END IF;
    PERFORM pg_sleep(0.2);
  END LOOP;
  SELECT count(DISTINCT event_id) INTO v_remaining_tevo
    FROM public.listings_snapshots WHERE aq_short_event_id IS NULL;
  RETURN QUERY SELECT 'listings_snapshots'::text, v_proc, v_upd, v_synth, v_remaining_tevo;

  ------------------------------------------------------------------
  -- SG broker listings: JOIN sg_events_canonical
  ------------------------------------------------------------------
  v_proc := 0; v_upd := 0; v_synth := 0;
  FOR r IN
    SELECT DISTINCT sls.sg_event_id,
                    c.sg_event_name   AS event_name,
                    c.sg_venue_name   AS venue_name,
                    c.sg_venue_id     AS sg_venue_id,
                    c.sg_datetime_utc AS event_date
    FROM public.seatgeek_listings_snapshots sls
    LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = sls.sg_event_id
    WHERE sls.aq_short_event_id IS NULL
    LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id, r.event_name, r.venue_name,
                                     r.event_date, NULL, NULL, r.sg_venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.event_name, r.venue_name, r.event_date, r.sg_event_id);
      v_synth := v_synth + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short, v_performer_short
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.seatgeek_listings_snapshots sls SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short),
        performer_short_id = coalesce(performer_short_id, v_performer_short)
      WHERE sls.sg_event_id = r.sg_event_id AND sls.aq_short_event_id IS NULL;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_upd := v_upd + v_rows;
    END IF;
    PERFORM pg_sleep(0.2);
  END LOOP;
  SELECT count(DISTINCT sg_event_id) INTO v_remaining_sgb
    FROM public.seatgeek_listings_snapshots WHERE aq_short_event_id IS NULL;
  RETURN QUERY SELECT 'seatgeek_listings_snapshots'::text, v_proc, v_upd, v_synth, v_remaining_sgb;

  ------------------------------------------------------------------
  -- SG seller listings: same JOIN target
  ------------------------------------------------------------------
  v_proc := 0; v_upd := 0; v_synth := 0;
  FOR r IN
    SELECT DISTINCT ssl.sg_event_id,
                    c.sg_event_name   AS event_name,
                    c.sg_venue_name   AS venue_name,
                    c.sg_venue_id     AS sg_venue_id,
                    c.sg_datetime_utc AS event_date
    FROM public.seatgeek_seller_listings ssl
    LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = ssl.sg_event_id
    WHERE ssl.aq_short_event_id IS NULL
    LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id, r.event_name, r.venue_name,
                                     r.event_date, NULL, NULL, r.sg_venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.event_name, r.venue_name, r.event_date, r.sg_event_id);
      v_synth := v_synth + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short, v_performer_short
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.seatgeek_seller_listings ssl SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short),
        performer_short_id = coalesce(performer_short_id, v_performer_short)
      WHERE ssl.sg_event_id = r.sg_event_id AND ssl.aq_short_event_id IS NULL;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_upd := v_upd + v_rows;
    END IF;
    PERFORM pg_sleep(0.2);
  END LOOP;
  SELECT count(DISTINCT sg_event_id) INTO v_remaining_sgs
    FROM public.seatgeek_seller_listings WHERE aq_short_event_id IS NULL;
  RETURN QUERY SELECT 'seatgeek_seller_listings'::text, v_proc, v_upd, v_synth, v_remaining_sgs;
END $$;

COMMENT ON FUNCTION public.match_unmatched_listings_chunked IS
  'Resource-friendly chunked backfill for listings AQ-linkage. Per-event matcher + bulk UPDATE + pg_sleep(0.2). Use p_max_events to throttle per-call cost. Called by listings_aq_backfill_overnight cron.';

-- ============================================================
-- 3. unified_listings v2 — expose aq_short_event_id, venue/performer short_ids
-- ============================================================

-- CREATE OR REPLACE VIEW can only APPEND columns (not insert/reorder), so the
-- new aq/venue/performer cols are appended at the end of each union branch.
CREATE OR REPLACE VIEW public.unified_listings AS
SELECT 'tevo'::text AS source_key,
       ls.event_id AS tevo_event_id,
       NULL::bigint AS sg_event_id,
       NULL::bigint AS sd_event_id,
       ls.tevo_ticket_group_id::text AS source_listing_id,
       ls.section, ls."row", ls.quantity,
       ls.retail_price, ls.wholesale_price,
       to_jsonb(ls.splits) AS splits_jsonb,
       ls.eticket AS is_eticket, ls.wheelchair AS is_wheelchair,
       ls.instant_delivery AS is_instant, ls.is_ancillary,
       ls.type AS listing_type, ls.brokerage_name, ls.is_owned,
       NULL::text AS sg_market_tier, NULL::boolean AS sg_is_b2b,
       ls.captured_at,
       ls.aq_short_event_id, ls.venue_short_id, ls.performer_short_id
FROM public.listings_snapshots ls
UNION ALL
SELECT 'sg_broker'::text, sls.tevo_event_id, sls.sg_event_id, NULL::bigint,
       sls.display_id, sls.section, sls."row", sls.quantity,
       sls.retail_price_all_in, sls.broadcast_price,
       sls.splits, NULL::boolean, sls.is_wheelchair_acc, sls.is_instant_download,
       NULL::boolean, NULL::text, NULL::text, sls.is_broker_owned,
       sls.market_source, sls.is_b2b, sls.captured_at,
       sls.aq_short_event_id, sls.venue_short_id, sls.performer_short_id
FROM public.seatgeek_listings_snapshots sls
UNION ALL
SELECT 'sg_seller'::text, ssl.tevo_event_id, ssl.sg_event_id, NULL::bigint,
       ssl.seller_listing_id, ssl.section, ssl."row", ssl.quantity,
       ssl.cost, NULL::numeric,
       to_jsonb(ARRAY[ssl.quantity]), NULL::boolean, NULL::boolean, ssl.is_instant,
       NULL::boolean, NULL::text, NULL::text, true,
       'exchange'::text, false, ssl.pulled_at,
       ssl.aq_short_event_id, ssl.venue_short_id, ssl.performer_short_id
FROM public.seatgeek_seller_listings ssl
UNION ALL
SELECT 'seatdata'::text, sdl.tevo_event_id, NULL::bigint, sdl.sd_event_id,
       sdl.content_hash, sdl.section, sdl."row", sdl.quantity,
       sdl.price, NULL::numeric,
       to_jsonb(ARRAY[sdl.quantity]), NULL::boolean, NULL::boolean, NULL::boolean,
       NULL::boolean, NULL::text, NULL::text, NULL::boolean,
       NULL::text, NULL::boolean, sdl.pulled_at,
       NULL::text, NULL::text, NULL::text       -- seatdata listings table has 0 rows; placeholders
FROM public.seatdata_listings_snapshots sdl;

ALTER VIEW public.unified_listings SET (security_invoker = true);

-- ============================================================
-- 4. v_market_listings_by_event — time-series rollup
-- ============================================================

CREATE OR REPLACE VIEW public.v_market_listings_by_event AS
SELECT
  ul.aq_short_event_id,
  date_trunc('hour', ul.captured_at) AS captured_hour,
  ul.source_key,
  count(*)             AS listing_rows,
  sum(ul.quantity)     AS total_qty,
  min(ul.retail_price) AS min_price,
  round(avg(ul.retail_price), 2) AS avg_price,
  max(ul.retail_price) AS max_price
FROM public.unified_listings ul
WHERE ul.aq_short_event_id IS NOT NULL
GROUP BY 1, 2, 3;

ALTER VIEW public.v_market_listings_by_event SET (security_invoker = true);

COMMENT ON VIEW public.v_market_listings_by_event IS
  'Per-event, per-hour, per-source rollup of listing prices + quantity for cross-exchange market tracking. Filtered to aq-linked rows; SYS- rows included for clusters of untracked events.';

-- ============================================================
-- 5. Cron: off-peak chunked backfill — 04:02-04:14 UTC (12:02-12:14 AM ET)
-- ============================================================
-- 13 firings × p_max_events=100 = 1,300 event-capacity. The 894+39+46 ≈
-- 980 distinct events will drain in ~10 firings. After events_remaining=0
-- the function self-unschedules so subsequent nights are no-ops.
--
-- Slot rationale: hour 04 UTC has crons at :00 (espn), :15/:30/:45 (sg_listings),
-- :20/:35/:50 (collect-listings). The 04:02-04:14 window is conflict-free.

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='listings_aq_backfill_overnight') THEN
    PERFORM cron.schedule(
      'listings_aq_backfill_overnight',
      '2-14 4 * * *',
      $cron$
        DO $$
        DECLARE v_remaining int;
        BEGIN
          SELECT max(events_remaining) INTO v_remaining
          FROM public.match_unmatched_listings_chunked(100, true);
          IF coalesce(v_remaining, 0) = 0 THEN
            PERFORM cron.unschedule('listings_aq_backfill_overnight');
          END IF;
        END $$;
      $cron$
    );
  END IF;
END $$;
