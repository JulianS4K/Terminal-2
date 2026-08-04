-- ============================================================================
-- Migration 20260804230000 — GoTickets Pro-API listings ingest (EVO-firehose mirror)
--
-- Lane:     A1 (data plane — new-source ingest + mapping + crons + retention)
-- Touches:  W (NEW tables): gotickets_event, gotickets_listings_snapshots,
--              gt_listings_poll_state, gt_listings_inflight, gt_catalog_sync_state
--           W (NEW fns): _gotickets_pro_token(), gt_catalog_sync(),
--              gt_catalog_drain(), gt_map_events(int), gt_listings_poll_tick(int),
--              gt_listings_drain(int)
--           W (config INSERT): collector_cadence (source='GT' ladder),
--              retention_policy (gotickets_listings_snapshots, 15d)
--           W (cron.job): gt_catalog_sync_daily, gt_catalog_drain_daily,
--              gt_map_events_hourly, gt_listings_poll_2min, gt_listings_drain_1min
--           R: public.events (map target), vault.decrypted_secrets
--              (GOTICKETS_ACCESS_ID/SECRET), net._http_response,
--              public.collector_band('GT','listings',hte)
-- Pre-reqs: 20260531140000 (collector_cadence + collector_band()),
--           20260705153000 (retention_policy + retention_tick_hourly runner),
--           extensions: pg_net (net.http_get/_http_response), pg_trgm (similarity()).
--           GoTickets Pro API access ENABLED on the broker key — verified 200 on
--           /rest/pro/api/payment-methods + /events/{id}/listings, 2026-08-04.
--
-- WHY: GoTickets was the only listing source with no listings ingest. This mirrors
--   the EVO firehose (evo_listings_poll_2min -> evo_listings_poll_tick ->
--   collect-listings -> listings_snapshots -> retention_policy 15d) for GoTickets,
--   with the two differences the source forces:
--     (1) MAPPING — GoTickets event ids are NOT tevo ids (EVO's are), so a
--         catalog + mapper stage resolves gt_event_id -> tevo_event_id via
--         exact-UTC-instant + trigram performer match. Measured 2026-08-04:
--         4,275 / 5,293 tracked upcoming-90d events (80.8%) auto-map.
--     (2) TRANSPORT — the pull is pg_net GET (RULE-2 read) against the Pro API
--         (gotickets.com/rest/pro/api), not an edge fn, because the auth is a
--         single base64 header. Same fire/drain shape as the TicketsData in-DB
--         ingest, kept entirely in SQL (no edge-fn deploy). The catalog is read
--         from the broker host (sc.gotickets.com/rest/events, dual-header auth).
--
-- READ-ONLY (RULE 2): every upstream call is net.http_get. gotickets.com +
--   sc.gotickets.com are on the scripts/check_readonly.py FORBIDDEN_HOSTS
--   allowlist; no net.http_post/put/patch/delete to either host exists.
--
-- APPLY / GO-LIVE ORDER (this migration is authored, NOT yet applied):
--   On apply, gotickets_event is empty, so gt_listings_poll_tick() no-ops (it
--   polls only MAPPED events) until the catalog populates — the firehose ramps
--   naturally, it does not burst. To bootstrap after apply, seed a wide delta
--   window (the full /rest/events dump is rate-limited; delta is not):
--     SELECT public.gt_catalog_sync(interval '45 days');  -- fire delta (async)
--     -- wait for the response, then:
--     SELECT public.gt_catalog_drain();  -- upsert changed events
--     SELECT public.gt_map_events();     -- resolve tevo_event_id (~81%)
--   Then the 2-min poll covers mapped events at the EVO cadence, and
--   gt_catalog_sync_hourly maintains the catalog incrementally (2h overlap).
--   To stage instead, cron.alter_job('gt_listings_poll_2min', active:=false)
--   before verifying, then re-enable.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT DO
--   NOTHING / unschedule-before-schedule. Re-apply is a no-op.
-- ============================================================================

-- ── 1. Catalog + cross-source xref (GoTickets event -> tevo_event_id) ─────────
CREATE TABLE IF NOT EXISTS public.gotickets_event (
  gt_event_id    bigint PRIMARY KEY,       -- GoTickets-internal event id
  name           text,
  performer      text,                      -- primary performer (map key)
  venue_name     text,
  venue_city     text,
  venue_state    text,
  event_time_utc timestamptz,
  status         text,                      -- 'AS_SCHEDULED' | 'CANCELLED' | ...
  tevo_event_id  bigint,                    -- mapped canonical (NULL until matched)
  mapped_via     text,                      -- 'instant_performer' | 'manual' | NULL
  map_score      numeric,                   -- trigram similarity at match time
  mapped_at      timestamptz,
  first_seen     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_gt_event_tevo ON public.gotickets_event (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_gt_event_time ON public.gotickets_event (event_time_utc);
REVOKE ALL ON TABLE public.gotickets_event FROM anon;

-- ── 2. Raw listings firehose (mirror of listings_snapshots) ──────────────────
CREATE TABLE IF NOT EXISTS public.gotickets_listings_snapshots (
  tevo_event_id     bigint,                 -- mapped canonical (terminal views key on this)
  gt_event_id       bigint      NOT NULL,
  captured_at       timestamptz NOT NULL,
  gt_listing_id     bigint      NOT NULL,
  section           text,
  section_id        bigint,
  row               text,
  quantity          integer,
  display_price     numeric(12,2),          -- unit shown price
  all_in_price      numeric(12,2),          -- incl. service fee
  service_fee       numeric(12,2),
  face_value        numeric(12,2),
  stock_type        text,                   -- MOBILE_TICKETS, etc.
  in_hand_date      date,
  general_admission boolean,
  splits            integer[],              -- validSplitQuantities
  notes             text,
  PRIMARY KEY (gt_event_id, captured_at, gt_listing_id)
);
CREATE INDEX IF NOT EXISTS idx_gt_ls_captured   ON public.gotickets_listings_snapshots (captured_at);            -- retention sweeps
CREATE INDEX IF NOT EXISTS idx_gt_ls_event_time ON public.gotickets_listings_snapshots (tevo_event_id, captured_at DESC); -- chart reads
REVOKE ALL ON TABLE public.gotickets_listings_snapshots FROM anon;

-- ── 3. Per-event poll clock (mirror of evo_listings_poll_state) ──────────────
CREATE TABLE IF NOT EXISTS public.gt_listings_poll_state (
  gt_event_id bigint PRIMARY KEY REFERENCES public.gotickets_event(gt_event_id) ON DELETE CASCADE,
  last_polled_listings_at timestamptz,
  listings_polls_today int NOT NULL DEFAULT 0,
  budget_day date NOT NULL DEFAULT current_date
);
CREATE INDEX IF NOT EXISTS idx_gt_poll_state_due ON public.gt_listings_poll_state (last_polled_listings_at NULLS FIRST);
REVOKE ALL ON TABLE public.gt_listings_poll_state FROM anon;

-- ── 4. Async correlation tables (pg_net request -> event; catalog request) ───
CREATE TABLE IF NOT EXISTS public.gt_listings_inflight (
  request_id    bigint PRIMARY KEY,         -- net.http_get() id
  gt_event_id   bigint      NOT NULL,
  tevo_event_id bigint,
  fired_at      timestamptz NOT NULL DEFAULT now()  -- = captured_at of the resulting snapshot
);
REVOKE ALL ON TABLE public.gt_listings_inflight FROM anon;

CREATE TABLE IF NOT EXISTS public.gt_catalog_sync_state (
  request_id       bigint PRIMARY KEY,
  fired_at         timestamptz NOT NULL DEFAULT now(),
  update_time_from timestamptz,          -- delta window start (logging)
  update_time_to   timestamptz,          -- delta window end
  events_upserted  integer,
  drained_at       timestamptz
);
REVOKE ALL ON TABLE public.gt_catalog_sync_state FROM anon;

-- ── 5. Cadence config — GT ladder, mirrors the current EVO listings ladder ───
INSERT INTO public.collector_cadence
  (source, scope, band, min_hours, max_hours, peak_interval_min, offpeak_interval_min, sort_order, notes) VALUES
  ('GT','listings','le3d',    0,   72,    5,    5, 1, 'GoTickets listings — mirrors EVO le3d cadence'),
  ('GT','listings','le7d',   72,  168,   15,   15, 2, NULL),
  ('GT','listings','d8_14', 168,  336,   30,   60, 3, NULL),
  ('GT','listings','d15_30',336,  720,   60,   60, 4, NULL),
  ('GT','listings','d31_60',720, 1440,  240,  240, 5, NULL),
  ('GT','listings','d61p', 1440, 4320,  720,  720, 6, '12h far-out'),
  ('GT','listings','d181p',4320, NULL, 1440, 1440, 7, '24h very-far')
ON CONFLICT (source, scope, band) DO NOTHING;

-- ── 6. Retention — 15 days, identical window/engine to the EVO firehose ──────
INSERT INTO public.retention_policy
  (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes)
VALUES
  ('gotickets_listings_snapshots', 'captured_at', 15, true, 50000, 90, 30,
   'GoTickets Pro-API listings firehose — 15d, mirrors listings_snapshots (mig 20260804230000). Swept by retention_tick_hourly.')
ON CONFLICT (table_name) DO NOTHING;

-- ── 7. Pro-API auth helper — X-Broker-Api-Token = base64(accessId:accessSecret)
--     (creds resolved server-side from Vault; never returned to a caller). ────
CREATE OR REPLACE FUNCTION public._gotickets_pro_token()
RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  SELECT translate(encode(convert_to(
    trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='GOTICKETS_ACCESS_ID'))||':'||
    trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='GOTICKETS_API_SECRET')),
    'UTF8'),'base64'), E'\n','');
