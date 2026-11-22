\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
-- The online rebuild of gotickets_listings_snapshots (mig 20261122030000): each phase in turn, what is kept (the
-- window, the deal evidence, a row the drain landed late) and what is not (older rows that are not evidence, a spell
-- row of another source), the swap's names / grants / options, the retention policy released, the cron gone, and
-- the writer landing in the rebuilt table afterwards.
CREATE FUNCTION ago(i interval) RETURNS timestamptz LANGUAGE sql AS $$ SELECT now() - i $$;
CREATE FUNCTION tick() RETURNS text LANGUAGE sql AS $$
  SELECT (j->>'from') || ' -> ' || (j->>'phase') || ' rows=' || (j->>'rows') || coalesce(' ERROR ' || (j->>'error'), '')
    FROM public.gt_snapshots_rebuild_tick(60) j $$;
CREATE FUNCTION snap(ev bigint, at_ timestamptz, lid bigint) RETURNS void LANGUAGE sql AS $$
  INSERT INTO public.gotickets_listings_snapshots (tevo_event_id, gt_event_id, captured_at, gt_listing_id, section, quantity, all_in_price, splits)
  VALUES (9000 + ev, ev, at_, lid, 'A', 2, 123.45, ARRAY[1,2]) $$;

-- the deal evidence: listing 201 of event 2 is a gotickets spell; listing 101 is a spell of ANOTHER source (does not protect)
INSERT INTO public.deal_listing_spell (source, tevo_event_id, listing_id, gt_event_id) VALUES
  ('gotickets', 9002, 201, 2),
  ('evo',       9001, 101, NULL);

-- the firehose before the rebuild
DO $$ BEGIN
  PERFORM snap(1, ago('40 days'), 101);    -- old, not evidence                → dropped
  PERFORM snap(2, ago('40 days'), 201);    -- old, evidence                    → kept (evidence)
  PERFORM snap(2, ago('39 days'), 201);    -- old, evidence, a second capture  → kept (evidence)
  PERFORM snap(2, ago('40 days'), 202);    -- old, same event, not evidence    → dropped
  PERFORM snap(3, ago('10 days'), 301);    -- inside the window                → kept (copy)
  PERFORM snap(3, ago('1 hour'),  302);    -- inside the window                → kept (copy)
  PERFORM snap(4, ago('10 minutes'), 401); -- newer than the copy's lag        → kept (finish)
END $$;

SELECT 'before: rows=' || count(*) || ' policy_parked=' || (SELECT next_eligible_at IS NOT NULL FROM retention_policy WHERE table_name='gotickets_listings_snapshots')
       || ' cron=' || (SELECT count(*) FROM cron.job WHERE jobname='gt_snapshots_rebuild_1min')
  FROM public.gotickets_listings_snapshots;

-- the phases, one tick each
SELECT tick();   -- init -> evidence
SELECT tick();   -- evidence -> copy
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
SELECT 'live: ' || string_agg(gt_listing_id::text, ',' ORDER BY gt_listing_id, captured_at) FROM public.gotickets_listings_snapshots;
SELECT 'old:  ' || string_agg(gt_listing_id::text, ',' ORDER BY gt_listing_id, captured_at) FROM public.gotickets_listings_snapshots_old;
SELECT 'new table gone: ' || (to_regclass('public.gotickets_listings_snapshots_new') IS NULL);
SELECT 'state: phase=' || phase || ' evidence_rows=' || evidence_rows || ' copied_rows=' || copied_rows || ' ticks=' || ticks
       || ' swapped=' || (swapped_at IS NOT NULL) || ' done=' || (done_at IS NOT NULL) || ' error=' || coalesce(last_error, '-')
  FROM public.gt_snapshots_rebuild;

