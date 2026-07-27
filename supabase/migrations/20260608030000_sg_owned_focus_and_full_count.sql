-- ============================================================
-- SG redesign: owned-focus listings (½ rate) + once-daily sales + full-count fix.
-- A1 2026-06-08 (operator-directed). ## Gated: apply via MCP after review.
--
-- Operator directives (2026-06-07/08):
--  1. "changed the changed listing per pull issue" — the broker DEDUPES raw snapshots
--     via ON CONFLICT (content_hash = event:id:bp:q). A stable listing is written ONCE
--     and never again, so refresh_sg_broker_listings_event_metrics (DISTINCT ON sglid
--     over 24h) only counts the sglids that CHANGED in 24h → listings_all_count = 411
--     when the live feed has 3,560 (verified head-to-head vs TD-seatgeek 2026-06-08).
--     FIX: compute the FULL count + price/owned aggregates from the WHOLE response at
--     process time and write them straight to seatgeek_event_metrics. Raw-snapshot dedup
--     (storage saving) is UNCHANGED; only the metric path is corrected. Retire the
--     now-redundant (and under-counting) hourly listings-metrics refresh.
--  2. "cut pull requests by half and only poll owned events" — listings poll OWNED events
--     only, at 2× their band interval (½ frequency). Drop league + non-owned pollers.
--  3. SG sales — flat 24h per event, ALL non-SKIP events ≤90d (broker /sales returns the
--     full sales tape in one poll), keep the post-event final flush.
--
-- Net SG broker load ≈ 3,600→1,800 listings/day + ~1,559 sales/day; far fewer competing
-- pollers → the 10-req/10s burst contention (the 429 source) clears without a shared gate.
-- ============================================================