$function$;
REVOKE ALL ON FUNCTION public._gotickets_pro_token() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._gotickets_pro_token() TO service_role;

-- ── 8. Catalog sync — fire the DELTA endpoint over an overlapping window ─────
--   The full /rest/events dump (313k rows) is heavily rate-limited (429 after a
--   few pulls, verified 2026-08-04), so the recurring sync uses the incremental
--   /rest/events/delta?updateTimeFrom=&updateTimeTo= (both required, NOT
--   rate-limited). p_lookback is the window width; running hourly at a 2h
--   lookback gives 1h of overlap, so a single failed run self-heals on the next
--   (upserts are idempotent). Seed the catalog once with a wide window, e.g.
--   SELECT public.gt_catalog_sync('45 days').
CREATE OR REPLACE FUNCTION public.gt_catalog_sync(p_lookback interval DEFAULT interval '2 hours')
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_req bigint; v_to timestamptz := now(); v_from timestamptz := now() - p_lookback;
BEGIN
  SELECT net.http_get(
    url := 'https://sc.gotickets.com/rest/events/delta'
           || '?updateTimeFrom=' || to_char(v_from AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"')
           || '&updateTimeTo='   || to_char(v_to   AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    headers := jsonb_build_object(
      'X-Api-Access-Id',     trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='GOTICKETS_ACCESS_ID')),
      'X-Api-Access-Secret', trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='GOTICKETS_API_SECRET')),
      'Accept','application/json'),
    timeout_milliseconds := 90000
  ) INTO v_req;
  INSERT INTO public.gt_catalog_sync_state(request_id, fired_at, update_time_from, update_time_to)
    VALUES (v_req, now(), v_from, v_to);
  RETURN v_req;
