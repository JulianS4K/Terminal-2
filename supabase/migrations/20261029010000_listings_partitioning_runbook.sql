-- Migration 20261029010000 · level:ops · lane:A1 (data plane — retention) · writes:_partition_lock_down()(new),partition_prepare()(new),partition_ensure_days()(new),partition_cutover()(new),partition_shrink_old()(new),partition_maintain()(new) · reads:pg_catalog,retention_policy · pre:20261027210000
--
-- ============================================================================
-- Daily range partitions for the two listing firehoses — the functions only.
-- Applying this migration changes NO table: every step is an explicit call (runbook below).
-- Supersedes the 20260619220000 BLUEPRINT (monthly, listings_snapshots only, no view rebind,
-- no evidence keep).
--
-- WHY (A1-DATA-1 / A1-DB-25, measured 2026-10-27/28): listings_snapshots (EVO, 67 GB) and
-- gotickets_listings_snapshots (GT, 131 GB) each take ~9-10 M rows/day since the pins resumed on
-- 10-23. retention_tick deletes ~135 rows/s on their bloated heaps, ~1.5 M/day at its budget: from
-- ~11-07, when the 10-23 rows pass the 15-day window, both tables grow without bound. With day
-- partitions, retention drops (or shrinks) a whole day: no row deletes, no dead tuples, no vacuum
-- debt — and the old heaps go away entirely once they age out.
--
-- DESIGN
--   * The existing table becomes the first partition, <t>_legacy, FOR VALUES FROM (MINVALUE) TO
--     (cutover), with no copy: a pre-validated CHECK (captured_at < cutover) lets ATTACH skip the
--     scan; its indexes are reused (the parent's are built from the same definitions) and so are
--     its foreign keys (an equivalent constraint on a partition is attached, not re-validated).
--   * Day partitions (UTC) from the cutover forward, plus a DEFAULT partition so an out-of-range
--     row never fails an insert (partition_maintain warns when the default holds rows).
--   * Views bind to the table's OID, so every view / materialized view on the old table is
--     re-created from its own definition after the swap (captured BEFORE the rename, so the text
--     still names the canonical table). Grants are copied from the old table; RLS stays enabled.
--   * Retention keeps retention_policy.keep_where rows (flagged deals' evidence): a day older than
--     keep_days is copied down to just those rows in a "<part>_k" table, which is swapped in for the
--     day (DETACH + ATTACH), and the full day is dropped. No keep_where: the day is dropped.
--   * Writers (EVO collect-listings via PostgREST, GT gt_listings_drain) insert by name, so they
--     write to the new parent unchanged. They are paused for the swap only.
--
-- RUNBOOK (per table; EVO first, GT the next day). CUTOVER = a whole hour a few hours ahead, UTC.
--   STAGE 1 · online (one scan of the table; reads/writes continue):
--       SELECT public.partition_prepare('listings_snapshots', 'CUTOVER');
--   STAGE 2 · window, < 1 min, before CUTOVER:
--       pause the writer cron(s) (cron.alter_job(<id>, active := false)), wait ~2 min, then
--       SELECT public.partition_cutover('listings_snapshots', 'CUTOVER');
--       resume the writer cron(s).
--   STAGE 3 · right after:
--       REFRESH MATERIALIZED VIEW public.v_dashboard_writes_24h;   -- EVO only; re-created WITH NO DATA
--       UPDATE public.retention_policy SET enabled = false WHERE table_name = '<t>';
--       schedule partition_maintain('<t>') daily (it pre-creates days and shrinks old ones).
--   LEGACY · once cutover + keep_days has passed (long scan, run from the SQL editor):
--       SELECT public.partition_shrink_old('<t>', true);
--   ROLLBACK: partition_cutover is one transaction — if it errors, nothing changed.
-- ============================================================================

-- STAGE 1 -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partition_prepare(p_table text, p_cutover timestamptz)
RETURNS text LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_ck text := p_table || '_hist_ck';
BEGIN
  IF p_cutover <= now() THEN
    RAISE EXCEPTION 'cutover % must be in the future', p_cutover;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_partitioned_table WHERE partrelid = format('public.%I', p_table)::regclass) THEN
    RAISE EXCEPTION '% is already partitioned', p_table;
  END IF;
  EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT IF EXISTS %I', p_table, v_ck);
  EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (captured_at < %L::timestamptz) NOT VALID',
                 p_table, v_ck, p_cutover);
  EXECUTE format('ALTER TABLE public.%I VALIDATE CONSTRAINT %I', p_table, v_ck);
  EXECUTE format('COMMENT ON CONSTRAINT %I ON public.%I IS %L', v_ck, p_table, p_cutover::text);
  RETURN format('%s: rows before %s validated; run partition_cutover before then', p_table, p_cutover);
