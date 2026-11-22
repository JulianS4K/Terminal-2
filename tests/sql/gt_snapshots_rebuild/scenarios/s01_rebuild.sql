\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- The online rebuild of gotickets_listings_snapshots into a day-partitioned table (mig 20261122030000): each phase in
-- turn, what is kept (the window, the deal evidence in the DEFAULT partition, a row the drain landed late) and what is
-- not (older rows that are not evidence, a spell row of another source), the swap's names / grants / options, the
-- retention policy disabled and the partition cron scheduled, the writer landing in the rebuilt table, then the
-- partition tick: days ahead, a stray row moved out of DEFAULT, aged days dropped with their evidence kept.
CREATE FUNCTION ago(i interval) RETURNS timestamptz LANGUAGE sql AS $$ SELECT now() - i $$;
CREATE FUNCTION tick() RETURNS text LANGUAGE sql AS $$
  SELECT (j->>'from') || ' -> ' || (j->>'phase') || ' rows=' || (j->>'rows') || coalesce(' ERROR ' || (j->>'error'), '')
    FROM public.gt_snapshots_rebuild_tick(60) j $$;
CREATE FUNCTION ptick() RETURNS text LANGUAGE sql AS $$
  SELECT 'partition tick: created=' || jsonb_array_length(j->'created') || ' dropped=' || jsonb_array_length(j->'dropped') || ' deleted=' || (j->>'deleted')
    FROM public.gt_snapshots_partition_tick(60) j $$;
CREATE FUNCTION snap(ev bigint, at_ timestamptz, lid bigint) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.gotickets_listings_snapshots (tevo_event_id, gt_event_id, captured_at, gt_listing_id, section, quantity, all_in_price, splits)
  VALUES (9000 + ev, ev, at_, lid, 'A', 2, 123.45, ARRAY[1,2]) $$;
CREATE FUNCTION live_ids() RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(gt_listing_id::text, ',' ORDER BY gt_listing_id, captured_at), '-') FROM public.gotickets_listings_snapshots $$;
CREATE FUNCTION default_ids() RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(gt_listing_id::text, ',' ORDER BY gt_listing_id, captured_at), '-') FROM public.gotickets_listings_snapshots_default $$;
CREATE FUNCTION day_parts() RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
   WHERE i.inhparent = coalesce(to_regclass('public.gotickets_listings_snapshots_new'), to_regclass('public.gotickets_listings_snapshots'))
     AND pg_get_expr(c.relpartbound, c.oid) <> 'DEFAULT' $$;

-- the deal evidence: listing 201 of event 2 and listing 303 of event 3 are gotickets spells; listing 101 is a spell of
-- ANOTHER source (does not protect)
INSERT INTO public.deal_listing_spell (source, tevo_event_id, listing_id, gt_event_id) VALUES
  ('gotickets', 9002, 201, 2),
  ('gotickets', 9003, 303, 3),
  ('evo',       9001, 101, NULL);