END $function$;
REVOKE ALL ON FUNCTION public.gt_catalog_sync(interval) FROM PUBLIC, anon, authenticated;

-- ── 9. Catalog drain — parse the /rest/events response, upsert gotickets_event
CREATE OR REPLACE FUNCTION public.gt_catalog_drain()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE r RECORD; v_n int := 0;
BEGIN
  SET LOCAL statement_timeout = '180s';   -- ~300k-row upsert; bounded, daily
  FOR r IN
    SELECT s.request_id, resp.status_code, resp.content
    FROM public.gt_catalog_sync_state s
    JOIN net._http_response resp ON resp.id = s.request_id
    WHERE s.drained_at IS NULL
    ORDER BY s.fired_at
  LOOP
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      INSERT INTO public.gotickets_event
        (gt_event_id, name, performer, venue_name, venue_city, venue_state, event_time_utc, status, updated_at)
      SELECT e.id, e.name, (e.performers->0->>'name'), e."venueName", e."venueCity", e."venueState",
             -- guard the cast: TBD-date events carry a null/blank eventTimeUtc; a
             -- poison value must not abort the whole daily upsert.
             CASE WHEN e."eventTimeUtc" ~ '^\d{4}-\d\d-\d\dT'
                  THEN (e."eventTimeUtc")::timestamp AT TIME ZONE 'UTC' END,
             e.status, now()
      FROM jsonb_to_recordset( (r.content::jsonb) -> 'events' ) AS e(
        id bigint, name text, performers jsonb, "venueName" text, "venueCity" text,
        "venueState" text, "eventTimeUtc" text, status text)
      WHERE e.id IS NOT NULL
      ON CONFLICT (gt_event_id) DO UPDATE SET
        name = EXCLUDED.name, performer = EXCLUDED.performer,
        venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city,
        venue_state = EXCLUDED.venue_state, event_time_utc = EXCLUDED.event_time_utc,
        status = EXCLUDED.status, updated_at = now();
      GET DIAGNOSTICS v_n = ROW_COUNT;
    ELSE
      v_n := 0;
    END IF;
    UPDATE public.gt_catalog_sync_state
       SET drained_at = now(), events_upserted = v_n WHERE request_id = r.request_id;
  END LOOP;
  RETURN v_n;