END $$;

-- partition lock-down -------------------------------------------------------
-- Supabase's default privileges grant anon/authenticated ALL on every new public table, and
-- PostgREST exposes partitions as tables of their own. Reads through the parent never check a
-- partition's grants, so every partition gets RLS on and no API-role grants.
CREATE OR REPLACE FUNCTION public._partition_lock_down(p_name text)
RETURNS void LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', p_name);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', p_name);
END $$;

-- day partitions ------------------------------------------------------------
-- Creates the missing UTC-day partitions from p_from up to p_days after today. A day already
-- covered (by name, or shrunk to <name>_k) is skipped; a day the DEFAULT partition already holds
-- rows for cannot be created and is reported, not raised.
CREATE OR REPLACE FUNCTION public.partition_ensure_days(p_table text, p_from timestamptz, p_days integer DEFAULT 14)
RETURNS integer LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_n    int := 0;
  v_lo   timestamptz := p_from;
  v_hi   timestamptz;
  v_end  timestamptz := (date_trunc('day', now() AT TIME ZONE 'UTC') + make_interval(days => p_days)) AT TIME ZONE 'UTC';
  v_name text;
BEGIN
  WHILE v_lo < v_end LOOP
    v_hi   := (date_trunc('day', v_lo AT TIME ZONE 'UTC') + interval '1 day') AT TIME ZONE 'UTC';
    v_name := format('%s_d%s', p_table, to_char(v_lo AT TIME ZONE 'UTC', 'YYYYMMDD'));
    IF to_regclass('public.' || v_name) IS NULL AND to_regclass('public.' || v_name || '_k') IS NULL THEN
      BEGIN
        EXECUTE format('CREATE TABLE public.%I PARTITION OF public.%I FOR VALUES FROM (%L) TO (%L)',
                       v_name, p_table, v_lo, v_hi);
        PERFORM public._partition_lock_down(v_name);
        v_n := v_n + 1;
      EXCEPTION WHEN invalid_object_definition OR check_violation THEN
        RAISE WARNING 'partition_ensure_days: % not created: %', v_name, SQLERRM;
      END;
    END IF;
    v_lo := v_hi;
  END LOOP;
  RETURN v_n;
END $$;

-- STAGE 2 -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partition_cutover(p_table text, p_cutover timestamptz, p_days_ahead integer DEFAULT 14)
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_old    regclass := format('public.%I', p_table)::regclass;
  v_legacy text := p_table || '_legacy';
  v_ck     text := p_table || '_hist_ck';
  v_valid  boolean;
  v_cut    text;
  v_pk     record;
  r        record;
  d        text;
  v_views  jsonb;
  v_fks    jsonb;
  v_idx    jsonb;
  v_acl    jsonb;
  v_days   int;
