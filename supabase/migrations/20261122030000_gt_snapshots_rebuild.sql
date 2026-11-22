-- Migration 20261122030000 · level:ops · lane:A1 (data plane — retention engine, KANBAN A1-DATA-1 P1+P3 / A1-DB-7) · writes:gotickets_listings_snapshots_new(new, PARTITIONED BY DAY, becomes gotickets_listings_snapshots at the swap),gotickets_listings_snapshots_default+gotickets_listings_snapshots_pYYYYMMDD(partitions),gt_snapshots_rebuild(new state row),gt_snapshots_rebuild_tick()(new),gt_snapshots_partition_ensure()(new),gt_snapshots_partition_tick()(new),gt_snapshots_size()(new),v_gt_snapshots_rebuild(new),cron:gt_snapshots_rebuild_1min(new, removes itself),cron:gt_snapshots_partition_hourly(scheduled at the swap),retention_policy(1 row: parked for the rebuild, DISABLED at the swap — retention becomes a partition drop),retention_run_log(a row per dropped partition) · reads:gotickets_listings_snapshots,deal_listing_spell,retention_policy,cron.job · pre:20261027210000
--
-- GOTICKETS LISTINGS FIREHOSE — REBUILT ONLINE TO ITS 15-DAY WINDOW AS A TABLE PARTITIONED BY DAY, THEN SWAPPED IN.
--
-- Operator 2026-11-22 ("Do it" — the CTAS swap, A1-DATA-1 phase P1; then "Also partition" — phase P3 for this table).
-- The facts on 2026-11-22 02:30Z:
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
-- A DELETE can never keep up with 9 M rows a day on this heap, reclaims no space, and re-bloats whatever it touches.
-- So: the rows worth keeping are copied into a fresh table RANGE-partitioned by UTC day of captured_at, its indexes
-- are built once, it is renamed into place, and from then on retention is `DROP` of the day partitions older than
-- the window — instant, no dead tuples, no VACUUM debt (the partition blueprint 20260619220000 argued this for
-- listings_snapshots; this is its first application). The deal evidence that must outlive the window (the policy's
-- keep_where: every snapshot of a gt_listing_id in deal_listing_spell, operator 2026-09-11) lives in the table's
-- DEFAULT partition — the one place a row can go whose day has no partition — and a day partition is dropped only
-- after its evidence rows were moved there.
--
-- The 900 s ceiling and the MCP tool's own limits mean this cannot be one statement, so it is a small state machine
-- that a one-minute cron advances, each tick bounded:
--
--   init ──▶ evidence ──▶ copy ──▶ index_pk ──▶ index_captured ──▶ index_event_time ──▶ finish ──▶ analyze ──▶ done
--
--   init      the cutoff (now − 15 d, fixed here); the day partitions from the cutoff's day to today + 7.
--   evidence  the keep_where rows older than the cutoff, read per spell event through the primary key (gt_event_id
--             leads it), so the 87 GB heap is never scanned. They land in the DEFAULT partition.
--   copy      the window [cutoff, now − 30 min) in 6-hour slices through `idx_gt_ls_captured`, heap-only (no
--             indexes on the new table yet), as many slices as fit a tick.
--   index_*   the primary key and the two indexes the readers use, built once on the finished copy (on the parent:
--             one statement builds every partition's), one per tick — plain builds; nothing reads the new table.
--   finish    ONE transaction. Takes the drain's own advisory lock (`cron_try_lock('gt_listings_drain')` is what
--             `gt_ingest_drain_1min` guards itself with, so the drain skips while it is held — it is the table's only
--             writer: checked in pg_proc; routers/broker.py only reads). Copies everything from `window_from − 7 h`
--             on with ON CONFLICT DO NOTHING: a drained row carries captured_at = fired_at and a response is drained
--             at most pg_net's 6-hour TTL after it fired, so nothing the slices missed can be older. Then LOCK TABLE,
--             rename old → `_old`, new → canonical, the parent's indexes and constraint to their canonical names (the
--             weekly REINDEX jobs 655–658 name `idx_gt_ls_event_time` / `idx_gt_ls_captured`; `gt_listings_drain`
--             names the PK columns in its ON CONFLICT — valid on a partitioned table because the key includes the
--             partition column), the grants and the comment; the retention_policy row is DISABLED (retention_tick's
--             ctid-batched DELETE must never run on a partitioned table — a ctid is only unique within one
--             partition) and `gt_snapshots_partition_hourly` is scheduled.
--   analyze   statistics for the planner; then the cron unschedules itself.
--
-- Retention from the swap on: `gt_snapshots_partition_tick()` (cron :07 hourly) creates the day partitions up to
-- today + 3 (a row for a day without a partition goes to DEFAULT and is moved into the day's partition when it is
-- created), and for every day partition whose upper bound is older than keep_days: DETACH, move its keep_where rows
-- into the parent (= DEFAULT now), DROP, a `retention_run_log` row. keep_days and keep_where stay on the (disabled)
-- retention_policy row — one place for the window and the evidence rule.
--
-- The old heap is NOT dropped here. It stays as `gotickets_listings_snapshots_old` until the operator has compared
-- the two and applies 20261122030100_gt_snapshots_drop_old.sql (the reclaim: ~130 GB).
--
-- Sizing (from the per-day counts): ~140 M rows kept ≈ 40 GB heap + ~20 GB indexes. The database is 440 GB and the
-- new table exists BESIDE the old one until the drop, so the build needs ~60 GB of free disk. CHECK THE PROJECT'S
-- DISK SIZE ON THE SUPABASE DASHBOARD BEFORE APPLYING. `TRUNCATE ticketsdata_listings_snapshots` (34 GB, 0 rows,
-- also P1) frees headroom first if needed — a separate operator yes.
--
-- Nothing upstream is touched (RULE 2). The drain keeps running between ticks; it is only paused for the minutes
-- of the finish tick, well inside pg_net's 6-hour response TTL.
--
-- Watch: SELECT * FROM v_gt_snapshots_rebuild;   Harness: tests/sql/gt_snapshots_rebuild.
-- Apply: `BEGIN;` / `COMMIT;` stripped (the tool wraps its own); any minute. The cron starts the rebuild at once.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. the new table: same shape, partitioned by day, no indexes yet ─────────────────────────
DO $pre$
BEGIN
  IF to_regclass('public.gotickets_listings_snapshots_old') IS NOT NULL THEN
    RAISE EXCEPTION 'gt_snapshots_rebuild: public.gotickets_listings_snapshots_old exists — a previous rebuild has not been dropped (mig 20261122030100)';
  END IF;