END $function$;
REVOKE ALL ON FUNCTION public.gt_catalog_drain() FROM PUBLIC, anon, authenticated;

-- ── 10. Mapper — resolve tevo_event_id via exact-UTC-instant + performer sim ──
CREATE OR REPLACE FUNCTION public.gt_map_events(p_horizon_days int DEFAULT 120)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  SET LOCAL statement_timeout = '120s';
  WITH cand AS (
    SELECT g.gt_event_id, e.id AS tevo_id,
           similarity(lower(g.performer), lower(e.primary_performer_name)) AS sim,
           row_number() OVER (PARTITION BY g.gt_event_id
             ORDER BY similarity(lower(g.performer), lower(e.primary_performer_name)) DESC) AS rn
    FROM public.gotickets_event g
    JOIN public.events e
      ON e.primary_performer_name IS NOT NULL
     AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
     AND date_trunc('minute', e.occurs_at_local::timestamptz) = date_trunc('minute', g.event_time_utc)
     AND similarity(lower(g.performer), lower(e.primary_performer_name)) > 0.45
    WHERE g.performer IS NOT NULL
      AND g.status = 'AS_SCHEDULED'
      AND g.event_time_utc > now()
      AND g.event_time_utc < now() + make_interval(days => p_horizon_days)
      -- (re)map rows that are unmapped or were auto-mapped (never clobber a manual map)
      AND (g.tevo_event_id IS NULL OR g.mapped_via = 'instant_performer')
  )
  UPDATE public.gotickets_event g
     SET tevo_event_id = c.tevo_id, mapped_via = 'instant_performer',
         map_score = round(c.sim::numeric, 3), mapped_at = now(), updated_at = now()
  FROM cand c
  WHERE c.rn = 1 AND g.gt_event_id = c.gt_event_id
    AND g.tevo_event_id IS DISTINCT FROM c.tevo_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;
REVOKE ALL ON FUNCTION public.gt_map_events(int) FROM PUBLIC, anon, authenticated;