BEGIN
  -- the prepared CHECK must be validated and match this cutover
  SELECT c.convalidated, obj_description(c.oid, 'pg_constraint')
    INTO v_valid, v_cut FROM pg_constraint c WHERE c.conrelid = v_old AND c.conname = v_ck;
  IF v_valid IS NOT TRUE THEN
    RAISE EXCEPTION 'run partition_prepare(%, %) first', p_table, p_cutover;
  END IF;
  IF v_cut::timestamptz IS DISTINCT FROM p_cutover THEN
    RAISE EXCEPTION 'prepared for cutover %, not %', v_cut, p_cutover;
  END IF;
  IF now() >= p_cutover THEN
    RAISE EXCEPTION 'cutover % has passed: newer rows would fail the CHECK; prepare again', p_cutover;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = v_old) THEN
    RAISE EXCEPTION '% has RLS policies: copy them by hand first', p_table;
  END IF;
  EXECUTE format('LOCK TABLE public.%I IN ACCESS EXCLUSIVE MODE', p_table);

  -- 1. capture everything bound to the old table, before anything is renamed
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'name', v.relname, 'kind', v.relkind, 'def', pg_get_viewdef(v.oid),
           'opts', coalesce(array_to_string(v.reloptions, ', '), ''),
           'owner', pg_get_userbyid(v.relowner),
           'acl', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                     'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END,
                     'priv', a.privilege_type)), '[]')
                     FROM aclexplode(v.relacl) a),
           'idx', (SELECT coalesce(jsonb_agg(pg_get_indexdef(i.indexrelid)), '[]') FROM pg_index i WHERE i.indrelid = v.oid),
           'comment', obj_description(v.oid, 'pg_class'))), '[]')
    INTO v_views
    FROM (SELECT DISTINCT dc.oid, dc.relname, dc.relkind, dc.reloptions, dc.relacl, dc.relowner
            FROM pg_depend dp
            JOIN pg_rewrite rw ON rw.oid = dp.objid AND dp.classid = 'pg_rewrite'::regclass
            JOIN pg_class dc ON dc.oid = rw.ev_class
           WHERE dp.refobjid = v_old AND dc.oid <> v_old AND dc.relkind IN ('v', 'm')) v;
  SELECT coalesce(jsonb_agg(jsonb_build_object('name', conname, 'def', pg_get_constraintdef(oid))), '[]')
    INTO v_fks FROM pg_constraint WHERE conrelid = v_old AND contype = 'f';
  SELECT conname, pg_get_constraintdef(oid) AS def INTO v_pk
    FROM pg_constraint WHERE conrelid = v_old AND contype = 'p';
  SELECT coalesce(jsonb_agg(jsonb_build_object('name', ic.relname, 'def', pg_get_indexdef(i.indexrelid))), '[]')
    INTO v_idx FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
   WHERE i.indrelid = v_old AND NOT i.indisprimary AND i.indisvalid;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END,
           'priv', a.privilege_type)), '[]')
    INTO v_acl FROM pg_class c, aclexplode(c.relacl) a WHERE c.oid = v_old;

  -- 2. a materialized view stores its rows: drop it, re-create it on the parent below
  FOR r IN SELECT e.v FROM jsonb_array_elements(v_views) e(v) WHERE e.v->>'kind' = 'm' LOOP
    EXECUTE format('DROP MATERIALIZED VIEW public.%I', r.v->>'name');
  END LOOP;
  -- an invalid index (a failed REINDEX CONCURRENTLY leftover) would block ATTACH's index match
  FOR r IN SELECT ic.relname FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = v_old AND NOT i.indisvalid LOOP
    EXECUTE format('DROP INDEX public.%I', r.relname);
  END LOOP;

  -- 3. swap: the old table and its index / constraint names move to *_legacy; the canonical names
  --    go to the new partitioned parent
  EXECUTE format('ALTER TABLE public.%I RENAME TO %I', p_table, v_legacy);
  IF v_pk.conname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.%I RENAME CONSTRAINT %I TO %I', v_legacy, v_pk.conname, left(v_pk.conname, 56) || '_legacy');
  END IF;
  FOR r IN SELECT e.i FROM jsonb_array_elements(v_idx) e(i) LOOP
    EXECUTE format('ALTER INDEX public.%I RENAME TO %I', r.i->>'name', left(r.i->>'name', 56) || '_legacy');
  END LOOP;
  FOR r IN SELECT e.f FROM jsonb_array_elements(v_fks) e(f) LOOP
    EXECUTE format('ALTER TABLE public.%I RENAME CONSTRAINT %I TO %I', v_legacy, r.f->>'name', left(r.f->>'name', 56) || '_legacy');
  END LOOP;

  EXECUTE format('CREATE TABLE public.%I (LIKE public.%I INCLUDING DEFAULTS INCLUDING GENERATED INCLUDING COMMENTS)'
                 ' PARTITION BY RANGE (captured_at)', p_table, v_legacy);
  IF v_pk.conname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I %s', p_table, v_pk.conname, v_pk.def);
  END IF;
  FOR r IN SELECT e.i FROM jsonb_array_elements(v_idx) e(i) LOOP
    -- the captured text says "CREATE INDEX <name> ON public.<t> USING ...": ONLY the parent
    EXECUTE regexp_replace(r.i->>'def', ' ON public\.', ' ON ONLY public.');
  END LOOP;
  PERFORM public._partition_lock_down(v_legacy);
  EXECUTE format('ALTER TABLE public.%I ATTACH PARTITION public.%I FOR VALUES FROM (MINVALUE) TO (%L)',
                 p_table, v_legacy, p_cutover);
  FOR r IN SELECT e.f FROM jsonb_array_elements(v_fks) e(f) LOOP
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I %s', p_table, r.f->>'name', r.f->>'def');
  END LOOP;
  EXECUTE format('CREATE TABLE public.%I PARTITION OF public.%I DEFAULT', p_table || '_default', p_table);
  PERFORM public._partition_lock_down(p_table || '_default');
  v_days := public.partition_ensure_days(p_table, p_cutover, p_days_ahead);
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', p_table);
  FOR r IN SELECT e.a FROM jsonb_array_elements(v_acl) e(a) LOOP
    EXECUTE format('GRANT %s ON public.%I TO %s', r.a->>'priv', p_table, r.a->>'grantee');
  END LOOP;

  -- 4. re-bind the views from their own text (it still names the canonical table)
  FOR r IN SELECT e.v FROM jsonb_array_elements(v_views) e(v) WHERE e.v->>'kind' = 'v' LOOP
    EXECUTE format('CREATE OR REPLACE VIEW public.%I %s AS %s', r.v->>'name',
                   CASE WHEN r.v->>'opts' <> '' THEN 'WITH (' || (r.v->>'opts') || ')' ELSE '' END, r.v->>'def');
  END LOOP;
  FOR r IN SELECT e.v FROM jsonb_array_elements(v_views) e(v) WHERE e.v->>'kind' = 'm' LOOP
    EXECUTE format('CREATE MATERIALIZED VIEW public.%I %s AS %s WITH NO DATA', r.v->>'name',
                   CASE WHEN r.v->>'opts' <> '' THEN 'WITH (' || (r.v->>'opts') || ')' ELSE '' END,
                   rtrim(r.v->>'def', E'; \n'));
    EXECUTE format('ALTER MATERIALIZED VIEW public.%I OWNER TO %I', r.v->>'name', r.v->>'owner');
    FOR d IN SELECT jsonb_array_elements_text(r.v->'idx') LOOP
      EXECUTE d;
    END LOOP;
    FOR d IN SELECT format('GRANT %s ON public.%I TO %s', a->>'priv', r.v->>'name', a->>'grantee')
               FROM jsonb_array_elements(r.v->'acl') a LOOP
      EXECUTE d;
    END LOOP;
    IF r.v->>'comment' IS NOT NULL THEN
      EXECUTE format('COMMENT ON MATERIALIZED VIEW public.%I IS %L', r.v->>'name', r.v->>'comment');
    END IF;
  END LOOP;

  NOTIFY pgrst, 'reload schema';
  RETURN jsonb_build_object('table', p_table, 'cutover', p_cutover, 'legacy', v_legacy,
                            'day_partitions', v_days, 'views_rebound', jsonb_array_length(v_views),
                            'foreign_keys', jsonb_array_length(v_fks), 'indexes', jsonb_array_length(v_idx));
