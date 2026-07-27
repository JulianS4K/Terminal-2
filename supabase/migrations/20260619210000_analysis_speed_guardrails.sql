-- Migration 20260619210000 · lane:A1 (operator-directed) ·
--   writes (DDL): CREATE VIEW x2 (recent firehose windows); CREATE ROLE analyst_ro
--     + GRANTs + ALTER ROLE ... SET statement_timeout; COMMENTs.
--   reads: none
--   ## APPLIED 2026-06-19 (operator-approved) via apply_migration. Pure additive
--   (new views + new role); touched NO existing object's data and changed NO
--   existing role's config. Post-apply still needs the out-of-band step below:
--   ALTER ROLE analyst_ro LOGIN PASSWORD '<...>' + repoint the analysis conn.
--
-- GOAL: data-analysis SPEED (operator reframe 2026-06-19). Two guardrails that
-- stop ad-hoc analysis from scanning the raw firehose unbounded:
--   (A) `*_recent` views — a 30-day window over the firehoses, so the common
--       "recent intraday" question prunes via idx_listings_captured instead of
--       seq-scanning 123 M rows / 48 GB. Analysts SELECT the view, not the table.
--   (B) `analyst_ro` role — a read-only login with statement_timeout=30s, so a
--       runaway ad-hoc scan self-aborts at 30 s instead of pinning IO for
--       68-140 s and spiking prod-RPC tail latency (measured contention,
--       2026-06-19). Route ad-hoc / MCP analysis connections through this role.
--
-- WHY NOT just `ALTER ROLE service_role SET statement_timeout` (the tempting
-- one-liner): service_role runs the INGEST + maintenance crons, and those
-- legitimately run minutes — measured max_exec_time (pg_stat_statements,
-- 2026-06-19): sg_blindspot_mv_refresh 565 s, listings_deltas_backfill_chunked
-- 266 s, build_venue_section_map 123 s, many cron bodies ~120 s. A ceiling low
-- enough to catch a 140 s analyst scan (~60 s) would ALSO kill the 565 s matview
-- refresh — the two overlap, so no single service_role ceiling separates them.
-- The crons already self-protect per-txn with `SET LOCAL statement_timeout`.
-- Hence: a SEPARATE bounded role for humans, service_role left untouched.
--
-- Full analysis: docs/archive/2026-06-19-snapshot-bloat-play.md (§"Speed solution").
-- Reversible: DROP VIEW ... ; DROP ROLE analyst_ro; (rollback at bottom).

-- ─────────────────────────────────────────────────────────────────────────────
-- (A) Recent-window views. 30 d covers the intraday/short-window charts; deeper
-- history lives in the pre-agg layer (event_listing_snapshot_daily, indefinite).
-- listings_snapshots prunes well: idx_listings_captured is (captured_at) btree.
-- seatgeek_listings_snapshots carries captured_at only as a trailing composite
-- column, so its view bounds the row set but prunes less tightly — still far
-- cheaper than the full table and steers analysts off the raw firehose.

CREATE OR REPLACE VIEW public.listings_snapshots_recent AS
  SELECT * FROM public.listings_snapshots
  WHERE captured_at >= now() - interval '30 days';

COMMENT ON VIEW public.listings_snapshots_recent IS
  'Last 30d of listings_snapshots (prunes via idx_listings_captured). Use this '
  'for recent/intraday analysis instead of the raw 48GB/123M-row firehose; '
  'deeper history lives in event_listing_snapshot_daily. (speed guardrail '
  '2026-06-19, docs/archive/2026-06-19-snapshot-bloat-play.md)';

CREATE OR REPLACE VIEW public.seatgeek_listings_snapshots_recent AS
  SELECT * FROM public.seatgeek_listings_snapshots
  WHERE captured_at >= now() - interval '30 days';

COMMENT ON VIEW public.seatgeek_listings_snapshots_recent IS
  'Last 30d of seatgeek_listings_snapshots. Bounds the row set for recent '
  'analysis; deeper history lives in seatgeek_event_metrics. (speed guardrail '
  '2026-06-19)';

-- ─────────────────────────────────────────────────────────────────────────────
-- (B) Bounded read-only analyst role. NOLOGIN by default here — the operator
-- attaches a password / grants LOGIN out-of-band (keep credentials out of git).
-- 30 s statement_timeout: generous for legit pre-agg queries (matview reads run
-- 31-90 ms), tight enough to abort a runaway raw-firehose scan long before it
-- contends with prod RPCs.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analyst_ro') THEN
    CREATE ROLE analyst_ro NOLOGIN;
  END IF;
END$$;

ALTER ROLE analyst_ro SET statement_timeout = '30s';
ALTER ROLE analyst_ro SET lock_timeout = '5s';
ALTER ROLE analyst_ro SET idle_in_transaction_session_timeout = '60s';

-- Read-only across public: existing tables/views + the pre-agg layer + the new
-- recent views. No INSERT/UPDATE/DELETE granted anywhere.
GRANT USAGE ON SCHEMA public TO analyst_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analyst_ro;
-- New objects created later are auto-readable (so analysts don't lose access on
-- the next migration). SELECT-only; no write default.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO analyst_ro;

COMMENT ON ROLE analyst_ro IS
  'Read-only ad-hoc/MCP analysis role. statement_timeout=30s bounds runaway raw '
  'firehose scans (prevents the 68-140s scans that spiked prod-RPC tail latency, '
  '2026-06-19). Route human/MCP analysis here; keep service_role for ingest. '
  'Operator grants LOGIN + password out-of-band.';

-- ─────────────────────────────────────────────────────────────────────────────
-- ROLLBACK:
--   DROP VIEW IF EXISTS public.listings_snapshots_recent;
--   DROP VIEW IF EXISTS public.seatgeek_listings_snapshots_recent;
--   ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE SELECT ON TABLES FROM analyst_ro;
--   REVOKE SELECT ON ALL TABLES IN SCHEMA public FROM analyst_ro;
--   REVOKE USAGE ON SCHEMA public FROM analyst_ro;
--   DROP ROLE IF EXISTS analyst_ro;
--
-- POST-APPLY (operator, out-of-band — NOT in git):
--   ALTER ROLE analyst_ro LOGIN PASSWORD '<generated>';  -- then point the MCP /
--   analyst connection string at analyst_ro. Verify: `SHOW statement_timeout;`
--   over that connection returns 30s, and a `SELECT count(*) FROM
--   listings_snapshots WHERE captured_at < now() - interval '60 days'` aborts at 30s.
