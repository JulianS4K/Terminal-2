-- ============================================================================
-- Migration 20260510120100 — Phase 2: backfill performer_external_ids
--
-- Lane:     canonical
-- Touches:  performer_external_ids (W), seatgeek_performer_xref (R),
--           seatdata_performer_xref (R), performer_espn_team_xref (R)
-- Pre-reqs: 20260509120000 (performer_external_ids exists),
--           20260510110000 (performer_espn_team_xref seeded)
--
-- Backfill performer_external_ids from per-source performer xrefs.
-- The ESPN rows (217) are populated by the athlete-crawl pipeline; this adds
-- 'sg_broker' and 'seatdata' rows so performer_external_ids becomes a
-- multi-source registry (not just ESPN).
-- ============================================================================

INSERT INTO performer_external_ids (
    performer_id, source, external_id, external_name, league, meta, set_at)
SELECT tevo_performer_id, 'sg_broker', md5(lower(sg_performer_name)),
       sg_performer_name, NULL,
       jsonb_strip_nulls(jsonb_build_object(
         'match_method',     match_method,
         'match_confidence', match_confidence)) || COALESCE(meta, '{}'::jsonb),
       matched_at
  FROM seatgeek_performer_xref
ON CONFLICT (performer_id, source) DO UPDATE
  SET external_id   = EXCLUDED.external_id,
      external_name = EXCLUDED.external_name,
      meta          = EXCLUDED.meta,
      set_at        = EXCLUDED.set_at;

INSERT INTO performer_external_ids (
    performer_id, source, external_id, external_name, league, meta, set_at)
SELECT tevo_performer_id, 'seatdata', md5(lower(sd_performer_name)),
       sd_performer_name, NULL,
       jsonb_strip_nulls(jsonb_build_object(
         'match_method',     match_method,
         'match_confidence', match_confidence,
         'sd_std_event_id',  sd_std_event_id)) || COALESCE(meta, '{}'::jsonb),
       matched_at
  FROM seatdata_performer_xref
ON CONFLICT (performer_id, source) DO UPDATE
  SET external_id   = EXCLUDED.external_id,
      external_name = EXCLUDED.external_name,
      meta          = EXCLUDED.meta,
      set_at        = EXCLUDED.set_at;

-- Wikipedia performer linkage — performer_wikipedia is the source-of-truth for
-- the Tevo↔Wikipedia mapping. Mirror non-rejected matches into performer_external_ids.
INSERT INTO performer_external_ids (
    performer_id, source, external_id, external_name, league, meta, set_at)
SELECT tevo_performer_id, 'wikipedia',
       COALESCE(wiki_pageid::text, md5(lower(wiki_title))),
       wiki_title, NULL,
       jsonb_strip_nulls(jsonb_build_object(
         'wiki_url',          wiki_url,
         'wiki_lang',         wiki_lang,
         'description',       description,
         'image_url',         image_url,
         'match_method',      match_method,
         'match_confidence',  match_confidence)),
       COALESCE(last_refreshed_at, updated_at, created_at, NOW())
  FROM performer_wikipedia
 WHERE wiki_title IS NOT NULL
   AND COALESCE(is_rejected, false) = false
ON CONFLICT (performer_id, source) DO UPDATE
  SET external_id   = EXCLUDED.external_id,
      external_name = EXCLUDED.external_name,
      meta          = EXCLUDED.meta,
      set_at        = EXCLUDED.set_at;
