-- Migration 20260831224204 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_aq_event_map_venue_date_indexes" (version 20260831224204) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831260200 — hub lookup indexes for the S4K matcher
-- Lane:     xref+macro
-- Touches:  aq_event_map (index only, no data change)
-- Pre-reqs: 20260831260100, pg_trgm (installed in `public`, not `extensions`)
--
-- s4k_match_to_aq_event_id keys tier 1 on canonical-venue + local date and
-- tier 3 on trigram venue similarity. Neither had index support, so a sweep
-- over ~1,700 event groups sequential-scanned aq_event_map once per group and
-- blew a 60s statement budget.
--
-- event_date is `timestamp without time zone`, so ::date is IMMUTABLE and
-- indexable here -- unlike the timestamptz->date cast, which is not.
--
-- Cross-lane note: aq_event_map is the shared AQ hub (A1 surface). These are
-- additive index-only changes -- no data, no schema semantics -- made under
-- explicit operator direction. Flagged to bot_chat.
-- ============================================================================

CREATE INDEX IF NOT EXISTS aq_event_map_cvenue_date_idx
  ON public.aq_event_map (
    (lower(regexp_replace(coalesce(venue_name,''), '[^a-z0-9]+', '', 'gi'))),
    ((event_date)::date)
  );

CREATE INDEX IF NOT EXISTS aq_event_map_event_date_d_idx
  ON public.aq_event_map (((event_date)::date));

CREATE INDEX IF NOT EXISTS aq_event_map_venue_trgm_idx
  ON public.aq_event_map USING gin (lower(venue_name) public.gin_trgm_ops);

CREATE INDEX IF NOT EXISTS aq_event_map_tevo_event_id_idx
  ON public.aq_event_map (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

ANALYZE public.aq_event_map;
;
