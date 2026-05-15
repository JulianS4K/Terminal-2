-- Migration 20260515300000 · level:security · lane:Security · writes:RLS+policy on aq_venue_map+aq_performer_map, body-guard+REVOKE/GRANT retrofit on 11 SECDEF fns · reads:pg_proc, pg_tables · pre:20260515180000,20260515210000,20260515220000,20260515230000,20260515240000,20260515250000,20260515260000,20260515270000,20260515270100,20260515280000
--
-- B1 post-PR-#101 security pass — closes two gaps surfaced by the 2026-05-14 audit
-- (`docs/security-audit-2026-05-14-post-pr101.md`):
--
--   1. SEC-HIGH: `aq_venue_map` (712 rows) and `aq_performer_map` (863 rows) were
--      created in 20260515220000 without RLS and missed the bulk deny-all sweep
--      from PR #97. `anon` currently has INSERT/SELECT/UPDATE/DELETE/TRUNCATE.
--      Section 1 below enables RLS, installs deny-all policies, and tightens GRANTs
--      to mirror the canonical pattern from `aq_event_map` (20260515180000).
--
--   2. SEC-MED (defense-in-depth): 11 SECURITY DEFINER functions added 2026-05-14/15
--      have SET search_path correctly but lack the BOT_HIERARCHY.md §6 body guard
--      (`IF current_user NOT IN (service_role, postgres, supabase_admin) ... RAISE`)
--      and the explicit `REVOKE EXECUTE ... FROM PUBLIC` + `GRANT EXECUTE ... TO
--      service_role` closure. Not an active vuln: all callers are service_role crons
--      that pass the guard. Section 2 below re-emits each function with the standard
--      §6 elements added.
--
-- Bodies in Section 2 are pulled verbatim from prod via pg_get_functiondef() — the
-- only edit per function is the prepended guard. Signatures, defaults, search_path,
-- volatility, and return types are preserved byte-for-byte so cron wrappers
-- (`PERFORM public.match_unmatched_orders_sweep(500, true)` etc.) continue to work
-- unchanged. CREATE OR REPLACE preserves the function oid, so existing cron.job
-- rows that reference by name still resolve.
--
-- ## Regression risk
-- cron.failed_jobs_90min  — none expected. Crons run as service_role; guard passes.
-- functions.pgcrypto_missing_extensions_searchpath — none. search_path already set.
-- views.security_definer_views — none (this migration touches no views).
-- data_freshness.* — none (no data movement).
-- rls.* — improved (closes anon write path on 2 tables).
--
-- ## Already applied to prod
-- NOT YET. Operator must authorize prod apply (per 2026-05-13 lockdown):
--   mcp__bccd...__apply_migration with this file's contents.
-- After apply, run:
--   SELECT * FROM public.release_health_check() WHERE status <> 'ok';
-- Diff vs. the pre-apply baseline captured in docs/security-audit-2026-05-14-post-pr101.md §8.

-- ============================================================
-- SECTION 1 — RLS + deny-all on aq_venue_map and aq_performer_map
-- ============================================================
-- Mirrors the pattern from 20260515180000_aq_event_map_short_id_pk.sql:67 where
-- aq_event_map gets ENABLE ROW LEVEL SECURITY + admin_only deny-all policy.
-- The aq_venue_map/aq_performer_map tables (20260515220000) missed this step.

ALTER TABLE public.aq_venue_map     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aq_performer_map ENABLE ROW LEVEL SECURITY;

-- Deny-all policies (idempotent via DO blocks — CREATE POLICY has no IF NOT EXISTS).
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'aq_venue_map' AND policyname = 'admin_only'
  ) THEN
    CREATE POLICY admin_only ON public.aq_venue_map
      FOR ALL TO anon, authenticated, coworker_readonly
      USING (false) WITH CHECK (false);
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'aq_performer_map' AND policyname = 'admin_only'
  ) THEN
    CREATE POLICY admin_only ON public.aq_performer_map
      FOR ALL TO anon, authenticated, coworker_readonly
      USING (false) WITH CHECK (false);
  END IF;
END $$;

-- Strip the table-level GRANTs that PostgREST inherits by default.
-- (Belt + suspenders alongside RLS — both must agree before anon can read/write.)
REVOKE ALL ON public.aq_venue_map     FROM anon, authenticated;
REVOKE ALL ON public.aq_performer_map FROM anon, authenticated;

-- service_role needs writes (matchers in Section 2 insert/update via SECDEF).
GRANT SELECT, INSERT, UPDATE, DELETE ON public.aq_venue_map     TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.aq_performer_map TO service_role;

-- ============================================================
-- SECTION 2 — §6 SECDEF convention retrofit (11 functions)
-- ============================================================
-- Each block:
--   1. CREATE OR REPLACE FUNCTION ... — same signature, same body, same search_path,
--      same volatility/language — with the current_user guard prepended.
--   2. REVOKE EXECUTE ... FROM PUBLIC, anon, authenticated.
--   3. GRANT EXECUTE ... TO service_role.