-- ── A) FULL-COUNT FIX: sg_broker_listings_process writes true per-pull metrics ──
-- Exact reproduction of the live body + one added block: on a 200, aggregate the FULL
-- response listings (not the deduped snapshot rows) and INSERT a seatgeek_event_metrics row.
CREATE OR REPLACE FUNCTION public.sg_broker_listings_process(p_limit integer DEFAULT 50)
 RETURNS TABLE(processed integer, listings_persisted integer)
 LANGUAGE plpgsql SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id,
           h.status_code, h.content::jsonb AS body,
           a.aq_short_event_id, x.tevo_event_id
    FROM public.sg_broker_pending p
    JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = p.sg_event_id
    LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = p.sg_event_id
    WHERE p.scope = 'listings' AND p.resolved_at IS NULL
    ORDER BY p.fired_at
    LIMIT p_limit
  LOOP
    v_processed := v_processed + 1;
    v_inserted := NULL;
    IF r.status_code = 200 AND jsonb_typeof(r.body->'listings') = 'array' THEN
      -- raw snapshots: UNCHANGED dedup-insert (ON CONFLICT keeps storage low)
      WITH src AS (SELECT l FROM jsonb_array_elements(r.body->'listings') AS l),
      ins AS (
        INSERT INTO public.seatgeek_listings_snapshots (
          tevo_event_id, sg_event_id, captured_at,
          sglid, display_id, retail_price_all_in, broadcast_price,
          deal_quality_score, quantity, splits, section, row,
          is_broker_owned, is_b2b, is_instant_download, is_sro,
          has_limited_view, is_wheelchair_acc, ada_details,
          delivery_method, in_hand_date, market_source, stock_type,
          seller_notes, endpoint, content_hash, raw, aq_short_event_id
        )
        SELECT r.tevo_event_id, r.sg_event_id, now(),
          NULLIF(l->>'sglid','')::bigint, l->>'id',
          NULLIF(l->>'pf','')::numeric, NULLIF(l->>'bp','')::numeric,
          NULLIF(l->>'ds','')::numeric, NULLIF(l->>'q','')::int,
          l->'sp', l->>'s', l->>'r',
          NULLIF(l->>'bo','')::boolean, NULLIF(l->>'is_b2b','')::boolean,
          NULLIF(l->>'idl','')::boolean, NULLIF(l->>'sro','')::boolean,
          NULLIF(l->>'lv','')::boolean, NULLIF(l->>'wa','')::boolean,
          l->>'ada', l->>'dm', NULLIF(l->>'ihd','')::date,
          l->>'m', l->>'st', l->>'pn',
          '/listings',
          md5(r.sg_event_id::text || ':' || (l->>'id') || ':' || (l->>'bp') || ':' || (l->>'q')),
          l, r.aq_short_event_id
        FROM src WHERE l->>'id' IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);

      -- FULL-COUNT FIX (2026-06-08): aggregate the WHOLE response (not the deduped rows)
      -- and write the true current-inventory metrics for this event. Matches the column
      -- set + broadcast_price basis of refresh_sg_broker_listings_event_metrics.
      INSERT INTO public.seatgeek_event_metrics (
        sg_event_id, tevo_event_id, captured_at,
        listings_all_count, listings_all_tickets,
        listings_all_min, listings_all_p25, listings_all_median, listings_all_mean,
        listings_all_p75, listings_all_p90, listings_all_max,
        listings_owned_count, listings_owned_tickets,
        listings_owned_min, listings_owned_p25, listings_owned_median, listings_owned_mean,
        listings_owned_p75, listings_owned_p90, listings_owned_max)
      SELECT r.sg_event_id, r.tevo_event_id, now(),
        count(*)::int, coalesce(sum(q),0)::int,
        round(min(bp),2),
        round(percentile_cont(0.25) WITHIN GROUP (ORDER BY bp)::numeric,2),
        round(percentile_cont(0.50) WITHIN GROUP (ORDER BY bp)::numeric,2),
        round(avg(bp),2),
        round(percentile_cont(0.75) WITHIN GROUP (ORDER BY bp)::numeric,2),
        round(percentile_cont(0.90) WITHIN GROUP (ORDER BY bp)::numeric,2),
        round(max(bp),2),
        count(*) FILTER (WHERE bo)::int, coalesce(sum(q) FILTER (WHERE bo),0)::int,
        round(min(bp) FILTER (WHERE bo),2),
        round((percentile_cont(0.25) WITHIN GROUP (ORDER BY bp) FILTER (WHERE bo))::numeric,2),
        round((percentile_cont(0.50) WITHIN GROUP (ORDER BY bp) FILTER (WHERE bo))::numeric,2),
        round(avg(bp) FILTER (WHERE bo),2),
        round((percentile_cont(0.75) WITHIN GROUP (ORDER BY bp) FILTER (WHERE bo))::numeric,2),
        round((percentile_cont(0.90) WITHIN GROUP (ORDER BY bp) FILTER (WHERE bo))::numeric,2),
        round(max(bp) FILTER (WHERE bo),2)
      FROM (
        SELECT NULLIF(l->>'bp','')::numeric AS bp, NULLIF(l->>'q','')::int AS q,
               NULLIF(l->>'bo','')::boolean AS bo
        FROM jsonb_array_elements(r.body->'listings') l
        WHERE l->>'id' IS NOT NULL AND NULLIF(l->>'bp','') IS NOT NULL
      ) lst
      HAVING count(*) > 0;
    END IF;

    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = CASE
            WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0)
            WHEN r.status_code = 429 THEN -429
            ELSE -1 END
      WHERE id = r.pending_id;

    -- advance cadence clock on 200 OR terminal 4xx (except 429) — unchanged (A1 2026-06-02)
    IF r.status_code = 200
       OR (r.status_code BETWEEN 400 AND 499 AND r.status_code <> 429) THEN
      UPDATE public.sg_event_priority_state
        SET last_polled_listings_at = now()
        WHERE sg_event_id = r.sg_event_id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

-- the hourly refresh now UNDER-counts (deduped snapshots) and is superseded by the per-pull
-- metrics above. Disable its cron; keep the function for ad-hoc/backfill use.
DO $u$ BEGIN PERFORM cron.unschedule('sg_broker_listings_metrics_refresh_hourly');
EXCEPTION WHEN OTHERS THEN NULL; END $u$;

