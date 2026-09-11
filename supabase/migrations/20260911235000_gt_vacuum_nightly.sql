-- ============================================================================
-- Migration 20260911235000 — nightly explicit VACUUM for the GoTickets firehose
-- Migration 20260911235000 · level:data-collection · lane:A1 · writes:cron.job · reads:none · pre:20260911250000
--
-- Lane:     A1 (data plane)
-- Touches:  cron.job (W) — one maintenance job; no table, data or schema change
-- Pre-reqs: 20260911250000 (autovacuum tuning for the untuned high-churn tables)
--
-- ── SCOPE REDUCED, DELIBERATELY ────────────────────────────────────────────
-- This migration originally also carried the per-table autovacuum reloptions
-- for gotickets_listings_snapshots and event_section_row_snapshots. Those were
-- landed independently by `20260911250000_autovacuum_tuning_high_churn.sql`
-- (another session, same day, same diagnosis, same verbatim values copied from
-- listings_snapshots — and it additionally covers ticketsdata_listings_snapshots
-- and self-checks all six tables). Two migrations setting the same reloptions
-- is last-write-wins noise and hides which one owns the setting, so the ALTER
-- TABLEs are removed here and 20260911250000 is the single owner.
--
-- What remains is the part that migration does not do: an explicit sweep.
--
-- ── WHY AN EXPLICIT VACUUM ON TOP OF THE RELOPTIONS ───────────────────────
-- scale_factor is a THRESHOLD, not a schedule. Once it is crossed, autovacuum
-- still has to win one of autovacuum_max_workers=3 against every other table on
-- a 412 GB instance — and gotickets_listings_snapshots is the highest-churn
-- table in the database (retention_tick deletes ~15M rows/day from it). A
-- nightly explicit pass guarantees the firehose is swept once a day regardless
-- of worker contention.
--
-- Plain VACUUM, never VACUUM FULL: no exclusive lock, no table rewrite, safe
-- against a live firehose. Like autovacuum it makes dead space REUSABLE rather
-- than returning it to the OS — reclaiming the existing bloat is a separate
-- operator decision (VACUUM FULL / pg_repack), and the index half of it is
-- handled online by 20260911236500.
--
-- VACUUM cannot run inside a transaction block, which is why this is scheduled
-- as a cron command rather than executed here.
--
-- 07:10 UTC = 03:10 ET: inside the offpeak window (ET 02:00-08:59), clear of
-- retention_tick at :44 and of the 07:30 UTC REINDEX jobs (20260911236500).
-- ============================================================================

SELECT cron.unschedule('vacuum_firehose_nightly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vacuum_firehose_nightly');

SELECT cron.schedule(
  'vacuum_firehose_nightly',
  '10 7 * * *',
  $cron$ VACUUM (ANALYZE) public.gotickets_listings_snapshots; $cron$);
