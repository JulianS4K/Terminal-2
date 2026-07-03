-- Migration 20260703015000 · level:standard · lane:broadway (D3) · writes:v_broadway_performer_getin · reads:broadway_cast_run,broadway_show_ref,events,event_listing_snapshot_daily · pre:20260703014500
--
-- Fix v_broadway_performer_getin: an unknown run_end (NULL) must NOT extend to
-- infinity. The original COALESCE(run_end, DATE '9999-12-31') let an open-ended
-- run swallow LATER performers' priced snapshots — Cole Escola's 2024 opening
-- run (run_end NULL, exact pause date unverified) was picking up Maya Rudolph's
-- 2026 get-in ($133.26), double-attributing it. Only one lead plays at a time,
-- so bound each run's effective end by the NEXT run's start for the same show
-- (LEAD over run_start), falling back to 9999-12-31 only for a genuinely-current
-- final run. Pure view redefinition; no data change. (Applied to prod out-of-band
-- 2026-07-03 — the #767 batch was skipped by the Supabase preview-branch limit
-- and hand-applied; this is the idempotent codification. Re-apply is a no-op.)

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
    ON e.venue_name ILIKE r.venue_name_pattern
   AND (r.event_name_pattern IS NULL OR e.name ILIKE r.event_name_pattern)
),
runs AS (
  -- effective end = explicit run_end, else the day before the next run starts
  -- (one lead at a time), else far-future for a genuinely-current final run.
  SELECT cr.*,
    COALESCE(
      cr.run_end,
      (LEAD(cr.run_start) OVER (PARTITION BY cr.show_slug ORDER BY cr.run_start NULLS FIRST)) - 1,
      DATE '9999-12-31'
    ) AS effective_run_end
  FROM public.broadway_cast_run cr
),
priced AS (
  SELECT
    cr.id AS cast_run_id, cr.show_slug, cr.role, cr.performer_name, cr.engagement_seq,
    cr.run_start, cr.run_end, cr.is_final_confirmed, cr.confidence,
    p.event_id, p.perf_date, s.snapshot_date, s.amalgam_getin
  FROM runs cr
  JOIN perf p
    ON p.show_slug = cr.show_slug
   AND p.perf_date >= COALESCE(cr.run_start, DATE '1900-01-01')
   AND p.perf_date <= cr.effective_run_end
  JOIN public.event_listing_snapshot_daily s
    ON s.event_id = p.event_id
   AND s.amalgam_getin IS NOT NULL
)
SELECT
  cast_run_id, show_slug, role, performer_name, engagement_seq,
  run_start, run_end, is_final_confirmed, confidence,
  count(DISTINCT event_id)                                              AS perfs_priced,
  count(*)                                                              AS snapshot_rows,
  min(snapshot_date)                                                   AS first_snapshot,
  max(snapshot_date)                                                   AS last_snapshot,
  round(avg(amalgam_getin), 2)                                         AS avg_getin,
  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_getin)::numeric, 2) AS median_getin,
  round(min(amalgam_getin), 2)                                         AS min_getin,
  round(max(amalgam_getin), 2)                                         AS max_getin,
  round(avg(amalgam_getin) FILTER (WHERE perf_date = run_end), 2)      AS closing_night_getin
FROM priced
GROUP BY
  cast_run_id, show_slug, role, performer_name, engagement_seq,
  run_start, run_end, is_final_confirmed, confidence;
