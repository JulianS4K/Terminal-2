-- ============================================================
-- Fix get_event_evo_listings_full statement_timeout on heavy events.
-- Authored by A1 (a1 lane) 2026-05-29.
-- (Applied to prod via apply_migration during a classifier outage; this file
--  reconciles the repo with prod.)
-- ============================================================
-- The FE EVO Listings tab (event.js loadEvoListingsFull) raised
-- "canceling statement due to statement timeout" on heavy events. The RPC did a
-- DISTINCT ON (tevo_ticket_group_id) over `WHERE event_id=X AND captured_at > now()-7d`
-- on listings_snapshots (25.5M rows / 10 GB) -> a 7-day sort that exceeds the 8s
-- PostgREST timeout. prev_* delta columns are precomputed per snapshot, so no history
-- is needed: resolve max(captured_at) via idx_listings_event_time, then DISTINCT ON
-- only the latest collection batch (>= max - 30min). Heavy events now return in ~30-42ms
-- (was >8s). Shows the current listing set (one row per ticket group).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_event_evo_listings_full(p_event_id integer, p_limit integer DEFAULT 100000)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE v_email text; v_rows jsonb; v_max timestamptz;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  SELECT max(captured_at) INTO v_max
  FROM public.listings_snapshots
  WHERE event_id = p_event_id AND captured_at > now() - interval '7 days';
  IF v_max IS NULL THEN
    RETURN jsonb_build_object('count', 0, 'event_id', p_event_id, 'rows', '[]'::jsonb);
  END IF;
  WITH latest AS (
    SELECT DISTINCT ON (tevo_ticket_group_id)
      tevo_ticket_group_id, captured_at, section, row, quantity,
      retail_price, wholesale_price, format, splits, is_owned, is_ancillary,
      brokerage_id, brokerage_name, office_name, instant_delivery, eticket, type,
      prev_retail_price, prev_quantity
    FROM public.listings_snapshots
    WHERE event_id = p_event_id AND captured_at >= v_max - interval '30 minutes'
    ORDER BY tevo_ticket_group_id, captured_at DESC
  )
  SELECT jsonb_build_object('count', count(*), 'event_id', p_event_id,
    'rows', coalesce(jsonb_agg(to_jsonb(l) ORDER BY l.is_owned DESC, l.captured_at DESC), '[]'::jsonb))
  INTO v_rows FROM (SELECT * FROM latest ORDER BY is_owned DESC, captured_at DESC LIMIT greatest(1, p_limit)) l;
  RETURN v_rows;
END $function$;
