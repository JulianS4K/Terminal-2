-- ============================================================================
-- Migration 20260621000000 — ESPN MMA/UFC support (performer xref seed)
--
-- Lane:     A1 (data plane — performer_external_ids is the ESPN xref surface)
-- Touches:  performer_external_ids (W, single-row UPSERT for UFC org)
-- Pre-reqs: none (table predates this; row is additive)
-- Pairs-with: supabase/functions/espn/index.ts MMA code path (same PR) — the
--             row is inert until the edge function understands meta.is_org.
--
-- WHY: the ESPN integration was team-sport-only. `event_xref` covered
--   MLB/NFL/NBA/NHL/WNBA/MLS + tennis/golf/F1; there was no MMA/UFC path, so
--   UFC events (e.g. UFC 329, tevo event 3350088) could never light up the
--   ESPN side panel. `performer_external_ids` is the canonical lookup the
--   `espn` edge fn reads (lookupTeamXref). This seeds the ONE row that maps the
--   UFC org performer → ESPN's `mma/ufc` league.
--
--   UFC is an ORG, not a team: ESPN has no `/teams/{id}/schedule` for it, so
--   the existing team-schedule resolver cannot match its events. meta.is_org
--   flags the edge fn to resolve UFC events via the MMA *scoreboard* (date
--   match) and to render a fight-card aggregate instead of a team box score.
--
-- external_id = 'ufc' is a sentinel (ESPN MMA has no numeric team id for the
--   org); the slug 'mma/ufc' is what actually drives every ESPN API call.
--
-- IDEMPOTENT: ON CONFLICT upsert; meta is merged (|| ) so any future enrichment
--   on this row is preserved.
-- ============================================================================

INSERT INTO public.performer_external_ids
  (performer_id, source, external_id, external_name, league, meta)
VALUES (
  25507,
  'espn',
  'ufc',
  'UFC - Ultimate Fighting Championship',
  'UFC',
  jsonb_build_object(
    'espn_slug', 'mma/ufc',
    'espn_abbr', 'UFC',
    'sport',     'mma',
    'is_org',    true,
    'seeded_by', 'migration_20260621000000_espn_mma_ufc_support'
  )
)
ON CONFLICT (performer_id, source) DO UPDATE
  SET external_id   = EXCLUDED.external_id,
      external_name = EXCLUDED.external_name,
      league        = EXCLUDED.league,
      meta          = public.performer_external_ids.meta || EXCLUDED.meta;
