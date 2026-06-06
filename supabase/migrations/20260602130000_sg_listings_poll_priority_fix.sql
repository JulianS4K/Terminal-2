-- Migration 20260602130000 · level:2 · lane:A1 (D0-diagnosed)
-- writes: REPLACE fn sg_listings_poll_tick, REPLACE fn sg_broker_listings_process,
--         UPDATE cron_policy(sg_listings_poll_2min), RESCHEDULE cron sg_listings_poll_2min
-- reads:  sg_event_priority_state, collector_cadence (via collector_band), sg_broker_pending
--
-- ============================================================
-- Fix the post-cadence-redesign SG listings polling starvation.
-- Diagnosed 2026-06-02: imminent events showed "no listings update in 24h+".
--
-- Root cause (regression from migs 20260531160000 + 20260531170000):
--   (1) PRIORITY LOST. The consolidated sg_listings_poll_tick selected due events
--       ordered ONLY by last_polled_listings_at ASC — no tier/horizon weighting.
--       The pre-redesign sg_priority_poll_tick ordered by tier sort_order; that was
--       dropped. At cutover ~1,900 events all had last_polled frozen at various
--       May-31 stamps; the large low-id far-future TRACK_BLINDSPOT block had the
--       OLDEST stamps, so it sat at the FRONT of the queue. With p_max=5/2min
--       (~150 polls/hr) the poller spent its whole budget on events 300h-2600h out
--       and never reached the imminent (≤24h) games behind them.
--   (2) 400-ZOMBIES. sg_broker_listings_process advances the cadence clock
--       (last_polled) ONLY on HTTP 200 (strand-safe for 429). But a *permanent*
--       400 (delisted SG id) never advances → the event stays "oldest" → re-fires
--       EVERY tick. 2 dead Seahawks events were burning ~40% of the poll budget.
--   (3) UNDER-PROVISIONED. Measured demand ≈ 317 polls/hr (le7d 169 + d8_14 49 +
--       d15_30 36 + d31p 63). The le7d band ALONE (169/hr) exceeds the 150/hr
--       budget, so priority ordering is necessary but not sufficient.
--
-- Fix:
--   (1) ORDER BY c.required_min ASC first (most-urgent band wins), then
--       last_polled ASC NULLS FIRST (staleness), then sg_datetime_utc. Imminent
--       events jump ahead of the far-future blindspot tail.
--   (2) Advance last_polled on 200 OR terminal 4xx (400-499 except 429), so a dead
--       id waits its full band interval (24h for blindspot) instead of re-firing
--       every tick. 429/5xx/no-response still leave it untouched (retry next tick).
--   (3) Raise throughput: sg_listings_poll_2min -> every minute, p_max stays 5
--       (SG /listings is ~5-req/10s; 5/burst then 59s idle is well clear of the
--       window — the in-tick fresh-ratelimit-remaining backoff still self-throttles).
--       cron_policy interval lowered 2->1 so cron_should_fire does not gate it back.
--   Recovery is automatic: imminent events become top-of-queue and are polled within
--   the first few ticks after deploy; no manual backfill needed.
--
-- Out of scope (separate follow-ups, noted in KANBAN): past events still labelled
--   HOT/WARM (classifier-demotion gap — harmless, the >now-6h window already excludes
--   them from polling); SKIP-demotion of persistently-4xx events (optional hardening).
--
-- Already applied to prod. Applied via MCP apply_migration 2026-06-02 (A1, operator-approved).
-- Post-apply verified: cron */1, policy 1/1/1500, priority ORDER BY + 4xx-advance live;
-- imminent le7d games (incl. the starved 6/3 WARM slate) firing top-of-queue within 2 ticks.
-- ============================================================

