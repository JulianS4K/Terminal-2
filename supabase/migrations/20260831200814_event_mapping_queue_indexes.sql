-- Migration 20260831200814 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "event_mapping_queue_indexes" (version 20260831200814) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

CREATE INDEX IF NOT EXISTS idx_gotickets_event_cname_time_unmapped
  ON public.gotickets_event (
    (lower(regexp_replace(coalesce(venue_name,''), '[^a-z0-9]+', '', 'gi'))),
    event_time_utc
  )
  WHERE tevo_event_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_sg_canonical_cname_time_unmapped
  ON public.sg_events_canonical (
    (lower(regexp_replace(coalesce(sg_venue_name,''), '[^a-z0-9]+', '', 'gi'))),
    sg_datetime_utc
  )
  WHERE tevo_event_id IS NULL;
;
