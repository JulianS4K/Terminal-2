-- Drop unique (team_id, league, captured_at) and (event_id, captured_at):
-- under the change-only ingest pattern (migration 17), upsert_espn_*_snapshot
-- RPCs already prevent semantic dupes via content_hash comparison. The unique
-- constraint instead caused spurious collisions when multiple inserts shared
-- the same statement-level NOW() (e.g. tests, batch jobs, fast back-to-back
-- runs). Removing it is safe because change-only is the only write path.
--
-- Applied to prod 2026-05-07 via MCP.

alter table espn_team_snapshots  drop constraint if exists espn_team_snapshots_espn_team_id_espn_league_captured_at_key;
alter table espn_event_snapshots drop constraint if exists espn_event_snapshots_espn_event_id_captured_at_key;
