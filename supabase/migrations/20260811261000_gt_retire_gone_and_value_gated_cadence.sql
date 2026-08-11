-- Migration 20260811261000 · lane:D0 · operator-directed 2026-08-11
--   ("remove listing if listing is gone on next passes" +
--    "reduce cadence to match EVO if median for entire event is under $25").
--
--   writes: gt_listings_poll_state [+col event_median_price],
--           gt_listings_drain(int) [fn — retire vanished deals + record event median],
--           gt_listings_poll_tick(int) [fn — value-gate the ≥2wk max cadence].
--
-- WHY
--  * Retire-on-pass: a deal was only retired when the scanner re-ran, and the scanner only
--    re-runs when a new snapshot lands. An event whose listings all disappear returns
--    {"listings":[]} → no snapshot → never re-scanned → stale deal lingers. The drain sees the
--    live-listing set every pass, so it retires any un-retired deal for that event whose
--    gt_listing_id is absent from the current response (empty response ⇒ retire all).
--  * Value-gated cadence: the ≥2wk "poll every 10 min" treatment is for deal-worthy events.
--    An event whose ENTIRE-event median all-in price is < $25 isn't worth the credits, so it
--    drops to EVO's DTE curve. The drain records the per-event median each pass; the poller
--    reads it. Unknown median (never polled) defaults to the 10-min class so we poll once to
--    learn the price, then re-classify.
--
-- ROLLBACK: restore gt_listings_drain + gt_listings_poll_tick to mig 20260811260000;
--   ALTER TABLE gt_listings_poll_state DROP COLUMN event_median_price.

ALTER TABLE public.gt_listings_poll_state
  ADD COLUMN IF NOT EXISTS event_median_price numeric;

-- Drain — insert listings, retire vanished deals, record event median, cadence state.
CREATE OR REPLACE FUNCTION public.gt_listings_drain(p_max integer DEFAULT 1000)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_total int := 0; v_rows int; v_ct int; v_live bigint[]; v_median numeric;
BEGIN
  SET LOCAL statement_timeout = '120s';
  FOR r IN
    SELECT inf.request_id, inf.gt_event_id, inf.tevo_event_id, inf.fired_at, resp.status_code, resp.content
    FROM public.gt_listings_inflight inf
    JOIN net._http_response resp ON resp.id = inf.request_id
    ORDER BY inf.fired_at LIMIT p_max
  LOOP
    v_ct := NULL; v_live := NULL; v_median := NULL;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN
        v_ct   := jsonb_array_length(coalesce((r.content::jsonb) -> 'listings', '[]'::jsonb));
        v_live := COALESCE((SELECT array_agg((l->>'id')::bigint)
                            FROM jsonb_array_elements((r.content::jsonb) -> 'listings') l),
                           ARRAY[]::bigint[]);
        IF v_ct > 0 THEN
          v_median := (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY (l->>'allInPrice')::numeric)
                       FROM jsonb_array_elements((r.content::jsonb) -> 'listings') l
                       WHERE (l->>'allInPrice') IS NOT NULL);
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
        v_ct := NULL; v_live := NULL; v_median := NULL;
        RAISE WARNING 'gt_listings_drain: request % (gt_event %) parse failed: %', r.request_id, r.gt_event_id, SQLERRM;
      END;
    END IF;

    -- Retire deals whose listing vanished this pass (only when we parsed the response).
    IF v_live IS NOT NULL THEN
      UPDATE public.gotickets_deals_feed f
         SET gone_at = now()
       WHERE f.gt_event_id = r.gt_event_id
         AND f.gone_at IS NULL
         AND NOT (f.gt_listing_id = ANY (v_live));
    END IF;

    -- Cadence state: empty backoff + credit/gone quarantine + event median (kept when non-empty).
    UPDATE public.gt_listings_poll_state ps SET
      last_status = r.status_code,
      event_median_price = CASE WHEN r.status_code = 200 AND coalesce(v_ct,0) > 0 THEN v_median
                                ELSE ps.event_median_price END,
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

-- Poller — ≥2wk US events get the 10-min max cadence ONLY when the entire-event median
-- all-in price is ≥ $25; cheaper events fall back to EVO's DTE curve.
CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(p_max integer DEFAULT 120)
 RETURNS integer
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_n int := 0; v_req bigint; v_token text;
  v_daily_cap int := 1000000;
  us_states text[] := ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC'];
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  IF (SELECT coalesce(sum(listings_polls_today),0) FROM public.gt_listings_poll_state
        WHERE budget_day = current_date) >= v_daily_cap THEN
    RETURN 0;
  END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      SELECT g.gt_event_id, g.tevo_event_id, g.event_time_utc,
             EXTRACT(epoch FROM (g.event_time_utc - now()))/3600.0 AS hte,
             ps.last_polled_listings_at, ps.event_median_price
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
      WHERE g.status = 'AS_SCHEDULED'
        AND g.event_time_utc > now() - interval '3 hours'
        AND upper(btrim(coalesce(g.venue_state,''))) = ANY(us_states)
        AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
        AND (ps.cold_until       IS NULL OR ps.cold_until       < now())
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at,
             CASE WHEN ev.event_time_utc >= now() + interval '14 days'
                       AND coalesce(ev.event_median_price, 9999) >= 25 THEN 10   -- ≥2wk, ≥$25: max
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
