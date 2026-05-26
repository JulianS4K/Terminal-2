-- 20260526070000_broker_movers_home_rpc.sql
--
-- Adds get_broker_movers_home(p_window_hours int) SECDEF RPC.
--
-- PURPOSE (D0 handoff 2026-05-26):
--   The terminal Home/Movers panels call T.api('/api/broker/movers') which
--   resolves to a cross-origin Render URL when the terminal is on any host
--   other than vibepass-terminal-test (e.g. Railway mirror). That makes
--   Home/Movers entirely dependent on the Render /api being alive and
--   CORS-whitelisted. Blind Spots works on any host because it calls a
--   Supabase RPC directly. This migration brings movers to the same pattern.
--
-- WHAT IT DOES:
--   1. Calls get_event_movers_with_sg(p_window_hours) — existing RPC.
--   2. Lifecycle filter: drops ghost/completed/cancelled events (same logic
--      as the Python broker_movers endpoint's `include_inactive=False` path).
--   3. Enriches each row with the delta/val fields computed in Python today
--      (delta_market_pct/abs, delta_owned_pct/abs, *_val fields).
--   4. Returns a flat jsonb array of enriched event rows.
--      FE note: the /api path returns bucketed {events:{owned_winners:[]...}};
--      this RPC returns a flat array that the FE feeds directly into state.rows
--      (skipping unionRows). The /api path remains as a fallback (42883 guard).
--
-- SECURITY: @s4kent.com gate + REVOKE anon, identical to other broker RPCs.
--
-- ROLLBACK: DROP FUNCTION public.get_broker_movers_home(integer);

CREATE OR REPLACE FUNCTION public.get_broker_movers_home(
  p_window_hours integer DEFAULT 24
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_email  text;
  v_result jsonb;
BEGIN
  -- Auth gate: terminal is @s4kent.com only
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email
      USING errcode = '42501';
  END IF;

  p_window_hours := greatest(1, least(p_window_hours, 168));

  WITH rpc_raw AS (
    -- Pull the raw movers + SG sales data
    SELECT * FROM public.get_event_movers_with_sg(p_window_hours)
  ),
  -- Lifecycle filter: same as broker_movers(include_inactive=False) in Python.
  -- Keep events with no lifecycle row (unknown = optimistic) or is_active = true.
  -- Remove events where a lifecycle row exists AND is_active is false/null.
  lifecycle_filtered AS (
    SELECT r.*
    FROM rpc_raw r
    LEFT JOIN public.event_lifecycle el ON el.event_id = r.event_id
    WHERE el.event_id IS NULL   -- no lifecycle row → treat as active
       OR el.is_active = true
  ),
  -- Compute all enrichment fields that Python's broker_movers does in-process.
  enriched AS (
    SELECT
      f.event_id,
      f.name,
      f.primary_performer_id                                   AS performer_id,
      f.primary_performer_name                                 AS performer_name,
      f.venue_id,
      f.venue_name,
      f.occurs_at_local,
      f.latest_at,
      f.cur_market_med,
      f.cur_market_tix,
      f.cur_owned_med,
      f.cur_owned_tix,
      f.cur_owned_share,
      -- pct deltas: NULL-safe, avoid division by zero
      CASE WHEN f.cur_market_med  IS NOT NULL
                AND f.prev_market_med IS NOT NULL
                AND f.prev_market_med <> 0
           THEN round((f.cur_market_med - f.prev_market_med)
                      / f.prev_market_med * 100, 2)
           END                                                 AS delta_market_pct,
      CASE WHEN f.cur_market_med  IS NOT NULL
                AND f.prev_market_med IS NOT NULL
           THEN round(f.cur_market_med - f.prev_market_med, 2)
           END                                                 AS delta_market_abs,
      CASE WHEN f.cur_owned_med   IS NOT NULL
                AND f.prev_owned_med  IS NOT NULL
                AND f.prev_owned_med  <> 0
           THEN round((f.cur_owned_med - f.prev_owned_med)
                      / f.prev_owned_med * 100, 2)
           END                                                 AS delta_owned_pct,
      CASE WHEN f.cur_owned_med   IS NOT NULL
                AND f.prev_owned_med  IS NOT NULL
           THEN round(f.cur_owned_med - f.prev_owned_med, 2)
           END                                                 AS delta_owned_abs,
      -- notional values: price × quantity
      CASE WHEN f.cur_market_med  IS NOT NULL AND f.cur_market_tix  IS NOT NULL
           THEN round(f.cur_market_med  * f.cur_market_tix,  2) END AS cur_market_val,
      CASE WHEN f.prev_market_med IS NOT NULL AND f.prev_market_tix IS NOT NULL
           THEN round(f.prev_market_med * f.prev_market_tix, 2) END AS prev_market_val,
      CASE WHEN f.cur_owned_med   IS NOT NULL AND f.cur_owned_tix   IS NOT NULL
           THEN round(f.cur_owned_med   * f.cur_owned_tix,   2) END AS cur_owned_val,
      CASE WHEN f.prev_owned_med  IS NOT NULL AND f.prev_owned_tix  IS NOT NULL
           THEN round(f.prev_owned_med  * f.prev_owned_tix,  2) END AS prev_owned_val,
      coalesce(f.sg_sales_window, 0)                          AS sg_sales_window
    FROM lifecycle_filtered f
  )
  SELECT coalesce(
    jsonb_agg(
      to_jsonb(e) ||
      -- delta_val derived from the already-computed val fields
      jsonb_build_object(
        'delta_market_val',
          CASE WHEN e.cur_market_val IS NOT NULL AND e.prev_market_val IS NOT NULL
               THEN round(e.cur_market_val - e.prev_market_val, 2) END,
        'delta_owned_val',
          CASE WHEN e.cur_owned_val IS NOT NULL AND e.prev_owned_val IS NOT NULL
               THEN round(e.cur_owned_val - e.prev_owned_val, 2) END
      )
    ),
    '[]'::jsonb
  )
  INTO v_result
  FROM enriched e;

  RETURN v_result;
END;
$function$;

-- No anon/authenticated direct access — SECDEF only via Auth.client.rpc()
REVOKE ALL ON FUNCTION public.get_broker_movers_home(integer) FROM anon, public;