END $pre$;

CREATE TABLE IF NOT EXISTS public.gotickets_listings_snapshots_new
  (LIKE public.gotickets_listings_snapshots INCLUDING DEFAULTS INCLUDING STORAGE)
  PARTITION BY RANGE (captured_at);
COMMENT ON TABLE public.gotickets_listings_snapshots_new IS
  'The GoTickets listings firehose being rebuilt to its 15-day window, partitioned by UTC day (mig 20261122030000). Filled by gt_snapshots_rebuild_tick(); becomes gotickets_listings_snapshots at the swap. Do not read or write.';
REVOKE ALL ON public.gotickets_listings_snapshots_new FROM PUBLIC, anon, authenticated;

-- the DEFAULT partition: the deal evidence (rows whose day has no partition any more) and any row that arrives for a
-- day whose partition does not exist yet (moved into it by gt_snapshots_partition_ensure). Named for the canonical
-- table from the start — partitions keep their names through the parent's rename.
CREATE TABLE IF NOT EXISTS public.gotickets_listings_snapshots_default
  PARTITION OF public.gotickets_listings_snapshots_new DEFAULT
  WITH (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.02);
COMMENT ON TABLE public.gotickets_listings_snapshots_default IS
  'gotickets_listings_snapshots DEFAULT partition (mig 20261122030000): the deal evidence (keep_where rows whose day partition was dropped) and rows for days without a partition yet.';

