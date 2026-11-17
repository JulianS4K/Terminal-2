-- Migration 20260811260000 · lane:D0/A1 (GoTickets ingest) · operator-directed 2026-08-11
--   ("events 2 weeks out and above pinged for the deal at max, US, without using all credits").
--
--   writes: gt_listings_poll_state [+cols consecutive_empty, cold_until, quarantined_until,
--           last_status], gt_listings_drain(int) [fn — classify outcome + backoff],
--           gt_listings_poll_tick(int) [fn — deal-focused cadence + budget ceiling],
--           view v_gt_credit_health.
--   auth: builder service_role-guarded SECDEF; view SELECT to authenticated/service_role.
--
-- STRATEGY. An event with no inventory can't carry a deal, and most far-out events return
-- empty. So we concentrate the (credit-metered) GoTickets budget where deals actually are:
--   * ≥14d-out US event WITH inventory ("hot") → poll every 10 min (max, for deal detection).
--   * ≥14d-out US event that returns [] ("cold", ≥2 consecutive empties) → poll every 6h just
--     to detect new inventory; the first non-empty poll clears cold → back to 10 min.
--   * 402 "Credits is not enough" → quarantine 7d (skip; weekly re-probe catches a recharge).
--     404 → quarantine 30d (event effectively gone).
--   * <14d-out US events → the normal collector_band DTE curve (near events, less deal runway).
--   * Daily budget ceiling (v_daily_cap) → a hard stop so polling can never drain the whole
--     credit balance in a day. Set generously (empty-backoff already bounds spend); lower it
--     to enforce a tighter credit budget once the dashboard balance is known.
--
-- ROLLBACK: restore gt_listings_drain / gt_listings_poll_tick to mig 20260811250000;
--   ALTER TABLE gt_listings_poll_state DROP COLUMN consecutive_empty, cold_until,
--   quarantined_until, last_status; DROP VIEW v_gt_credit_health.

-- 1. Backoff / quarantine state on the per-event poll bookkeeping.
ALTER TABLE public.gt_listings_poll_state
  ADD COLUMN IF NOT EXISTS consecutive_empty  int     NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS cold_until         timestamptz,
  ADD COLUMN IF NOT EXISTS quarantined_until  timestamptz,
  ADD COLUMN IF NOT EXISTS last_status        int;

-- 2. Drain — insert listings (200 non-empty) AND classify each outcome into the cadence
--    state so the poller can back off empties + quarantine credit failures.
CREATE OR REPLACE FUNCTION public.gt_listings_drain(p_max integer DEFAULT 1000)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_total int := 0; v_rows int; v_ct int;
BEGIN
  SET LOCAL statement_timeout = '120s';
  FOR r IN
    SELECT inf.request_id, inf.gt_event_id, inf.tevo_event_id, inf.fired_at, resp.status_code, resp.content
    FROM public.gt_listings_inflight inf
    JOIN net._http_response resp ON resp.id = inf.request_id
    ORDER BY inf.fired_at LIMIT p_max
  LOOP
    v_ct := NULL;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN
        v_ct := jsonb_array_length(coalesce((r.content::jsonb) -> 'listings', '[]'::jsonb));
        IF v_ct > 0 THEN
          INSERT INTO public.gotickets_listings_snapshots
            (tevo_event_id, gt_event_id, captured_at, gt_listing_id, section, section_id, row,
             quantity, display_price, all_in_price, service_fee, face_value, stock_type,
             in_hand_date, general_admission, splits, notes)
          SELECT r.tevo_event_id, r.gt_event_id, r.fired_at, l."id", l.section, l."sectionId", l.row,
                 l.quantity, l."displayPrice", l."allInPrice", l."serviceFee", l."faceValue", l."stockType",
                 NULLIF(l."inHandDate", '')::date, l."generalAdmission",
                 ARRAY(SELECT jsonb_array_elements_text(COALESCE(l."validSplitQuantities", '[]'::jsonb))::int),
                 l.notes
          FROM jsonb_to_recordset( (r.content::jsonb) -> 'listings' ) AS l(
            "id" bigint, section text, "sectionId" bigint, row text, quantity int,
            "displayPrice" numeric, "allInPrice" numeric, "serviceFee" numeric, "faceValue" numeric,
            "stockType" text, "inHandDate" text, "generalAdmission" boolean,
            "validSplitQuantities" jsonb, notes text)
          ON CONFLICT (gt_event_id, captured_at, gt_listing_id) DO NOTHING;
          GET DIAGNOSTICS v_rows = ROW_COUNT;
          v_total := v_total + v_rows;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_ct := NULL;
        RAISE WARNING 'gt_listings_drain: request % (gt_event %) parse failed: %', r.request_id, r.gt_event_id, SQLERRM;
      END;
    END IF;

    -- Classify outcome into cadence state (empty backoff + credit quarantine).
    UPDATE public.gt_listings_poll_state ps SET
      last_status = r.status_code,
      consecutive_empty = CASE
        WHEN r.status_code = 200 AND coalesce(v_ct,0) > 0 THEN 0
        WHEN r.status_code = 200 AND coalesce(v_ct,0) = 0 THEN ps.consecutive_empty + 1
        ELSE ps.consecutive_empty END,
      cold_until = CASE
        WHEN r.status_code = 200 AND coalesce(v_ct,0) > 0 THEN NULL
        WHEN r.status_code = 200 AND coalesce(v_ct,0) = 0 AND ps.consecutive_empty + 1 >= 2
             THEN now() + interval '6 hours'
        ELSE ps.cold_until END,
      quarantined_until = CASE
        WHEN r.status_code = 402 THEN now() + interval '7 days'
        WHEN r.status_code = 404 THEN now() + interval '30 days'
        WHEN r.status_code = 200 THEN NULL
        ELSE ps.quarantined_until END
    WHERE ps.gt_event_id = r.gt_event_id;

    DELETE FROM public.gt_listings_inflight WHERE request_id = r.request_id;
  END LOOP;
  RETURN v_total;
