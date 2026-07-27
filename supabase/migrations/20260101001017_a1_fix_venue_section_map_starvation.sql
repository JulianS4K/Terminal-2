-- Migration 20260620160000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — fix seat-map crosswalk build starvation)
-- Touches W: CREATE TABLE public.venue_section_map_build_state;
--            CREATE OR REPLACE FUNCTION public.build_venue_section_map_batch(int,interval)
-- Touches R: public.seatmap_manifest, public.events, public.venue_section_map
-- Pre-reqs: build_venue_section_map(bigint,text,interval), venue_section_map
-- Already applied to prod · via MCP 2026-06-20 (final fn = v5: round-robin + 3d window + 45s tick budget)
-- Backfill kicked manually 2026-06-20: venue_section_map evo coverage 15 -> 180 venues
-- (~79k crosswalk rows); the */10 venue_section_map_refresh cron drains the remainder.
--
-- ============================================================
-- FIX: seat-map section crosswalk starves — 222 venues have live listings + a
-- seatmap_manifest but only 15 are in venue_section_map (frozen since 2026-06-09).
--
-- ROOT CAUSE: build_venue_section_map_batch picks the "stalest" (venue,platform)
-- combos via  LEFT JOIN (max updated_at FROM venue_section_map) ... ORDER BY lb
-- ASC NULLS FIRST.  A combo only gets a venue_section_map row (hence an updated_at)
-- when it has listings in the window. The candidate set CROSS JOINs 5 platforms, so
-- every venue's tp/vd/sh combos (and evo/sg for listing-less venues) produce ZERO
-- rows and keep updated_at = NULL *forever*. Those NULL combos sit permanently at the
-- front of the NULLS-FIRST queue (ordered by venue_id), so each 25/tick batch re-picks
-- the same lowest-venue_id dead combos and never reaches the venues that DO have data.
--
-- FIX: track every ATTEMPT (not just row-producing builds) in a tiny state table and
-- order candidates by last_attempt_at. This guarantees forward progress — a zero-row
-- combo is stamped and rotates to the back, so productive evo/sg combos are reached and
-- refreshed in round-robin. No change to build_venue_section_map itself.
--
-- Also drop the per-tick build window from 7d -> 3d (default below). Now that the
-- round-robin actually reaches busy venues (it never did before), a 7-day scan of the
-- listings_snapshots firehose per venue could push a batch(25) tick over its 120s cron
-- slot. 3 days of listings still captures the live section set (section names are
-- stable), so the crosswalk is unchanged while each tick stays well inside budget.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.venue_section_map_build_state (
  tevo_venue_id   bigint  NOT NULL,
  platform        text    NOT NULL,
  last_attempt_at timestamptz,
  last_rows       integer,
  PRIMARY KEY (tevo_venue_id, platform)
);

COMMENT ON TABLE public.venue_section_map_build_state IS
  'Per-(venue,platform) attempt bookkeeping for the seat-map crosswalk builder. '
  'Ordering by last_attempt_at guarantees round-robin progress even for zero-row '
  'combos (no listings) that never write a venue_section_map row. A1 · mig 20260620160000.';

-- service-role-only (written by the SECDEF builder, which bypasses RLS); deny anon/auth.
ALTER TABLE public.venue_section_map_build_state ENABLE ROW LEVEL SECURITY;

-- Seed existing crosswalk rows so already-built venues aren't treated as never-attempted.
INSERT INTO public.venue_section_map_build_state (tevo_venue_id, platform, last_attempt_at, last_rows)
SELECT tevo_venue_id, platform, max(updated_at), count(*)
FROM public.venue_section_map
GROUP BY tevo_venue_id, platform
ON CONFLICT (tevo_venue_id, platform) DO NOTHING;

CREATE OR REPLACE FUNCTION public.build_venue_section_map_batch(p_batch integer DEFAULT 25, p_window interval DEFAULT '3 days'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r record; v_n integer := 0; v_rows integer; v_start timestamptz := clock_timestamp();
BEGIN
  FOR r IN
    WITH cand AS (
      SELECT v.venue_id, p.platform
      FROM (SELECT DISTINCT sm.venue_id FROM public.seatmap_manifest sm
            WHERE sm.has_map AND EXISTS(SELECT 1 FROM public.events e WHERE e.venue_id=sm.venue_id)) v
      CROSS JOIN (VALUES ('evo'),('sg'),('tp'),('vd'),('sh')) p(platform)
    )
    SELECT c.venue_id, c.platform
    FROM cand c
    LEFT JOIN public.venue_section_map_build_state st
      ON st.tevo_venue_id = c.venue_id AND st.platform = c.platform
    ORDER BY st.last_attempt_at ASC NULLS FIRST, c.venue_id
    LIMIT p_batch
  LOOP
    -- Wall-clock budget: a busy venue's firehose scan can run tens of seconds, so a
    -- full batch(25) tick could otherwise approach the 120s cron slot budget (a >2-min
    -- job holds a connection — forbidden by the cron concurrency rules). Stop early once
    -- ~45s elapsed; the round-robin (last_attempt_at order) resumes from here next tick,
    -- so coverage still drains, just bounded per tick.
    EXIT WHEN clock_timestamp() - v_start > interval '45 seconds';
    -- Each iteration is wrapped so a single venue's failure (e.g. transient) is
    -- caught and the combo is still STAMPED (last_rows NULL) — it rotates to the
    -- back of the round-robin instead of blocking its batch-mates, guaranteeing
    -- forward progress.
    BEGIN
      v_rows := public.build_venue_section_map(r.venue_id, r.platform, p_window);
      v_n := v_n + 1;
    EXCEPTION WHEN OTHERS THEN
      v_rows := NULL;
      RAISE WARNING 'build_venue_section_map_batch: skipped venue % platform %: %', r.venue_id, r.platform, SQLERRM;
    END;
    -- stamp the attempt regardless of rows produced -> guarantees round-robin progress
    INSERT INTO public.venue_section_map_build_state AS s (tevo_venue_id, platform, last_attempt_at, last_rows)
    VALUES (r.venue_id, r.platform, now(), v_rows)
    ON CONFLICT (tevo_venue_id, platform) DO UPDATE
      SET last_attempt_at = excluded.last_attempt_at, last_rows = excluded.last_rows;
  END LOOP;
  RETURN v_n;
END; $function$;
