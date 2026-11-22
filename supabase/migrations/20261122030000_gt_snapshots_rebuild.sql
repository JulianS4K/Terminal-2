-- Migration 20261122030000 · level:ops · lane:A1 (data plane — retention engine, KANBAN A1-DATA-1 P1 / A1-DB-7) · writes:gotickets_listings_snapshots_new(new, becomes gotickets_listings_snapshots at the swap),gt_snapshots_rebuild(new state row),gt_snapshots_rebuild_tick()(new),v_gt_snapshots_rebuild(new),cron:gt_snapshots_rebuild_1min(new, removes itself),retention_policy(1 row: parked for the rebuild, released at the swap) · reads:gotickets_listings_snapshots,deal_listing_spell,retention_policy,cron.job · pre:20261027210000
--
-- GOTICKETS LISTINGS FIREHOSE — REBUILT ONLINE TO ITS 15-DAY WINDOW, THEN SWAPPED IN.
--
-- Operator 2026-11-22 ("Do it" — the CTAS swap, A1-DATA-1 phase P1). The facts on 2026-11-22 02:30Z:
--   * `gotickets_listings_snapshots` is 130 GB (87 GB heap, 33 GB primary key, 10 GB on the two chart/retention
--     indexes) holding ~300 M live rows, the oldest from 2026-08-27. The policy keeps 15 days.
--   * The poller is back on: `gt_ingest_drain_1min` lands 8.7–12.3 M rows a day (per-day counts 11-12 .. 11-21).
--     The retention_policy note of 2026-10-27 ("no writer since 09-27, every surviving row is keep_where evidence")
--     no longer describes the table.
--   * The sweep deletes NOTHING: every `retention_tick` since 2026-11-17 12:44Z has been cancelled by the postgres
--     role's 900 s statement_timeout before its first 50 000-row GoTickets batch finished (`last_error =
--     query_canceled`; the last logged batch took 12 min); pg_cron records the cancelled run as "succeeded".
--     The table therefore grows by the whole inflow, and listings_snapshots is in the same state.
--
-- A DELETE can never catch up with 9 M rows a day on this heap, and a delete reclaims no space anyway. The fix is
-- the swap the KANBAN already names: copy the rows worth keeping into a fresh table, build its indexes once, rename
-- it into place, and drop the old heap. The 900 s ceiling and the MCP tool's own limits mean this cannot be one
-- statement, so it is driven by a small state machine that a one-minute cron advances, each tick bounded:
--
--   init ──▶ evidence ──▶ copy ──▶ index_pk ──▶ index_captured ──▶ index_event_time ──▶ finish ──▶ analyze ──▶ done
--
--   evidence  the retention policy's `keep_where` rows older than the cutoff (now − 15 d at init): every snapshot of
--             a `gt_listing_id` that `deal_listing_spell` (source 'gotickets') holds — a flagged deal's own evidence
--             outlives the TTL (operator 2026-09-11, mig 20260911162500). Read per spell event through the primary
--             key (gt_event_id leads it), so the 87 GB heap is never scanned.
--   copy      the window [cutoff, now − 30 min) in 6-hour slices through `idx_gt_ls_captured`, a heap-only copy (no
--             indexes on the new table yet), as many slices as fit a tick.
--   index_*   the primary key and the two indexes the readers and the sweep use, built once on the finished copy,
--             one per tick (plain builds — nothing reads the new table, so CONCURRENTLY is not needed and the
--             cron's multi-statement transaction block does not matter).
--   finish    ONE transaction. Takes the drain's own advisory lock (`cron_try_lock('gt_listings_drain')` is what
--             `gt_ingest_drain_1min` guards itself with, so the drain skips while it is held — it is the table's only
--             writer: checked in pg_proc, routers/broker.py only reads). Then copies everything from
--             `window_from − 7 h` on with ON CONFLICT DO NOTHING: a drained row carries captured_at = fired_at, and a
--             response is drained at most pg_net's 6-hour TTL after it fired, so no row the slices missed can be
--             older than that. Then LOCK TABLE, rename old → `_old`, new → canonical, indexes and the constraint to
--             their canonical names (the weekly REINDEX jobs 655–658 name `idx_gt_ls_event_time` /
--             `idx_gt_ls_captured`; `gt_listings_drain` names the PK columns in its ON CONFLICT), the grants and the
--             comment, the retention policy released (`next_eligible_at` cleared) so the hourly sweep resumes on a
--             heap where a 50 000-row batch is seconds, not 15 minutes.
--   analyze   statistics for the planner; then the cron unschedules itself.
--
-- The old heap is NOT dropped here. It stays as `gotickets_listings_snapshots_old` until the operator has compared
-- the two and applies 20261122030100_gt_snapshots_drop_old.sql (the reclaim: ~130 GB).
--
-- Sizing (from the per-day counts): ~140 M rows kept ≈ 40 GB heap + ~20 GB indexes. The database is 440 GB and
-- the new table exists BESIDE the old one until the drop, so the build needs ~60 GB of free disk. CHECK THE
-- PROJECT'S DISK SIZE ON THE SUPABASE DASHBOARD BEFORE APPLYING. `TRUNCATE ticketsdata_listings_snapshots` (34 GB,
-- 0 rows, also P1) frees headroom first if needed — a separate operator yes.
--
-- Nothing upstream is touched (RULE 2). The drain keeps running between ticks; it is only paused for the minutes
-- of the finish tick, well inside pg_net's 6-hour response TTL.
--
-- Watch: SELECT * FROM v_gt_snapshots_rebuild;   Harness: tests/sql/gt_snapshots_rebuild.
-- Apply: `BEGIN;` / `COMMIT;` stripped (the tool wraps its own); any minute. The cron starts the rebuild at once.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. the new table: same shape, same autovacuum settings, no indexes yet ─────────────────────────
DO $pre$
BEGIN
  IF to_regclass('public.gotickets_listings_snapshots_old') IS NOT NULL THEN
    RAISE EXCEPTION 'gt_snapshots_rebuild: public.gotickets_listings_snapshots_old exists — a previous rebuild has not been dropped (mig 20261122030100)';
  END IF;
END $pre$;

CREATE TABLE IF NOT EXISTS public.gotickets_listings_snapshots_new
  (LIKE public.gotickets_listings_snapshots INCLUDING DEFAULTS INCLUDING STORAGE)
  WITH (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.02);
COMMENT ON TABLE public.gotickets_listings_snapshots_new IS
  'The GoTickets listings firehose being rebuilt to its 15-day window (mig 20261122030000). Filled by gt_snapshots_rebuild_tick(); becomes gotickets_listings_snapshots at the swap. Do not read or write.';
REVOKE ALL ON public.gotickets_listings_snapshots_new FROM PUBLIC, anon, authenticated;

-- ───────────────────────── 2. the state row ─────────────────────────
CREATE TABLE IF NOT EXISTS public.gt_snapshots_rebuild (
  id             int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  phase          text NOT NULL DEFAULT 'init',
  keep_days      int NOT NULL DEFAULT 15,
  cutoff         timestamptz,                                   -- rows older than this are kept only as deal evidence
  window_from    timestamptz,                                   -- the copy's high-water mark (captured_at)
  window_step    interval NOT NULL DEFAULT interval '6 hours',  -- one copy slice
  copy_lag       interval NOT NULL DEFAULT interval '30 minutes', -- the copy phase stops this far behind now()
  late_margin    interval NOT NULL DEFAULT interval '7 hours',  -- pg_net TTL (6 h) + 1: how far back the finish re-reads
  evidence_after bigint NOT NULL DEFAULT 0,                     -- the last spell gt_event_id whose evidence was copied
  evidence_rows  bigint NOT NULL DEFAULT 0,
  copied_rows    bigint NOT NULL DEFAULT 0,
  ticks          int NOT NULL DEFAULT 0,
  started_at     timestamptz NOT NULL DEFAULT now(),
  swapped_at     timestamptz,
  done_at        timestamptz,
  last_error     text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.gt_snapshots_rebuild (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
COMMENT ON TABLE public.gt_snapshots_rebuild IS 'One row: the state of the online rebuild of gotickets_listings_snapshots (mig 20261122030000). Advanced by gt_snapshots_rebuild_tick().';
REVOKE ALL ON public.gt_snapshots_rebuild FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.gt_snapshots_rebuild TO service_role;

-- while the rebuild runs the hourly sweep must not spend its 15 minutes on the old heap (it has deleted nothing since 11-17)
UPDATE public.retention_policy
   SET next_eligible_at = now() + interval '14 days',
       notes = coalesce(notes, '') || ' PARKED 2026-11-22 (mig 20261122030000) while gt_snapshots_rebuild_tick() rebuilds the table; released at the swap.',
       updated_at = now()
 WHERE table_name = 'gotickets_listings_snapshots';

-- ───────────────────────── 3. the tick ─────────────────────────
CREATE OR REPLACE FUNCTION public.gt_snapshots_rebuild_tick(p_seconds integer DEFAULT 480)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  s       public.gt_snapshots_rebuild%ROWTYPE;
  v_t0    timestamptz := clock_timestamp();
  v_from  text;
  v_n     bigint;
  v_rows  bigint := 0;
  v_ev    bigint;
  v_to    timestamptz;
  v_more  boolean := false;
  v_role  text;
  v_err   text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: gt_snapshots_rebuild_tick is service-only' USING ERRCODE = '42501';
  END IF;
  -- one tick at a time (the cron fires every minute; a long tick makes the next ones skip)
  IF NOT pg_try_advisory_xact_lock(hashtext('cron_job:gt_snapshots_rebuild')::bigint) THEN
    RETURN jsonb_build_object('skipped', 'another tick is running');
  END IF;
  SELECT * INTO s FROM public.gt_snapshots_rebuild WHERE id = 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'gt_snapshots_rebuild: no state row'; END IF;
  IF s.phase = 'done' THEN RETURN jsonb_build_object('phase', 'done', 'done_at', s.done_at); END IF;
  v_from := s.phase;
  UPDATE public.gt_snapshots_rebuild SET ticks = ticks + 1, updated_at = now() WHERE id = 1;

  BEGIN
    IF s.phase = 'init' THEN
      -- the policy's window; the cutoff is fixed here so the slices are stable across ticks
      SELECT coalesce(p.keep_days, 15) INTO s.keep_days FROM public.retention_policy p WHERE p.table_name = 'gotickets_listings_snapshots';
      s.keep_days := coalesce(s.keep_days, 15);
      s.cutoff := date_trunc('hour', now()) - make_interval(days => s.keep_days);
      IF to_regclass('public.gotickets_listings_snapshots_new') IS NULL THEN
        RAISE EXCEPTION 'gotickets_listings_snapshots_new does not exist (mig 20261122030000 creates it)';
      END IF;
      UPDATE public.gt_snapshots_rebuild
         SET keep_days = s.keep_days, cutoff = s.cutoff, window_from = s.cutoff, phase = 'evidence', updated_at = now()
       WHERE id = 1;

    ELSIF s.phase = 'evidence' THEN
      -- the keep_where rows under the cutoff: the snapshots of every deal_listing_spell gotickets listing, read per spell
      -- event through the primary key (gt_event_id, captured_at, gt_listing_id)
      FOR v_ev IN
        SELECT DISTINCT d.gt_event_id FROM public.deal_listing_spell d
         WHERE d.source = 'gotickets' AND d.gt_event_id IS NOT NULL AND d.gt_event_id > s.evidence_after
         ORDER BY 1
      LOOP
        IF clock_timestamp() - v_t0 > make_interval(secs => p_seconds) THEN v_more := true; EXIT; END IF;
        INSERT INTO public.gotickets_listings_snapshots_new
        SELECT t.* FROM public.gotickets_listings_snapshots t
         WHERE t.gt_event_id = v_ev AND t.captured_at < s.cutoff
           AND EXISTS (SELECT 1 FROM public.deal_listing_spell d WHERE d.source = 'gotickets' AND d.listing_id = t.gt_listing_id);
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_rows := v_rows + v_n;
        s.evidence_after := v_ev;
      END LOOP;
      UPDATE public.gt_snapshots_rebuild
         SET evidence_after = s.evidence_after, evidence_rows = evidence_rows + v_rows,
             phase = CASE WHEN v_more THEN 'evidence' ELSE 'copy' END, updated_at = now()
       WHERE id = 1;

    ELSIF s.phase = 'copy' THEN
      -- the window, in slices, heap-only (the indexes come after); stops copy_lag behind now()
      LOOP
        EXIT WHEN clock_timestamp() - v_t0 > make_interval(secs => p_seconds);
        v_to := least(s.window_from + s.window_step, now() - s.copy_lag);
        EXIT WHEN v_to <= s.window_from;
        INSERT INTO public.gotickets_listings_snapshots_new
        SELECT t.* FROM public.gotickets_listings_snapshots t
         WHERE t.captured_at >= s.window_from AND t.captured_at < v_to;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_rows := v_rows + v_n;
        s.window_from := v_to;
      END LOOP;
      UPDATE public.gt_snapshots_rebuild
         SET window_from = s.window_from, copied_rows = copied_rows + v_rows,
             phase = CASE WHEN s.window_from >= now() - s.copy_lag THEN 'index_pk' ELSE 'copy' END, updated_at = now()
       WHERE id = 1;

    ELSIF s.phase = 'index_pk' THEN
      IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'gotickets_listings_snapshots_new_pkey') THEN
        ALTER TABLE public.gotickets_listings_snapshots_new
          ADD CONSTRAINT gotickets_listings_snapshots_new_pkey PRIMARY KEY (gt_event_id, captured_at, gt_listing_id);
      END IF;
      UPDATE public.gt_snapshots_rebuild SET phase = 'index_captured', updated_at = now() WHERE id = 1;

    ELSIF s.phase = 'index_captured' THEN
      CREATE INDEX IF NOT EXISTS idx_gt_ls_new_captured ON public.gotickets_listings_snapshots_new USING btree (captured_at);
      UPDATE public.gt_snapshots_rebuild SET phase = 'index_event_time', updated_at = now() WHERE id = 1;

    ELSIF s.phase = 'index_event_time' THEN
      CREATE INDEX IF NOT EXISTS idx_gt_ls_new_event_time ON public.gotickets_listings_snapshots_new USING btree (tevo_event_id, captured_at DESC);
      UPDATE public.gt_snapshots_rebuild SET phase = 'finish', updated_at = now() WHERE id = 1;

    ELSIF s.phase = 'finish' THEN
      -- 1. the drain's own lock: gt_ingest_drain_1min guards itself with cron_try_lock('gt_listings_drain') and skips
      --    while this transaction holds it, so from here to COMMIT nothing writes the old table
      PERFORM pg_advisory_xact_lock(hashtext('cron_job:gt_listings_drain')::bigint);
      -- 2. what the slices could have missed — a row the drain landed after its slice was copied (captured_at =
      --    fired_at, drained within pg_net's 6-hour TTL) — and everything since the last slice
      INSERT INTO public.gotickets_listings_snapshots_new
      SELECT t.* FROM public.gotickets_listings_snapshots t
       WHERE t.captured_at >= s.window_from - s.late_margin
      ON CONFLICT (gt_event_id, captured_at, gt_listing_id) DO NOTHING;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_rows := v_n;
      -- 3. the swap
      LOCK TABLE public.gotickets_listings_snapshots IN ACCESS EXCLUSIVE MODE;
      ALTER TABLE public.gotickets_listings_snapshots RENAME TO gotickets_listings_snapshots_old;
      ALTER TABLE public.gotickets_listings_snapshots_old RENAME CONSTRAINT gotickets_listings_snapshots_pkey TO gotickets_listings_snapshots_old_pkey;
      ALTER INDEX IF EXISTS public.idx_gt_ls_captured RENAME TO idx_gt_ls_captured_old;
      ALTER INDEX IF EXISTS public.idx_gt_ls_event_time RENAME TO idx_gt_ls_event_time_old;
      -- the empty, invalid leftovers of past REINDEX CONCURRENTLY runs (0 bytes each on 2026-11-22)
      DROP INDEX IF EXISTS public.idx_gt_ls_captured_ccnew;
      DROP INDEX IF EXISTS public.idx_gt_ls_event_time_ccnew;
      ALTER TABLE public.gotickets_listings_snapshots_new RENAME TO gotickets_listings_snapshots;
      ALTER TABLE public.gotickets_listings_snapshots RENAME CONSTRAINT gotickets_listings_snapshots_new_pkey TO gotickets_listings_snapshots_pkey;
      ALTER INDEX public.idx_gt_ls_new_captured RENAME TO idx_gt_ls_captured;
      ALTER INDEX public.idx_gt_ls_new_event_time RENAME TO idx_gt_ls_event_time;
      -- the grants the old table had (2026-11-22: service_role all; coworker_readonly, analyst_ro read; nothing for anon / authenticated)
      FOREACH v_role IN ARRAY ARRAY['service_role'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN EXECUTE format('GRANT ALL ON public.gotickets_listings_snapshots TO %I', v_role); END IF;
      END LOOP;
      FOREACH v_role IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN EXECUTE format('GRANT SELECT ON public.gotickets_listings_snapshots TO %I', v_role); END IF;
      END LOOP;
      FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN EXECUTE format('REVOKE ALL ON public.gotickets_listings_snapshots FROM %I', v_role); END IF;
      END LOOP;
      EXECUTE format('COMMENT ON TABLE public.gotickets_listings_snapshots IS %L',
        'GoTickets Pro-API listings firehose. 15d retention (20260804230000) + autovacuum parity with listings_snapshots (20260911235000). Rebuilt online to its window on ' || to_char(now(), 'YYYY-MM-DD') || ' (mig 20261122030000): the 130 GB heap of 300 M rows became the 15 days + deal evidence; retention sweeps it hourly again.');
      EXECUTE format('COMMENT ON TABLE public.gotickets_listings_snapshots_old IS %L',
        'The GoTickets listings heap before the rebuild of ' || to_char(now(), 'YYYY-MM-DD') || ' (mig 20261122030000). Nothing reads or writes it. Dropped by mig 20261122030100 once the operator has compared it with the rebuilt table.');
      -- the sweep works again: a 50 000-row batch on the new heap is seconds
      UPDATE public.retention_policy
         SET next_eligible_at = NULL, clean_runs = 0, last_error = NULL, updated_at = now(),
             notes = coalesce(notes, '') || ' REBUILT ' || to_char(now(), 'YYYY-MM-DD') || ' (mig 20261122030000): the table is its 15-day window + deal evidence again; sweeping resumed.'
       WHERE table_name = 'gotickets_listings_snapshots';
      PERFORM pg_notify('pgrst', 'reload schema');
      UPDATE public.gt_snapshots_rebuild
         SET phase = 'analyze', swapped_at = now(), copied_rows = copied_rows + v_rows, window_from = now(), updated_at = now()
       WHERE id = 1;

    ELSIF s.phase = 'analyze' THEN
      ANALYZE public.gotickets_listings_snapshots;
      IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_snapshots_rebuild_1min') THEN
        PERFORM cron.unschedule('gt_snapshots_rebuild_1min');
      END IF;
      UPDATE public.gt_snapshots_rebuild SET phase = 'done', done_at = now(), updated_at = now() WHERE id = 1;

    ELSE
      RAISE EXCEPTION 'gt_snapshots_rebuild: unknown phase %', s.phase;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- the phase's work is rolled back (a sub-transaction); the next tick retries it
    v_err := left(SQLERRM, 500);
    UPDATE public.gt_snapshots_rebuild SET last_error = v_err, updated_at = now() WHERE id = 1;
    RETURN jsonb_build_object('phase', v_from, 'error', v_err, 'ms', (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int);
  END;

  UPDATE public.gt_snapshots_rebuild SET last_error = NULL WHERE id = 1 AND last_error IS NOT NULL;
  SELECT * INTO s FROM public.gt_snapshots_rebuild WHERE id = 1;
  RETURN jsonb_build_object('from', v_from, 'phase', s.phase, 'rows', v_rows, 'window_from', s.window_from,
                            'evidence_rows', s.evidence_rows, 'copied_rows', s.copied_rows,
                            'ms', (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int);
END $function$;
COMMENT ON FUNCTION public.gt_snapshots_rebuild_tick(integer) IS
  'One bounded step of the online rebuild of gotickets_listings_snapshots (mig 20261122030000): init → evidence → copy → index_pk → index_captured → index_event_time → finish (catch-up + swap, one transaction, the drain paused by its own advisory lock) → analyze → done. Service-only; one tick at a time.';
REVOKE ALL ON FUNCTION public.gt_snapshots_rebuild_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gt_snapshots_rebuild_tick(integer) TO service_role;

-- ───────────────────────── 4. the watch view ─────────────────────────
CREATE OR REPLACE VIEW public.v_gt_snapshots_rebuild AS
SELECT s.phase, s.cutoff, s.window_from, s.evidence_rows, s.copied_rows, s.ticks, s.started_at, s.swapped_at, s.done_at,
       s.last_error, s.updated_at,
       -- to_regclass(text) is resolved when the view is read, not when it is created: after the swap the names point at
       -- the new table, and a missing table is NULL rather than an error
       pg_size_pretty(pg_total_relation_size(to_regclass('public.gotickets_listings_snapshots'))) AS live_size,
       pg_size_pretty(pg_total_relation_size(to_regclass('public.gotickets_listings_snapshots_new'))) AS new_size,
       pg_size_pretty(pg_total_relation_size(to_regclass('public.gotickets_listings_snapshots_old'))) AS old_size,
       EXISTS (SELECT 1 FROM cron.job j WHERE j.jobname = 'gt_snapshots_rebuild_1min') AS cron_scheduled
  FROM public.gt_snapshots_rebuild s;
COMMENT ON VIEW public.v_gt_snapshots_rebuild IS 'The rebuild of gotickets_listings_snapshots at a glance (mig 20261122030000): phase, high-water mark, rows, sizes of the live / new / old tables, whether the cron is still scheduled.';
REVOKE ALL ON public.v_gt_snapshots_rebuild FROM anon, authenticated;
GRANT SELECT ON public.v_gt_snapshots_rebuild TO service_role;

-- ───────────────────────── 5. the cron: every minute until the tick unschedules it ─────────────────────────
-- A multi-statement command runs as one implicit transaction (mig 20260916130000), so the SETs apply to the tick:
-- 3 h for an index build on ~140 M rows, 150 s to wait for the drain's lock at the finish.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_snapshots_rebuild_1min') THEN PERFORM cron.unschedule('gt_snapshots_rebuild_1min'); END IF;
  PERFORM cron.schedule('gt_snapshots_rebuild_1min', '* * * * *',
                        $j$SET statement_timeout = '3h'; SET lock_timeout = '150s'; SELECT public.gt_snapshots_rebuild_tick(480);$j$);
END
$cron$;

COMMIT;
