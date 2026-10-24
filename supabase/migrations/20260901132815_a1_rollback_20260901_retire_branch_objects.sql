-- ROLLBACK STEP 3a (operator-directed full rollback to the 2026-08-29 state).
--
-- Retires the objects created by the 50 migrations of branch
-- claude/pause-tickets-data-crons-gt85nq. Two groups:
--
--  B. Objects that hold no data (functions, view, indexes) are dropped outright.
--
--  C. Objects that HOLD DATA are moved into schema rollback_20260901 rather
--     than dropped. Nothing in the e43d549 tree references them, so prod
--     behaves exactly as it did on 2026-08-29, but the rows survive and this
--     step is itself reversible. Purging them is a separate operator decision,
--     not something a rollback should assume.
--
-- Step 3b restores the three PRE-EXISTING functions the branch overwrote.

CREATE SCHEMA IF NOT EXISTS rollback_20260901;
COMMENT ON SCHEMA rollback_20260901 IS
  'Quarantine for data-bearing objects created by branch claude/pause-tickets-data-crons-gt85nq and retired by the 2026-09-01 rollback to e43d549. Unreferenced by application code. Drop only on explicit operator instruction.';

-- ---------------------------------------------------------------------------
-- B. Drop branch-created code objects.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS public.v_aq_event_resolve;

DO $drop_fns$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
     WHERE ns.nspname = 'public'
       AND p.proname IN ('sweep_news_image_urls','event_mapping_enqueue','event_mapping_drain',
                         'gt_listings_inflight_reap','s4k_normalize_event_name',
                         's4k_match_to_aq_event_id','s4k_orders_match_sweep','s4k_name_ok',
                         's4k_is_tbd_event','s4k_orders_queue','s4k_orders_drain',
                         's4k_orders_map_events','evo_map_events_to_gotickets',
                         'aq_sync_source_event_ids')
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS %s', r.sig);
    n := n + 1;
    RAISE NOTICE 'dropped %', r.sig;
  END LOOP;
  RAISE NOTICE 'dropped % branch-created function(s)', n;
END $drop_fns$;

-- sweep_all_expired_pg_net_pending is deliberately NOT in that list: it exists
-- on origin/main, and the branch migration that would have replaced it
-- (20260831220000_pg_net_orphan_reap.sql) was authored but never applied --
-- gt_listings_inflight_reap being absent from prod is the proof it never ran.

DROP INDEX IF EXISTS public.idx_gotickets_event_cname_time_unmapped;
DROP INDEX IF EXISTS public.idx_sg_canonical_cname_time_unmapped;
DROP INDEX IF EXISTS public.aq_event_map_cvenue_date_idx;
DROP INDEX IF EXISTS public.aq_event_map_event_date_d_idx;
DROP INDEX IF EXISTS public.aq_event_map_venue_trgm_idx;
DROP INDEX IF EXISTS public.aq_event_map_tevo_event_id_idx;
DROP INDEX IF EXISTS public.aq_event_map_gotickets_event_id_idx;
DROP INDEX IF EXISTS public.events_cvenue_localdate_idx;
DROP INDEX IF EXISTS public.events_localdate_idx;
DROP INDEX IF EXISTS public.sg_seller_pending_unresolved_idx;
DROP INDEX IF EXISTS public.evo_orders_pending_unresolved_idx;
DROP INDEX IF EXISTS public.gt_listings_inflight_fired_at_idx;

-- ---------------------------------------------------------------------------
-- C. Quarantine data-bearing branch objects.
-- ---------------------------------------------------------------------------
DO $quarantine$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['event_mapping_queue','s4k_marketplace_orders',
                           's4k_orders_pending','s4k_map_legacy']
  LOOP
    IF EXISTS (SELECT 1 FROM information_schema.tables
                WHERE table_schema='public' AND table_name=t) THEN
      EXECUTE format('ALTER TABLE public.%I SET SCHEMA rollback_20260901', t);
      RAISE NOTICE 'quarantined public.% -> rollback_20260901.%', t, t;
    END IF;
  END LOOP;
END $quarantine$;

-- aq_event_map.gotickets_event_id was added to a PRE-EXISTING table by
-- 20260901001224. Reverting the schema means dropping the column, but it holds
-- real EVO<->GoTickets links, so preserve them alongside the quarantined tables.
DO $gt_col$
DECLARE n bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema='public' AND table_name='aq_event_map'
                AND column_name='gotickets_event_id') THEN
    CREATE TABLE IF NOT EXISTS rollback_20260901.aq_event_map_gotickets_event_id (
      aq_short_event_id  text PRIMARY KEY,
      gotickets_event_id text NOT NULL
    );
    INSERT INTO rollback_20260901.aq_event_map_gotickets_event_id (aq_short_event_id, gotickets_event_id)
    SELECT aq_short_event_id, gotickets_event_id::text
      FROM public.aq_event_map
     WHERE gotickets_event_id IS NOT NULL
    ON CONFLICT (aq_short_event_id) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RAISE NOTICE 'preserved % aq_event_map.gotickets_event_id link(s)', n;
    ALTER TABLE public.aq_event_map DROP COLUMN gotickets_event_id;
  END IF;
END $gt_col$;

-- Post-condition: nothing the branch created is left in public.
DO $verify$
DECLARE leftover text;
BEGIN
  SELECT string_agg(x, ', ') INTO leftover FROM (
    SELECT p.proname AS x FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
     WHERE ns.nspname='public'
       AND p.proname IN ('sweep_news_image_urls','event_mapping_enqueue','event_mapping_drain',
                         'gt_listings_inflight_reap','s4k_normalize_event_name',
                         's4k_match_to_aq_event_id','s4k_orders_match_sweep','s4k_name_ok',
                         's4k_is_tbd_event','s4k_orders_queue','s4k_orders_drain',
                         's4k_orders_map_events','evo_map_events_to_gotickets',
                         'aq_sync_source_event_ids')
    UNION ALL
    SELECT table_name FROM information_schema.tables
     WHERE table_schema='public'
       AND table_name IN ('event_mapping_queue','s4k_marketplace_orders','s4k_orders_pending','s4k_map_legacy')
    UNION ALL
    SELECT 'aq_event_map.gotickets_event_id' FROM information_schema.columns
     WHERE table_schema='public' AND table_name='aq_event_map' AND column_name='gotickets_event_id'
    UNION ALL
    SELECT 'v_aq_event_resolve' FROM information_schema.views
     WHERE table_schema='public' AND table_name='v_aq_event_resolve'
  ) s;
  IF leftover IS NOT NULL THEN
    RAISE EXCEPTION 'rollback incomplete, still present in public: %', leftover;
  END IF;
END $verify$;
