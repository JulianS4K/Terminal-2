-- Migration 20260516040000 · admin · resume listings_aq_backfill_overnight · pre:20260516030000
-- Finding 1 from D0 Phase 2a spot-check (2026-05-16): listings_snapshots has 0%
-- aq_short_event_id coverage (0 of 2.4M rows in 7d). seatgeek_seller_listings
-- at 8% (62/759). Matcher works (tested 70-100% hit rate on 10+ diverse samples)
-- but the backfill cron from migration 20260515240000 was set active=false and
-- never fired (0 entries in cron.job_run_details).
--
-- This migration flips the cron back on. Schedule unchanged (`2-14 4 * * *` —
-- 13 firings nightly at 4:02-4:14 UTC, off-peak). Each firing processes 100
-- events, drains the ~894 distinct unmatched events in ~1 night. Cron
-- self-unschedules when events_remaining=0 (built-in safeguard from 20260515240000).
--
-- Attempted seed (one-shot match_unmatched_listings_chunked(50, true)) failed
-- with 2-min statement timeout — the SG listings branch processes ~50K rows
-- per event, 50 events × 50K = 2.5M row UPDATE blew the apply_migration cap.
-- Tonight's per-minute cron firings have a 60-second slot each (no transaction
-- cap), so chunked(100) per firing succeeds even when the apply context can't.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16. Cron active=true.
-- First firing: 2026-05-17 04:02 UTC. Expected drain complete by 04:14.
-- Post-firing verification:
--   SELECT count(*) FILTER (WHERE aq_short_event_id IS NOT NULL) AS with_aq, count(*) total
--   FROM public.listings_snapshots WHERE captured_at > now() - interval '24 hours';
-- Expected: pct ~95% by 04:30 (matcher hit rate observed on 10-event diverse sample).

SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname = 'listings_aq_backfill_overnight'),
  active := true
);
