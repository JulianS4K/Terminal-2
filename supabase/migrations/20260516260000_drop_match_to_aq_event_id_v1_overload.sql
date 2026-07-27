-- ============================================================================
-- B1 OPS-HIGH (bot_chat #258, active 5+h): drop 7-arg match_to_aq_event_id.
--
-- Problem: two overloads coexist —
--   • 7-arg: (text, bigint, text, text, timestamptz, numeric DEFAULT NULL, numeric DEFAULT NULL)
--   • 8-arg: (text, bigint, text, text, timestamptz, numeric DEFAULT NULL, numeric DEFAULT NULL, bigint DEFAULT NULL)
-- The 5-arg call sites inside `match_unmatched_orders_sweep` (Vivid + SG
-- branches) match BOTH overloads via the DEFAULT fill, so Postgres refuses
-- to resolve and the cron `match_unmatched_orders_sweep_hourly` has been
-- failing every :22 since at least 18:22 UTC 2026-05-16.
--
-- Fix: drop the 7-arg overload. B1 verified no app-side or edge-fn callers
-- reference the 7-arg directly; all current callers route cleanly to 8-arg
-- (5-arg Vivid/SG + 8-arg TickPick/SG-snapshots/EVO via default fill).
--
-- Verification: `SELECT count(*) FROM pg_proc ... WHERE proname='match_to_aq_event_id'`
-- returns 1. Next :22 firing of match_unmatched_orders_sweep_hourly
-- succeeds.
-- ============================================================================

DROP FUNCTION IF EXISTS public.match_to_aq_event_id(
  p_source text, p_source_event_id bigint, p_event_name text, p_venue_name text,
  p_event_date timestamp with time zone, p_lat numeric, p_lon numeric
);

DO $check$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM pg_proc p
  JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname='public' AND p.proname='match_to_aq_event_id';
  IF n <> 1 THEN
    RAISE EXCEPTION 'expected exactly 1 match_to_aq_event_id overload after drop, found %', n;
  END IF;
END $check$;