-- ── 11. Listings poll tick — fire Pro-API GET per due mapped event ───────────
--    Mirror of evo_listings_poll_tick: select by collector_band('GT',...), fire
--    async, stamp state. Pull is pg_net GET (not an edge fn). p_max caps per tick.
CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(p_max int DEFAULT 120)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE r RECORD; v_n int := 0; v_req bigint; v_token text;
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      SELECT g.gt_event_id, g.tevo_event_id,
             EXTRACT(epoch FROM (g.event_time_utc - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
      WHERE g.tevo_event_id IS NOT NULL
        AND g.status = 'AS_SCHEDULED'
        AND g.event_time_utc > now() - interval '3 hours'
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at
      FROM ev
      JOIN LATERAL public.collector_band('GT','listings', ev.hte) c ON true
      WHERE ev.last_polled_listings_at IS NULL
         OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    )
    SELECT gt_event_id, tevo_event_id FROM due ORDER BY last_polled_listings_at NULLS FIRST LIMIT p_max
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
REVOKE ALL ON FUNCTION public.gt_listings_poll_tick(int) FROM PUBLIC, anon, authenticated;

-- ── 12. Listings drain — parse completed responses into the firehose ─────────
CREATE OR REPLACE FUNCTION public.gt_listings_drain(p_max int DEFAULT 1000)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE r RECORD; v_total int := 0; v_rows int;
BEGIN
  SET LOCAL statement_timeout = '120s';
  FOR r IN
    SELECT inf.request_id, inf.gt_event_id, inf.tevo_event_id, inf.fired_at,
           resp.status_code, resp.content
    FROM public.gt_listings_inflight inf
    JOIN net._http_response resp ON resp.id = inf.request_id
    ORDER BY inf.fired_at
    LIMIT p_max
  LOOP
    -- Per-response isolation: a single malformed/non-JSON 200 body must not abort
    -- the whole drain batch. On error, log + skip; the inflight row is still
    -- cleared below so the pipeline never jams on one bad payload.
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      BEGIN
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
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'gt_listings_drain: request % (gt_event %) parse failed: %',
          r.request_id, r.gt_event_id, SQLERRM;
      END;
    END IF;
    -- Clear the inflight row whether the pull succeeded, errored, or returned
    -- non-200 (a failed pull just skips this cycle; the poller re-fires on cadence).
    DELETE FROM public.gt_listings_inflight WHERE request_id = r.request_id;
  END LOOP;
  RETURN v_total;
END $function$;
REVOKE ALL ON FUNCTION public.gt_listings_drain(int) FROM PUBLIC, anon, authenticated;

-- ── 13. Schedule the pipeline (mirror EVO cadence; drains + catalog staggered)
DO $sched$
DECLARE j text;
BEGIN
  FOREACH j IN ARRAY ARRAY['gt_catalog_sync_daily','gt_catalog_drain_daily',
    'gt_catalog_sync_hourly','gt_catalog_drain_hourly',
    'gt_map_events_hourly','gt_listings_poll_2min','gt_listings_drain_1min']
  LOOP
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = j) THEN PERFORM cron.unschedule(j); END IF;
  END LOOP;
END $sched$;

-- catalog: incremental delta every hour (2h overlapping window, rate-limit-safe),
-- drain 5 min later, remap at :35
SELECT cron.schedule('gt_catalog_sync_hourly',  '15 * * * *', $c$SELECT public.gt_catalog_sync();$c$);
SELECT cron.schedule('gt_catalog_drain_hourly', '20 * * * *', $c$SELECT public.gt_catalog_drain();$c$);
SELECT cron.schedule('gt_map_events_hourly',    '35 * * * *', $c$SELECT public.gt_map_events();$c$);
-- listings: fire every 2 min (mirror evo_listings_poll_2min), drain every minute
SELECT cron.schedule('gt_listings_poll_2min',  '*/2 * * * *', $c$SELECT public.gt_listings_poll_tick(120);$c$);
SELECT cron.schedule('gt_listings_drain_1min', '* * * * *',   $c$SELECT public.gt_listings_drain(1000);$c$);
