-- Migration 20260602140000 · level:2 · lane:A1
-- writes: ALTER collector_cadence (+owned_kind col, PK swap), REPLACE SG/listings cadence rows,
--         NEW collector_band(text,text,numeric,boolean) overload, REPLACE sg_listings_poll_tick
-- reads:  sg_event_priority_state.owned_count_last_7d
--
-- ============================================================
-- Ownership-aware SG listings cadence (follow-up to 20260602130000).
-- SeatGeek LISTINGS ONLY. EVO + SG-sales are NOT touched: the existing 3-arg
-- collector_band(source,scope,hours) is preserved verbatim; this adds a 4-arg
-- overload used solely by sg_listings_poll_tick. The 3 callers are
-- evo_listings_poll_tick / sg_sales_poll_tick (3-arg) + sg_listings_poll_tick (4-arg).
--
-- Policy (measured 2026-06-02): owned events = 232 (~10%); non-owned = 2,060 (~90%);
-- d31p is 100% non-owned (1,501). So we poll OWNED inventory tight and NON-OWNED
-- market-context loose, peak tighter than off-peak, with EVERY event >= every ~22h
-- (honours the operator "everything at least every 24h" floor, 2h margin). Targets
-- ~75% peak utilisation on the 300/hr (1-min x p_max=5) budget from mig 130000 — so
-- NO budget/cadence-frequency change is needed here (the 24h floor rules out the
-- off-peak-only tail + per-window p_max variants that would have needed more budget).
--
--   Demand at this table:  peak ~226/hr (75%) · off-peak ~155/hr (52%) · daily ~63%.
--
-- Already applied to prod. Applied via MCP apply_migration 2026-06-02 (A1, operator-approved).
-- DDL validated by a rolled-back prod dry-run (Supabase branch-replay is broken at infra level);
-- post-apply verified: EVO 3-arg=15 + SG-sales 3-arg=60 UNCHANGED, SG-listings 4-arg owned=45/non=300,
-- demand peak ~75% / off ~52%, owned events leading the queue.
-- ============================================================

-- ---------- 1. Add ownership dimension to the cadence config (additive) ----------
ALTER TABLE public.collector_cadence
  ADD COLUMN IF NOT EXISTS owned_kind text NOT NULL DEFAULT 'any'
    CHECK (owned_kind IN ('any','owned','non'));

ALTER TABLE public.collector_cadence DROP CONSTRAINT collector_cadence_pkey;
ALTER TABLE public.collector_cadence ADD CONSTRAINT collector_cadence_pkey
  PRIMARY KEY (source, scope, band, owned_kind);

-- ---------- 2. Replace SG/listings 'any' rows with ownership-specific cadence ----------
DELETE FROM public.collector_cadence WHERE source='SG' AND scope='listings' AND owned_kind='any';
INSERT INTO public.collector_cadence
  (source, scope, band, owned_kind, min_hours, max_hours, peak_interval_min, offpeak_interval_min, enabled, sort_order, notes) VALUES
  -- OWNED (our inventory) -> tight
  ('SG','listings','le7d',  'owned',   0,  168,   45,   90, true, 1, 'owned: imminent premium cadence'),
  ('SG','listings','d8_14', 'owned', 168,  336,  150,  300, true, 2, 'owned'),
  ('SG','listings','d15_30','owned', 336,  720,  600, 1200, true, 3, 'owned'),
  ('SG','listings','d31p',  'owned', 720, NULL, 1200, 1320, true, 4, 'owned far (still <=22h floor)'),
  -- NON-OWNED (market context) -> loose, but every <=22h (24h SLA, 2h margin)
  ('SG','listings','le7d',  'non',     0,  168,  300,  600, true, 1, 'non-owned market read'),
  ('SG','listings','d8_14', 'non',   168,  336,  720, 1320, true, 2, 'non-owned'),
  ('SG','listings','d15_30','non',   336,  720, 1320, 1320, true, 3, 'non-owned floor'),
  ('SG','listings','d31p',  'non',   720, NULL, 1320, 1320, true, 4, 'non-owned floor');

-- ---------- 3. Ownership-aware collector_band overload (4-arg). 3-arg UNCHANGED ----------
CREATE OR REPLACE FUNCTION public.collector_band(p_source text, p_scope text, p_hours numeric, p_owned boolean)
RETURNS TABLE(band text, required_min integer) LANGUAGE sql STABLE
SET search_path TO 'public','pg_temp'
AS $function$
  SELECT c.band,
         CASE WHEN EXTRACT(hour FROM now() AT TIME ZONE 'America/New_York')::int
                   = ANY (ARRAY[12,13,14,15,16,17,18,19,20,21,22,23])
              THEN c.peak_interval_min ELSE c.offpeak_interval_min END
  FROM public.collector_cadence c
  WHERE c.source = p_source AND c.scope = p_scope AND c.enabled
    AND p_hours >= c.min_hours AND (c.max_hours IS NULL OR p_hours < c.max_hours)
    AND c.owned_kind IN (CASE WHEN p_owned THEN 'owned' ELSE 'non' END, 'any')
  ORDER BY (c.owned_kind <> 'any') DESC, c.sort_order   -- prefer ownership-specific; fall back to 'any'
  LIMIT 1;
$function$;

-- ---------- 4. sg_listings_poll_tick passes ownership into the band lookup ----------
-- Body identical to mig 20260602130000 EXCEPT the LATERAL collector_band call gains the
-- 4th arg (owned flag). Priority ORDER BY (required_min ASC + staleness) is preserved.
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
           EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0,
           (coalesce(s.owned_count_last_7d,0) > 0)) c ON true   -- 2026-06-02: ownership-aware band
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      AND ( s.last_polled_listings_at IS NULL
            OR s.last_polled_listings_at < v_now - make_interval(mins => c.required_min) )
      AND ( s.last_fired_listings_at IS NULL
            OR s.last_fired_listings_at < v_now - interval '90 seconds' )
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