-- ───────────────────────── 2. partitions: one UTC day each ─────────────────────────
-- Creates the day partition if missing: a standalone table of the parent''s shape, any rows for that day the DEFAULT
-- partition caught meanwhile moved into it, a CHECK that lets ATTACH skip scanning it, then ATTACH (SHARE UPDATE
-- EXCLUSIVE on the parent — gentler than CREATE TABLE … PARTITION OF). Returns the partition name.
CREATE OR REPLACE FUNCTION public.gt_snapshots_partition_ensure(p_parent regclass, p_day date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_name text := 'gotickets_listings_snapshots_p' || to_char(p_day, 'YYYYMMDD');
  v_lo   timestamptz := (p_day::timestamp AT TIME ZONE 'UTC');
  v_hi   timestamptz := ((p_day + 1)::timestamp AT TIME ZONE 'UTC');
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: gt_snapshots_partition_ensure is service-only' USING ERRCODE = '42501';
  END IF;
  IF to_regclass('public.' || v_name) IS NOT NULL THEN RETURN v_name; END IF;
  EXECUTE format('CREATE TABLE public.%I (LIKE %s INCLUDING DEFAULTS INCLUDING STORAGE) WITH (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_insert_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.02)',
                 v_name, p_parent::text);
  IF to_regclass('public.gotickets_listings_snapshots_default') IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = 'public.gotickets_listings_snapshots_default'::regclass AND inhparent = p_parent) THEN
    EXECUTE format('WITH moved AS (DELETE FROM public.gotickets_listings_snapshots_default d WHERE d.captured_at >= %L AND d.captured_at < %L RETURNING d.*) INSERT INTO public.%I SELECT * FROM moved',
                   v_lo, v_hi, v_name);
  END IF;
  EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (captured_at >= %L AND captured_at < %L)', v_name, v_name || '_day', v_lo, v_hi);
  EXECUTE format('ALTER TABLE %s ATTACH PARTITION public.%I FOR VALUES FROM (%L) TO (%L)', p_parent::text, v_name, v_lo, v_hi);
  EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', v_name, v_name || '_day');
  RETURN v_name;
