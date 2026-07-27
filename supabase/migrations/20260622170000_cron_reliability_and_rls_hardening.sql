-- ============================================================================
-- Migration 20260622xxxxxx — cron reliability + RLS hardening (health-sweep batch)
--
-- Lane:     A1 (data plane — owns crons, td_* ingest, table security)
-- Touches:  td_tm_discover_drain() (W, CREATE OR REPLACE — dedupe ON CONFLICT)
--           axs_probe, sg_market_chart (W, ENABLE RLS + REVOKE anon/auth)
--           cron.job: sweep-old-sg-listings, sweep_duplicate_listings_hourly
--             (W, re-register with explicit statement_timeout)
-- Pairs-with: CREATE INDEX CONCURRENTLY idx_sg_listings_captured (run separately,
--             non-txn) — makes the SG retention sweep's ORDER BY captured_at fast.
--
-- WHY (from the 2026-06-22 health sweep):
--  1. td_tm_discover_drain failed 100% with "ON CONFLICT DO UPDATE command cannot
--     affect row a second time": two AQ rows can match the SAME Ticketmaster
--     event, producing duplicate computed event_id in one INSERT. Dedupe the
--     insert on the computed event_id (DISTINCT ON) before the upsert.
--  2. axs_probe had FULL anon/authenticated CRUD grants with RLS off (read/write
--     exposure); sg_market_chart had RLS off. Enable RLS (service_role bypasses;
--     matches the 24 other internal tables) + revoke anon/auth grants on axs_probe.
--  3. sweep-old-sg-listings (4/4) and sweep_duplicate_listings_hourly (6/24) timed
--     out: the functions self-batch with 60-90s internal budgets, but their cron
--     commands never raised statement_timeout above the role default, so PG killed
--     them early. Re-register with an explicit SET LOCAL statement_timeout that
--     exceeds each function's internal budget.
-- ============================================================================

-- 0. Index backing the SG retention sweep's `ORDER BY captured_at LIMIT n`
--    (seatgeek_listings_snapshots had no captured_at-leading index → full scans).
--    Applied to prod out-of-band via CREATE INDEX CONCURRENTLY (non-txn); this
--    IF NOT EXISTS form makes the migration reproducible on a fresh DB and a
--    no-op against prod where it already exists.
CREATE INDEX IF NOT EXISTS idx_sg_listings_captured
  ON public.seatgeek_listings_snapshots (captured_at);

