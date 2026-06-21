-- ============================================================================
-- Migration 20260621152000 — raise SG broker 429 alert threshold 15% -> 20%
--
-- Lane:     A1 (data plane / SG broker monitoring)
-- Touches:  public.check_sg_broker_429_health (W, CREATE OR REPLACE)
-- Pre-reqs: 20260519130000 (429 monitoring protocol)
-- Apply:    PROPOSAL — authored under operator-directed automated-runs review;
--           apply is A1/operator-gated (CLAUDE.md §1).
--
-- WHY:
--   Live pct_429 on the `listings` scope hovers 3-18% at peak hours and sits
--   right ON the 15% alert line (verified 2026-06-21; `sales` scope = 0%). The
--   */15 cron therefore re-flags on every breach, producing the ~80 SG_BROKER_429
--   bot_chat flags the C1 checkpoint called the "dominant 2nd-day signal." This
--   is line-dancing, not an incident — the original migration itself noted the
--   15% number was provisional ("bump ... if the threshold is too noisy").
--
-- FIX:
--   Raise the in-function threshold to 20% (5pt headroom over observed peak),
--   which keeps a genuine sustained-rate-limit alert while killing the noise.
--   Only the v_threshold literal changes; hysteresis + payload are unchanged.
--
-- NOTE for A1: this is the noise-cut, not the cure. If peak listings 429s are
--   structurally too high, the durable fix is a small listings poll burst/cadence
--   trim to stay under the SG token quota (see v_sg_token_budget). Threshold bump
--   buys quiet while that's evaluated.
--
-- VERIFICATION (run after apply):
--   SELECT public.check_sg_broker_429_health();  -- 'threshold' = 20, 'alerted' false at <20%
-- ============================================================================

CREATE OR REPLACE FUNCTION public.check_sg_broker_429_health()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_pct_429_listings numeric;
  v_pct_429_sales    numeric;
  v_total_listings   int;
  v_total_sales      int;
  v_starved_count    int;
  v_alerted_recently boolean;
  v_alert_msg        text;
  v_threshold        numeric := 20.0;   -- was 15.0 (mig 20260519130000); raised to cut line-dancing noise
BEGIN
  SELECT
    count(*) FILTER (WHERE scope = 'listings'),
    count(*) FILTER (WHERE scope = 'sales'),
    round(100.0 * count(*) FILTER (WHERE rows_persisted = -429 AND scope = 'listings')
          / NULLIF(count(*) FILTER (WHERE scope = 'listings'), 0), 1),
    round(100.0 * count(*) FILTER (WHERE rows_persisted = -429 AND scope = 'sales')
          / NULLIF(count(*) FILTER (WHERE scope = 'sales'), 0), 1)
  INTO v_total_listings, v_total_sales, v_pct_429_listings, v_pct_429_sales
  FROM public.sg_broker_pending
  WHERE fired_at > now() - interval '1 hour'
    AND resolved_at IS NOT NULL;

  SELECT count(*) INTO v_starved_count FROM public.v_sg_broker_429_starved_events;

  SELECT EXISTS (
    SELECT 1 FROM public.bot_chat
    WHERE event_type = 'flag'
      AND bot_lane = 'A1'
      AND message LIKE 'SG_BROKER_429_HEALTH:%'
      AND created_at > now() - interval '1 hour'
      AND resolved_at IS NULL
  ) INTO v_alerted_recently;

  IF (coalesce(v_pct_429_listings, 0) > v_threshold OR coalesce(v_pct_429_sales, 0) > v_threshold)
     AND NOT v_alerted_recently
  THEN
    v_alert_msg := 'SG_BROKER_429_HEALTH: pct_429 over threshold (>'
      || v_threshold::text || '%) — listings='
      || coalesce(v_pct_429_listings, 0)::text || '% ('
      || v_total_listings::text || ' req/h), sales='
      || coalesce(v_pct_429_sales, 0)::text || '% ('
      || v_total_sales::text || ' req/h). '
      || v_starved_count::text
      || ' chronically-starved events. Inspect: SELECT * FROM v_sg_broker_429_health; SELECT * FROM v_sg_broker_429_starved_events;';
    PERFORM public.bot_chat_log(
      p_level => 'admin', p_lane => 'A1',
      p_event_type => 'flag',
      p_message => v_alert_msg,
      p_related_pr => NULL, p_related_mig => '20260519130000',
      p_in_reply_to => NULL::bigint, p_meta => NULL::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'checked_at',        now(),
    'pct_429_listings',  v_pct_429_listings,
    'pct_429_sales',     v_pct_429_sales,
    'total_listings_1h', v_total_listings,
    'total_sales_1h',    v_total_sales,
    'starved_events',    v_starved_count,
    'threshold',         v_threshold,
    'alerted',           (coalesce(v_pct_429_listings, 0) > v_threshold OR coalesce(v_pct_429_sales, 0) > v_threshold) AND NOT v_alerted_recently,
    'already_open_flag', v_alerted_recently
  );
END $function$;
