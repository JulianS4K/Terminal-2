-- Drop deprecated team_xref. Replaced by performer_external_ids (source='espn')
-- which has 217 rows vs team_xref's 38, and is the canonical TEvo↔ESPN bridge
-- going forward.
--
-- Verified before drop:
--   espn fn v2 (deployed 2026-05-07) reads from performer_external_ids ✓
--   espn-collect v3 (deployed 2026-05-07) reads from performer_external_ids ✓
--   smoke-tests: /espn/applicable + /espn/performer return correct sport-slug
--     and full ESPN data for teams sourced from any of (team_xref bridge,
--     home_venues match, tevo-perf-find search, manual fix) ✓
--
-- Applied to prod 2026-05-07 via MCP.

drop table if exists team_xref cascade;
