-- ============================================================================
-- Migration 20260911162400 — the EVO leg of the scanner never ran: temp-table collision
--
-- Lane:     D0 (deals surface)
-- Touches:  scan_listing_deals(…) (CREATE OR REPLACE — resets its scratch tables per call)
-- Pre-reqs: 20260911162300
--
-- Operator 2026-09-11: "give sources its own temp".
--
-- THE BUG. `deal_scan_tick_1min` calls the scanner twice in ONE cron transaction:
--     PERFORM scan_listing_deals('gotickets', 25);   -- creates _cand, _present, _lst, _scored, _deals
--     PERFORM scan_listing_deals('evo', 25);         -- CREATE TEMP TABLE _cand  ->  42P07
-- The five scratch tables are declared ON COMMIT DROP, and ON COMMIT does not fire until the
-- transaction COMMITS — not when the function returns. So the second call always collided on
-- the first name it creates, and the tick's own exception handler swallowed it as a WARNING:
--
--     first[gotickets OK]  second[evo FAILED: relation "_cand" already exists]
--
-- Measured before this fix: the EVO leg scanned 15 times in 24 HOURS (it should run every tick),
-- last at 18:54Z, while 266 EVO events meeting every candidate rule had been captured in the
-- preceding 30 minutes. Live EVO rows in the feed: 0. This was read as a 7-day-floor effect in
-- migs 161800-162300; it was not — the leg was barely executing. EVO only ever got through on a
-- tick where the GoTickets call failed BEFORE reaching its first CREATE TEMP TABLE.
--
-- Predates 162300: _cand / _lst / _scored / _deals collided the same way from 161800 onward.
-- 162300's _present did not cause it and does not change it (_cand still collides first).
--
-- THE FIX. Each call now starts from a clean set of scratch tables instead of inheriting the
-- previous call's. Renaming them per source (_cand_gotickets / _cand_evo) was the other option
-- but there are 35 references across the five names and every query would have to become
-- EXECUTE format(...) dynamic SQL — a large, high-risk rewrite of the function that IS the
-- product, for no behavioural gain over this. Splitting the tick into one cron job per source
-- would also work (separate transactions, no shared temp namespace) and stays available.
--
-- Names are pg_temp-qualified so this can never touch a permanent table.
--
-- ROLLBACK: re-apply scan_listing_deals from 20260911162300 (restores the collision).
-- ============================================================================

DO $do$
DECLARE
  v_def  text;
  v_args text;
  v_cnt  int;
  v_old  text := $a$  PERFORM set_config('statement_timeout', '45000', true);

  IF p_source = 'gotickets' THEN
    CREATE TEMP TABLE _cand ON COMMIT DROP AS$a$;
  v_new  text := $b$  PERFORM set_config('statement_timeout', '45000', true);

  -- Give this call its own scratch tables. Both sources run as two calls inside ONE cron
  -- transaction and ON COMMIT DROP does not fire until that transaction commits, so without
  -- this reset the second call dies on "relation _cand already exists" and that source never
  -- scans. pg_temp-qualified so it can only ever drop this session's temp tables.
  DROP TABLE IF EXISTS pg_temp._cand, pg_temp._present, pg_temp._lst, pg_temp._scored, pg_temp._deals;

  IF p_source = 'gotickets' THEN
    CREATE TEMP TABLE _cand ON COMMIT DROP AS$b$;
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid) INTO v_def, v_args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'scan_listing_deals';
  IF v_def IS NULL THEN RAISE EXCEPTION 'scan_listing_deals not found'; END IF;

  v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'anchor matched % times (expected exactly 1) — refusing to replace scanner', v_cnt;
  END IF;

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.scan_listing_deals(%s) RETURNS jsonb LANGUAGE plpgsql '
    || 'SECURITY DEFINER SET search_path TO ''public'', ''extensions'', ''pg_temp'' AS %L',
    v_args, replace(v_def, v_old, v_new));
END
$do$;

COMMENT ON FUNCTION public.scan_listing_deals(text,integer,numeric,integer,numeric,numeric,numeric,integer,numeric,integer,numeric,numeric,numeric,boolean) IS
  'Deal scanner for one listing source (gotickets | evo): events with a curated zone, 7+ days out, polled in the last 30 min, newest capture newer than the last scan — nearest event first. Resets its own scratch tables on entry, because the tick calls it once per source inside ONE transaction and ON COMMIT DROP only fires at commit (mig 20260911162400 — before it, the second source silently never scanned). _present is the whole capture, _lst drops deal_listing_excluded() rows. Curated-zone MAD outliers → realized anchor → PRICE MODEL → gotickets_deals_feed; retires name their cause (delisted | excluded | repriced) for deal_listing_spell. D0 mig 20260911161800 / 162000 / 162100 / 162200 / 162300 / 162400.';