-- ---------- 1. Priority-ordered listings poller (only the ORDER BY changes) ----------
CREATE OR REPLACE FUNCTION public.sg_listings_poll_tick(p_max int DEFAULT 20, p_min_remaining int DEFAULT 3)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  v_token     text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_remaining int;
  r           RECORD;
  v_req       bigint;
  v_now       timestamptz := clock_timestamp();
  v_count     int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;

  -- Rate-aware backoff: only on a FRESH low reading (~10s window). Stale/none => fire.
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
  FROM public.sg_broker_pending p
  JOIN net._http_response h ON h.id = p.request_id
  WHERE h.headers ? 'ratelimit-remaining' AND h.created > v_now - interval '10 seconds'
  ORDER BY h.id DESC LIMIT 1;
  IF v_remaining IS NOT NULL AND v_remaining < p_min_remaining THEN RETURN 0; END IF;

  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    JOIN LATERAL public.collector_band('SG','listings',
           EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0) c ON true
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      AND ( s.last_polled_listings_at IS NULL
            OR s.last_polled_listings_at < v_now - make_interval(mins => c.required_min) )
      AND ( s.last_fired_listings_at IS NULL
            OR s.last_fired_listings_at < v_now - interval '90 seconds' )   -- don't re-fire a pending request
    -- 2026-06-02: prioritise by band urgency (smaller required_min = closer event),
    -- THEN by staleness, THEN by datetime. Replaces flat last_polled ASC which let the
    -- far-future blindspot tail starve imminent events.
    ORDER BY c.required_min ASC, s.last_polled_listings_at ASC NULLS FIRST, s.sg_datetime_utc
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_fired_listings_at = v_now, listings_polls_today = listings_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;
REVOKE ALL ON FUNCTION public.sg_listings_poll_tick(int,int) FROM anon, PUBLIC;

-- ---------- 2. Drain advances the cadence clock on 200 OR terminal 4xx ----------
CREATE OR REPLACE FUNCTION public.sg_broker_listings_process(p_limit integer DEFAULT 50)
RETURNS TABLE(processed integer, listings_persisted integer)
LANGUAGE plpgsql SET search_path TO 'public','extensions','pg_temp'
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
    END IF;

    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = CASE
            WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0)
            WHEN r.status_code = 429 THEN -429
            ELSE -1 END
      WHERE id = r.pending_id;

    -- A1 2026-05-31: advance the cadence clock on success (strand-safe).
    -- A1 2026-06-02: ALSO advance on a terminal 4xx (400-499, except 429). A permanent
    -- 400 (delisted/invalid SG id) would otherwise never advance last_polled and re-fire
    -- every tick, burning the budget. Advancing makes it wait its band interval (~24h for
    -- blindspot) before retrying. 429/5xx/timeout still leave last_polled untouched so the
    -- request retries next tick.
    IF r.status_code = 200
       OR (r.status_code BETWEEN 400 AND 499 AND r.status_code <> 429) THEN
      UPDATE public.sg_event_priority_state
        SET last_polled_listings_at = now()
        WHERE sg_event_id = r.sg_event_id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

-- ---------- 3. Throughput: poll every minute (p_max stays 5); lower policy gate ----------
-- daily_max_fires raised 800 -> 1500: at 1-min cadence a day can see up to 1440
-- firings; the old 800 cap (set when cadence was 2-min / 720/day max) would trip
-- ~13h in and skip_budget the rest of the day = a fresh silent outage.
UPDATE public.cron_policy
  SET peak_min_interval_min = 1, offpeak_min_interval_min = 1, daily_max_fires = 1500,
      updated_at = now(),
      notes = 'SG band-driven listings scan; rate-aware backoff + strand-safe advance-on-200/4xx; 1-min cadence (2026-06-02 starvation fix)'
  WHERE jobname = 'sg_listings_poll_2min';

-- Reschedule in place (same jobname; now 1-min). p_max=5 keeps each burst <= the
-- ~5-req/10s /listings window; 59s idle between bursts leaves ample token headroom.
SELECT cron.schedule('sg_listings_poll_2min', '* * * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_listings_poll_2min') THEN RETURN; END IF; PERFORM public.sg_listings_poll_tick(5); END $b$;$cron$);
