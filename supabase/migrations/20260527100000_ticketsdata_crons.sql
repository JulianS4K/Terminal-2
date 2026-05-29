-- 20260527100000_ticketsdata_crons.sql
--
-- TicketsData integration — cron subsystem.
-- Depends on: 20260527040000 (get_app_secret whitelist) + 20260527050000 (foundation schema).
--
-- 5 FUNCTIONS:
--   td_api_platform(p text)          — IMMUTABLE internal→API platform string mapper
--   td_watchlist_refresh()           — daily: upsert active events into ticketsdata_event_xref
--   td_enqueue_peak(interval_tag)    — 4×/day: push (event×platform) pairs to td_pull_queue
--   td_pull_drain(p_max int)         — every 1 min: fire net.http_get ≤5/fire (5/sec cap)
--   td_normalize_drain(p_max int)    — every 2 min: drain responses → snapshots + credit log
--   td_pending_sweep()               — hourly: orphan cleanup + stuck-request reset
--
-- 5 CRON JOBS:
--   td_watchlist_refresh      '0 9 * * *'              once daily, 9 UTC = 5am ET
--   td_enqueue_peak           '10 16,20,0,3 * * *'     4× at ET peak: noon/4pm/8pm/11pm
--   td_pull_drain             '*/1 16-23,0-4 * * *'    every min, 8h peak window
--   td_normalize_drain        '*/2 16-23,0-4 * * *'    every 2 min, same window
--   td_pending_sweep          '25 * * * *'             hourly at :25
--
-- BUDGET MATH (Phase 1 — SH + VD only):
--   40 events × 2 platforms × 4 intervals × 1 credit = 320 credits/day < 333 cap ✓
--   Sustained fire rate: 320 / 86400 = 0.004 req/sec << 5/sec quota ✓
--   Peak burst: ≤5 per drain fire (5/sec cap) — well under 5 req/sec quota ✓
--
-- MINUTE OFFSETS:
--   td_pull_drain fires at :0 — TD API, no SG conflict (different API endpoint)
--   td_normalize_drain at :0/:2/:4 — process-only, no HTTP, safe alongside SG crons
--   td_watchlist_refresh at :0 hour — no conflict with SG (different hour 9 UTC)
--   td_pending_sweep at :25 — clear of SG crons (:0/:2/:4)
--
-- PHASE 2 (deferred):
--   GT/TP require /events discovery (no event IDs in aq_event_map).
--   td_watchlist_refresh includes stubs for GT/TP rows (active=false, event_url=NULL)
--   once discovery is implemented via a future /events drain function.


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. td_api_platform — maps internal code to TicketsData API platform string
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_api_platform(p_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE p_code
    WHEN 'SH' THEN 'stubhub'
    WHEN 'VD' THEN 'vividseats'
    WHEN 'GT' THEN 'gametime'
    WHEN 'TP' THEN 'tickpick'
    ELSE LOWER(p_code)
  END;
$$;

REVOKE ALL ON FUNCTION public.td_api_platform(text) FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. td_watchlist_refresh()
--    Daily at 9 UTC (5am ET). Upserts active events from aq_event_map into
--    ticketsdata_event_xref for SH + VD platforms. Uses sg_events_canonical
--    for reliable datetime filtering. Resets enqueues_today counter.
--    Sets always_on=true for Knicks events (performer ILIKE '%knicks%').
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_watchlist_refresh()
RETURNS integer   -- returns count of (event, platform) pairs upserted
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r         RECORD;
  v_count   int := 0;
  v_now     timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_watchlist_refresh') THEN RETURN 0; END IF;

  -- Reset enqueues_today for all xref rows (new UTC day)
  UPDATE public.ticketsdata_event_xref
  SET enqueues_today = 0, updated_at = v_now
  WHERE enqueues_today > 0;

  -- Deactivate xref rows for past events
  UPDATE public.ticketsdata_event_xref
  SET active = false, updated_at = v_now
  WHERE active = true
    AND event_id IN (
      SELECT aem.sh_event_id   -- TEvo-style: use sg_datetime_utc as date proxy
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
    );

  -- Upsert active SH rows (StubHub — direct ID from aq_event_map.sh_event_id)
  FOR r IN
    SELECT
      aem.sh_event_id                                                    AS event_id,
      aem.aq_short_event_id,
      aem.performer,
      aem.event_name,
      sgc.sg_datetime_utc
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.sh_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id,
      'SH',
      r.aq_short_event_id,
      'https://www.stubhub.com/x/event/' || r.event_id::text || '/',
      true,
      (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
      'direct_id',
      v_now
    )
    ON CONFLICT (event_id, platform) DO UPDATE
      SET active       = true,
          always_on    = (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
          event_url    = EXCLUDED.event_url,  -- URL is deterministic; refresh in case sh_event_id changed
          updated_at   = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- Upsert active VD rows (VividSeats — direct ID from aq_event_map.vivid_event_id)
  FOR r IN
    SELECT
      aem.vivid_event_id                                                 AS event_id,
      aem.aq_short_event_id,
      aem.performer,
      aem.event_name,
      sgc.sg_datetime_utc
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.vivid_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id,
      'VD',
      r.aq_short_event_id,
      'https://www.vividseats.com/production/' || r.event_id::text,
      true,
      (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
      'direct_id',
      v_now
    )
    ON CONFLICT (event_id, platform) DO UPDATE
      SET active       = true,
          always_on    = (COALESCE(r.performer, '') ILIKE '%knicks%' OR COALESCE(r.event_name, '') ILIKE '%knicks%'),
          event_url    = EXCLUDED.event_url,
          updated_at   = v_now;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_watchlist_refresh() FROM anon, public;
COMMENT ON FUNCTION public.td_watchlist_refresh() IS
  'Daily watchlist upsert for SH+VD. Phase 2 will add GT/TP via /events discovery. '
  'Resets enqueues_today counter. Returns (event, platform) pairs upserted.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. td_enqueue_peak(p_interval_tag)
--    Fires 4×/day at peak ET times. Selects the top active (event, platform)
--    pairs and inserts them into td_pull_queue. Skips pairs with unresolved
--    pending rows (pileup guard). Caps at 80 pairs per fire (40 events × 2 platforms).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_enqueue_peak(
  p_interval_tag text DEFAULT 'manual'
)
RETURNS integer   -- count of rows inserted into td_pull_queue
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r       RECORD;
  v_count int := 0;
  v_now   timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_enqueue_peak') THEN RETURN 0; END IF;

  -- Hard budget check before touching the queue
  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_enqueue_peak: daily credit budget exhausted, skipping';
    RETURN 0;
  END IF;

  FOR r IN
    SELECT x.event_id, x.platform, x.event_url, x.always_on
    FROM public.ticketsdata_event_xref x
    JOIN public.sg_events_canonical sgc
      ON sgc.sg_event_id = (
        SELECT aem.sg_event_id FROM public.aq_event_map aem
        WHERE aem.aq_short_event_id = x.aq_short_event_id
        LIMIT 1
      )
    WHERE x.active      = true
      AND x.event_url   IS NOT NULL
      AND x.enqueues_today < 4
      -- 7-day gate OR always_on (Knicks, operator-pinned)
      AND (x.always_on = true OR sgc.sg_datetime_utc < v_now + interval '7 days')
      -- Pileup guard: no unresolved pending row for this (event, platform)
      AND NOT EXISTS (
        SELECT 1 FROM public.td_pull_queue q
        WHERE q.event_id  = x.event_id
          AND q.platform  = x.platform
          AND q.resolved_at IS NULL
      )
    ORDER BY x.always_on DESC, x.rank_score DESC NULLS LAST, x.last_enqueued_at NULLS FIRST
    LIMIT 80   -- 40 events × 2 platforms (SH+VD); raise for phase 2
  LOOP
    INSERT INTO public.td_pull_queue
      (event_id, platform, event_url, interval_tag, created_at)
    VALUES
      (r.event_id, r.platform, r.event_url, p_interval_tag, v_now);

    UPDATE public.ticketsdata_event_xref
    SET last_enqueued_at = v_now,
        enqueues_today   = enqueues_today + 1,
        updated_at       = v_now
    WHERE (event_id, platform) = (r.event_id, r.platform);

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_enqueue_peak(text) FROM anon, public;
COMMENT ON FUNCTION public.td_enqueue_peak(text) IS
  'Pushes top active (event×platform) pairs to td_pull_queue. '
  '7-day gate OR always_on. Pileup guard. 80 pairs max per fire = 40 events × SH+VD.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. td_pull_drain(p_max)
--    Fires every minute in the peak window. Retrieves creds from vault once
--    per call. Fires net.http_get for up to p_max unfired rows in FIFO order.
--    Uses params jsonb for safe URL encoding of event_url (no string concat).
--    NEVER log the request URL — it contains credentials.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_pull_drain(
  p_max integer DEFAULT 5   -- ≤5 per fire = ≤5/sec burst (Starter: 5 req/sec cap)
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  r         RECORD;
  v_user    text;
  v_pass    text;
  v_req_id  bigint;
  v_count   int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_pull_drain') THEN RETURN 0; END IF;

  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_pull_drain: daily credit budget exhausted, skipping';
    RETURN 0;
  END IF;

  -- Fetch creds once per invocation — not per row
  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');

  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'td_pull_drain: TICKETSDATA creds missing from vault';
  END IF;

  FOR r IN
    SELECT id, event_id, platform, event_url
    FROM public.td_pull_queue
    WHERE fired_at IS NULL
    ORDER BY created_at ASC
    LIMIT p_max
  LOOP
    -- Use params jsonb for proper URL encoding — especially important for event_url
    SELECT net.http_get(
      url     := 'https://ticketsdata.com/fetch',
      params  := jsonb_build_object(
                   'platform',  public.td_api_platform(r.platform),
                   'event_url', r.event_url,
                   'username',  v_user,
                   'password',  v_pass
                 ),
      headers := '{}'::jsonb,
      timeout_milliseconds := 35000
    ) INTO v_req_id;

    UPDATE public.td_pull_queue
    SET request_id = v_req_id,
        fired_at   = clock_timestamp()
    WHERE id = r.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_pull_drain(integer) FROM anon, public;
COMMENT ON FUNCTION public.td_pull_drain(integer) IS
  'Fires net.http_get for unfired td_pull_queue rows (FIFO). '
  'Default 5/fire = 5/sec burst (Starter plan cap). Creds via vault; never logged.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. td_normalize_drain(p_max)
--    Fires every 2 minutes. JOINs td_pull_queue with net._http_response to
--    process resolved responses. Normalizes 200s into snapshots; re-queues
--    429/503/504; handles quota exhaustion (402), auth failure (401),
--    and platform access issues (403/404). Traps query_canceled (57014).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_normalize_drain(
  p_max integer DEFAULT 50
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  r           RECORD;
  listing     RECORD;
  v_sc        int;
  v_quota     int;
  v_hash      text;
  v_count     int := 0;
  v_inserted  int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_normalize_drain') THEN RETURN 0; END IF;

  FOR r IN
    SELECT
      p.id,
      p.event_id,
      p.platform,
      p.event_url,
      p.interval_tag,
      p.retry_count,
      h.status_code   AS http_sc,
      h.content       AS raw_content
    FROM public.td_pull_queue p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
      AND p.request_id  IS NOT NULL
    ORDER BY p.fired_at ASC
    LIMIT p_max
  LOOP
    BEGIN
      -- Prefer the JSON status field; fall back to pg_net's h.status_code
      v_sc    := COALESCE((r.raw_content::jsonb->>'status')::int, r.http_sc);
      v_quota := (r.raw_content::jsonb->>'quota_remaining')::int;

      IF v_sc = 200 THEN
        -- ── Normalize and insert listings ────────────────────────────────
        v_inserted := 0;
        FOR listing IN
          SELECT *
          FROM public.ticketsdata_normalize_listings(r.platform, r.raw_content::jsonb)
        LOOP
          v_hash := md5(listing.raw::text);
          INSERT INTO public.ticketsdata_listings_snapshots
            (event_id, platform, td_listing_id, section, row, quantity,
             list_price, price_with_fees, is_parking, content_hash, raw)
          VALUES
            (r.event_id, r.platform, listing.td_listing_id, listing.section,
             listing.row, listing.quantity, listing.list_price,
             listing.price_with_fees, listing.is_parking, v_hash, listing.raw)
          ON CONFLICT (event_id, platform, content_hash) DO NOTHING;
          v_inserted := v_inserted + 1;
        END LOOP;

        UPDATE public.td_pull_queue
        SET resolved_at   = clock_timestamp(),
            status_code   = 200,
            credits_used  = 1,
            rows_inserted = v_inserted
        WHERE id = r.id;

        PERFORM public.td_charge_credit(1, r.event_id, r.platform, '/fetch', 200, v_quota);

        UPDATE public.ticketsdata_event_xref
        SET last_fetched_at = clock_timestamp(),
            updated_at      = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);

      ELSIF v_sc IN (429, 503) AND r.retry_count < 2 THEN
        -- Re-queue: rate-limited or service unavailable; drain will retry next window
        INSERT INTO public.td_pull_queue
          (event_id, platform, event_url, interval_tag, retry_count)
        VALUES
          (r.event_id, r.platform, r.event_url, r.interval_tag, r.retry_count + 1);

        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(),
            status_code = v_sc,
            error_msg   = CASE v_sc WHEN 429 THEN 'rate_limited_requeued'
                                              ELSE 'service_unavailable_requeued' END
        WHERE id = r.id;

      ELSIF v_sc = 504 AND r.retry_count < 1 THEN
        -- Timeout — retry once
        INSERT INTO public.td_pull_queue
          (event_id, platform, event_url, interval_tag, retry_count)
        VALUES
          (r.event_id, r.platform, r.event_url, r.interval_tag, r.retry_count + 1);

        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(),
            status_code = 504,
            error_msg   = 'timeout_requeued'
        WHERE id = r.id;

      ELSIF v_sc = 402 THEN
        -- Quota exhausted — disable TD drain crons immediately
        UPDATE public.cron_policy
        SET enabled    = false,
            notes      = notes || ' [DISABLED 402 quota_exhausted ' || now()::date::text || ']',
            updated_at = now()
        WHERE jobname IN ('td_pull_drain', 'td_normalize_drain', 'td_enqueue_peak');

        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(),
            status_code = 402,
            error_msg   = 'quota_exhausted — td crons disabled'
        WHERE id = r.id;

        RAISE NOTICE 'td_normalize_drain: 402 quota exhausted — TD crons disabled. Re-enable after billing reset.';
        EXIT;  -- stop processing remaining rows in this invocation

      ELSIF v_sc = 403 THEN
        -- Platform not entitled for this account — deactivate this (event, platform) row
        UPDATE public.ticketsdata_event_xref
        SET active     = false,
            meta       = meta || jsonb_build_object('403_at', now()),
            updated_at = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);

        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(),
            status_code = 403,
            error_msg   = 'access_denied — xref deactivated'
        WHERE id = r.id;

      ELSIF v_sc = 404 THEN
        -- Event not found on this platform — deactivate
        UPDATE public.ticketsdata_event_xref
        SET active     = false,
            meta       = meta || jsonb_build_object('404_at', now()),
            updated_at = clock_timestamp()
        WHERE (event_id, platform) = (r.event_id, r.platform);

        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(),
            status_code = 404,
            error_msg   = 'event_not_found — xref deactivated'
        WHERE id = r.id;

      ELSIF v_sc = 401 THEN
        -- Credential failure — break loudly so operator sees it
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(),
            status_code = 401,
            error_msg   = 'invalid_credentials'
        WHERE id = r.id;

        RAISE EXCEPTION 'td_normalize_drain: 401 invalid credentials — check TICKETSDATA vault secrets';

      ELSE
        -- Unknown / transient error — mark resolved, log for review
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(),
            status_code = v_sc,
            error_msg   = left(r.raw_content, 500)
        WHERE id = r.id;

      END IF;

      v_count := v_count + 1;

    EXCEPTION
      WHEN query_canceled THEN
        -- pg_cron cancelled this iteration (57014) — exit cleanly
        RAISE NOTICE 'td_normalize_drain: query_canceled at row % — exiting gracefully', r.id;
        EXIT;
      WHEN OTHERS THEN
        -- Row-level error — log and continue
        UPDATE public.td_pull_queue
        SET resolved_at = clock_timestamp(),
            status_code = -1,
            error_msg   = left(SQLERRM, 500)
        WHERE id = r.id;
    END;
  END LOOP;

  RETURN v_count;
END $$;

REVOKE ALL ON FUNCTION public.td_normalize_drain(integer) FROM anon, public;
COMMENT ON FUNCTION public.td_normalize_drain(integer) IS
  'Drains net._http_response for td_pull_queue rows. '
  '200→snapshots+charge; 429/503→re-queue; 402→disable crons; 401→RAISE; 403/404→deactivate xref.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 6. td_pending_sweep()
--    Hourly at :25. Cleans up old resolved rows, resets stuck fired rows
--    (pg_net may lose a request after ~1h), and deactivates past events.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_pending_sweep()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_pending_sweep') THEN RETURN; END IF;

  -- Prune old resolved rows (keep 7 days of history)
  DELETE FROM public.td_pull_queue
  WHERE resolved_at IS NOT NULL
    AND created_at < v_now - interval '7 days';

  -- Reset stuck rows: fired but not resolved after 1 hour
  -- pg_net may have lost the request — mark as error (do not auto-refire)
  UPDATE public.td_pull_queue
  SET resolved_at = v_now,
      status_code = -1,
      error_msg   = 'timeout_sweep — pg_net request unresolved after 1h'
  WHERE fired_at IS NOT NULL
    AND resolved_at IS NULL
    AND fired_at < v_now - interval '1 hour';

  -- Deactivate xref rows for events now past (with 2h buffer for late normalization)
  UPDATE public.ticketsdata_event_xref
  SET active     = false,
      updated_at = v_now
  WHERE active = true
    AND event_id IN (
      SELECT aem.sh_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
    )
    AND platform = 'SH';

  UPDATE public.ticketsdata_event_xref
  SET active     = false,
      updated_at = v_now
  WHERE active = true
    AND event_id IN (
      SELECT aem.vivid_event_id
      FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours'
    )
    AND platform = 'VD';

END $$;

REVOKE ALL ON FUNCTION public.td_pending_sweep() FROM anon, public;
COMMENT ON FUNCTION public.td_pending_sweep() IS
  'Hourly cleanup: prune 7d+ resolved rows, reset stuck requests, deactivate past events.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Schedule cron jobs
-- ─────────────────────────────────────────────────────────────────────────────
DO $sched$ BEGIN

  -- td_watchlist_refresh: daily at 9 UTC = 5am ET
  PERFORM cron.schedule(
    'td_watchlist_refresh',
    '0 9 * * *',
    $cron$DO $body$
    BEGIN
      PERFORM public.td_watchlist_refresh();
    END $body$;$cron$
  );

  -- td_enqueue_peak: 4 fixed slots in ET peak window
  -- 16 UTC=noon EDT, 20 UTC=4pm EDT, 0 UTC=8pm EDT, 3 UTC=11pm EDT
  PERFORM cron.schedule(
    'td_enqueue_peak',
    '10 16,20,0,3 * * *',
    $cron$DO $body$
    BEGIN
      PERFORM public.td_enqueue_peak(
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 16 THEN '12pm'
          WHEN 20 THEN '4pm'
          WHEN  0 THEN '8pm'
          WHEN  3 THEN '11pm'
          ELSE        'manual'
        END
      );
    END $body$;$cron$
  );

  -- td_pull_drain: every minute in peak window (16-23 UTC + 0-4 UTC)
  PERFORM cron.schedule(
    'td_pull_drain',
    '*/1 16-23,0-4 * * *',
    $cron$DO $body$
    BEGIN
      PERFORM public.td_pull_drain(5);
    END $body$;$cron$
  );

  -- td_normalize_drain: every 2 minutes in peak window
  PERFORM cron.schedule(
    'td_normalize_drain',
    '*/2 16-23,0-4 * * *',
    $cron$DO $body$
    BEGIN
      PERFORM public.td_normalize_drain(50);
    END $body$;$cron$
  );

  -- td_pending_sweep: hourly at :25
  PERFORM cron.schedule(
    'td_pending_sweep',
    '25 * * * *',
    $cron$DO $body$
    BEGIN
      PERFORM public.td_pending_sweep();
    END $body$;$cron$
  );

END $sched$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. cron_policy rows
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   daily_max_fires, work_check_sql, enabled, notes)
VALUES
  ('td_watchlist_refresh',
   '{}'::int[], 1440, 1440, 1,
   'SELECT true',
   true,
   'TicketsData daily watchlist re-rank + URL upsert. 9 UTC = 5am ET. SH+VD Phase 1.'),

  ('td_enqueue_peak',
   '{}'::int[], 360, 360, 4,
   'SELECT public.td_budget_ok()',
   true,
   'TicketsData enqueue 4x/day: 16/20/0/3 UTC = noon/4pm/8pm/11pm EDT. 80 pairs/fire = 40 events × SH+VD.'),

  ('td_pull_drain',
   '{}'::int[], 1, 1, NULL,
   'SELECT public.td_budget_ok()',
   true,
   'TicketsData pull drain. ≤5/fire = ≤5/sec (Starter 5 req/sec cap). Credit gate stops at 333/day.'),

  ('td_normalize_drain',
   '{}'::int[], 2, 2, NULL,
   'SELECT public.td_budget_ok()',
   true,
   'TicketsData normalize drain. ≤50/fire. Traps 57014. Re-queues 429/503/504.'),

  ('td_pending_sweep',
   '{}'::int[], 60, 60, 24,
   'SELECT true',
   true,
   'TicketsData orphan cleanup + stuck-request reset. Hourly at :25.')

ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et            = EXCLUDED.peak_hours_et,
      peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires          = EXCLUDED.daily_max_fires,
      work_check_sql           = EXCLUDED.work_check_sql,
      enabled                  = true,
      notes                    = EXCLUDED.notes,
      updated_at               = now();