-- 1. td_tm_discover_drain: dedupe the upsert input on the computed event_id.
CREATE OR REPLACE FUNCTION public.td_tm_discover_drain()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; v_count int := 0; v_n int;
BEGIN
  IF NOT public.cron_should_fire('td_tm_discover_drain') THEN RETURN 0; END IF;
  FOR r IN SELECT p.id AS performer_id, h.status_code, h.content AS raw_content
    FROM public.td_tm_performers p JOIN net._http_response h ON h.id = p.pending_discover_request_id
    WHERE p.active = true AND p.pending_discover_request_id IS NOT NULL ORDER BY p.id
  LOOP
    IF r.status_code = 200 THEN
      WITH items AS (
        SELECT item->>'id' AS tm_hex, item->>'url' AS event_url, item->>'discoveryId' AS discovery_id,
               item->>'title' AS title,
               (item->'dates'->>'startDate')::timestamptz AS dt_utc, item->'venue'->>'name' AS venue
        FROM jsonb_array_elements(COALESCE(r.raw_content::jsonb->'body'->'items','[]'::jsonb)) AS item
        WHERE item->>'id' ~ '^[0-9A-Fa-f]{1,16}$'
          AND item->>'url' LIKE 'https://www.ticketmaster.com/%/event/%'
          AND item->>'title' NOT LIKE '%*%' AND lower(item->>'title') NOT LIKE '%parking%'
          AND COALESCE((item->>'cancelled')::boolean, false) = false
          AND (item->'dates'->>'startDate') IS NOT NULL
      ),
      matched AS (
        SELECT DISTINCT ON (t.aq_short_event_id)
          t.aq_short_event_id, i.tm_hex, i.event_url, i.discovery_id
        FROM items i
        CROSS JOIN public.td_target_events() t
        JOIN public.aq_event_map aem ON aem.aq_short_event_id = t.aq_short_event_id
        WHERE abs(extract(epoch FROM (aem.event_date::timestamptz - i.dt_utc))) < 64800
          AND ((aem.event_name ILIKE '%yankees%' AND i.venue ILIKE '%yankee stadium%')
            OR (aem.event_name ILIKE '%knicks%'  AND i.venue ILIKE '%madison square garden%'))
        ORDER BY t.aq_short_event_id,
                 (CASE WHEN i.title ILIKE '%vs.%' OR i.title ILIKE '% at %' THEN 0 ELSE 1 END),
                 abs(extract(epoch FROM (aem.event_date::timestamptz - i.dt_utc)))
      ),
      -- FIX: two AQ rows can resolve to the SAME TM event -> duplicate computed
      -- event_id in one INSERT -> ON CONFLICT error. Keep one row per event_id.
      dedup AS (
        SELECT DISTINCT ON (('x'||lpad(tm_hex,16,'0'))::bit(64)::bigint)
          ('x'||lpad(tm_hex,16,'0'))::bit(64)::bigint AS event_id,
          aq_short_event_id, event_url, discovery_id
        FROM matched
        ORDER BY ('x'||lpad(tm_hex,16,'0'))::bit(64)::bigint, aq_short_event_id
      )
      INSERT INTO public.ticketsdata_event_xref
        (event_id, platform, aq_short_event_id, event_url, td_event_id, active, always_on, match_method, updated_at)
      SELECT event_id, 'TM', aq_short_event_id, event_url, discovery_id,
             true, true, 'tm_events_venue_date', clock_timestamp()
      FROM dedup
      ON CONFLICT (event_id, platform) DO UPDATE
        SET event_url = EXCLUDED.event_url, td_event_id = EXCLUDED.td_event_id, active = true, always_on = true,
            aq_short_event_id = EXCLUDED.aq_short_event_id, match_method = 'tm_events_venue_date', updated_at = clock_timestamp();
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_count := v_count + v_n;
      UPDATE public.aq_event_map aem SET tm_event_id = x.event_id
      FROM public.ticketsdata_event_xref x
      WHERE x.platform='TM' AND x.active = true AND x.aq_short_event_id = aem.aq_short_event_id
        AND aem.tm_event_id IS DISTINCT FROM x.event_id;
      PERFORM public.td_charge_credit(1, NULL, 'TM', '/events', 200, (r.raw_content::jsonb->>'quota_remaining')::int);
    END IF;
    UPDATE public.td_tm_performers SET pending_discover_request_id = NULL, last_discovered_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE id = r.performer_id;
  END LOOP;
  RETURN v_count;
END $function$;

-- 2. RLS hardening on the two exposed tables.
ALTER TABLE public.axs_probe       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sg_market_chart ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_probe       FROM anon, authenticated;
REVOKE ALL ON public.sg_market_chart FROM anon, authenticated;

-- 3. Re-register the timing-out retention sweeps with explicit statement_timeout
--    above each function's internal time budget.
SELECT cron.schedule('sweep-old-sg-listings', '15 3,9,15,21 * * *',
  $cmd$ DO $b$ BEGIN IF NOT public.cron_should_fire('sweep-old-sg-listings') THEN RETURN; END IF; SET LOCAL statement_timeout='150s'; PERFORM public.sweep_old_sg_listings(720); END $b$; $cmd$);

SELECT cron.schedule('sweep_duplicate_listings_hourly', '15 * * * *',
  $cmd$ DO $b$ BEGIN IF NOT public.cron_should_fire('sweep_duplicate_listings_hourly') THEN RETURN; END IF; SET LOCAL statement_timeout='90s'; PERFORM public.sweep_duplicate_listings(200); END $b$; $cmd$);