END $function$;
COMMENT ON FUNCTION public.gt_snapshots_partition_ensure(regclass, date) IS 'Creates (if missing) and attaches the UTC-day partition of the GoTickets listings firehose for p_day, moving the day''s rows out of the DEFAULT partition first (mig 20261122030000). Service-only.';
REVOKE ALL ON FUNCTION public.gt_snapshots_partition_ensure(regclass, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gt_snapshots_partition_ensure(regclass, date) TO service_role;

-- the size of a table with its partitions (pg_total_relation_size of a partitioned parent is its own, empty, relation)
CREATE OR REPLACE FUNCTION public.gt_snapshots_size(p_table text)
 RETURNS bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN to_regclass(p_table) IS NULL THEN NULL
         ELSE pg_total_relation_size(to_regclass(p_table))
              + coalesce((SELECT sum(pg_total_relation_size(i.inhrelid)) FROM pg_inherits i WHERE i.inhparent = to_regclass(p_table)), 0) END::bigint
$function$;

-- ───────────────────────── 3. the state row ─────────────────────────
CREATE TABLE IF NOT EXISTS public.gt_snapshots_rebuild (
  id             int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  phase          text NOT NULL DEFAULT 'init',
  keep_days      int NOT NULL DEFAULT 15,
  cutoff         timestamptz,                                     -- rows older than this are kept only as deal evidence
  window_from    timestamptz,                                     -- the copy's high-water mark (captured_at)
  window_step    interval NOT NULL DEFAULT interval '6 hours',    -- one copy slice
  copy_lag       interval NOT NULL DEFAULT interval '30 minutes', -- the copy phase stops this far behind now()
  late_margin    interval NOT NULL DEFAULT interval '7 hours',    -- pg_net TTL (6 h) + 1: how far back the finish re-reads
  days_ahead     int NOT NULL DEFAULT 3,                          -- partitions kept ready past today (the build creates 7)
  evidence_after bigint NOT NULL DEFAULT 0,                       -- the last spell gt_event_id whose evidence was copied
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
COMMENT ON TABLE public.gt_snapshots_rebuild IS 'One row: the state of the online rebuild of gotickets_listings_snapshots (mig 20261122030000). Advanced by gt_snapshots_rebuild_tick(); days_ahead / keep-window settings read by gt_snapshots_partition_tick().';
REVOKE ALL ON public.gt_snapshots_rebuild FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.gt_snapshots_rebuild TO service_role;

-- while the rebuild runs the hourly sweep must not spend its 15 minutes on the old heap (it has deleted nothing since 11-17)
UPDATE public.retention_policy
   SET next_eligible_at = now() + interval '14 days',
       notes = coalesce(notes, '') || ' PARKED 2026-11-22 (mig 20261122030000) while gt_snapshots_rebuild_tick() rebuilds the table; disabled at the swap — retention becomes a partition drop.',
       updated_at = now()
 WHERE table_name = 'gotickets_listings_snapshots';

-- ───────────────────────── 4. the rebuild tick ─────────────────────────
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
  v_day   date;
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
      -- the day partitions of the window, with a week ahead for the build
      FOR v_day IN SELECT d::date FROM generate_series(s.cutoff::date, current_date + 7, interval '1 day') d LOOP
        PERFORM public.gt_snapshots_partition_ensure('public.gotickets_listings_snapshots_new'::regclass, v_day);
      END LOOP;
      UPDATE public.gt_snapshots_rebuild
         SET keep_days = s.keep_days, cutoff = s.cutoff, window_from = s.cutoff, phase = 'evidence', updated_at = now()
       WHERE id = 1;

    ELSIF s.phase = 'evidence' THEN
      -- the keep_where rows under the cutoff: the snapshots of every deal_listing_spell gotickets listing, read per spell
      -- event through the primary key (gt_event_id, captured_at, gt_listing_id); they route to the DEFAULT partition
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
      -- on the parent: one statement builds every partition's index (the key includes the partition column)
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
      -- the days the build may have outrun
      FOR v_day IN SELECT d::date FROM generate_series(current_date, current_date + s.days_ahead, interval '1 day') d LOOP
        PERFORM public.gt_snapshots_partition_ensure('public.gotickets_listings_snapshots_new'::regclass, v_day);
      END LOOP;
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
      -- the grants the old table had (2026-11-22: service_role all; coworker_readonly, analyst_ro read; nothing for anon /
      -- authenticated); a grant on the parent covers its partitions for queries through the parent
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
        'GoTickets Pro-API listings firehose, partitioned by UTC day of captured_at (one gotickets_listings_snapshots_pYYYYMMDD a day; the DEFAULT partition holds the deal evidence). Rebuilt online on ' || to_char(now(), 'YYYY-MM-DD') || ' (mig 20261122030000) from the 130 GB / 300 M-row heap. Retention = gt_snapshots_partition_tick() dropping days older than retention_policy.keep_days after moving their keep_where rows to the DEFAULT partition; the retention_policy row is disabled on purpose (a ctid DELETE must not run on a partitioned table).');
      EXECUTE format('COMMENT ON TABLE public.gotickets_listings_snapshots_old IS %L',
        'The GoTickets listings heap before the rebuild of ' || to_char(now(), 'YYYY-MM-DD') || ' (mig 20261122030000). Nothing reads or writes it. Dropped by mig 20261122030100 once the operator has compared it with the rebuilt table.');
      -- retention is a partition drop from here: the policy row keeps the window (keep_days) and the evidence rule
      -- (keep_where) for gt_snapshots_partition_tick(), but retention_tick() must not touch a partitioned table
      UPDATE public.retention_policy
         SET enabled = false, next_eligible_at = NULL, clean_runs = 0, last_error = NULL, updated_at = now(),
             notes = coalesce(notes, '') || ' REBUILT ' || to_char(now(), 'YYYY-MM-DD') || ' (mig 20261122030000) as a table partitioned by UTC day; DISABLED here on purpose: retention is gt_snapshots_partition_tick() (cron gt_snapshots_partition_hourly) dropping day partitions older than keep_days after moving their keep_where rows to the DEFAULT partition. keep_days / keep_where on this row are still the settings it reads.'
       WHERE table_name = 'gotickets_listings_snapshots';
      IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'gt_snapshots_partition_hourly') THEN
        PERFORM cron.schedule('gt_snapshots_partition_hourly', '7 * * * *',
          $j$SET statement_timeout = '600s'; SET lock_timeout = '30s'; DO $b$ BEGIN IF NOT public.cron_should_fire('gt_snapshots_partition_hourly') THEN RETURN; END IF; PERFORM public.gt_snapshots_partition_tick(240); END $b$;$j$);
      END IF;
      PERFORM pg_notify('pgrst', 'reload schema');
      UPDATE public.gt_snapshots_rebuild
         SET phase = 'analyze', swapped_at = now(), copied_rows = copied_rows + v_rows, window_from = now(), updated_at = now()
       WHERE id = 1;

    ELSIF s.phase = 'analyze' THEN
      ANALYZE public.gotickets_listings_snapshots;   -- a partitioned table: the partitions too
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
  'One bounded step of the online rebuild of gotickets_listings_snapshots into a day-partitioned table (mig 20261122030000): init → evidence → copy → index_pk → index_captured → index_event_time → finish (catch-up + swap, one transaction, the drain paused by its own advisory lock) → analyze → done. Service-only; one tick at a time.';
