-- Migration 20260831230958 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_s4k_unlink_duplicate_seed_hub_rows" (version 20260831230958) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831231500 — unlink duplicate tevo links on S4K seed rows
--
-- Lane:     xref+macro
-- Touches:  aq_event_map (W), s4k_marketplace_orders (W)
-- Pre-reqs: 20260831230154
--
-- The seam-review bot (PROJECT_BIBLE §2.6) flagged aq_event_map on PR #944.
-- Auditing it found a real regression introduced by this branch: of the 498
-- tevo_event_ids carrying more than one hub row, 490 pre-date today, but 8 were
-- created by the S4K seeding run.
--
-- Defect chain:
--   1. create_system_aq_event hashes name|venue|date TO THE MINUTE. S4K carries
--      a date only, so every seed hashes at T00:00 and can never collide with an
--      existing hub row holding the real showtime -- it mints a duplicate of an
--      event the hub already had (e.g. "Miami Open Tennis - Session 9",
--      existing 2027-03-20 11:00 vs seed 2027-03-20 00:00).
--   2. link_aq_tevo_from_events() then stamped the SAME tevo_event_id on both,
--      producing the N-rows-per-tevo_event_id fan-out §0 warns about.
--   3. On one row it did worse. The S4K order is dated 2026-09-22; the hub row
--      and the TEvo event are 2026-09-23. link_aq_tevo_from_events matched them
--      through its +/-1d tolerance, i.e. it linked a seed to the ADJACENT GAME
--      OF A SERIES -- exactly the failure §4 documents an explicit guard against
--      for sg_attempt_event_xref_v3 ("an off-date pick is rejected when a
--      same-venue, name-consistent series sibling exists within +/-3d").
--      link_aq_tevo_from_events carries no such guard. That is a pre-existing
--      weakness in an A1 function, surfaced by this branch, not introduced by
--      it -- flagged to bot_chat rather than patched here, since fixing another
--      surface's matcher unilaterally is out of scope for this PR.
--
-- Fix: drop the tevo link from the newer, seed-side row only. The older row
-- keeps it, so every consumer resolving that tevo_event_id gets exactly one hub
-- row again. The seed row itself stays -- it is the hub key for real S4K orders
-- -- it simply stops claiming a TEvo event that another row already owns, or in
-- the series case one that was never its own. Affected orders then re-derive
-- through the canonical chain and end up NULL rather than wrong, which is the
-- correct outcome: downstream views key on tevo_event_id, so a wrong link is
-- worse than none.
-- ============================================================================

WITH dupe AS (
  SELECT tevo_event_id
    FROM public.aq_event_map
   WHERE tevo_event_id IS NOT NULL
   GROUP BY tevo_event_id
  HAVING count(*) > 1
), new_only AS (
  -- groups that would not be duplicated but for a row created by this branch
  SELECT d.tevo_event_id FROM dupe d
   WHERE (SELECT count(*) FROM public.aq_event_map a
           WHERE a.tevo_event_id = d.tevo_event_id
             AND coalesce(a.imported_at, '2000-01-01'::timestamptz)
                 < '2026-08-31 22:00'::timestamptz) <= 1
), offenders AS (
  SELECT a.aq_short_event_id
    FROM public.aq_event_map a
    JOIN new_only n ON n.tevo_event_id = a.tevo_event_id
   WHERE a.aq_source = 'system_seed'
     AND a.imported_at >= '2026-08-31 22:00'::timestamptz
)
UPDATE public.aq_event_map a
   SET tevo_event_id = NULL
  FROM offenders o
 WHERE a.aq_short_event_id = o.aq_short_event_id;

-- Drop the now-unsupported derived links on the affected orders.
UPDATE public.s4k_marketplace_orders o
   SET tevo_event_id = NULL
 WHERE o.tevo_event_id IS NOT NULL
   AND NOT EXISTS (
     SELECT 1 FROM public.aq_event_map a
      WHERE a.aq_short_event_id = o.aq_short_event_id
        AND a.tevo_event_id = o.tevo_event_id);
;