-- the names the readers, the drain's ON CONFLICT and the weekly REINDEX jobs rely on
SELECT 'live indexes: ' || string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE tablename = 'gotickets_listings_snapshots';
SELECT 'old indexes:  ' || string_agg(indexname, ',' ORDER BY indexname) FROM pg_indexes WHERE tablename = 'gotickets_listings_snapshots_old';
SELECT 'pk: ' || conname || ' ' || pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'public.gotickets_listings_snapshots'::regclass AND contype = 'p';
SELECT 'options: ' || array_to_string(reloptions, ',') FROM pg_class WHERE oid = 'public.gotickets_listings_snapshots'::regclass;
SELECT 'grants: service_role insert=' || has_table_privilege('service_role', 'public.gotickets_listings_snapshots', 'INSERT')
       || ' coworker_readonly select=' || has_table_privilege('coworker_readonly', 'public.gotickets_listings_snapshots', 'SELECT')
       || ' analyst_ro select=' || has_table_privilege('analyst_ro', 'public.gotickets_listings_snapshots', 'SELECT')
       || ' anon select=' || has_table_privilege('anon', 'public.gotickets_listings_snapshots', 'SELECT')
       || ' authenticated select=' || has_table_privilege('authenticated', 'public.gotickets_listings_snapshots', 'SELECT');
SELECT 'comment mentions rebuild: ' || (obj_description('public.gotickets_listings_snapshots'::regclass) LIKE '%Rebuilt online%')
       || '; old comment: ' || (obj_description('public.gotickets_listings_snapshots_old'::regclass) LIKE '%Dropped by mig 20261122030100%');

-- the retention policy sweeps again; the cron is gone
SELECT 'policy: parked=' || (next_eligible_at IS NOT NULL) || ' error=' || coalesce(last_error, '-') || ' clean_runs=' || clean_runs || ' notes_rebuilt=' || (notes LIKE '%REBUILT%') || ' notes_parked=' || (notes LIKE '%PARKED 2026-11-22%')
  FROM public.retention_policy WHERE table_name = 'gotickets_listings_snapshots';
SELECT 'cron left: ' || count(*) FROM cron.job WHERE jobname = 'gt_snapshots_rebuild_1min';
SELECT 'view: phase=' || phase || ' cron_scheduled=' || cron_scheduled || ' old_size_known=' || (old_size IS NOT NULL) || ' new_size_known=' || (new_size IS NOT NULL) FROM public.v_gt_snapshots_rebuild;

-- the drain's write path lands in the rebuilt table (the same ON CONFLICT target it names)
INSERT INTO public.gotickets_listings_snapshots (tevo_event_id, gt_event_id, captured_at, gt_listing_id)
VALUES (9007, 7, now(), 701), (9007, 7, now(), 701)
ON CONFLICT (gt_event_id, captured_at, gt_listing_id) DO NOTHING;
SELECT 'after a drain: live=' || (SELECT count(*) FROM public.gotickets_listings_snapshots) || ' old=' || (SELECT count(*) FROM public.gotickets_listings_snapshots_old);

-- the drop migration refuses while the rebuild is not done, and drops the old heap when it is
UPDATE public.gt_snapshots_rebuild SET phase = 'analyze';
DO $$ BEGIN
  BEGIN
    PERFORM 1; -- the guard of mig 20261122030100
    IF (SELECT phase FROM public.gt_snapshots_rebuild WHERE id = 1) IS DISTINCT FROM 'done' THEN RAISE EXCEPTION 'guard refused'; END IF;
    DROP TABLE public.gotickets_listings_snapshots_old;
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'drop while not done: %', SQLERRM; END;
END $$;
UPDATE public.gt_snapshots_rebuild SET phase = 'done';
SELECT 'old still there before the drop migration: ' || (to_regclass('public.gotickets_listings_snapshots_old') IS NOT NULL);
\i ../../../../supabase/migrations/20261122030100_gt_snapshots_drop_old.sql
SELECT 'old after the drop migration: ' || (to_regclass('public.gotickets_listings_snapshots_old') IS NOT NULL) || '; live rows=' || (SELECT count(*) FROM public.gotickets_listings_snapshots);
