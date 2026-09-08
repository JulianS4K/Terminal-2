-- Migration 20260908233000 · level:data-collection · lane:A1 · writes:cron.job · reads:aq_event_map,events · pre:20260908230000
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. Verified:
-- run once by hand it linked 7 hub rows, which the CRM mapper then turned into
-- 185 mapped orders (future CRM order coverage 82.9% -> 83.5%).
--
-- Schedule link_aq_tevo_from_events(). It was ORPHANED — a working function that
-- nothing ever called.
--
-- HOW IT WAS FOUND. The single biggest unmapped CRM event was "Oregon Ducks at
-- Illinois Fighting Illini Football" 2026-10-24 at Gies Memorial Stadium: 143
-- orders across two venue spellings. The venue resolved (975), the TEvo event
-- existed in our own mirror (3241216, venue 975, right date) — and nothing
-- linked them.
--
-- WHY THE BRIDGE COULD NOT: hub row 5535 carries sg_event_id 18035413, and
-- aq_tevo_search_candidates() deliberately excludes rows with an sg_event_id
-- because those belong to sg-to-tevo-search-bridge. But the SG bridge had not
-- filled it either. The row fell between two pipelines: skipped by one as "not
-- mine", never reached by the other.
--
-- link_aq_tevo_from_events() closes exactly that gap. It needs no API call at
-- all — it joins aq_event_map straight to the `events` mirror on exact
-- venue_name + name + date±1, requires one distinct TEvo event, and propagates
-- by aq_short_event_id. It is the cheapest fill in the system and it was not
-- wired to anything: `SELECT ... FROM cron.job WHERE command ILIKE
-- '%link_aq_tevo_from_events%'` returns zero rows. backfill_aq_maps() (cron 307)
-- does NOT call it — that one fills tevo_event_id from sg_events_canonical, a
-- different path that requires SG to have resolved the event first.
--
-- SCHEDULE at ':45', ahead of the two fills that depend on hub rows already
-- carrying ids: aq_link_tevo_siblings_hourly at ':50' (which propagates a filled
-- id to duplicate hub rows) and the bridge at ':53' (which then has fewer rows
-- to spend TEvo requests on). Ungated, matching the local-backfill precedent of
-- job 320.
--
-- SAFETY: the function is unchanged. It is fill-only (`WHERE tevo_event_id IS
-- NULL`), requires exact name AND exact venue AND a one-day date window, and
-- takes only groups resolving to a single TEvo event — strictly stronger keys
-- than anything else in this pipeline.
--
-- REVERSIBLE: SELECT cron.unschedule('aq_link_tevo_from_events_hourly');

SELECT cron.schedule(
  'aq_link_tevo_from_events_hourly',
  '45 * * * *',
  $cron$
  SET statement_timeout='120s';
  SELECT public.link_aq_tevo_from_events();
  $cron$
);
