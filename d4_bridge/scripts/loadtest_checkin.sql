-- ============================================================================
-- D4 / Exos check-in load harness (D4-OPS-11)
--
-- Purpose: stress the two concurrency-critical SQL patterns of the real
-- ticketing RPCs at 1000-person scale, in isolation, on a THROWAWAY Supabase
-- branch (never prod — a 1000-row hammer competes with prod's live pipelines):
--   * exos_mint_tickets   -> hot-row tier/event counter UPDATE
--   * exos_check_in_ticket -> atomic compare-and-swap status flip + audit insert
--
-- This MODELS those patterns (same UPDATE ... WHERE status='active' CAS + the
-- hot counter) without the RLS/auth wrapper, so the numbers measure the DB
-- engine, not the per-call network/RLS overhead (which dominates real latency
-- and must be measured separately at the door rehearsal on the deployed app).
--
-- HOW TO RUN
--   1. Create a copy-on-write branch (Supabase MCP create_branch, or the CLI).
--   2. Run section [SETUP] once (single session).
--   3. Run section [WORKER] in N concurrent sessions (psql &, pgbench -c N, or
--      N parallel MCP execute_sql calls). Two modes:
--        a. disjoint slice  -> set :slice to 0..N-1, :nworkers to N (throughput)
--        b. stampede        -> point every worker at the same id range (proves
--           no double-admit under contention)
--   4. Run section [VERIFY].
--   5. Delete the branch.
--
-- Observed 2026-05-23 (small branch instance, 8 lanes):
--   * mint 1000 tickets: ~14ms in-DB; counters consistent.
--   * 8 concurrent lanes checked in all 1000 EXACTLY once, 0 double-audits.
--   * 6-lane stampede on the same 50 tickets: exactly 50 admits, 0 doubles.
--   * In-DB check-in throughput is not the bottleneck (µs/op); the real limit
--     is per-scan network + RLS round-trip + camera decode (rehearsal item).
-- ============================================================================

-- ============================== [SETUP] =====================================
CREATE TABLE IF NOT EXISTS lt_event   (id int primary key, tickets_sold int not null default 0);
CREATE TABLE IF NOT EXISTS lt_tier    (id int primary key, event_id int, sold int not null default 0, capacity int not null default 0);
CREATE TABLE IF NOT EXISTS lt_tickets (id bigserial primary key, tier_id int, event_id int, status text not null default 'active', check_in_at timestamptz);
CREATE INDEX IF NOT EXISTS lt_tickets_slice_idx ON lt_tickets((id % 8)) WHERE status='active';
CREATE TABLE IF NOT EXISTS lt_checkins(id bigserial primary key, ticket_id bigint, scanned_at timestamptz default now());
CREATE TABLE IF NOT EXISTS lt_metrics (phase text, n int, ms numeric, extra jsonb, at timestamptz default now());

INSERT INTO lt_event VALUES (1,0) ON CONFLICT DO NOTHING;
INSERT INTO lt_tier  VALUES (1,1,0,0) ON CONFLICT DO NOTHING;  -- capacity 0 = unlimited

-- mirrors exos_mint_tickets: atomic hot-row tier counter + event counter + insert
CREATE OR REPLACE FUNCTION lt_mint(p_qty int) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  UPDATE lt_tier SET sold = sold + p_qty WHERE id=1 AND (capacity=0 OR sold+p_qty<=capacity);
  IF NOT FOUND THEN RAISE EXCEPTION 'lt_mint: sold out'; END IF;
  UPDATE lt_event SET tickets_sold = tickets_sold + p_qty WHERE id=1;
  INSERT INTO lt_tickets(tier_id,event_id,status) SELECT 1,1,'active' FROM generate_series(1,p_qty);
END $f$;

-- mirrors exos_check_in_ticket: atomic CAS flip (the double-scan guard) + audit
CREATE OR REPLACE FUNCTION lt_checkin(p_id bigint) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v int;
BEGIN
  UPDATE lt_tickets SET status='used', check_in_at=now() WHERE id=p_id AND status='active';
  GET DIAGNOSTICS v = ROW_COUNT;
  IF v=0 THEN RETURN 'used'; END IF;   -- lost the race / already used
  INSERT INTO lt_checkins(ticket_id) VALUES (p_id);
  RETURN 'checked-in';
END $f$;

-- mint 1000 (serial throughput baseline): 100 calls x mint-cap 10
DO $d$ DECLARE t0 timestamptz := clock_timestamp(); BEGIN
  FOR i IN 1..100 LOOP PERFORM lt_mint(10); END LOOP;
  INSERT INTO lt_metrics(phase,n,ms) VALUES ('mint_serial',1000, round((extract(epoch from clock_timestamp()-t0)*1000)::numeric,1));
END $d$;

-- ============================== [WORKER] ====================================
-- Run this block in N concurrent sessions. Disjoint mode: replace :slice with
-- the worker index (0..N-1) and the modulus with N. Stampede mode: replace the
-- WHERE with a fixed range every worker shares (e.g. id BETWEEN 1001 AND 1050).
DO $d$
DECLARE t0 timestamptz := clock_timestamp(); c int:=0; u int:=0; r text; tid bigint;
BEGIN
  FOR tid IN SELECT id FROM lt_tickets WHERE id % 8 = 0 /*:slice*/ AND status='active' ORDER BY id LOOP
    r := lt_checkin(tid);
    IF r='checked-in' THEN c:=c+1; ELSE u:=u+1; END IF;
  END LOOP;
  INSERT INTO lt_metrics(phase,n,ms,extra)
  VALUES ('cc', c, round((extract(epoch from clock_timestamp()-t0)*1000)::numeric,1),
          jsonb_build_object('worker',0 /*:slice*/,'already_used',u));
END $d$;

-- ============================== [VERIFY] ====================================
SELECT
  (SELECT count(*) FROM lt_tickets WHERE status='used')      AS used,
  (SELECT count(*) FROM lt_tickets WHERE status='active')    AS still_active,
  (SELECT count(*) FROM lt_checkins)                         AS audit_rows,
  (SELECT count(DISTINCT ticket_id) FROM lt_checkins)        AS distinct_audited,
  NOT EXISTS (SELECT 1 FROM lt_checkins GROUP BY ticket_id HAVING count(*)>1) AS no_double_admit,
  (SELECT sum(n) FROM lt_metrics WHERE phase='cc')           AS lanes_total_admits,
  (SELECT round(max(ms),1) FROM lt_metrics WHERE phase='cc') AS slowest_lane_ms;
