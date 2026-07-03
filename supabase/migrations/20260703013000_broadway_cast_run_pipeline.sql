-- Migration 20260703013000 · level:standard · lane:broadway (D3) · pre:20260703011000
--
-- Broadway CAST-RUN overlay — the "who is playing the lead on a given night"
-- dimension that Broadway is missing (sports has espn_injuries_snapshots,
-- concerts have events.primary_performer_id; a Broadway event row is the SHOW,
-- and the star is an overlay that changes over the run). This is the data
-- layer that lets us slice ticket price by ACTOR, not just by date — i.e.
-- reproduce the TickPick "Average Closing Night Ticket Price by Actor" chart
-- from our OWN pipeline.
--
-- Two tables + one engine view:
--   broadway_show_ref        — one row per tracked show; carries the predicate
--                              that resolves the show to canonical `events`
--                              rows (name + venue pattern). No dependency on
--                              broadway_shows (that pipeline is unapplied).
--   broadway_cast_run        — one row per (show, role, performer, stint):
--                              the run window + final-performance date + the
--                              trade-press source it was curated from.
--   v_broadway_performer_getin — joins cast runs to A1's per-performance daily
--                              price history (event_listing_snapshot_daily) and
--                              aggregates get-in per performer/stint. This is
--                              the general performer-stats engine.
--
-- CAST SOURCE (design decision, D3): the feed is a CURATED, CITED run-table
-- refreshed on casting-announcement news — NOT an automated scraper. IBDB /
-- Wikipedia / Playbill all 403 automated fetchers, and cast changes are
-- low-volume (~7 changes over ~2 years for Oh, Mary!), so a hand-verified
-- table sourced from the trade press is both more accurate and auditable.
-- Every row carries source_name/source_url + a confidence score. The schema
-- is shaped so an automated feed (a future GET-only broadway_cast_client.py
-- against IBDB/BroadwayWorld) can UPSERT into the same table with no change.
--
-- SEAM (PROJECT_BIBLE §2.6): the view READS A1-owned event_listing_snapshot_daily
-- + events (reads are always open). broadway_* tables are D3-owned (§2.4).
--
-- RULE 1: authored as a file only. Apply to prod is Applier-gated (A1).