-- ── B) LISTINGS: owned-only at ½ band rate ──────────────────────────────────
-- Add a rate multiplier; owned cron passes 2 (→ poll each owned event half as often).
-- Drop the old 3-arg signature first (adding a DEFAULT param creates an overload, not a
-- replacement — see MIGRATION_CONVENTIONS §3 landmine; a later 3-arg call would be ambiguous).
DROP FUNCTION IF EXISTS public.sg_listings_poll_tick(integer, integer, text);
CREATE OR REPLACE FUNCTION public.sg_listings_poll_tick(
  p_max integer DEFAULT 20, p_min_remaining integer DEFAULT 3,
  p_owned_kind text DEFAULT NULL::text, p_rate_mult numeric DEFAULT 1)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_remaining int; r RECORD; v_req bigint; v_now timestamptz := clock_timestamp(); v_count int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
  FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
  WHERE h.headers ? 'ratelimit-remaining' AND h.created > v_now - interval '10 seconds'
  ORDER BY h.id DESC LIMIT 1;
  IF v_remaining IS NOT NULL AND v_remaining < p_min_remaining THEN RETURN 0; END IF;

  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    JOIN LATERAL public.collector_band('SG','listings',
           EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0,
           (coalesce(s.owned_count_last_7d,0) > 0)) c ON true
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      AND ( p_owned_kind IS NULL
            OR (coalesce(s.owned_count_last_7d,0) > 0) = (p_owned_kind = 'owned') )
      AND ( s.last_polled_listings_at IS NULL
            OR s.last_polled_listings_at < v_now - make_interval(mins => round(c.required_min * p_rate_mult)::int) )
      AND ( s.last_fired_listings_at IS NULL
            OR s.last_fired_listings_at < v_now - interval '90 seconds' )
    ORDER BY c.required_min ASC, s.last_polled_listings_at ASC NULLS FIRST, s.sg_datetime_utc
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_fired_listings_at = v_now, listings_polls_today = listings_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;

-- owned-only @ ½ rate, p_max 5→4 (burst headroom). Drop league + non-owned + league rescue.
SELECT cron.schedule('sg_listings_poll_owned_1min', '*/2 * * * *',
  $cb$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_listings_poll_owned_1min') THEN RETURN; END IF; PERFORM public.sg_listings_poll_tick(4, 3, 'owned', 2); END $b$;$cb$);
DO $u$ BEGIN
  PERFORM cron.unschedule('sg_listings_poll_league_2min');
  PERFORM cron.unschedule('sg_listings_poll_nonowned_5min');
  PERFORM cron.unschedule('sg_priority_rescue_league_15min');
EXCEPTION WHEN OTHERS THEN NULL; END $u$;

-- ── C) SALES: flat 24h, all non-SKIP ≤90d, keep post-event final flush ───────
DROP FUNCTION IF EXISTS public.sg_sales_poll_tick(integer);  -- old 1-arg → avoid overload ambiguity
CREATE OR REPLACE FUNCTION public.sg_sales_poll_tick(p_max integer DEFAULT 50, p_horizon_days integer DEFAULT 90)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; v_req bigint; v_now timestamptz := clock_timestamp();
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN'); v_polled int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'sg_sales_poll_tick: caller % not authorized', current_user; END IF;
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  IF p_max <= 0 THEN RETURN 0; END IF;
  FOR r IN
    SELECT s.sg_event_id,
           EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0 AS hte
    FROM public.sg_event_priority_state s
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '24 hours'
      AND s.sg_datetime_utc <= v_now + make_interval(days => p_horizon_days)
      AND (
        -- post-event one-shot final flush: poll once after the event ends
        ( EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0 < -2
          AND (s.last_polled_sales_at IS NULL OR s.last_polled_sales_at < s.sg_datetime_utc) )
        -- otherwise: flat once-a-day (one /sales poll returns the full sales tape)
        OR ( EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0 >= -2
          AND (s.last_polled_sales_at IS NULL OR s.last_polled_sales_at < v_now - interval '24 hours') )
      )
    ORDER BY (EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0 < -2) DESC,
             s.last_polled_sales_at NULLS FIRST, s.sg_datetime_utc
    LIMIT p_max
  LOOP
    SELECT net.http_get(url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'sales', v_req, v_now);
    UPDATE public.sg_event_priority_state SET last_polled_sales_at = v_now, sales_polls_today = sales_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_polled := v_polled + 1;
  END LOOP;
  RETURN v_polled;
END $function$;

-- sales cron: cover ~1,559 events/day @ 1×/day → ~4/tick is ample; p_max 4 (was 4). Keep odd-minute stagger.
SELECT cron.schedule('sg_sales_poll_5min', '1-59/2 * * * *',
  $cb$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_sales_poll_5min') THEN RETURN; END IF; PERFORM public.sg_sales_poll_tick(4, 90); END $b$;$cb$);