END $$;

-- retention -----------------------------------------------------------------
-- Every partition whose whole range is older than retention_policy.keep_days: with a keep_where,
-- copied down to the rows it keeps (swapped in as <part>_k); without one, dropped. The legacy
-- partition is a scan of the whole old heap, so it is only included on request.
CREATE OR REPLACE FUNCTION public.partition_shrink_old(p_table text, p_include_legacy boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_keep_days int;
  v_keep      text;
  v_cutoff    timestamptz;
  r           record;
  v_kept      bigint;
  v_out       jsonb := '[]'::jsonb;
  v_k         text;
BEGIN
  SELECT keep_days, nullif(btrim(keep_where), '') INTO v_keep_days, v_keep
    FROM public.retention_policy WHERE table_name = p_table;
  IF v_keep_days IS NULL THEN
    RAISE EXCEPTION 'no retention_policy row for %', p_table;
  END IF;
  v_cutoff := now() - make_interval(days => v_keep_days);

  FOR r IN
    SELECT c.relname, pg_get_expr(c.relpartbound, c.oid) AS bound,
           (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz AS hi
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
     WHERE i.inhparent = format('public.%I', p_table)::regclass
       AND c.relname NOT LIKE '%\_k' AND c.relname <> p_table || '_default'
       AND (p_include_legacy OR c.relname <> p_table || '_legacy')
  LOOP
    CONTINUE WHEN r.hi IS NULL OR r.hi > v_cutoff;
    IF v_keep IS NULL THEN
      EXECUTE format('DROP TABLE public.%I', r.relname);
      v_out := v_out || jsonb_build_object('partition', r.relname, 'kept', 0);
      CONTINUE;
    END IF;
    v_k := left(r.relname, 61) || '_k';
    EXECUTE format('CREATE TABLE public.%I (LIKE public.%I INCLUDING DEFAULTS INCLUDING GENERATED)', v_k, p_table);
    PERFORM public._partition_lock_down(v_k);
    EXECUTE format('INSERT INTO public.%I SELECT * FROM public.%I t WHERE %s', v_k, r.relname, v_keep);
    GET DIAGNOSTICS v_kept = ROW_COUNT;
    EXECUTE format('ALTER TABLE public.%I DETACH PARTITION public.%I', p_table, r.relname);
    EXECUTE format('ALTER TABLE public.%I ATTACH PARTITION public.%I %s', p_table, v_k, r.bound);
    EXECUTE format('DROP TABLE public.%I', r.relname);
    v_out := v_out || jsonb_build_object('partition', r.relname, 'kept', v_kept);
  END LOOP;
  RETURN v_out;
END $$;

-- daily cron body -------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partition_maintain(p_table text, p_days_ahead integer DEFAULT 14)
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_created int;
  v_default bigint;
BEGIN
  v_created := public.partition_ensure_days(p_table, date_trunc('day', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC', p_days_ahead);
  EXECUTE format('SELECT count(*) FROM (SELECT 1 FROM public.%I LIMIT 100000) s', p_table || '_default') INTO v_default;
  IF v_default > 0 THEN
    RAISE WARNING 'partition_maintain: %_default holds % rows (a day partition was missing)', p_table, v_default;
  END IF;
  RETURN jsonb_build_object('table', p_table, 'created', v_created, 'default_rows', v_default,
                            'shrunk', public.partition_shrink_old(p_table, false));
END $$;

REVOKE ALL ON FUNCTION public._partition_lock_down(text),
                       public.partition_prepare(text, timestamptz),
                       public.partition_ensure_days(text, timestamptz, integer),
                       public.partition_cutover(text, timestamptz, integer),
                       public.partition_shrink_old(text, boolean),
                       public.partition_maintain(text, integer)
  FROM PUBLIC, anon, authenticated;