-- ============================================================================
-- (1) broadway_show_ref — tracked-show dimension + event-resolution predicate
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_show_ref (
  show_slug            text        PRIMARY KEY,           -- 'oh-mary'
  title                text        NOT NULL,              -- 'Oh, Mary!'
  venue_name_pattern   text        NOT NULL,              -- PRIMARY ANCHOR: ILIKE against events.venue_name, e.g. '%Lyceum%'
  event_name_pattern   text,                              -- OPTIONAL guard: ILIKE against events.name; NULL = resolve by venue alone
  city                 text,
  notes                text,
  first_seen_at        timestamptz NOT NULL DEFAULT now(),
  last_seen_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.broadway_show_ref IS
  'Tracked-show dimension for the cast-run overlay. venue_name_pattern is the '
  'PRIMARY anchor — each Broadway house runs one show at a time, so venue '
  'resolves the show reliably even when the source spells the title many ways '
  '("Wicked" vs "Wicked\t"; "SIX: The Musical" / "Six the Musical"). '
  'event_name_pattern is an OPTIONAL identity guard (nullable): set it only to '
  'disambiguate a house that hosts more than one tracked show in-window, or to '
  'pin the slug across a future venue transition. Resolves to public.events '
  'without depending on the (unapplied) broadway_shows pipeline.';

-- ============================================================================
-- (2) broadway_cast_run — one row per (show, role, performer, engagement)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.broadway_cast_run (
  id                   bigserial   PRIMARY KEY,
  show_slug            text        NOT NULL REFERENCES public.broadway_show_ref (show_slug),
  role                 text        NOT NULL,              -- 'Mary Todd Lincoln'
  performer_name       text        NOT NULL,              -- 'Maya Rudolph'
  performer_id         bigint,                            -- future canonical link (nullable — Broadway stars are not on the event row)
  engagement_seq       integer     NOT NULL DEFAULT 1,    -- 1,2,… for a performer with multiple stints
  run_start            date,                              -- first performance of this stint
  run_end              date,                              -- final ("closing") performance of this stint
  is_open              boolean     NOT NULL DEFAULT false, -- run has no announced end
  is_final_confirmed   boolean     NOT NULL DEFAULT false, -- run_end is an announced final vs. projected
  source_name          text,                              -- 'Playbill' | 'BroadwayWorld' | 'IBDB' | …
  source_url           text,
  confidence           numeric(3,2) NOT NULL DEFAULT 1.00, -- 0.00..1.00 curator confidence in the dates
  note                 text,
  first_seen_at        timestamptz NOT NULL DEFAULT now(),
  last_seen_at         timestamptz NOT NULL DEFAULT now(),

  -- at least one bound must be known; confidence stays in range
  CONSTRAINT broadway_cast_run_has_bound CHECK (run_start IS NOT NULL OR run_end IS NOT NULL),
  CONSTRAINT broadway_cast_run_conf_range CHECK (confidence >= 0 AND confidence <= 1),
  CONSTRAINT broadway_cast_run_uniq UNIQUE (show_slug, role, performer_name, engagement_seq)
);

CREATE INDEX IF NOT EXISTS idx_bwy_cast_run_show ON public.broadway_cast_run (show_slug);
CREATE INDEX IF NOT EXISTS idx_bwy_cast_run_window ON public.broadway_cast_run (run_start, run_end);
CREATE INDEX IF NOT EXISTS idx_bwy_cast_run_performer ON public.broadway_cast_run (performer_name);

COMMENT ON TABLE public.broadway_cast_run IS
  'Curated cast-run overlay: which performer played which role over which '
  'date window (the Broadway analogue of an injury/roster report). Feed is '
  'hand-verified from the trade press (source_name/source_url + confidence); '
  'shaped for a future automated UPSERT feed. run_end = final performance = '
  'the "closing night" the get-in chart keys on.';

-- ============================================================================
-- (3) v_broadway_performer_getin — the performer-stats engine
--     cast run  ⋈  events (name+venue)  ⋈  event_listing_snapshot_daily
--     Get-in metric = amalgam_getin (blended across sources); coverage counts
--     expose how much of each run we actually snapshotted (secondary-market
--     history only reaches back to when we started collecting — runs before
--     that resolve to zero priced performances, which is expected).
-- ============================================================================

CREATE OR REPLACE VIEW public.v_broadway_performer_getin
WITH (security_invoker = true)
AS
WITH perf AS (
  SELECT
    r.show_slug,
    e.id                        AS event_id,
    (e.occurs_at_local)::date   AS perf_date
  FROM public.broadway_show_ref r
  JOIN public.events e
    ON e.venue_name ILIKE r.venue_name_pattern                      -- primary anchor: venue
   AND (r.event_name_pattern IS NULL OR e.name ILIKE r.event_name_pattern)  -- optional name guard
),
priced AS (
  SELECT
    cr.id                       AS cast_run_id,
    cr.show_slug,
    cr.role,
    cr.performer_name,
    cr.engagement_seq,
    cr.run_start,
    cr.run_end,
    cr.is_final_confirmed,
    cr.confidence,
    p.event_id,
    p.perf_date,
    s.snapshot_date,
    s.amalgam_getin
  FROM public.broadway_cast_run cr
  JOIN perf p
    ON p.show_slug = cr.show_slug
   AND p.perf_date >= COALESCE(cr.run_start, DATE '1900-01-01')
   AND p.perf_date <= COALESCE(cr.run_end,   DATE '9999-12-31')
  JOIN public.event_listing_snapshot_daily s
    ON s.event_id = p.event_id
   AND s.amalgam_getin IS NOT NULL
)
SELECT
  cast_run_id,
  show_slug,
  role,
  performer_name,
  engagement_seq,
  run_start,
  run_end,
  is_final_confirmed,
  confidence,
  count(DISTINCT event_id)                                              AS perfs_priced,
  count(*)                                                              AS snapshot_rows,
  min(snapshot_date)                                                   AS first_snapshot,
  max(snapshot_date)                                                   AS last_snapshot,
  round(avg(amalgam_getin), 2)                                         AS avg_getin,
  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_getin)::numeric, 2) AS median_getin,
  round(min(amalgam_getin), 2)                                         AS min_getin,
  round(max(amalgam_getin), 2)                                         AS max_getin,
  -- closing-night proxy: get-in observed on the final-performance date
  round(avg(amalgam_getin) FILTER (WHERE perf_date = run_end), 2)      AS closing_night_getin
FROM priced
GROUP BY
  cast_run_id, show_slug, role, performer_name, engagement_seq,
  run_start, run_end, is_final_confirmed, confidence;

COMMENT ON VIEW public.v_broadway_performer_getin IS
  'Performer-stats engine: joins broadway_cast_run to per-performance daily '
  'price history (event_listing_snapshot_daily, via events name+venue match) '
  'and aggregates get-in per performer/stint. perfs_priced/snapshot_rows show '
  'coverage — runs predating our snapshot window resolve to zero rows (secondary '
  'price history is not backfillable). closing_night_getin = the TickPick metric.';

-- ============================================================================
-- (4) RLS — authenticated read, service_role write (matches broadway_* pattern)
-- ============================================================================

ALTER TABLE public.broadway_show_ref  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.broadway_cast_run  ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT unnest(ARRAY['broadway_show_ref','broadway_cast_run'])
  LOOP
    EXECUTE format(
      'DROP POLICY IF EXISTS %I ON public.%I; '
      'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true);',
      t || '_read', t, t || '_read', t
    );
  END LOOP;
END $$;

-- ============================================================================
-- DONE. Seed ships in 20260703013500_broadway_cast_run_seed_oh_mary.sql.
-- ============================================================================
