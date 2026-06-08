-- Migration 20260608210400 · lane:D0 (Fantasy feature, Phase 2) → PENDING operator apply · writes:cron.schedule('fantasy-score-hourly') · reads:fantasy_scoring_periods
--
-- ## NOT YET APPLIED TO PROD — authored as a file only (CLAUDE.md lockdown rule 1).
--
-- Phase 2 of the Fantasy League feature — periodic scoring cron.
--
-- Unlike the ESPN crons (which net.http_post out to an Edge Function), scoring
-- is PURE in-DB SQL, so this is a direct cron → SQL call. No HTTP, no secret,
-- cheaper. It scans for any 'open' scoring period whose ends_at has passed and
-- scores it (idempotent — fantasy_score_period gates on status='scored').
--
-- Cadence: hourly at :48 (a free minute in the T2 hourly band; see
-- CRON_HIERARCHY.md). Hourly is ample since periods are weekly and scoring a
-- settled week is cheap + idempotent. Cron prefix `fantasy-*` per
-- MIGRATION_CONVENTIONS.
--
-- Idempotent install: unschedule any prior job of the same name first.

select cron.unschedule('fantasy-score-hourly')
  where exists (select 1 from cron.job where jobname = 'fantasy-score-hourly');

select cron.schedule(
  'fantasy-score-hourly',
  '48 * * * *',
  $cron$ select public.fantasy_score_due_periods(); $cron$
);