-- ---- 1/11: aq_event_map_ingest(jsonb) ----------------------
CREATE OR REPLACE FUNCTION public.aq_event_map_ingest(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_inserted int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'aq_event_map_ingest: caller % not authorized', current_user;
  END IF;
  WITH src AS (SELECT r FROM jsonb_array_elements(p_rows) AS r),
  ins AS (
    INSERT INTO public.aq_event_map (
      aq_short_event_id, event_id_uuid,
      event_name, venue_name, event_date, city, state, performer, category,
      vivid_event_id, sh_event_id, sg_event_id, tm_event_id, tnow_production_id
    )
    SELECT
      NULLIF(r->>'aq_short_event_id',''),
      NULLIF(r->>'event_id_uuid','')::uuid,
      NULLIF(r->>'event_name',''),
      NULLIF(r->>'venue_name',''),
      NULLIF(r->>'event_date','')::timestamp,
      NULLIF(r->>'city',''),
      NULLIF(r->>'state',''),
      NULLIF(r->>'performer',''),
      NULLIF(r->>'category',''),
      NULLIF(regexp_replace(coalesce(r->>'vivid_event_id',''),  '[^0-9]', '', 'g'), '')::bigint,
      NULLIF(regexp_replace(coalesce(r->>'sh_event_id',''),     '[^0-9]', '', 'g'), '')::bigint,
      NULLIF(regexp_replace(coalesce(r->>'sg_event_id',''),     '[^0-9]', '', 'g'), '')::bigint,
      NULLIF(regexp_replace(coalesce(r->>'tm_event_id',''),     '[^0-9]', '', 'g'), '')::bigint,
      NULLIF(r->>'tnow_production_id','')
    FROM src
    WHERE NULLIF(r->>'aq_short_event_id','') IS NOT NULL
    ON CONFLICT (aq_short_event_id) DO UPDATE SET
      event_id_uuid      = EXCLUDED.event_id_uuid,
      event_name         = EXCLUDED.event_name,
      venue_name         = EXCLUDED.venue_name,
      event_date         = EXCLUDED.event_date,
      city               = EXCLUDED.city,
      state              = EXCLUDED.state,
      performer          = EXCLUDED.performer,
      category           = EXCLUDED.category,
      vivid_event_id     = EXCLUDED.vivid_event_id,
      sh_event_id        = EXCLUDED.sh_event_id,
      sg_event_id        = EXCLUDED.sg_event_id,
      tm_event_id        = EXCLUDED.tm_event_id,
      tnow_production_id = EXCLUDED.tnow_production_id
    RETURNING 1
  )
  SELECT count(*) INTO v_inserted FROM ins;
  RETURN v_inserted;
END $function$;

REVOKE EXECUTE ON FUNCTION public.aq_event_map_ingest(jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.aq_event_map_ingest(jsonb) TO service_role;

-- ---- 2/11: create_system_aq_event(text, text, text, timestamptz, bigint) ----
CREATE OR REPLACE FUNCTION public.create_system_aq_event(
  p_source           text,
  p_event_name       text,
  p_venue_name       text,
  p_event_date       timestamp with time zone,
  p_source_event_id  bigint DEFAULT NULL::bigint
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_new_id text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'create_system_aq_event: caller % not authorized', current_user;
  END IF;
  v_new_id := 'SYS-' || substring(
    md5(coalesce(p_event_name,'') || '|' || coalesce(p_venue_name,'') || '|' ||
        coalesce(to_char(p_event_date::timestamptz, 'YYYY-MM-DD"T"HH24:MI'),''))
    from 1 for 10);
  INSERT INTO public.aq_event_map (
    aq_short_event_id, event_name, venue_name, event_date,
    category, aq_source, imported_at
  )
  VALUES (
    v_new_id, p_event_name, p_venue_name, p_event_date::timestamp,
    p_source, 'system_seed', now()
  )
  ON CONFLICT (aq_short_event_id) DO NOTHING;
  RETURN v_new_id;
END $function$;

REVOKE EXECUTE ON FUNCTION public.create_system_aq_event(text, text, text, timestamp with time zone, bigint) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.create_system_aq_event(text, text, text, timestamp with time zone, bigint) TO service_role;

-- ---- 3/11: cron_last_fire(text) ----------------------------
-- Note: this function was LANGUAGE sql in prod; converted to LANGUAGE plpgsql to
-- accommodate the guard. Single-statement body, no behavior change.
CREATE OR REPLACE FUNCTION public.cron_last_fire(p_jobname text)
RETURNS timestamp with time zone
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'cron_last_fire: caller % not authorized', current_user;
  END IF;
  RETURN (
    SELECT max(decided_at) FROM public.cron_gate_decisions
    WHERE jobname = p_jobname AND decision = 'fire'
  );
END $function$;

REVOKE EXECUTE ON FUNCTION public.cron_last_fire(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cron_last_fire(text) TO service_role;

-- ---- 4/11: cron_resume_with_gate(text) ---------------------
CREATE OR REPLACE FUNCTION public.cron_resume_with_gate(p_jobname text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_schedule  text;
  v_cmd       text;
  v_wrapped   text;
  v_new_jobid bigint;
  v_inner     text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'cron_resume_with_gate: caller % not authorized', current_user;
  END IF;
  SELECT schedule, command INTO v_schedule, v_cmd
  FROM public.cron_pause_state_20260514 WHERE jobname = p_jobname;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'jobname % not in cron_pause_state_20260514 snapshot', p_jobname;
  END IF;

  IF v_cmd ~* '^\s*DO\s+\$' THEN
    RAISE EXCEPTION 'cron_resume_with_gate cannot auto-wrap a DO-block command for %. Manual wrap required. Original command: %', p_jobname, v_cmd;
  END IF;

  v_inner := trim(both ' ;' from v_cmd);
  v_inner := regexp_replace(v_inner, '^\s*SELECT\s+\*\s+FROM\s+', 'PERFORM ', 'i');
  v_inner := regexp_replace(v_inner, '^\s*SELECT\s+',             'PERFORM ', 'i');

  v_wrapped := format(
    $wrap$DO $body$ BEGIN IF NOT public.cron_should_fire(%L) THEN RETURN; END IF; %s; END $body$;$wrap$,
    p_jobname, v_inner);

  PERFORM cron.unschedule(p_jobname) FROM cron.job WHERE jobname = p_jobname;
  v_new_jobid := cron.schedule(p_jobname, v_schedule, v_wrapped);

  RETURN format('jobid=%s schedule=%I wrapped=true', v_new_jobid, v_schedule);
END $function$;

REVOKE EXECUTE ON FUNCTION public.cron_resume_with_gate(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cron_resume_with_gate(text) TO service_role;

-- ---- 5/11: cron_should_fire(text) --------------------------
CREATE OR REPLACE FUNCTION public.cron_should_fire(p_jobname text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_policy        public.cron_policy%ROWTYPE;
  v_hour_et       int;
  v_in_peak       boolean;
  v_interval_min  int;
  v_last_fire     timestamptz;
  v_fires_today   int := NULL;
  v_has_work      boolean := true;
  v_decision      text;
  v_now           timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'cron_should_fire: caller % not authorized', current_user;
  END IF;
  v_hour_et := EXTRACT(hour FROM (v_now AT TIME ZONE 'America/New_York'))::int;
  SELECT * INTO v_policy FROM public.cron_policy WHERE jobname = p_jobname;

  IF NOT FOUND THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'fire_no_policy', v_hour_et);
    RETURN true;
  END IF;

  IF NOT v_policy.enabled THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'disabled', v_hour_et);
    RETURN false;
  END IF;

  IF v_policy.daily_max_fires IS NOT NULL THEN
    SELECT count(*) INTO v_fires_today FROM public.cron_gate_decisions
      WHERE jobname = p_jobname AND decision = 'fire'
        AND decided_at >= date_trunc('day', v_now AT TIME ZONE 'UTC');
    IF v_fires_today >= v_policy.daily_max_fires THEN
      INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, fires_today)
        VALUES (p_jobname, v_now, 'skip_budget', v_hour_et, v_fires_today);
      RETURN false;
    END IF;
  END IF;

  SELECT max(decided_at) INTO v_last_fire
    FROM public.cron_gate_decisions
    WHERE jobname = p_jobname AND decision = 'fire';
  v_in_peak := v_hour_et = ANY(v_policy.peak_hours_et);
  v_interval_min := CASE WHEN v_in_peak THEN v_policy.peak_min_interval_min
                                        ELSE v_policy.offpeak_min_interval_min END;
  IF v_last_fire IS NOT NULL AND (v_now - v_last_fire) < make_interval(mins => v_interval_min) THEN
    v_decision := CASE WHEN v_in_peak THEN 'skip_interval' ELSE 'skip_offpeak' END;
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
      VALUES (p_jobname, v_now, v_decision, v_hour_et, v_last_fire, v_fires_today);
    RETURN false;
  END IF;

  IF v_policy.work_check_sql IS NOT NULL THEN
    BEGIN
      EXECUTE v_policy.work_check_sql INTO v_has_work;
    EXCEPTION WHEN OTHERS THEN
      v_has_work := true;
    END;
    IF NOT coalesce(v_has_work, false) THEN
      INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
        VALUES (p_jobname, v_now, 'skip_no_work', v_hour_et, v_last_fire, v_fires_today);
      RETURN false;
    END IF;
  END IF;

  INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
    VALUES (p_jobname, v_now, 'fire', v_hour_et, v_last_fire, v_fires_today);
  RETURN true;
END $function$;

REVOKE EXECUTE ON FUNCTION public.cron_should_fire(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cron_should_fire(text) TO service_role;

-- ---- 6/11: listings_deltas_backfill_chunked(integer) -------
CREATE OR REPLACE FUNCTION public.listings_deltas_backfill_chunked(p_max_events integer DEFAULT 100)
RETURNS TABLE(source_table text, events_processed integer, rows_updated integer, events_remaining integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; v_proc int; v_upd int; v_rows int; v_remaining int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'listings_deltas_backfill_chunked: caller % not authorized', current_user;
  END IF;
  v_proc := 0; v_upd := 0;
  FOR r IN
    SELECT DISTINCT event_id FROM public.listings_snapshots
    WHERE prev_retail_price IS NULL AND event_id IS NOT NULL LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    WITH ranked AS (
      SELECT id, lag(retail_price) OVER w AS pr_price, lag(quantity) OVER w AS pr_qty
      FROM public.listings_snapshots
      WHERE event_id = r.event_id
      WINDOW w AS (PARTITION BY tevo_ticket_group_id ORDER BY captured_at)
    )
    UPDATE public.listings_snapshots ls SET prev_retail_price = ranked.pr_price, prev_quantity = ranked.pr_qty
    FROM ranked WHERE ls.id = ranked.id AND ranked.pr_price IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_upd := v_upd + v_rows;
    PERFORM pg_sleep(0.1);
  END LOOP;
  SELECT count(DISTINCT event_id) INTO v_remaining FROM public.listings_snapshots
    WHERE prev_retail_price IS NULL AND event_id IS NOT NULL;
  RETURN QUERY SELECT 'listings_snapshots'::text, v_proc, v_upd, v_remaining;

  v_proc := 0; v_upd := 0;
  FOR r IN
    SELECT DISTINCT sg_event_id FROM public.seatgeek_listings_snapshots
    WHERE prev_broadcast_price IS NULL AND sg_event_id IS NOT NULL LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    WITH ranked AS (
      SELECT id, lag(broadcast_price) OVER w AS pr_price, lag(quantity) OVER w AS pr_qty
      FROM public.seatgeek_listings_snapshots
      WHERE sg_event_id = r.sg_event_id
      WINDOW w AS (PARTITION BY display_id ORDER BY captured_at)
    )
    UPDATE public.seatgeek_listings_snapshots sls SET prev_broadcast_price = ranked.pr_price, prev_quantity = ranked.pr_qty
    FROM ranked WHERE sls.id = ranked.id AND ranked.pr_price IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_upd := v_upd + v_rows;
    PERFORM pg_sleep(0.1);
  END LOOP;
  SELECT count(DISTINCT sg_event_id) INTO v_remaining FROM public.seatgeek_listings_snapshots
    WHERE prev_broadcast_price IS NULL AND sg_event_id IS NOT NULL;
  RETURN QUERY SELECT 'seatgeek_listings_snapshots'::text, v_proc, v_upd, v_remaining;
END $function$;

REVOKE EXECUTE ON FUNCTION public.listings_deltas_backfill_chunked(integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.listings_deltas_backfill_chunked(integer) TO service_role;

-- ---- 7/11: match_unmatched_listings_chunked(integer, boolean) ----
CREATE OR REPLACE FUNCTION public.match_unmatched_listings_chunked(
  p_max_events       integer DEFAULT 100,
  p_create_synthetic boolean DEFAULT true
)
RETURNS TABLE(source_table text, events_processed integer, listings_updated integer, synthetic_created integer, events_remaining integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_aq_id text; v_venue_short text; v_performer_short text;
  v_remaining_tevo int; v_remaining_sgb int; v_remaining_sgs int;
  v_proc int; v_upd int; v_synth int; v_rows int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'match_unmatched_listings_chunked: caller % not authorized', current_user;
  END IF;
  v_proc := 0; v_upd := 0; v_synth := 0;
  FOR r IN
    SELECT DISTINCT ls.event_id,
                    e.name        AS event_name,
                    e.venue_name  AS venue_name,
                    e.venue_id    AS venue_id,
                    CASE WHEN e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
                         THEN e.occurs_at_local::timestamptz
                         ELSE NULL END AS event_date
    FROM public.listings_snapshots ls
    LEFT JOIN public.events e ON e.id = ls.event_id
    WHERE ls.aq_short_event_id IS NULL
    LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('evo', NULL, r.event_name, r.venue_name,
                                     r.event_date, NULL, NULL, r.venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('evo', r.event_name, r.venue_name, r.event_date);
      v_synth := v_synth + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short, v_performer_short
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.listings_snapshots ls SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short),
        performer_short_id = coalesce(performer_short_id, v_performer_short)
      WHERE ls.event_id = r.event_id AND ls.aq_short_event_id IS NULL;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_upd := v_upd + v_rows;
    END IF;
    PERFORM pg_sleep(0.2);
  END LOOP;
  SELECT count(DISTINCT event_id) INTO v_remaining_tevo
    FROM public.listings_snapshots WHERE aq_short_event_id IS NULL;
  RETURN QUERY SELECT 'listings_snapshots'::text, v_proc, v_upd, v_synth, v_remaining_tevo;

  v_proc := 0; v_upd := 0; v_synth := 0;
  FOR r IN
    SELECT DISTINCT sls.sg_event_id,
                    c.sg_event_name   AS event_name,
                    c.sg_venue_name   AS venue_name,
                    c.sg_venue_id     AS sg_venue_id,
                    c.sg_datetime_utc AS event_date
    FROM public.seatgeek_listings_snapshots sls
    LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = sls.sg_event_id
    WHERE sls.aq_short_event_id IS NULL
    LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id, r.event_name, r.venue_name,
                                     r.event_date, NULL, NULL, r.sg_venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.event_name, r.venue_name, r.event_date, r.sg_event_id);
      v_synth := v_synth + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short, v_performer_short
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.seatgeek_listings_snapshots sls SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short),
        performer_short_id = coalesce(performer_short_id, v_performer_short)
      WHERE sls.sg_event_id = r.sg_event_id AND sls.aq_short_event_id IS NULL;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_upd := v_upd + v_rows;
    END IF;
    PERFORM pg_sleep(0.2);
  END LOOP;
  SELECT count(DISTINCT sg_event_id) INTO v_remaining_sgb
    FROM public.seatgeek_listings_snapshots WHERE aq_short_event_id IS NULL;
  RETURN QUERY SELECT 'seatgeek_listings_snapshots'::text, v_proc, v_upd, v_synth, v_remaining_sgb;

  v_proc := 0; v_upd := 0; v_synth := 0;
  FOR r IN
    SELECT DISTINCT ssl.sg_event_id,
                    c.sg_event_name   AS event_name,
                    c.sg_venue_name   AS venue_name,
                    c.sg_venue_id     AS sg_venue_id,
                    c.sg_datetime_utc AS event_date
    FROM public.seatgeek_seller_listings ssl
    LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = ssl.sg_event_id
    WHERE ssl.aq_short_event_id IS NULL
    LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id, r.event_name, r.venue_name,
                                     r.event_date, NULL, NULL, r.sg_venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.event_name, r.venue_name, r.event_date, r.sg_event_id);
      v_synth := v_synth + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short, v_performer_short
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.seatgeek_seller_listings ssl SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short),
        performer_short_id = coalesce(performer_short_id, v_performer_short)
      WHERE ssl.sg_event_id = r.sg_event_id AND ssl.aq_short_event_id IS NULL;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
      v_upd := v_upd + v_rows;
    END IF;
    PERFORM pg_sleep(0.2);
  END LOOP;
  SELECT count(DISTINCT sg_event_id) INTO v_remaining_sgs
    FROM public.seatgeek_seller_listings WHERE aq_short_event_id IS NULL;
  RETURN QUERY SELECT 'seatgeek_seller_listings'::text, v_proc, v_upd, v_synth, v_remaining_sgs;
END $function$;

REVOKE EXECUTE ON FUNCTION public.match_unmatched_listings_chunked(integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.match_unmatched_listings_chunked(integer, boolean) TO service_role;

-- ---- 8/11: match_unmatched_orders_sweep(integer, boolean) ----
CREATE OR REPLACE FUNCTION public.match_unmatched_orders_sweep(
  p_max_per_table    integer DEFAULT 500,
  p_create_synthetic boolean DEFAULT true
)
RETURNS TABLE(table_name text, rows_examined integer, rows_matched integer, rows_synthetic integer, rows_unmatched integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_aq_id text; v_conf numeric(3,2); v_method text;
  v_venue_short_id text; v_performer_short_id text;
  v_matched int; v_synthetic int; v_examined int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'match_unmatched_orders_sweep: caller % not authorized', current_user;
  END IF;
  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT vivid_order_id, raw, event_name, event_date,
           (raw->'venue'->>'name')                AS v_venue,
           NULLIF(raw->>'productionId','')::bigint AS pid
    FROM public.vivid_orders
    WHERE aq_short_event_id IS NULL
      AND status <> 'ignored_tbd_postponed'
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('vivid', r.pid, r.event_name, r.v_venue, r.event_date) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('vivid', r.event_name, r.v_venue, r.event_date, r.pid);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short_id, v_performer_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.vivid_orders SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short_id),
        performer_short_id = coalesce(performer_short_id, v_performer_short_id)
      WHERE vivid_order_id = r.vivid_order_id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'vivid_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT tp_order_id, raw, event_name, event_date,
           (raw->'venue'->>'name')                          AS v_venue,
           NULLIF(raw->'venue'->>'id','')::bigint           AS source_vid,
           NULLIF(raw->'venue'->>'latitude','')::numeric    AS lat,
           NULLIF(raw->'venue'->>'longitude','')::numeric   AS lon,
           NULLIF(raw->>'event_date_utc','')::timestamptz   AS event_date_utc
    FROM public.tickpick_orders
    WHERE aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('tickpick', NULL,
           r.event_name, r.v_venue,
           coalesce(r.event_date_utc, r.event_date),
           r.lat, r.lon, r.source_vid) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('tickpick', r.event_name, r.v_venue,
                                               coalesce(r.event_date_utc, r.event_date));
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short_id, v_performer_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.tickpick_orders SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short_id),
        performer_short_id = coalesce(performer_short_id, v_performer_short_id)
      WHERE tp_order_id = r.tp_order_id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'tickpick_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT id, sg_order_id, sg_event_id, sg_event_name, sg_venue, sg_event_date
    FROM public.seatgeek_orders
    WHERE aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id,
                                     r.sg_event_name, r.sg_venue,
                                     r.sg_event_date::timestamptz) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.sg_event_name IS NOT NULL AND r.sg_event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.sg_event_name, r.sg_venue,
                                               r.sg_event_date::timestamptz, r.sg_event_id);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id INTO v_venue_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.seatgeek_orders SET
        aq_short_event_id = v_aq_id,
        venue_short_id    = coalesce(venue_short_id, v_venue_short_id)
      WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'seatgeek_orders'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT s.id, s.sg_event_id,
           c.sg_event_name   AS event_name,
           c.sg_venue_name   AS venue_name,
           c.sg_datetime_utc AS event_date,
           c.sg_venue_id     AS sg_venue_id
    FROM public.seatgeek_sales_snapshots s
    LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = s.sg_event_id
    WHERE s.aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('seatgeek', r.sg_event_id,
                                     r.event_name, r.venue_name, r.event_date,
                                     NULL, NULL, r.sg_venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.event_date IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('seatgeek', r.event_name, r.venue_name,
                                               r.event_date, r.sg_event_id);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id INTO v_venue_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.seatgeek_sales_snapshots SET
        aq_short_event_id = v_aq_id,
        venue_short_id    = coalesce(venue_short_id, v_venue_short_id)
      WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'seatgeek_sales_snapshots'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;

  v_examined := 0; v_matched := 0; v_synthetic := 0;
  FOR r IN
    SELECT i.id, i.event_id, i.event_name, i.venue_name, i.occurs_at, i.venue_id
    FROM public.evo_order_items i
    WHERE i.aq_short_event_id IS NULL
    LIMIT p_max_per_table
  LOOP
    v_examined := v_examined + 1;
    SELECT m.aq_short_event_id INTO v_aq_id
    FROM public.match_to_aq_event_id('evo', NULL,
                                     r.event_name, r.venue_name, r.occurs_at,
                                     NULL, NULL, r.venue_id) m
    LIMIT 1;
    IF v_aq_id IS NULL AND p_create_synthetic AND r.event_name IS NOT NULL AND r.occurs_at IS NOT NULL THEN
      v_aq_id := public.create_system_aq_event('evo', r.event_name, r.venue_name, r.occurs_at);
      v_synthetic := v_synthetic + 1;
    END IF;
    IF v_aq_id IS NOT NULL THEN
      SELECT a.venue_short_id, a.performer_short_id INTO v_venue_short_id, v_performer_short_id
      FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq_id LIMIT 1;
      UPDATE public.evo_order_items SET
        aq_short_event_id  = v_aq_id,
        venue_short_id     = coalesce(venue_short_id,     v_venue_short_id),
        performer_short_id = coalesce(performer_short_id, v_performer_short_id)
      WHERE id = r.id;
      v_matched := v_matched + 1;
    END IF;
  END LOOP;
  RETURN QUERY SELECT 'evo_order_items'::text, v_examined, v_matched, v_synthetic, v_examined - v_matched;
END $function$;

REVOKE EXECUTE ON FUNCTION public.match_unmatched_orders_sweep(integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.match_unmatched_orders_sweep(integer, boolean) TO service_role;

-- ---- 9/11: sg_canonical_link_from_tevo_chunked(integer) ----
CREATE OR REPLACE FUNCTION public.sg_canonical_link_from_tevo_chunked(p_max_events integer DEFAULT 100)
RETURNS TABLE(events_processed integer, matches_made integer, tier_breakdown jsonb, events_remaining integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; m RECORD;
  v_proc int := 0; v_matched int := 0;
  v_tiers jsonb := '{}'::jsonb;
  v_remaining int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_canonical_link_from_tevo_chunked: caller % not authorized', current_user;
  END IF;
  FOR r IN
    SELECT e.id, e.name, e.venue_name, e.venue_id, e.occurs_at_local,
           (SELECT latitude  FROM venue_assets WHERE tevo_venue_id = e.venue_id) AS lat,
           (SELECT longitude FROM venue_assets WHERE tevo_venue_id = e.venue_id) AS lon
    FROM public.events e
    WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '90 days'
      AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical WHERE tevo_event_id = e.id)
    ORDER BY e.occurs_at_local LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    SELECT * INTO m FROM public.match_tevo_to_sg_canonical(
      r.name, r.venue_name, r.occurs_at_local::timestamptz, r.venue_id, r.lat, r.lon
    ) LIMIT 1;
    IF m.sg_event_id IS NOT NULL THEN
      UPDATE public.sg_events_canonical
        SET tevo_event_id = r.id,
            match_method  = m.match_method,
            match_confidence = m.confidence,
            matched_at = now()
        WHERE sg_event_id = m.sg_event_id
          AND (tevo_event_id IS NULL OR tevo_event_id = r.id);
      IF FOUND THEN
        v_matched := v_matched + 1;
        v_tiers := v_tiers || jsonb_build_object(m.match_method, coalesce((v_tiers->>m.match_method)::int, 0) + 1);
      END IF;
    END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
  SELECT count(*) INTO v_remaining FROM public.events e
    WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '90 days'
      AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
      AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical WHERE tevo_event_id = e.id);
  RETURN QUERY SELECT v_proc, v_matched, v_tiers, v_remaining;
END $function$;

REVOKE EXECUTE ON FUNCTION public.sg_canonical_link_from_tevo_chunked(integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_canonical_link_from_tevo_chunked(integer) TO service_role;

-- ---- 10/11: sg_classify_events() ---------------------------
CREATE OR REPLACE FUNCTION public.sg_classify_events()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_classify_events: caller % not authorized', current_user;
  END IF;
  WITH listings_by_tevo AS (
    SELECT
      event_id AS tevo_event_id,
      count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
      count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
      AND event_id IS NOT NULL
    GROUP BY event_id
  ),
  listings_by_aq AS (
    SELECT
      aq_short_event_id,
      count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
      count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
      AND aq_short_event_id IS NOT NULL
    GROUP BY aq_short_event_id
  ),
  event_metrics AS (
    SELECT
      c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_datetime_utc,
      coalesce(a.aq_short_event_id,
               (SELECT aem.aq_short_event_id FROM public.aq_event_map aem WHERE aem.sg_event_id = c.sg_event_id LIMIT 1)) AS aq_short_event_id,
      EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event,
      coalesce(lt.owned_cnt,    la.owned_cnt,    0) AS owned_cnt,
      coalesce(lt.listings_cnt, la.listings_cnt, 0) AS listings_cnt
    FROM public.sg_events_canonical c
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = c.sg_event_id
    LEFT JOIN listings_by_tevo lt ON lt.tevo_event_id = c.tevo_event_id
    LEFT JOIN listings_by_aq   la ON la.aq_short_event_id = a.aq_short_event_id
    WHERE c.sg_datetime_utc IS NOT NULL
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '60 days'
  ),
  classified AS (
    SELECT em.*,
      (SELECT p.tier FROM public.sg_priority_policy p
       WHERE p.enabled = true
         AND em.hours_to_event >= coalesce(p.min_hours_to_event, -999999)
         AND em.hours_to_event <  coalesce(p.max_hours_to_event, 999999)
         AND (p.requires_owned = false OR em.owned_cnt > 0)
       ORDER BY p.sort_order LIMIT 1) AS tier
    FROM event_metrics em
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         owned_cnt, listings_cnt, coalesce(tier, 'SKIP'), hours_to_event, v_now
  FROM classified WHERE sg_event_id IS NOT NULL
  ON CONFLICT (sg_event_id) DO UPDATE SET
    sg_event_name           = EXCLUDED.sg_event_name,
    sg_venue_name           = EXCLUDED.sg_venue_name,
    sg_datetime_utc         = EXCLUDED.sg_datetime_utc,
    aq_short_event_id       = EXCLUDED.aq_short_event_id,
    owned_count_last_7d     = EXCLUDED.owned_count_last_7d,
    active_listings_last_7d = EXCLUDED.active_listings_last_7d,
    tier                    = EXCLUDED.tier,
    hours_to_event          = EXCLUDED.hours_to_event,
    computed_at             = EXCLUDED.computed_at,
    sales_polls_today       = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day              = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END $function$;

REVOKE EXECUTE ON FUNCTION public.sg_classify_events() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_classify_events() TO service_role;

-- ---- 11/11: sg_priority_poll_tick(integer) -----------------
CREATE OR REPLACE FUNCTION public.sg_priority_poll_tick(p_max_polls integer DEFAULT 50)
RETURNS TABLE(rpt_tier text, rpt_events_polled integer, rpt_scope text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_req bigint;
  v_now timestamptz := clock_timestamp();
  v_token text;
  v_polled_sales jsonb := '{}'::jsonb;
  v_polled_listings jsonb := '{}'::jsonb;
  v_remaining int := p_max_polls;
  v_tier_name text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_priority_poll_tick: caller % not authorized', current_user;
  END IF;
  v_token := public.get_app_secret('SEATGEEK_API_TOKEN');
  IF v_token IS NULL OR v_token = '' THEN
    RAISE NOTICE 'sg_priority_poll_tick: SEATGEEK_API_TOKEN missing';
    RETURN;
  END IF;

  FOR r IN
    SELECT s.sg_event_id, s.tier, s.sales_polls_today, p.interval_seconds, p.daily_polls_per_event
    FROM public.sg_event_priority_state s
    JOIN public.sg_priority_policy p ON p.tier = s.tier AND p.enabled = true
    WHERE p.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '2 hours'
      AND (s.last_polled_sales_at IS NULL
           OR v_now - s.last_polled_sales_at >= make_interval(secs => p.interval_seconds))
      AND (p.daily_polls_per_event IS NULL OR s.sales_polls_today < p.daily_polls_per_event)
    ORDER BY p.sort_order, s.sg_datetime_utc
    LIMIT v_remaining
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'sales', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_polled_sales_at = v_now, sales_polls_today = sales_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_polled_sales := v_polled_sales || jsonb_build_object(r.tier, coalesce((v_polled_sales->>r.tier)::int, 0) + 1);
    v_remaining := v_remaining - 1;
    EXIT WHEN v_remaining <= 0;
  END LOOP;

  IF v_remaining > 0 THEN
    FOR r IN
      SELECT s.sg_event_id, s.tier, s.listings_polls_today, p.interval_seconds, p.daily_polls_per_event
      FROM public.sg_event_priority_state s
      JOIN public.sg_priority_policy p ON p.tier = s.tier AND p.enabled = true
      WHERE p.tier <> 'SKIP'
        AND s.sg_datetime_utc > v_now - interval '2 hours'
        AND (s.last_polled_listings_at IS NULL
             OR v_now - s.last_polled_listings_at >= make_interval(secs => p.interval_seconds))
        AND (p.daily_polls_per_event IS NULL OR s.listings_polls_today < p.daily_polls_per_event)
      ORDER BY p.sort_order, s.sg_datetime_utc
      LIMIT v_remaining
    LOOP
      SELECT net.http_get(
        url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
        timeout_milliseconds := 30000
      ) INTO v_req;
      INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
        VALUES (r.sg_event_id, 'listings', v_req, v_now);
      UPDATE public.sg_event_priority_state
        SET last_polled_listings_at = v_now, listings_polls_today = listings_polls_today + 1
        WHERE sg_event_id = r.sg_event_id;
      v_polled_listings := v_polled_listings || jsonb_build_object(r.tier, coalesce((v_polled_listings->>r.tier)::int, 0) + 1);
      v_remaining := v_remaining - 1;
      EXIT WHEN v_remaining <= 0;
    END LOOP;
  END IF;

  FOR v_tier_name IN SELECT pp.tier FROM public.sg_priority_policy pp WHERE pp.enabled = true AND pp.tier <> 'SKIP'
  LOOP
    rpt_tier := v_tier_name;
    rpt_scope := 'sales';
    rpt_events_polled := coalesce((v_polled_sales->>v_tier_name)::int, 0);
    RETURN NEXT;
    rpt_scope := 'listings';
    rpt_events_polled := coalesce((v_polled_listings->>v_tier_name)::int, 0);
    RETURN NEXT;
  END LOOP;
END $function$;

REVOKE EXECUTE ON FUNCTION public.sg_priority_poll_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sg_priority_poll_tick(integer) TO service_role;

-- ============================================================
-- End of migration.
-- ============================================================
-- Verification (run as service_role after apply):
--
--   SELECT n.nspname || '.' || p.proname AS fn,
--          p.prosecdef AS is_definer,
--          pg_get_functiondef(p.oid) ~ 'current_user NOT IN' AS has_guard,
--          has_function_privilege('public', p.oid::regprocedure::text, 'EXECUTE') AS public_exec
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN ('aq_event_map_ingest','create_system_aq_event','cron_last_fire',
--                        'cron_resume_with_gate','cron_should_fire','listings_deltas_backfill_chunked',
--                        'match_unmatched_listings_chunked','match_unmatched_orders_sweep',
--                        'sg_canonical_link_from_tevo_chunked','sg_classify_events','sg_priority_poll_tick');
--   -- expect: all 11 with is_definer=true, has_guard=true, public_exec=false
--
--   SELECT tablename, rowsecurity FROM pg_tables
--    WHERE schemaname='public' AND tablename IN ('aq_venue_map','aq_performer_map');
--   -- expect: both rowsecurity=true
--
--   SELECT * FROM public.release_health_check() WHERE status <> 'ok';
--   -- expect: no new warn/fail rows vs. pre-apply baseline