END $function$;

-- 3. Poller — deal-focused cadence for US events, credit-conserving.
CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(p_max integer DEFAULT 120)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_n int := 0; v_req bigint; v_token text;
  v_daily_cap int := 1000000;  -- hard daily poll ceiling (credit safety); tune to balance
  us_states text[] := ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC'];
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  -- Daily credit budget ceiling.
  IF (SELECT coalesce(sum(listings_polls_today),0) FROM public.gt_listings_poll_state
        WHERE budget_day = current_date) >= v_daily_cap THEN
    RETURN 0;
  END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      SELECT g.gt_event_id, g.tevo_event_id, g.event_time_utc,
             EXTRACT(epoch FROM (g.event_time_utc - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
      WHERE g.status = 'AS_SCHEDULED'
        AND g.event_time_utc > now() - interval '3 hours'
        AND upper(btrim(coalesce(g.venue_state,''))) = ANY(us_states)
        AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())   -- skip credit-gated / gone
        AND (ps.cold_until       IS NULL OR ps.cold_until       < now())     -- skip cold (empty) events until due
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at,
             CASE WHEN ev.event_time_utc >= now() + interval '14 days' THEN 10   -- ≥2wk hot: max for deals
                  ELSE (SELECT required_min FROM public.collector_band('GT','listings', ev.hte)) END AS req_min
      FROM ev
    )
    SELECT gt_event_id, tevo_event_id FROM due
    WHERE last_polled_listings_at IS NULL
       OR last_polled_listings_at < now() - make_interval(mins => req_min)
    ORDER BY last_polled_listings_at NULLS FIRST
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
      headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept','application/json'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.gt_listings_inflight(request_id, gt_event_id, tevo_event_id, fired_at)
      VALUES (v_req, r.gt_event_id, r.tevo_event_id, now());
    INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.gt_event_id, now(), 1, current_date)
      ON CONFLICT (gt_event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

-- 4. Credit-depletion monitor — hourly 402/429/200 mix + 402 fraction (depletion proxy).
CREATE OR REPLACE VIEW public.v_gt_credit_health AS
SELECT date_trunc('hour', created) AS hr,
       count(*) FILTER (WHERE status_code = 200) AS ok_200,
       count(*) FILTER (WHERE status_code = 402) AS credits_402,
       count(*) FILTER (WHERE status_code = 429) AS rate_429,
       count(*) FILTER (WHERE status_code = 404) AS not_found_404,
       round(count(*) FILTER (WHERE status_code = 402)::numeric
             / nullif(count(*),0), 5) AS frac_402
FROM net._http_response
WHERE created > now() - interval '48 hours'
  AND (headers->>'server') = 'cloudflare'
GROUP BY 1 ORDER BY 1 DESC;
GRANT SELECT ON public.v_gt_credit_health TO authenticated, service_role;
COMMENT ON VIEW public.v_gt_credit_health IS
  'GoTickets API health / credit-depletion proxy: hourly 200/402/429/404 counts + 402 fraction. A flat low frac_402 = healthy; a rising frac_402 = the credit balance is actually draining. D0 mig 20260811260000.';