REVOKE ALL ON FUNCTION public.gt_snapshots_rebuild_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gt_snapshots_rebuild_tick(integer) TO service_role;

-- ───────────────────────── 5. retention from the swap on: days ahead, aged days dropped ─────────────────────────
CREATE OR REPLACE FUNCTION public.gt_snapshots_partition_tick(p_seconds integer DEFAULT 240)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_t0       timestamptz := clock_timestamp();
  v_parent   regclass := to_regclass('public.gotickets_listings_snapshots');
  v_keep     int;
  v_where    text;
  v_ahead    int;
  v_day      date;
  v_created  text[] := '{}';
  v_dropped  text[] := '{}';
  v_p        record;
  v_rows     bigint;
  v_kept     bigint;
  v_total    bigint := 0;
  v_t1       timestamptz;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: gt_snapshots_partition_tick is service-only' USING ERRCODE = '42501';
  END IF;
  IF NOT pg_try_advisory_xact_lock(hashtext('cron_job:gt_snapshots_partition')::bigint) THEN
    RETURN jsonb_build_object('skipped', 'another tick is running');
  END IF;
  -- before the swap the live table is the old heap: nothing to do
  IF v_parent IS NULL OR (SELECT relkind FROM pg_class WHERE oid = v_parent) <> 'p' THEN
    RETURN jsonb_build_object('skipped', 'gotickets_listings_snapshots is not partitioned');
  END IF;
  SELECT coalesce(keep_days, 15), keep_where INTO v_keep, v_where FROM public.retention_policy WHERE table_name = 'gotickets_listings_snapshots';
  v_keep := coalesce(v_keep, 15);
  SELECT coalesce(days_ahead, 3) INTO v_ahead FROM public.gt_snapshots_rebuild WHERE id = 1;
  v_ahead := coalesce(v_ahead, 3);

  -- 1. the days ahead (yesterday too, for a drain that lands a late row)
  FOR v_day IN SELECT d::date FROM generate_series(current_date - 1, current_date + v_ahead, interval '1 day') d LOOP
    IF to_regclass('public.gotickets_listings_snapshots_p' || to_char(v_day, 'YYYYMMDD')) IS NULL THEN
      v_created := v_created || public.gt_snapshots_partition_ensure(v_parent, v_day);
    END IF;
  END LOOP;

  -- 2. the day partitions whose whole day is older than the window, oldest first: detach, keep the evidence, drop
  FOR v_p IN
    SELECT c.oid, c.relname,
           substring(pg_get_expr(c.relpartbound, c.oid) FROM $re$TO \('([^']+)'\)$re$)::timestamptz AS hi
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = v_parent AND pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT'
     ORDER BY 3
  LOOP
    EXIT WHEN v_p.hi > now() - make_interval(days => v_keep);
    EXIT WHEN clock_timestamp() - v_t0 > make_interval(secs => p_seconds);
    v_t1 := clock_timestamp();
    EXECUTE format('ALTER TABLE %s DETACH PARTITION public.%I', v_parent::text, v_p.relname);
    EXECUTE format('SELECT count(*) FROM public.%I', v_p.relname) INTO v_rows;
    v_kept := 0;
    IF coalesce(btrim(v_where), '') <> '' THEN
      -- the policy's own keep_where (alias t), the rows routed into the DEFAULT partition now that the day has none
      EXECUTE format('INSERT INTO %s SELECT t.* FROM public.%I t WHERE %s ON CONFLICT (gt_event_id, captured_at, gt_listing_id) DO NOTHING',
                     v_parent::text, v_p.relname, v_where);
      GET DIAGNOSTICS v_kept = ROW_COUNT;
    END IF;
    EXECUTE format('DROP TABLE public.%I', v_p.relname);
    INSERT INTO public.retention_run_log (table_name, cutoff, deleted, duration_ms, note)
    VALUES ('gotickets_listings_snapshots', now() - make_interval(days => v_keep), v_rows - v_kept,
            (extract(epoch FROM clock_timestamp() - v_t1) * 1000)::int,
            format('dropped partition %s (%s rows); %s deal-evidence rows kept in the DEFAULT partition', v_p.relname, v_rows, v_kept));
    v_total := v_total + v_rows - v_kept;
    v_dropped := v_dropped || v_p.relname;
  END LOOP;
  IF cardinality(v_dropped) > 0 THEN
    UPDATE public.retention_policy
       SET last_run_at = now(), last_deleted = v_total, total_deleted = total_deleted + v_total, updated_at = now()
     WHERE table_name = 'gotickets_listings_snapshots';
  END IF;
  RETURN jsonb_build_object('created', to_jsonb(v_created), 'dropped', to_jsonb(v_dropped), 'deleted', v_total,
                            'ms', (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int);
END $function$;
COMMENT ON FUNCTION public.gt_snapshots_partition_tick(integer) IS
  'Retention of the day-partitioned gotickets_listings_snapshots (mig 20261122030000): creates the day partitions up to today + gt_snapshots_rebuild.days_ahead, and for each day partition older than retention_policy.keep_days: DETACH, move its keep_where rows (the policy''s own predicate) into the DEFAULT partition, DROP, one retention_run_log row. Hourly (cron gt_snapshots_partition_hourly, scheduled at the swap). Service-only.';
REVOKE ALL ON FUNCTION public.gt_snapshots_partition_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gt_snapshots_partition_tick(integer) TO service_role;

-- ───────────────────────── 6. the watch view ─────────────────────────
CREATE OR REPLACE VIEW public.v_gt_snapshots_rebuild AS
SELECT s.phase, s.cutoff, s.window_from, s.evidence_rows, s.copied_rows, s.ticks, s.started_at, s.swapped_at, s.done_at,
       s.last_error, s.updated_at,
       -- names resolved when the view is read (to_regclass is stable, not folded at creation): after the swap they point
       -- at the new table; a missing table is NULL
       pg_size_pretty(public.gt_snapshots_size('public.gotickets_listings_snapshots')) AS live_size,
       pg_size_pretty(public.gt_snapshots_size('public.gotickets_listings_snapshots_new')) AS new_size,
       pg_size_pretty(public.gt_snapshots_size('public.gotickets_listings_snapshots_old')) AS old_size,
       (SELECT count(*) FROM pg_inherits i WHERE i.inhparent = coalesce(to_regclass('public.gotickets_listings_snapshots_new'), to_regclass('public.gotickets_listings_snapshots'))
          AND pg_get_expr((SELECT relpartbound FROM pg_class WHERE oid = i.inhrelid), i.inhrelid) <> 'DEFAULT') AS day_partitions,
       EXISTS (SELECT 1 FROM cron.job j WHERE j.jobname = 'gt_snapshots_rebuild_1min') AS rebuild_cron,
       EXISTS (SELECT 1 FROM cron.job j WHERE j.jobname = 'gt_snapshots_partition_hourly') AS partition_cron
  FROM public.gt_snapshots_rebuild s;
COMMENT ON VIEW public.v_gt_snapshots_rebuild IS 'The rebuild of gotickets_listings_snapshots at a glance (mig 20261122030000): phase, high-water mark, rows, sizes of the live / new / old tables (partitions included), day partitions, which crons are scheduled.';
REVOKE ALL ON public.v_gt_snapshots_rebuild FROM anon, authenticated;
GRANT SELECT ON public.v_gt_snapshots_rebuild TO service_role;

-- ───────────────────────── 7. the cron: every minute until the tick unschedules it ─────────────────────────
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
