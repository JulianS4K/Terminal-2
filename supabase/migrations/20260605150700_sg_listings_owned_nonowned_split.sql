-- Migration 20260603180000 · level:2 · lane:A1
-- writes: REPLACE fn sg_listings_poll_tick (+p_owned_kind filter arg),
--         UPDATE collector_cadence (SG/listings owned_kind='non' -> once-daily 1440/1440),
--         RESCHEDULE crons: drop sg_listings_poll_2min; add sg_listings_poll_owned_1min (ON)
--         + sg_listings_poll_nonowned_5min (gate-disabled / OFF for now),
--         cron_policy rows for the two new jobs (old row removed)
-- reads:  sg_event_priority_state.owned_count_last_7d, collector_cadence (via collector_band)
--
-- ============================================================
-- Split SG LISTINGS polling into two independent systems: OWNED and NON-OWNED.
-- Operator directive 2026-06-03: "create 2 sg systems, owned and non-owned, only
-- poll owned for now and resume owned crons. non-owned redesign so everything only
-- polls once a day regardless of when it is."
--
-- Context: the single combined cron sg_listings_poll_2min was PAUSED earlier today
-- (cron_policy.enabled=false) during the broker /listings token-spend + 429
-- investigation. This migration retires that combined cron and replaces it with two
-- ownership-scoped crons sharing ONE function (the existing rate-aware, strand-safe
-- sg_listings_poll_tick, now taking a 3rd filter arg p_owned_kind).
--
-- OWNED  (234 events, 54 le7d / 62 d8_14 / 118 d15_30): keep the existing tight,
--        horizon-banded cadence (le7d 45/90, d8_14 150/300, d15_30 600/1200, etc.,
--        from mig 20260602140000). Cron sg_listings_poll_owned_1min runs every minute,
--        p_max=5, ENABLED (resumed per directive). ~14 due at cutover; trivial load.
-- NON-OWNED (2,041 events, 1,487 of them 30d+): REDESIGNED to once-per-day per event
--        REGARDLESS of horizon -> all SG/listings owned_kind='non' cadence rows set to
--        1440/1440 min. Cron sg_listings_poll_nonowned_5min is wired (every 5 min, p_max=8;
--        the 1440-min per-event cadence gate spreads the ~2,041 daily polls across the day
--        and keeps bursts <10/8s) but GATE-DISABLED for now ("only poll owned for now").
--        Flip cron_policy.enabled=true on that job to turn non-owned back on.
--
-- Both crons call the SAME function, so both honour the shared-token rate-aware backoff
-- (ratelimit-remaining < p_min_remaining => fire nothing) and the 90s per-event refire
-- guard. EVO + SG-sales are untouched.
--
-- NOTE: adding p_owned_kind creates a NEW overload, so the prior (integer,integer)
-- signature is DROPPED first (PROJECT_BIBLE §7 overload macro).
--
-- Already applied to prod. Applied via MCP apply_migration 2026-06-03 (A1, operator-directed).
-- ============================================================

-- ---------- 1. Replace the poller with an ownership filter arg ----------
DROP FUNCTION IF EXISTS public.sg_listings_poll_tick(integer, integer);

CREATE OR REPLACE FUNCTION public.sg_listings_poll_tick(
  p_max           integer DEFAULT 20,
  p_min_remaining integer DEFAULT 3,
  p_owned_kind    text    DEFAULT NULL   -- NULL = both, 'owned' = owned only, 'non' = non-owned only
)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
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
           (coalesce(s.owned_count_last_7d,0) > 0)) c ON true
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      -- ownership scope: NULL = both; otherwise match owned-flag to requested kind
      AND ( p_owned_kind IS NULL
            OR (coalesce(s.owned_count_last_7d,0) > 0) = (p_owned_kind = 'owned') )
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

-- ---------- 2. NON-OWNED redesign: once-daily regardless of horizon ----------
UPDATE public.collector_cadence
SET peak_interval_min    = 1440,
    offpeak_interval_min = 1440,
    notes                = 'non-owned: once-daily floor (horizon-agnostic, 2026-06-03 owned/non split)',
    updated_at           = now()
WHERE source = 'SG' AND scope = 'listings' AND owned_kind = 'non';

-- ---------- 3. Retire the combined cron ----------
SELECT cron.unschedule(jobname) FROM cron.job WHERE jobname = 'sg_listings_poll_2min';
DELETE FROM public.cron_policy WHERE jobname = 'sg_listings_poll_2min';

-- ---------- 4. Cron policies for the two new systems ----------
-- OWNED: resumed (enabled=true), every-minute gate, tight horizon cadence
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES
  ('sg_listings_poll_owned_1min',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23], 1, 1,
   NULL, 1500, true,
   'SG OWNED listings scan; rate-aware backoff + strand-safe advance-on-200; 1-min cadence (owned/non split 2026-06-03)',
   now())
ON CONFLICT (jobname) DO UPDATE
  SET enabled = excluded.enabled, peak_hours_et = excluded.peak_hours_et,
      peak_min_interval_min = excluded.peak_min_interval_min,
      offpeak_min_interval_min = excluded.offpeak_min_interval_min,
      daily_max_fires = excluded.daily_max_fires, notes = excluded.notes, updated_at = now();

-- NON-OWNED: wired but OFF for now (enabled=false); per-event cadence is once-daily
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES
  ('sg_listings_poll_nonowned_5min',
   ARRAY[12,13,14,15,16,17,18,19,20,21,22,23], 5, 5,
   NULL, NULL, false,
   'SG NON-OWNED listings scan; once-daily per-event (cadence 1440); OFF for now (only poll owned). Flip enabled=true to resume.',
   now())
ON CONFLICT (jobname) DO UPDATE
  SET enabled = excluded.enabled, peak_hours_et = excluded.peak_hours_et,
      peak_min_interval_min = excluded.peak_min_interval_min,
      offpeak_min_interval_min = excluded.offpeak_min_interval_min,
      daily_max_fires = excluded.daily_max_fires, notes = excluded.notes, updated_at = now();

-- ---------- 5. Schedule the two new crons ----------
SELECT cron.schedule('sg_listings_poll_owned_1min', '* * * * *', $cron$
DO $b$ BEGIN
  IF NOT public.cron_should_fire('sg_listings_poll_owned_1min') THEN RETURN; END IF;
  PERFORM public.sg_listings_poll_tick(5, 3, 'owned');
END $b$;
$cron$);

SELECT cron.schedule('sg_listings_poll_nonowned_5min', '*/5 * * * *', $cron$
DO $b$ BEGIN
  IF NOT public.cron_should_fire('sg_listings_poll_nonowned_5min') THEN RETURN; END IF;
  PERFORM public.sg_listings_poll_tick(8, 3, 'non');
END $b$;
$cron$);
