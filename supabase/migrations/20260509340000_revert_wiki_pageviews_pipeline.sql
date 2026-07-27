-- ============================================================================
-- Migration 20260509340000 — Revert Wikipedia pageviews SQL pipeline
--
-- Per product directive: "for wikipedia keep the data but allow future ai
-- connectors to use as additional context, dont think it's useful in a sql
-- environment."
--
-- The pageviews trend math (spike_multiplier vs baseline) was overkill for
-- a SQL surface — the actual day-trader workflow doesn't run "show me
-- performers with rising buzz" SELECTs. The buzz signal lives in actual
-- price/order deltas, which we already have. The summary text + image_url
-- in performer_wikipedia is more useful as raw context for future AI
-- connectors (RAG corpus, prompt-time enrichment) than as numbers to JOIN.
--
-- WHAT THIS MIGRATION DROPS (added 5h ago in 20260509330000):
--   ✗ wiki_pageviews_queue_daily   cron
--   ✗ wiki_pageviews_process_daily cron
--   ✗ wiki_pageviews_queue(int)    function
--   ✗ wiki_pageviews_process()     function
--   ✗ v_performer_pageview_trend   view
--   ✗ performer_wiki_pageviews         table
--   ✗ performer_wiki_pageviews_pending table
--
-- WHAT THIS MIGRATION KEEPS:
--   ✓ performer_wikipedia      — title, extract, image_url, wiki_url
--   ✓ performer_wiki_searches  — search-side state for the enrichment cron
--   ✓ Three enrichment crons   — performer_wiki_queue_searches_5min etc.
--     (these still populate wiki_title / extract / image_url for new
--     performers; useful as AI-connector context)
--   ✓ v_unmatched_events       — orphan-events bucket from same migration
--   ✓ event_match_attempts     — match-audit log from same migration
-- ============================================================================

-- (1) Unschedule pageview crons. Wrap in DO blocks so partial state on
--     retries doesn't blow up.
DO $$
BEGIN
  PERFORM cron.unschedule('wiki_pageviews_queue_daily');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
  PERFORM cron.unschedule('wiki_pageviews_process_daily');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

-- (2) Drop trend view first (depends on the table)
DROP VIEW IF EXISTS v_performer_pageview_trend;

-- (3) Drop functions
DROP FUNCTION IF EXISTS wiki_pageviews_queue(int);
DROP FUNCTION IF EXISTS wiki_pageviews_process();

-- (4) Drop tables
DROP TABLE IF EXISTS performer_wiki_pageviews;
DROP TABLE IF EXISTS performer_wiki_pageviews_pending;

-- (5) Marker comment on the kept summary table so future readers know the
--     intended consumer is AI-connector context, not SQL analytics.
COMMENT ON TABLE performer_wikipedia IS
  'Wikipedia summary enrichment per TEvo performer (title, extract, image_url, '
  'wiki_url). Intended consumer: AI/RAG connectors that want plain-English '
  'context about a performer (e.g. "who is this team / artist"). NOT intended '
  'as a SQL analytics surface — buzz/trend signals live in price/order deltas. '
  'See docs/wikipedia-usage-2026-05-09.md.';
