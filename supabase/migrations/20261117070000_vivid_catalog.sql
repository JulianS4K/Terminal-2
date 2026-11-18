-- Migration 20261117070000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:vivid_catalog_event(new),vivid_catalog_venue(new),vivid_catalog_sync(new),vivid_catalog_audit(new),aq_event_map(vivid_event_id fill — DML only, no DDL),vivid_orders(tevo_event_id fill-only by id),vivid_catalog_pull()(new),vivid_catalog_map()(new),vivid_catalog_tick()(new),cron:vivid_catalog_tick_1min,cron:vivid_catalog_map_hourly · reads:vault.decrypted_secrets(VIVID_API_TOKEN),events,aq_event_map,vivid_orders,venue_timezone (via tevo_event_utc),tickpick_catalog_name_fits() · pre:20261117060040
--
-- MAPPING PROGRAM, MAP-12 (operator 2026-11-17: "also incorporate https://brokers.vividseats.com/webservices/events/search").
--
-- WHAT THE ENDPOINT IS (probed 2026-11-17 with the broker token the order pull keeps in the vault). GET
--   brokers.vividseats.com/webservices/events/search, the token in an `Api-token` HEADER (the ?apiToken= form the
--   v1 order methods take is refused here: "Must provide an API token as Api-token header"). It answers a JSON array
--   of 1,000 events, in start order from yesterday, and pages ONLY by `page=N` (name, venueId, performerId,
--   startDate/endDate, offset, pageSize were all ignored: byte-identical pages). Rate limit, from the server itself:
--   "This method may only be called 1 time(s) every 5 second(s)". Page 40 was 2026-11-30, page 120 the New Year,
--   page 300 June 2027 — the whole catalogue is a few hundred pages, so a full pass is about an hour at the limit.
--   Each event: eventId (= the productionId our Vivid orders carry and the hub's vivid_event_id — 25,466 order rows
--   join the hub on it; the orders' own "eventId" is a different, performer-level id and matches nothing), eventName,
--   eventDate (venue wall clock; a T00:00:00 start is a date-only placeholder, 4 in 1,000), venue {venueId, name,
--   city, state, countryCode, timezone}, performers [{performerId, name, master, category {categoryId, name,
--   eventType}}], listingCount, ticketCount, integrationType. The hub already holds a Vivid id on 4,237 upcoming
--   rows (from our orders), so the catalogue starts with a large identity seed.
--
-- WHAT THIS DOES. The TickPick catalogue's shape (mig 20261117040000), adapted to a page cursor and a rate limit:
--   vivid_catalog_event / _venue / _sync / _audit; vivid_catalog_pull(p_pages) fetches up to p_pages pages 5.2 s
--   apart, resuming the stored page; an empty page ends the pass (next pass after 6 h). vivid_catalog_tick() runs
--   every minute and pulls 8 pages when a pass is open or due (≈ 45 s). vivid_catalog_map(apply) hourly: identity
--   (hub vivid_event_id, or a Vivid order already mapped — same local day AND the name fits), then TEvo venue
--   (manual row → learned from matches) + local day + tickpick_catalog_name_fits (the generic name rule), ties by
--   start minute (venue timezone from the catalogue) unless the start is a midnight placeholder; two catalogue
--   events on one EVO event → neither; matches re-verified each pass. DML only, fill-only: aq_event_map.vivid_event_id
--   on the matched events' hub rows (no rows created, no DDL), vivid_orders.tevo_event_id by productionId
--   (matched_via 'vivid_catalog_id'; a disagreeing existing map is audited, never re-pointed). The venue xref lives
--   in vivid_catalog_venue (aq_venue_map has no Vivid id column; adding one is DDL on a shared table — not here).
-- RULE 2: GETs of brokers.vividseats.com only, one method, inside its published rate limit.
-- Rollback: cron.unschedule('vivid_catalog_tick_1min'); cron.unschedule('vivid_catalog_map_hourly'); drop the four
--   tables and three functions; hub / order fills are audited in vivid_catalog_audit and reversible from it.

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.vivid_catalog_event (
  vivid_event_id   bigint PRIMARY KEY,                -- Vivid's eventId = the productionId on our orders = aq_event_map.vivid_event_id
  name             text,
  event_local      timestamp,                         -- venue wall clock; T00:00:00 = date-only placeholder
  event_date       date GENERATED ALWAYS AS (event_local::date) STORED,
  time_known       boolean GENERATED ALWAYS AS (event_local IS NOT NULL AND event_local::time <> '00:00:00'::time) STORED,
  timezone         text,
  vivid_venue_id   bigint,
  venue_name       text,
  venue_city       text,
  venue_state      text,
  venue_country    text,
  category         text,
  event_type       text,
  performers       jsonb NOT NULL DEFAULT '[]'::jsonb,
  listing_count    integer,
  ticket_count     integer,
  integration_type text,
  raw              jsonb,
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  tevo_event_id    bigint,
  tevo_match_method text,
  tevo_matched_at  timestamptz
);
COMMENT ON TABLE public.vivid_catalog_event IS
  'Vivid Seats'' event catalogue (GET brokers.vividseats.com/webservices/events/search, paged), one row per Vivid eventId (= productionId on our orders), with our EVO match. vivid_catalog_pull() fills it, vivid_catalog_map() matches it. Mig 20261117070000.';
CREATE INDEX IF NOT EXISTS vivid_catalog_event_venue_day_idx ON public.vivid_catalog_event (vivid_venue_id, event_date);
CREATE INDEX IF NOT EXISTS vivid_catalog_event_tevo_idx ON public.vivid_catalog_event (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS vivid_catalog_event_day_idx ON public.vivid_catalog_event (event_date);

CREATE TABLE IF NOT EXISTS public.vivid_catalog_venue (
  vivid_venue_id bigint PRIMARY KEY,
  name           text,
  city           text,
  state          text,
  country        text,
  timezone       text,
  tevo_venue_id  bigint,
  method         text,                                -- manual | matched_events
  events         integer,
  first_seen_at  timestamptz NOT NULL DEFAULT now(),
  last_seen_at   timestamptz NOT NULL DEFAULT now(),
  derived_at     timestamptz
);
COMMENT ON TABLE public.vivid_catalog_venue IS
  'Vivid venues seen in the catalogue and the TEvo venue each maps to (manual, or learned from matched events). A ''manual'' row is never overwritten. Mig 20261117070000.';

CREATE TABLE IF NOT EXISTS public.vivid_catalog_sync (
  id                integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  next_page         integer NOT NULL DEFAULT 1,
  pass_started_at   timestamptz,
  pass_finished_at  timestamptz,
  pages_total       integer NOT NULL DEFAULT 0,
  events_total      integer NOT NULL DEFAULT 0,
  last_run_at       timestamptz,
  last_status       integer,
  last_error        text,
  runs              integer NOT NULL DEFAULT 0
);
INSERT INTO public.vivid_catalog_sync (id) VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS public.vivid_catalog_audit (
  id             bigserial PRIMARY KEY,
  at             timestamptz NOT NULL DEFAULT now(),
  run_id         uuid NOT NULL,
  vivid_event_id bigint,
  action         text NOT NULL,                      -- match | drop | hub_vivid | order_tevo | order_disagree | venue_xref
  target         text NOT NULL,
  target_key     text,
  old_tevo       bigint,
  new_tevo       bigint,
  note           text
);
CREATE INDEX IF NOT EXISTS vivid_catalog_audit_run_idx ON public.vivid_catalog_audit (run_id);
CREATE INDEX IF NOT EXISTS vivid_catalog_audit_event_idx ON public.vivid_catalog_audit (vivid_event_id);

ALTER TABLE public.vivid_catalog_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vivid_catalog_venue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vivid_catalog_sync  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vivid_catalog_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vivid_catalog_event, public.vivid_catalog_venue, public.vivid_catalog_sync, public.vivid_catalog_audit FROM anon, authenticated;
GRANT SELECT ON public.vivid_catalog_event, public.vivid_catalog_venue, public.vivid_catalog_sync, public.vivid_catalog_audit TO service_role;

-- ───────────────────────── the pull ─────────────────────────
-- Up to p_pages pages, 5.2 s apart (the server allows one call per 5 s), resuming the stored page; an empty page
-- ends the pass. RULE 2: GET only.
CREATE OR REPLACE FUNCTION public.vivid_catalog_pull(p_pages integer DEFAULT 8)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  tok      text;
  s        public.vivid_catalog_sync;
  r        extensions.http_response;
  j        jsonb;
  v_page   int;
  v_pages  int := 0;
  v_events int := 0;
  v_n      int;
  v_done   boolean := false;
BEGIN
  SELECT decrypted_secret INTO tok FROM vault.decrypted_secrets WHERE name = 'VIVID_API_TOKEN';
  IF tok IS NULL THEN
    UPDATE public.vivid_catalog_sync SET last_run_at = now(), last_error = 'no_token', runs = runs + 1 WHERE id = 1;
    RETURN jsonb_build_object('error', 'no_token');
  END IF;
  SELECT * INTO s FROM public.vivid_catalog_sync WHERE id = 1 FOR UPDATE;
  v_page := greatest(s.next_page, 1);
  IF v_page = 1 THEN
    UPDATE public.vivid_catalog_sync SET pass_started_at = now(), pass_finished_at = NULL, pages_total = 0, events_total = 0 WHERE id = 1;
  END IF;

  PERFORM set_config('http.timeout_msec', '25000', true);
  WHILE v_pages < p_pages AND NOT v_done LOOP
    IF v_pages > 0 THEN PERFORM pg_sleep(5.2); END IF;
    r := extensions.http(('GET', 'https://brokers.vividseats.com/webservices/events/search?page=' || v_page,
           ARRAY[extensions.http_header('Api-token', tok), extensions.http_header('Accept', 'application/json')], NULL, NULL)::extensions.http_request);
    j := public.safe_jsonb(r.content);
    IF r.status IS DISTINCT FROM 200 OR j IS NULL OR jsonb_typeof(j) <> 'array' THEN
      UPDATE public.vivid_catalog_sync
         SET last_run_at = now(), last_status = r.status, runs = runs + 1,
             last_error = format('page %s: http %s %s', v_page, coalesce(r.status::text, 'none'), left(coalesce(r.content, ''), 300)),
             pages_total = pages_total + v_pages, events_total = events_total + v_events
       WHERE id = 1;
      RETURN jsonb_build_object('pages', v_pages, 'events', v_events, 'page', v_page, 'http', r.status, 'error', 'bad_page');
    END IF;
    v_pages := v_pages + 1;
    IF jsonb_array_length(j) = 0 THEN
      v_done := true;
      EXIT;
    END IF;

    INSERT INTO public.vivid_catalog_event AS t
      (vivid_event_id, name, event_local, timezone, vivid_venue_id, venue_name, venue_city, venue_state, venue_country,
       category, event_type, performers, listing_count, ticket_count, integration_type, raw, last_seen_at)
    SELECT (e->>'eventId')::bigint, e->>'eventName',
           CASE WHEN (e->>'eventDate') ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN left(e->>'eventDate', 19)::timestamp END,
           e->'venue'->>'timezone',
           CASE WHEN (e->'venue'->>'venueId') ~ '^\d+$' THEN (e->'venue'->>'venueId')::bigint END,
           e->'venue'->>'name', e->'venue'->>'city', e->'venue'->>'state', e->'venue'->>'countryCode',
           coalesce((SELECT p->'category'->>'name' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e->'performers') = 'array' THEN e->'performers' ELSE '[]'::jsonb END) p ORDER BY (p->>'master') = 'true' DESC LIMIT 1), NULL),
           coalesce((SELECT p->>'eventType' FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e->'performers') = 'array' THEN e->'performers' ELSE '[]'::jsonb END) p ORDER BY (p->>'master') = 'true' DESC LIMIT 1), NULL),
           CASE WHEN jsonb_typeof(e->'performers') = 'array'
                THEN (SELECT coalesce(jsonb_agg(p - 'url' - 'cmsPath' - 'slug'), '[]'::jsonb) FROM jsonb_array_elements(e->'performers') p) ELSE '[]'::jsonb END,
           CASE WHEN (e->>'listingCount') ~ '^\d+$' THEN (e->>'listingCount')::int END,
           CASE WHEN (e->>'ticketCount') ~ '^\d+$' THEN (e->>'ticketCount')::int END,
           e->>'integrationType', e - 'performers', now()
      FROM jsonb_array_elements(j) e
     WHERE (e->>'eventId') ~ '^\d+$'
    ON CONFLICT (vivid_event_id) DO UPDATE
      SET name = EXCLUDED.name, event_local = EXCLUDED.event_local, timezone = EXCLUDED.timezone,
          vivid_venue_id = EXCLUDED.vivid_venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city,
          venue_state = EXCLUDED.venue_state, venue_country = EXCLUDED.venue_country,
          category = EXCLUDED.category, event_type = EXCLUDED.event_type, performers = EXCLUDED.performers,
          listing_count = EXCLUDED.listing_count, ticket_count = EXCLUDED.ticket_count, integration_type = EXCLUDED.integration_type,
          raw = EXCLUDED.raw, last_seen_at = now();
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_events := v_events + v_n;

    INSERT INTO public.vivid_catalog_venue AS v (vivid_venue_id, name, city, state, country, timezone, last_seen_at)
    SELECT DISTINCT ON ((e->'venue'->>'venueId')::bigint)
           (e->'venue'->>'venueId')::bigint, e->'venue'->>'name', e->'venue'->>'city', e->'venue'->>'state', e->'venue'->>'countryCode', e->'venue'->>'timezone', now()
      FROM jsonb_array_elements(j) e
     WHERE (e->'venue'->>'venueId') ~ '^\d+$'
     ORDER BY (e->'venue'->>'venueId')::bigint
    ON CONFLICT (vivid_venue_id) DO UPDATE
      SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state, country = EXCLUDED.country,
          timezone = coalesce(EXCLUDED.timezone, v.timezone), last_seen_at = now();

    v_page := v_page + 1;
  END LOOP;

  UPDATE public.vivid_catalog_sync
     SET next_page = CASE WHEN v_done THEN 1 ELSE v_page END,
         pages_total = pages_total + v_pages, events_total = events_total + v_events,
         pass_finished_at = CASE WHEN v_done THEN now() ELSE pass_finished_at END,
         last_run_at = now(), last_status = 200, last_error = NULL, runs = runs + 1
   WHERE id = 1;
  RETURN jsonb_build_object('pages', v_pages, 'events', v_events, 'next_page', CASE WHEN v_done THEN 1 ELSE v_page END, 'pass_done', v_done);