-- the firehose before the rebuild
DO $$ BEGIN
  PERFORM snap(1, ago('40 days'), 101);    -- old, not evidence                → dropped
  PERFORM snap(2, ago('40 days'), 201);    -- old, evidence                    → kept (evidence → DEFAULT)
  PERFORM snap(2, ago('39 days'), 201);    -- old, evidence, a second capture  → kept (evidence → DEFAULT)
  PERFORM snap(2, ago('40 days'), 202);    -- old, same event, not evidence    → dropped
  PERFORM snap(3, ago('10 days'), 301);    -- inside the window                → kept (copy)
  PERFORM snap(3, ago('10 days'), 303);    -- inside the window, evidence      → kept (copy; survives its day's drop)
  PERFORM snap(3, ago('1 hour'),  302);    -- inside the window                → kept (copy)
  PERFORM snap(4, ago('10 minutes'), 401); -- newer than the copy's lag        → kept (finish)
END $$;

SELECT 'before: rows=' || count(*) || ' policy_parked=' || (SELECT next_eligible_at IS NOT NULL FROM retention_policy WHERE table_name='gotickets_listings_snapshots')
       || ' rebuild_cron=' || (SELECT count(*) FROM cron.job WHERE jobname='gt_snapshots_rebuild_1min')
       || ' new_is_partitioned=' || (SELECT relkind = 'p' FROM pg_class WHERE oid = 'public.gotickets_listings_snapshots_new'::regclass)
       || ' day_partitions=' || day_parts()
  FROM public.gotickets_listings_snapshots;

-- the phases, one tick each
SELECT tick();   -- init -> evidence
SELECT 'after init: day_partitions=' || day_parts() || ' (cutoff day .. today + 7)';
SELECT tick();   -- evidence -> copy
SELECT 'evidence in DEFAULT: ' || default_ids();
SELECT tick();   -- copy -> index_pk
SELECT tick();   -- index_pk -> index_captured
SELECT tick();   -- index_captured -> index_event_time
SELECT tick();   -- index_event_time -> finish
SELECT 'cutoff is ' || extract(day FROM now() - cutoff)::int || ' days ago; window_from is ' || round(extract(epoch FROM now() - window_from) / 60)::int || ' min ago; evidence_rows=' || evidence_rows || ' copied_rows=' || copied_rows
  FROM public.gt_snapshots_rebuild;

-- between the index builds and the finish the drain keeps landing rows in the old table: one it drained late (fired
-- 3 h ago, inside pg_net's TTL) and one older than the cutoff that is not evidence
DO $$ BEGIN
  PERFORM snap(5, ago('3 hours'), 501);    -- landed late                      → kept (finish re-reads 7 h back)
  PERFORM snap(6, ago('20 days'), 601);    -- old, not evidence                → dropped
END $$;

SELECT tick();   -- finish -> analyze (catch-up + swap)
SELECT tick();   -- analyze -> done
SELECT 'again: ' || (public.gt_snapshots_rebuild_tick(60)->>'phase');

-- what the rebuilt table holds
SELECT 'live: ' || live_ids();
SELECT 'old:  ' || string_agg(gt_listing_id::text, ',' ORDER BY gt_listing_id, captured_at) FROM public.gotickets_listings_snapshots_old;
SELECT 'DEFAULT partition: ' || default_ids();
SELECT 'new table gone: ' || (to_regclass('public.gotickets_listings_snapshots_new') IS NULL) || '; live is partitioned: ' || (SELECT relkind = 'p' FROM pg_class WHERE oid = 'public.gotickets_listings_snapshots'::regclass) || '; day_partitions=' || day_parts();
SELECT 'state: phase=' || phase || ' evidence_rows=' || evidence_rows || ' copied_rows=' || copied_rows || ' ticks=' || ticks
       || ' swapped=' || (swapped_at IS NOT NULL) || ' done=' || (done_at IS NOT NULL) || ' error=' || coalesce(last_error, '-')
  FROM public.gt_snapshots_rebuild;

-- the names the readers, the drain's ON CONFLICT and the weekly REINDEX jobs rely on (the parent's; partition indexes are named by Postgres)
SELECT 'live indexes: ' || string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE tablename = 'gotickets_listings_snapshots';
SELECT 'old indexes:  ' || string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE tablename = 'gotickets_listings_snapshots_old';
SELECT 'pk: ' || conname || ' ' || pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.gotickets_listings_snapshots'::regclass AND contype = 'p';
SELECT 'every partition has 3 indexes: ' || bool_and(n = 3) FROM (SELECT count(*) AS n FROM pg_inherits i JOIN pg_indexes x ON x.tablename = i.inhrelid::regclass::text WHERE i.inhparent = 'public.gotickets_listings_snapshots'::regclass GROUP BY i.inhrelid) s;
SELECT 'partition options: ' || array_to_string(reloptions, ',') FROM pg_class WHERE oid = 'public.gotickets_listings_snapshots_default'::regclass;
SELECT 'grants: service_role insert=' || has_table_privilege('service_role', 'public.gotickets_listings_snapshots', 'INSERT')
       || ' coworker_readonly select=' || has_table_privilege('coworker_readonly', 'public.gotickets_listings_snapshots', 'SELECT')
       || ' analyst_ro select=' || has_table_privilege('analyst_ro', 'public.gotickets_listings_snapshots', 'SELECT')
       || ' anon select=' || has_table_privilege('anon', 'public.gotickets_listings_snapshots', 'SELECT')
       || ' authenticated select=' || has_table_privilege('authenticated', 'public.gotickets_listings_snapshots', 'SELECT');
SELECT 'comment mentions rebuild: ' || (obj_description('public.gotickets_listings_snapshots'::regclass) LIKE '%Rebuilt online%')
       || '; old comment: ' || (obj_description('public.gotickets_listings_snapshots_old'::regclass) LIKE '%Dropped by mig 20261122030100%');

-- the retention policy is disabled (retention_tick must not ctid-delete on a partitioned table); the crons swapped
SELECT 'policy: enabled=' || enabled || ' parked=' || (next_eligible_at IS NOT NULL) || ' error=' || coalesce(last_error, '-') || ' clean_runs=' || clean_runs || ' notes_rebuilt=' || (notes LIKE '%REBUILT%') || ' notes_parked=' || (notes LIKE '%PARKED 2026-11-22%')
  FROM public.retention_policy WHERE table_name = 'gotickets_listings_snapshots';
SELECT 'crons: ' || string_agg(jobname || ' [' || schedule || ']', ', ' ORDER BY jobname) FROM cron.job;
SELECT 'view: phase=' || phase || ' rebuild_cron=' || rebuild_cron || ' partition_cron=' || partition_cron || ' day_partitions=' || day_partitions || ' old_size_known=' || (old_size IS NOT NULL) || ' new_size_known=' || (new_size IS NOT NULL) FROM public.v_gt_snapshots_rebuild;

-- the drain's write path lands in the rebuilt table (the same ON CONFLICT target it names), in today's partition
INSERT INTO public.gotickets_listings_snapshots (tevo_event_id, gt_event_id, captured_at, gt_listing_id)
VALUES (9007, 7, now(), 701), (9007, 7, now(), 701)
ON CONFLICT (gt_event_id, captured_at, gt_listing_id) DO NOTHING;
SELECT 'after a drain: live=' || (SELECT count(*) FROM public.gotickets_listings_snapshots) || ' old=' || (SELECT count(*) FROM public.gotickets_listings_snapshots_old) || ' DEFAULT=' || (SELECT count(*) FROM public.gotickets_listings_snapshots_default);

-- ── the partition tick ──
-- nothing to do yet: the days ahead exist (the build made a week), no day is older than 15 days
SELECT ptick();
-- a row for a day with no partition goes to DEFAULT; creating the day moves it into its partition
INSERT INTO public.gotickets_listings_snapshots (tevo_event_id, gt_event_id, captured_at, gt_listing_id) VALUES (9008, 8, (current_date + 9)::timestamp AT TIME ZONE 'UTC' + interval '5 hours', 801);
SELECT 'stray in DEFAULT: ' || default_ids();
SELECT 'ensured: ' || (public.gt_snapshots_partition_ensure('public.gotickets_listings_snapshots'::regclass, current_date + 9) = 'gotickets_listings_snapshots_p' || to_char(current_date + 9, 'YYYYMMDD'));
SELECT 'after ensure: DEFAULT=' || default_ids() || ' day_partitions=' || day_parts() || ' row in its day=' || (SELECT count(*) FROM public.gotickets_listings_snapshots WHERE gt_listing_id = 801 AND tableoid = to_regclass('public.gotickets_listings_snapshots_p' || to_char(current_date + 9, 'YYYYMMDD')));
-- a 1-day window: every day partition up to yesterday goes; the evidence (303) moves to DEFAULT, 301 is gone
UPDATE public.retention_policy SET keep_days = 1 WHERE table_name = 'gotickets_listings_snapshots';
SELECT ptick();
SELECT 'after the drop: live=' || live_ids() || ' DEFAULT=' || default_ids() || ' day_partitions=' || day_parts();
SELECT 'run log: rows=' || count(*) || ' deleted=' || sum(deleted) || ' kept_noted=' || count(*) FILTER (WHERE note LIKE '%1 deal-evidence rows kept%') FROM public.retention_run_log WHERE table_name = 'gotickets_listings_snapshots';
SELECT 'policy after: last_deleted=' || last_deleted || ' total_deleted=' || total_deleted || ' swept=' || (last_run_at IS NOT NULL) FROM public.retention_policy WHERE table_name = 'gotickets_listings_snapshots';
UPDATE public.retention_policy SET keep_days = 15 WHERE table_name = 'gotickets_listings_snapshots';
SELECT ptick();

-- the drop migration refuses while the rebuild is not done, and drops the old heap when it is
UPDATE public.gt_snapshots_rebuild SET phase = 'analyze';
DO $$ BEGIN
  BEGIN
    IF (SELECT phase FROM public.gt_snapshots_rebuild WHERE id = 1) IS DISTINCT FROM 'done' THEN RAISE EXCEPTION 'guard refused'; END IF;
    DROP TABLE public.gotickets_listings_snapshots_old;
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'drop while not done: %', SQLERRM; END;
END $$;
UPDATE public.gt_snapshots_rebuild SET phase = 'done';
SELECT 'old still there before the drop migration: ' || (to_regclass('public.gotickets_listings_snapshots_old') IS NOT NULL);
\i ../../../../supabase/migrations/20261122030100_gt_snapshots_drop_old.sql
SELECT 'old after the drop migration: ' || (to_regclass('public.gotickets_listings_snapshots_old') IS NOT NULL) || '; live rows=' || (SELECT count(*) FROM public.gotickets_listings_snapshots);
