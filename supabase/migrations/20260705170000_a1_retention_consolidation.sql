-- ============================================================================
-- Migration 20260705170000 — retention consolidation: converge on the
--                            retention_policy engine (PR #805), retire the
--                            parallel data_retention_policy engine (PR #804)
--
-- Lane:     A1 (data plane)
-- Touches:  data_retention_policy (DROP), run_data_retention_tick (DROP),
--           cron.job (unschedule data-retention-runner; re-enable
--           cron_gate_decisions_prune_daily + cron-run-details-cleanup),
--           retention_policy (W: +seatgeek_sales_snapshots disabled row),
--           retention_run_log (W: retirement note), section_metrics (idx dedup)
-- Pre-reqs: 20260705153000_a1_retention_policy_engine (PR #805)
--
-- Two operator-directed sessions built retention engines in parallel on
-- 2026-07-05: the per-minute data_retention_policy tick (applied 15:24Z,
-- PR #804, file 20260705152000) and the hourly retention_policy engine
-- (applied 16:10Z, PR #805, merged to main first, with run_log + deadman
-- wiring and the original 15d listings policy). Both ran side by side,
-- harmlessly but redundantly (idempotent TTL deletes; one exact-duplicate
-- section_metrics index). This converges on the PR #805 engine as the single
-- source of truth.
--
-- The retired engine drained ~14.38M rows before convergence:
--   listings_snapshots 10,660,813 · ticketsdata 1,980,781 · esrs 1,096,624 ·
--   section_metrics 603,116 · cron_gate_decisions 8,143 · job_run_details 28,294
-- Ported to the surviving system here:
--   * seatgeek_sales_snapshots seeded DISABLED (pulled_at, 30d) — flip with
--     seatgeek_listings_snapshots when SG pollers resume.
--   * cron_gate_decisions + cron.job_run_details CANNOT live in
--     retention_policy (engine is public-schema-only, no extra-predicate
--     support for gates' decision <> 'fire') — their original standalone
--     crons are re-enabled instead (20260705152000 had tombstoned them).
--   * idx_section_metrics_captured_at (dup of PR #805's
--     idx_section_metrics_captured) dropped CONCURRENTLY on prod; plain form
--     below for replay. idx_event_metrics_captured_at +
--     idx_cron_gate_decisions_decided_at KEPT (they serve the surviving
--     engine's event_metrics policy + the re-enabled gates prune).
--
-- Applied to prod 2026-07-05 via MCP; idempotent on replay.
-- ============================================================================

-- 1. Retire the parallel per-minute engine
select cron.unschedule(jobid) from cron.job where jobname = 'data-retention-runner';
drop function if exists public.run_data_retention_tick(boolean);

insert into public.retention_run_log (table_name, deleted, note)
select 'data_retention_policy(retired)', 14377771,
  'consolidation 20260705170000: parallel per-minute engine (PR #804) retired into this engine (PR #805). Drained before convergence: listings 10,660,813 / td 1,980,781 / esrs 1,096,624 / section_metrics 603,116 / gates 8,143 / job_run_details 28,294.'
where not exists (select 1 from public.retention_run_log where table_name = 'data_retention_policy(retired)');

drop table if exists public.data_retention_policy;

-- 2. Re-enable the two standalone prunes the surviving engine cannot host
select cron.alter_job(jobid, active := true) from cron.job
where jobname in ('cron_gate_decisions_prune_daily', 'cron-run-details-cleanup') and not active;

-- 3. De-duplicate the section_metrics captured_at index (keep the
--    engine-referenced name idx_section_metrics_captured)
drop index if exists public.idx_section_metrics_captured_at;

-- 4. Port the missing SG-sales row into the surviving registry (disabled)
insert into public.retention_policy (table_name, ts_column, keep_days, enabled, notes)
values ('seatgeek_sales_snapshots', 'pulled_at', 30, false,
        'seeded by consolidation 20260705170000; enable together with seatgeek_listings_snapshots when SG pollers resume')
on conflict (table_name) do nothing;