END $function$;
COMMENT ON FUNCTION public.vivid_catalog_pull(integer) IS
  'GET up to p_pages pages of Vivid Seats'' event catalogue (brokers.vividseats.com/webservices/events/search?page=N, 1,000 a page, 5.2 s apart) into vivid_catalog_event/_venue, resuming the stored page; an empty page ends the pass. Read-only upstream (RULE 2). Mig 20261117070000.';

-- ───────────────────────── the mapper ─────────────────────────
CREATE OR REPLACE FUNCTION public.vivid_catalog_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_out jsonb := '{}'::jsonb;
  v_n   int;
BEGIN
  -- 0. candidates: upcoming, local day known
  DROP TABLE IF EXISTS _vc_cand;
  CREATE TEMP TABLE _vc_cand ON COMMIT DROP AS
  SELECT c.vivid_event_id, c.name, c.performers, c.vivid_venue_id, c.event_date, c.time_known,
         CASE WHEN c.time_known AND c.timezone IS NOT NULL AND c.timezone IN (SELECT name FROM pg_timezone_names)
              THEN c.event_local AT TIME ZONE c.timezone END AS event_utc,
         c.tevo_event_id AS cur_tevo, c.tevo_match_method AS cur_method
    FROM public.vivid_catalog_event c
   WHERE c.event_date BETWEEN current_date - 1 AND current_date + 400;
  CREATE INDEX ON _vc_cand (vivid_event_id);
  v_out := v_out || jsonb_build_object('candidates', (SELECT count(*) FROM _vc_cand));

  -- 1. verify the matched
  DROP TABLE IF EXISTS _vc_drop;
  CREATE TEMP TABLE _vc_drop ON COMMIT DROP AS
  SELECT x.vivid_event_id, x.cur_tevo, x.cur_method,
         CASE WHEN e.id IS NULL THEN 'event_gone' WHEN e.state = 'ignored' THEN 'event_ignored' ELSE 'day_moved' END AS why
    FROM _vc_cand x LEFT JOIN public.events e ON e.id = x.cur_tevo
   WHERE x.cur_tevo IS NOT NULL
     AND (e.id IS NULL OR e.state = 'ignored' OR left(e.occurs_at_local, 10) IS DISTINCT FROM to_char(x.event_date, 'YYYY-MM-DD'));
  v_out := v_out || jsonb_build_object('dropped', (SELECT count(*) FROM _vc_drop));
  IF p_apply THEN
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.vivid_event_id, 'drop', 'vivid_catalog_event', d.vivid_event_id::text, d.cur_tevo, d.why || ' (' || coalesce(d.cur_method, '?') || ')' FROM _vc_drop d;
    UPDATE public.vivid_catalog_event c SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL
      FROM _vc_drop d WHERE d.vivid_event_id = c.vivid_event_id;
  END IF;
  UPDATE _vc_cand x SET cur_tevo = NULL, cur_method = NULL FROM _vc_drop d WHERE d.vivid_event_id = x.vivid_event_id;

  DROP TABLE IF EXISTS _vc_pick;
  CREATE TEMP TABLE _vc_pick (vivid_event_id bigint PRIMARY KEY, tevo_event_id bigint NOT NULL, method text NOT NULL) ON COMMIT DROP;

  -- 2. identity: the hub's vivid_event_id; our Vivid orders already mapped — same local day AND the name still fits
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT DISTINCT ON (x.vivid_event_id) x.vivid_event_id, a.tevo_event_id, 'hub_identity'
    FROM _vc_cand x
    JOIN public.aq_event_map a ON a.vivid_event_id = x.vivid_event_id AND a.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = a.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
   ORDER BY x.vivid_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT x.vivid_event_id, o.tevo, 'order_identity'
    FROM _vc_cand x
    JOIN (SELECT (o.raw->>'productionId')::bigint AS pid, o.tevo_event_id AS tevo
            FROM public.vivid_orders o
           WHERE o.tevo_event_id IS NOT NULL AND (o.raw->>'productionId') ~ '^\d+$'
           GROUP BY 1, 2) o ON o.pid = x.vivid_event_id
    JOIN public.events e ON e.id = o.tevo AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
     AND NOT EXISTS (SELECT 1 FROM public.vivid_orders o2
                      WHERE (o2.raw->>'productionId') ~ '^\d+$' AND (o2.raw->>'productionId')::bigint = x.vivid_event_id
                        AND o2.tevo_event_id IS NOT NULL AND o2.tevo_event_id <> o.tevo)
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object('identity', (SELECT count(*) FROM _vc_pick));

  -- 3. venues: manual rows, then the mode of the venues the identity picks and standing matches point at
  DROP TABLE IF EXISTS _vc_venue;
  CREATE TEMP TABLE _vc_venue ON COMMIT DROP AS
  WITH known AS (
    SELECT v.vivid_venue_id, v.tevo_venue_id, 'manual' AS method, 1 AS pri
      FROM public.vivid_catalog_venue v WHERE v.method = 'manual' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT s.vivid_venue_id, s.tv, 'matched_events', 2
      FROM (SELECT x.vivid_venue_id, e.venue_id AS tv, count(*) AS n,
                   row_number() OVER (PARTITION BY x.vivid_venue_id ORDER BY count(*) DESC, e.venue_id) AS rn
              FROM _vc_cand x
              LEFT JOIN _vc_pick p ON p.vivid_event_id = x.vivid_event_id
              JOIN public.events e ON e.id = coalesce(p.tevo_event_id, x.cur_tevo)
             WHERE x.vivid_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY x.vivid_venue_id, e.venue_id) s
     WHERE s.rn = 1
  )
  SELECT DISTINCT ON (k.vivid_venue_id) k.vivid_venue_id, k.tevo_venue_id, k.method FROM known k ORDER BY k.vivid_venue_id, k.pri;
  CREATE INDEX ON _vc_venue (vivid_venue_id);
  v_out := v_out || jsonb_build_object('venues_resolved', (SELECT count(*) FROM _vc_venue));

  -- 4. venue + local day (+ name, + minute)
  DROP TABLE IF EXISTS _vc_fit;
  CREATE TEMP TABLE _vc_fit ON COMMIT DROP AS
  SELECT x.vivid_event_id, e.id AS tevo_event_id,
         (x.event_utc IS NOT NULL AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _vc_cand x
    JOIN _vc_venue v ON v.vivid_venue_id = x.vivid_venue_id
    JOIN public.events e ON e.venue_id = v.tevo_venue_id
                        AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
                        AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL
     AND NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = x.vivid_event_id)
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name);
  DROP TABLE IF EXISTS _vc_claimed;
  CREATE TEMP TABLE _vc_claimed ON COMMIT DROP AS
  SELECT x.cur_tevo AS tevo_event_id FROM _vc_cand x WHERE x.cur_tevo IS NOT NULL
  UNION SELECT p.tevo_event_id FROM _vc_pick p
  UNION SELECT c.tevo_event_id FROM public.vivid_catalog_event c
         WHERE c.tevo_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM _vc_drop d WHERE d.vivid_event_id = c.vivid_event_id);
  WITH per AS (
    SELECT f.vivid_event_id, count(*) AS n_fit, min(f.tevo_event_id) AS one_fit,
           count(*) FILTER (WHERE f.same_minute) AS n_minute, min(f.tevo_event_id) FILTER (WHERE f.same_minute) AS one_minute
      FROM _vc_fit f
     WHERE NOT EXISTS (SELECT 1 FROM _vc_claimed c WHERE c.tevo_event_id = f.tevo_event_id)
     GROUP BY f.vivid_event_id),
  pick AS (
    SELECT p.vivid_event_id,
           CASE WHEN p.n_fit = 1 THEN p.one_fit WHEN p.n_minute = 1 THEN p.one_minute END AS tevo_event_id,
           CASE WHEN p.n_fit = 1 THEN 'venue_day_name' WHEN p.n_minute = 1 THEN 'venue_time_name' END AS method
      FROM per p),
  uniq AS (
    SELECT p.* FROM pick p
     WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.vivid_event_id <> p.vivid_event_id))
  INSERT INTO _vc_pick (vivid_event_id, tevo_event_id, method)
  SELECT u.vivid_event_id, u.tevo_event_id, u.method FROM uniq u
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object(
    'picked', (SELECT count(*) FROM _vc_pick),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT method m, count(*) n FROM _vc_pick GROUP BY 1) s),
    'ambiguous', (SELECT count(DISTINCT f.vivid_event_id) FROM _vc_fit f WHERE NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = f.vivid_event_id)),
    'unmatched', (SELECT count(*) FROM _vc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _vc_pick p WHERE p.vivid_event_id = x.vivid_event_id)),
    'no_venue', (SELECT count(*) FROM _vc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _vc_venue v WHERE v.vivid_venue_id = x.vivid_venue_id)));

  IF p_apply THEN
    UPDATE public.vivid_catalog_event c
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = p.method, tevo_matched_at = now()
      FROM _vc_pick p WHERE p.vivid_event_id = c.vivid_event_id;
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.vivid_event_id, 'match', 'vivid_catalog_event', p.vivid_event_id::text, p.tevo_event_id, p.method FROM _vc_pick p;

    WITH cnt AS (
      SELECT c.vivid_venue_id, count(*) AS n
        FROM public.vivid_catalog_event c JOIN public.events e ON e.id = c.tevo_event_id
        JOIN _vc_venue v ON v.vivid_venue_id = c.vivid_venue_id AND v.tevo_venue_id = e.venue_id
       GROUP BY c.vivid_venue_id),
    u AS (
      INSERT INTO public.vivid_catalog_venue AS v (vivid_venue_id, tevo_venue_id, method, events, derived_at)
      SELECT t.vivid_venue_id, t.tevo_venue_id, t.method, coalesce(cnt.n, 0), now()
        FROM _vc_venue t LEFT JOIN cnt ON cnt.vivid_venue_id = t.vivid_venue_id
      ON CONFLICT (vivid_venue_id) DO UPDATE
        SET tevo_venue_id = EXCLUDED.tevo_venue_id, method = EXCLUDED.method, events = EXCLUDED.events, derived_at = now()
        WHERE v.method IS DISTINCT FROM 'manual'
          AND (v.tevo_venue_id IS DISTINCT FROM EXCLUDED.tevo_venue_id OR v.method IS DISTINCT FROM EXCLUDED.method OR v.events IS DISTINCT FROM EXCLUDED.events)
      RETURNING v.vivid_venue_id, v.tevo_venue_id, v.method, v.events)
    INSERT INTO public.vivid_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'vivid_catalog_venue', u.vivid_venue_id::text, format('tevo_venue %s via %s (%s events)', u.tevo_venue_id, u.method, u.events) FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_written', v_n);

    -- 5. hub: vivid_event_id on the matched events' rows (fill-only; one Vivid id per EVO event)
    WITH vv AS (
      SELECT c.tevo_event_id, min(c.vivid_event_id) AS vivid_event_id
        FROM public.vivid_catalog_event c
       WHERE c.tevo_event_id IS NOT NULL AND c.event_date >= current_date - 1
       GROUP BY c.tevo_event_id HAVING count(*) = 1),
    u AS (
      UPDATE public.aq_event_map a SET vivid_event_id = vv.vivid_event_id
        FROM vv
       WHERE a.tevo_event_id = vv.tevo_event_id AND a.vivid_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.vivid_event_id = vv.vivid_event_id AND o.tevo_event_id IS DISTINCT FROM vv.tevo_event_id)
       RETURNING a.aq_short_event_id, a.tevo_event_id, vv.vivid_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.vivid_event_id, 'hub_vivid', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_vivid_filled', v_n);

    -- 6. orders: by productionId, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.vivid_orders o
         SET tevo_event_id = c.tevo_event_id
        FROM public.vivid_catalog_event c
       WHERE o.tevo_event_id IS NULL AND (o.raw->>'productionId') ~ '^\d+$'
         AND c.vivid_event_id = (o.raw->>'productionId')::bigint AND c.tevo_event_id IS NOT NULL
       RETURNING o.vivid_order_id, c.vivid_event_id, c.tevo_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, u.vivid_event_id, 'order_tevo', 'vivid_orders', u.vivid_order_id, u.tevo_event_id, 'vivid_catalog_id' FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_filled', v_n);
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, old_tevo, new_tevo)
    SELECT v_run, c.vivid_event_id, 'order_disagree', 'vivid_orders', o.vivid_order_id, o.tevo_event_id, c.tevo_event_id
      FROM public.vivid_orders o
      JOIN public.vivid_catalog_event c ON (o.raw->>'productionId') ~ '^\d+$' AND c.vivid_event_id = (o.raw->>'productionId')::bigint
     WHERE o.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id
       AND o.event_date >= now() - interval '1 day'
       AND NOT EXISTS (SELECT 1 FROM public.vivid_catalog_audit a
                        WHERE a.action = 'order_disagree' AND a.target_key = o.vivid_order_id AND a.new_tevo = c.tevo_event_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_disagree_new', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;
COMMENT ON FUNCTION public.vivid_catalog_map(boolean) IS
  'Maps Vivid Seats'' catalogue to EVO events (identity through the hub / mapped orders, then venue + local day + name, then same minute), fills aq_event_map.vivid_event_id and vivid_orders.tevo_event_id by id (fill-only) and learns the Vivid venue xref. apply=false dry-runs. Every change in vivid_catalog_audit. Mig 20261117070000.';

-- ───────────────────────── the minute tick ─────────────────────────
CREATE OR REPLACE FUNCTION public.vivid_catalog_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE s public.vivid_catalog_sync;
BEGIN
  SELECT * INTO s FROM public.vivid_catalog_sync WHERE id = 1;
  -- a pass is open (next_page > 1) or due (none yet, or the last finished over 6 h ago)
  IF s.next_page > 1 OR s.pass_finished_at IS NULL OR s.pass_finished_at < now() - interval '6 hours' THEN
    RETURN public.vivid_catalog_pull(8);
  END IF;
  RETURN jsonb_build_object('idle', true, 'next_pass_after', s.pass_finished_at + interval '6 hours');
END $function$;
COMMENT ON FUNCTION public.vivid_catalog_tick() IS
  'Every minute: pull 8 pages of Vivid Seats'' catalogue (≈ 45 s at one call per 5 s) while a pass is open or due; a pass is the whole catalogue, repeated every 6 h. Cron vivid_catalog_tick_1min. Mig 20261117070000.';

REVOKE ALL ON FUNCTION public.vivid_catalog_pull(integer), public.vivid_catalog_map(boolean), public.vivid_catalog_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vivid_catalog_pull(integer), public.vivid_catalog_map(boolean), public.vivid_catalog_tick() TO service_role;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vivid_catalog_tick_1min') THEN PERFORM cron.unschedule('vivid_catalog_tick_1min'); END IF;
  PERFORM cron.schedule('vivid_catalog_tick_1min', '* * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '58s'; SELECT public.vivid_catalog_tick(); COMMIT;$j$);
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vivid_catalog_map_hourly') THEN PERFORM cron.unschedule('vivid_catalog_map_hourly'); END IF;
  PERFORM cron.schedule('vivid_catalog_map_hourly', '43 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '150s'; SELECT public.vivid_catalog_map(true); COMMIT;$j$);
END
$cron$;

COMMIT;

-- the first page now, outside the DDL transaction; the minute tick carries the pass on, the hourly map applies
SELECT public.vivid_catalog_pull(1);
