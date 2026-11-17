-- Migration 20261117040000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tickpick_catalog_event(new),tickpick_catalog_venue(new),tickpick_catalog_sync(new),tickpick_catalog_audit(new),aq_event_map(tp_event_id fill — DML only, no DDL),tickpick_orders(tevo_event_id fill-only by id),aq_venue_map(tickpick_venue_id fill-only),tickpick_catalog_name_fits()(new),tickpick_catalog_pull()(new),tickpick_catalog_map()(new),tickpick_catalog_tick()(new),cron:tickpick_catalog_hourly · reads:vault.decrypted_secrets(TICKPICK_API_TOKEN),events,aq_event_map,aq_venue_map,cross_source_venue_map,tickpick_orders,venue_timezone (via tevo_event_utc) · pre:20261117030000
--
-- MAPPING PROGRAM, MAP-11 (KANBAN "Mapping program"): TickPick's event catalogue, pulled and mapped.
--
-- WHY. TickPick publishes its whole event catalogue (developer.tickpick.com/api, GET /1.0/catalog/events: cursor
--   pages of up to 1,000 events, filters by date window / venue / performer / state / country), readable with the
--   account token the order pull already keeps in the vault. Each event carries TickPick's event id — today the
--   TicketNetwork event id — the venue (TickPick's own venue id, city, state, country), the start in the venue's local
--   time with its IANA zone and in UTC, two flags saying whether the date and the time are real or placeholders,
--   the status (scheduled / rescheduled / postponed / canceled), a merged_into pointer when TickPick folds an event
--   into another, a three-level category and the performers with roles. Until now nothing of ours read it: the hub
--   held a TickPick id on 43 rows, every TickPick order was mapped by name, venue and day, and the resolver's
--   identity stage for 'tickpick' (event_mapper_identity -> aq_event_map.tp_event_id) had almost nothing to hit.
--   Probed 2026-11-17: one national page of 1,000 events for the next 7 days answered 200 in under a second
--   (912 with a confirmed time, 894 in the US, 30 canceled); a full forward walk is a few hundred pages.
--
-- WHAT.
--   tickpick_catalog_event / _venue   the catalogue as TickPick serves it (raw kept), plus our EVO match per event
--   tickpick_catalog_sync             one row per pull kind ('window', 'walk') with the resumable cursor
--   tickpick_catalog_audit            every change the mapper makes (match, drop, hub fill, order fill, venue xref)
--   tickpick_catalog_pull(kind, from, to, max_pages)   GETs pages into the tables, resuming the kind's cursor
--   tickpick_catalog_map(apply)       the mapper (see below); apply=false is a faithful dry run
--   tickpick_catalog_tick()           the hourly step: window pull (today..+60 d) + a slice of the two-year walk
--                                     + the mapper; cron tickpick_catalog_hourly at :41
--
-- THE MAPPER, in order, every run:
--   0. candidates: catalogue events not canceled, not merged away, date confirmed, local day between yesterday
--      and +400 days. Placeholder times (time_confirmed=false) are candidates but never break a tie by time.
--   1. verify: a catalogue event already matched whose EVO event is gone / ignored / on another local day is
--      dropped (audit 'drop') and matched again.
--   2. identity: the hub's tp_event_id (hub_identity) and our own TickPick orders already mapped to EVO by the
--      resolver (order_identity, the order's raw event id = this catalogue id) — accepted only on the same local day.
--   3. venues: TickPick venue id -> TEvo venue: tickpick_catalog_venue.method='manual' first, then aq_venue_map
--      (unique), then cross_source_venue_map when one TEvo venue carries the id, then the mode of the venues this
--      run's matched events point at ('matched_events'; learned, like the MLB mapper's parks).
--   4. venue + day: EVO events at that TEvo venue on the catalogue event's local day whose name fits
--      (tickpick_catalog_name_fits: same normalised name, one contains the other, every TickPick performer
--      named in the EVO name, or the EVO primary performer named in the TickPick name; parking/tailgate/shuttle
--      only maps to parking/tailgate/shuttle). One fit -> venue_day_name. Several fits and a confirmed time ->
--      the EVO event starting the same minute (tevo_event_utc within 60 s) -> venue_time_name. Two catalogue
--      events fitting the same EVO event the same day -> neither (ambiguous, counted). Nothing is claimed twice.
--   5. hub: aq_event_map.tp_event_id filled — DML, fill-only — on the hub rows of matched EVO events, unless
--      another hub row already carries that TickPick id for a different EVO event. No hub rows are created
--      (the hub is a spine for events we trade; a catalogue of 100k events is not), no DDL on the hub.
--   6. orders: tickpick_orders.tevo_event_id filled by id (matched_via 'tp_catalog_id', confidence 1.0) where
--      NULL; an order mapped elsewhere than the catalogue says is audited ('order_disagree'), never re-pointed.
--   7. venue xref: aq_venue_map.tickpick_venue_id filled (UNIQUE respected) from this run's learned venues.
--
-- WHAT THIS DOES NOT DO. No POST — the catalogue's id-lookup endpoint is a POST and stays unused (RULE 2; the
--   merged_into pointer on the page carries the same fact). No listing / inventory read (that is a seller surface).
--   No write to any TickPick endpoint. No DDL on aq_event_map (hub readers hold it in long transactions).
-- RULE 2: GETs of api.tickpick.com only, through the same vault token n2s_tickpick_sale_state() uses.
-- Rollback: cron.unschedule('tickpick_catalog_hourly'); the tables and functions can be dropped; hub / order /
--   venue fills are audited in tickpick_catalog_audit (old/new values) and reversible from it.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── tables ─────────────────────────
CREATE TABLE IF NOT EXISTS public.tickpick_catalog_event (
  tp_event_id      bigint PRIMARY KEY,
  name             text,
  status           text,
  merged_into      bigint,
  event_local      timestamp,                       -- venue wall clock, as TickPick serves it (placeholder when flags say so)
  event_utc        timestamptz,
  timezone         text,
  date_confirmed   boolean NOT NULL DEFAULT true,
  time_confirmed   boolean NOT NULL DEFAULT true,
  event_date       date GENERATED ALWAYS AS (event_local::date) STORED,
  cat_parent       text,
  cat_child        text,
  cat_grandchild   text,
  tp_venue_id      bigint,
  venue_name       text,
  venue_city       text,
  venue_state      text,
  venue_country    text,
  performers       jsonb NOT NULL DEFAULT '[]'::jsonb,
  raw              jsonb,
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  tevo_event_id    bigint,
  tevo_match_method text,
  tevo_matched_at  timestamptz
);
COMMENT ON TABLE public.tickpick_catalog_event IS
  'TickPick''s event catalogue (GET /1.0/catalog/events), one row per TickPick event id (= TicketNetwork event id today), with our EVO match. tickpick_catalog_pull() fills it, tickpick_catalog_map() matches it. Mig 20261117040000.';
CREATE INDEX IF NOT EXISTS tickpick_catalog_event_venue_day_idx ON public.tickpick_catalog_event (tp_venue_id, event_date);
CREATE INDEX IF NOT EXISTS tickpick_catalog_event_tevo_idx ON public.tickpick_catalog_event (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS tickpick_catalog_event_day_idx ON public.tickpick_catalog_event (event_date);

CREATE TABLE IF NOT EXISTS public.tickpick_catalog_venue (
  tp_venue_id    bigint PRIMARY KEY,
  name           text,
  city           text,
  state          text,
  country        text,
  timezone       text,
  tevo_venue_id  bigint,
  method         text,                               -- manual | aq_venue_map | cross_source | matched_events
  events         integer,                            -- matched events behind a learned id
  first_seen_at  timestamptz NOT NULL DEFAULT now(),
  last_seen_at   timestamptz NOT NULL DEFAULT now(),
  derived_at     timestamptz
);
COMMENT ON TABLE public.tickpick_catalog_venue IS
  'TickPick venues seen in the catalogue (TickPick''s own venue ids) and the TEvo venue each maps to; method says where the pairing came from. A ''manual'' row is never overwritten. Mig 20261117040000.';

CREATE TABLE IF NOT EXISTS public.tickpick_catalog_sync (
  kind          text PRIMARY KEY CHECK (kind IN ('window', 'walk')),
  next_cursor   text,                                -- NULL = the next run starts from the first page
  date_from     date,
  date_to       date,
  pages_total   integer NOT NULL DEFAULT 0,
  events_total  integer NOT NULL DEFAULT 0,
  started_at    timestamptz,
  finished_at   timestamptz,
  last_run_at   timestamptz,
  last_status   integer,
  last_error    text,
  runs          integer NOT NULL DEFAULT 0
);
INSERT INTO public.tickpick_catalog_sync (kind) VALUES ('window'), ('walk') ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS public.tickpick_catalog_audit (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  run_id      uuid NOT NULL,
  tp_event_id bigint,
  action      text NOT NULL,                         -- match | drop | hub_tp | order_tevo | order_disagree | venue_xref | venue_map
  target      text NOT NULL,
  target_key  text,
  old_tevo    bigint,
  new_tevo    bigint,
  note        text
);
CREATE INDEX IF NOT EXISTS tickpick_catalog_audit_run_idx ON public.tickpick_catalog_audit (run_id);
CREATE INDEX IF NOT EXISTS tickpick_catalog_audit_event_idx ON public.tickpick_catalog_audit (tp_event_id);

ALTER TABLE public.tickpick_catalog_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickpick_catalog_venue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickpick_catalog_sync  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tickpick_catalog_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tickpick_catalog_event, public.tickpick_catalog_venue, public.tickpick_catalog_sync, public.tickpick_catalog_audit FROM anon, authenticated;
GRANT SELECT ON public.tickpick_catalog_event, public.tickpick_catalog_venue, public.tickpick_catalog_sync, public.tickpick_catalog_audit TO service_role;

-- ───────────────────────── name fit ─────────────────────────
-- Does a TickPick event name (with its performers) describe this EVO event?
CREATE OR REPLACE FUNCTION public.tickpick_catalog_name_fits(p_tp_name text, p_tp_performers jsonb, p_evo_name text, p_evo_performer text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  WITH n AS (
    SELECT public.event_mapper_norm_name(p_tp_name)  AS a,
           public.event_mapper_norm_name(p_evo_name) AS b,
           public.event_mapper_norm_name(p_evo_performer) AS bp
  ),
  perf AS (
    SELECT count(*) AS n_all,
           count(*) FILTER (WHERE length(x.nm) >= 3 AND position(x.nm IN (SELECT b FROM n)) > 0) AS n_in
      FROM (SELECT public.event_mapper_norm_name(p->>'name') AS nm
              FROM jsonb_array_elements(coalesce(p_tp_performers, '[]'::jsonb)) p
             WHERE coalesce(p->>'name', '') <> '') x
  )
  SELECT CASE
           WHEN n.a = '' OR n.b = '' THEN false
           WHEN (n.a ~ '(parking|tailgate|shuttle)') <> (n.b ~ '(parking|tailgate|shuttle)') THEN false
           WHEN n.a = n.b THEN true
           WHEN length(n.a) >= 4 AND position(n.a IN n.b) > 0 THEN true
           WHEN length(n.b) >= 4 AND position(n.b IN n.a) > 0 THEN true
           WHEN perf.n_all > 0 AND perf.n_in = perf.n_all THEN true
           WHEN length(n.bp) >= 4 AND position(n.bp IN n.a) > 0 THEN true
           ELSE false
         END
    FROM n, perf;
$function$;
COMMENT ON FUNCTION public.tickpick_catalog_name_fits(text, jsonb, text, text) IS
  'TickPick event name + performers vs an EVO event name + primary performer: equal normalised names, containment, every TickPick performer in the EVO name, or the EVO performer in the TickPick name. Parking only fits parking. Mig 20261117040000.';

-- ───────────────────────── the pull ─────────────────────────
-- GETs pages of the catalogue for [p_from, p_to] into the tables, resuming p_kind's stored cursor; stops after
-- p_max_pages or the last page (cursor reset). Returns what happened. RULE 2: GET only.
CREATE OR REPLACE FUNCTION public.tickpick_catalog_pull(p_kind text, p_from date, p_to date, p_max_pages integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  tok      text;
  s        public.tickpick_catalog_sync;
  r        extensions.http_response;
  j        jsonb;
  v_url    text;
  v_cursor text;
  v_pages  int := 0;
  v_events int := 0;
  v_more   boolean := true;
  v_n      int;
BEGIN
  IF p_kind NOT IN ('window', 'walk') THEN
    RAISE EXCEPTION 'tickpick_catalog_pull: kind must be window or walk, got %', p_kind;
  END IF;
  SELECT decrypted_secret INTO tok FROM vault.decrypted_secrets WHERE name = 'TICKPICK_API_TOKEN';
  IF tok IS NULL THEN
    UPDATE public.tickpick_catalog_sync SET last_run_at = now(), last_error = 'no_token', runs = runs + 1 WHERE kind = p_kind;
    RETURN jsonb_build_object('kind', p_kind, 'error', 'no_token');
  END IF;

  SELECT * INTO s FROM public.tickpick_catalog_sync WHERE kind = p_kind FOR UPDATE;
  -- a new window (the dates moved) or a finished walk starts from the first page
  IF s.next_cursor IS NULL OR s.date_from IS DISTINCT FROM p_from OR s.date_to IS DISTINCT FROM p_to THEN
    v_cursor := NULL;
    UPDATE public.tickpick_catalog_sync
       SET next_cursor = NULL, date_from = p_from, date_to = p_to, started_at = now(), finished_at = NULL,
           pages_total = 0, events_total = 0
     WHERE kind = p_kind;
  ELSE
    v_cursor := s.next_cursor;
  END IF;

  PERFORM set_config('http.timeout_msec', '20000', true);
  WHILE v_more AND v_pages < p_max_pages LOOP
    v_url := 'https://api.tickpick.com/1.0/catalog/events?limit=1000'
          || '&dateFrom=' || to_char(p_from, 'YYYY-MM-DD') || '&dateTo=' || to_char(p_to, 'YYYY-MM-DD')
          || CASE WHEN v_cursor IS NULL THEN '' ELSE '&cursor=' || extensions.urlencode(v_cursor) END;
    r := extensions.http(('GET', v_url,
           ARRAY[extensions.http_header('Authorization', 'Bearer ' || tok),
                 extensions.http_header('Accept', 'application/json')], NULL, NULL)::extensions.http_request);
    j := public.safe_jsonb(r.content);
    IF r.status IS DISTINCT FROM 200 OR j IS NULL OR jsonb_typeof(j->'events') <> 'array' THEN
      UPDATE public.tickpick_catalog_sync
         SET last_run_at = now(), last_status = r.status, runs = runs + 1,
             last_error = format('http %s %s', coalesce(r.status::text, 'none'), left(coalesce(r.content, ''), 300)),
             pages_total = pages_total + v_pages, events_total = events_total + v_events
       WHERE kind = p_kind;
      RETURN jsonb_build_object('kind', p_kind, 'pages', v_pages, 'events', v_events, 'http', r.status, 'error', 'bad_page');
    END IF;
    v_pages := v_pages + 1;

    INSERT INTO public.tickpick_catalog_event AS t
      (tp_event_id, name, status, merged_into, event_local, event_utc, timezone, date_confirmed, time_confirmed,
       cat_parent, cat_child, cat_grandchild, tp_venue_id, venue_name, venue_city, venue_state, venue_country, performers, raw, last_seen_at)
    SELECT (e->>'event_id')::bigint, e->>'name', lower(e->>'status'),
           CASE WHEN (e->>'merged_into') ~ '^\d+$' THEN (e->>'merged_into')::bigint END,
           CASE WHEN (e->>'event_date') ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN left(e->>'event_date', 19)::timestamp END,
           CASE WHEN (e->>'event_date_utc') ~ '^\d{4}-\d\d-\d\dT' THEN (e->>'event_date_utc')::timestamptz END,
           e->>'timezone',
           coalesce((e->>'date_confirmed')::boolean, true), coalesce((e->>'time_confirmed')::boolean, true),
           nullif(e->'category'->>'parent', '-'), nullif(e->'category'->>'child', '-'), nullif(e->'category'->>'grandchild', '-'),
           CASE WHEN (e->'venue'->>'venue_id') ~ '^\d+$' THEN (e->'venue'->>'venue_id')::bigint END,
           e->'venue'->>'name', e->'venue'->>'city', e->'venue'->>'state', e->'venue'->>'country',
           CASE WHEN jsonb_typeof(e->'performers') = 'array' THEN e->'performers' ELSE '[]'::jsonb END,
           e, now()
      FROM jsonb_array_elements(j->'events') e
     WHERE (e->>'event_id') ~ '^\d+$'
    ON CONFLICT (tp_event_id) DO UPDATE
      SET name = EXCLUDED.name, status = EXCLUDED.status, merged_into = EXCLUDED.merged_into,
          event_local = EXCLUDED.event_local, event_utc = EXCLUDED.event_utc, timezone = EXCLUDED.timezone,
          date_confirmed = EXCLUDED.date_confirmed, time_confirmed = EXCLUDED.time_confirmed,
          cat_parent = EXCLUDED.cat_parent, cat_child = EXCLUDED.cat_child, cat_grandchild = EXCLUDED.cat_grandchild,
          tp_venue_id = EXCLUDED.tp_venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city,
          venue_state = EXCLUDED.venue_state, venue_country = EXCLUDED.venue_country,
          performers = EXCLUDED.performers, raw = EXCLUDED.raw, last_seen_at = now();
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_events := v_events + v_n;

    INSERT INTO public.tickpick_catalog_venue AS v (tp_venue_id, name, city, state, country, timezone, last_seen_at)
    SELECT DISTINCT ON ((e->'venue'->>'venue_id')::bigint)
           (e->'venue'->>'venue_id')::bigint, e->'venue'->>'name', e->'venue'->>'city', e->'venue'->>'state', e->'venue'->>'country',
           e->>'timezone', now()
      FROM jsonb_array_elements(j->'events') e
     WHERE (e->'venue'->>'venue_id') ~ '^\d+$'
     ORDER BY (e->'venue'->>'venue_id')::bigint, (e->>'timezone') IS NULL
    ON CONFLICT (tp_venue_id) DO UPDATE
      SET name = EXCLUDED.name, city = EXCLUDED.city, state = EXCLUDED.state, country = EXCLUDED.country,
          timezone = coalesce(EXCLUDED.timezone, v.timezone), last_seen_at = now();

    v_more   := coalesce((j->>'has_more')::boolean, false) AND nullif(j->>'next_cursor', '') IS NOT NULL;
    v_cursor := CASE WHEN v_more THEN j->>'next_cursor' END;
  END LOOP;

  UPDATE public.tickpick_catalog_sync
     SET next_cursor = v_cursor, pages_total = pages_total + v_pages, events_total = events_total + v_events,
         finished_at = CASE WHEN v_more THEN NULL ELSE now() END,
         last_run_at = now(), last_status = 200, last_error = NULL, runs = runs + 1
   WHERE kind = p_kind;
  RETURN jsonb_build_object('kind', p_kind, 'pages', v_pages, 'events', v_events, 'done', NOT v_more);
END $function$;
COMMENT ON FUNCTION public.tickpick_catalog_pull(text, date, date, integer) IS
  'GET pages of TickPick''s catalogue (api.tickpick.com/1.0/catalog/events, 1,000 a page) for a date window into tickpick_catalog_event/_venue, resuming the kind''s cursor; stops after max_pages or the last page. Read-only upstream (RULE 2). Mig 20261117040000.';

-- ───────────────────────── the mapper ─────────────────────────
CREATE OR REPLACE FUNCTION public.tickpick_catalog_map(p_apply boolean DEFAULT true)
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
  -- 0. candidates
  DROP TABLE IF EXISTS _tc_cand;
  CREATE TEMP TABLE _tc_cand ON COMMIT DROP AS
  SELECT c.tp_event_id, c.name, c.performers, c.tp_venue_id, c.event_date, c.event_utc, c.time_confirmed,
         c.tevo_event_id AS cur_tevo, c.tevo_match_method AS cur_method
    FROM public.tickpick_catalog_event c
   WHERE c.status IS DISTINCT FROM 'canceled' AND c.merged_into IS NULL AND c.date_confirmed
     AND c.event_date BETWEEN current_date - 1 AND current_date + 400;
  CREATE INDEX ON _tc_cand (tp_event_id);
  v_out := v_out || jsonb_build_object('candidates', (SELECT count(*) FROM _tc_cand));

  -- 1. verify the matched: still that event, on that day?
  DROP TABLE IF EXISTS _tc_drop;
  CREATE TEMP TABLE _tc_drop ON COMMIT DROP AS
  SELECT x.tp_event_id, x.cur_tevo, x.cur_method,
         CASE WHEN e.id IS NULL THEN 'event_gone'
              WHEN e.state = 'ignored' THEN 'event_ignored'
              ELSE 'day_moved' END AS why
    FROM _tc_cand x
    LEFT JOIN public.events e ON e.id = x.cur_tevo
   WHERE x.cur_tevo IS NOT NULL
     AND (e.id IS NULL OR e.state = 'ignored' OR left(e.occurs_at_local, 10) IS DISTINCT FROM to_char(x.event_date, 'YYYY-MM-DD'));
  v_out := v_out || jsonb_build_object('dropped', (SELECT count(*) FROM _tc_drop));
  IF p_apply THEN
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.tp_event_id, 'drop', 'tickpick_catalog_event', d.tp_event_id::text, d.cur_tevo, d.why || ' (' || coalesce(d.cur_method, '?') || ')' FROM _tc_drop d;
    UPDATE public.tickpick_catalog_event c SET tevo_event_id = NULL, tevo_match_method = NULL, tevo_matched_at = NULL
      FROM _tc_drop d WHERE d.tp_event_id = c.tp_event_id;
  END IF;
  UPDATE _tc_cand x SET cur_tevo = NULL, cur_method = NULL FROM _tc_drop d WHERE d.tp_event_id = x.tp_event_id;

  -- every pick of this run lands here
  DROP TABLE IF EXISTS _tc_pick;
  CREATE TEMP TABLE _tc_pick (tp_event_id bigint PRIMARY KEY, tevo_event_id bigint NOT NULL, method text NOT NULL) ON COMMIT DROP;

  -- 2. identity: the hub already knows the TickPick id; our own orders already mapped by the resolver.
  --    Both were put there by name matchers, so an identity is taken only on the same local day AND when the
  --    name still fits (an order mapped to the parking row must not make the concert a parking event).
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT DISTINCT ON (x.tp_event_id) x.tp_event_id, a.tevo_event_id, 'hub_identity'
    FROM _tc_cand x
    JOIN public.aq_event_map a ON a.tp_event_id = x.tp_event_id AND a.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = a.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
   ORDER BY x.tp_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at DESC NULLS LAST
  ON CONFLICT DO NOTHING;
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT x.tp_event_id, o.tevo, 'order_identity'
    FROM _tc_cand x
    JOIN (SELECT (o.raw->'event'->>'event_id')::bigint AS tp, o.tevo_event_id AS tevo, count(*) AS n
            FROM public.tickpick_orders o
           WHERE o.tevo_event_id IS NOT NULL AND (o.raw->'event'->>'event_id') ~ '^\d+$'
           GROUP BY 1, 2) o ON o.tp = x.tp_event_id
    JOIN public.events e ON e.id = o.tevo AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name)
     AND NOT EXISTS (SELECT 1 FROM public.tickpick_orders o2
                      WHERE (o2.raw->'event'->>'event_id') ~ '^\d+$' AND (o2.raw->'event'->>'event_id')::bigint = x.tp_event_id
                        AND o2.tevo_event_id IS NOT NULL AND o2.tevo_event_id <> o.tevo)   -- orders disagree among themselves: no identity
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object('identity', (SELECT count(*) FROM _tc_pick));

  -- 3. venues: TickPick venue id -> TEvo venue
  DROP TABLE IF EXISTS _tc_venue;
  CREATE TEMP TABLE _tc_venue ON COMMIT DROP AS
  WITH known AS (
    SELECT v.tp_venue_id, v.tevo_venue_id, 'manual' AS method, 1 AS pri
      FROM public.tickpick_catalog_venue v WHERE v.method = 'manual' AND v.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT m.tickpick_venue_id, m.tevo_venue_id, 'aq_venue_map', 2
      FROM public.aq_venue_map m WHERE m.tickpick_venue_id IS NOT NULL AND m.tevo_venue_id IS NOT NULL
    UNION ALL
    SELECT c.tickpick_venue_id, min(c.tevo_venue_id), 'cross_source', 3
      FROM public.cross_source_venue_map c
     WHERE c.tickpick_venue_id IS NOT NULL AND c.tevo_venue_id IS NOT NULL
     GROUP BY c.tickpick_venue_id HAVING count(DISTINCT c.tevo_venue_id) = 1
    UNION ALL
    -- learned: the venues this run's identity picks and the standing matches point at (mode per TickPick venue)
    SELECT s.tp_venue_id, s.tv, 'matched_events', 4
      FROM (SELECT x.tp_venue_id, e.venue_id AS tv, count(*) AS n,
                   row_number() OVER (PARTITION BY x.tp_venue_id ORDER BY count(*) DESC, e.venue_id) AS rn
              FROM _tc_cand x
              LEFT JOIN _tc_pick p ON p.tp_event_id = x.tp_event_id
              JOIN public.events e ON e.id = coalesce(p.tevo_event_id, x.cur_tevo)
             WHERE x.tp_venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY x.tp_venue_id, e.venue_id) s
     WHERE s.rn = 1
  )
  SELECT DISTINCT ON (k.tp_venue_id) k.tp_venue_id, k.tevo_venue_id, k.method
    FROM known k ORDER BY k.tp_venue_id, k.pri;
  CREATE INDEX ON _tc_venue (tp_venue_id);
  v_out := v_out || jsonb_build_object('venues_resolved', (SELECT count(*) FROM _tc_venue));

  -- 4. venue + local day (+ name, + time)
  DROP TABLE IF EXISTS _tc_fit;
  CREATE TEMP TABLE _tc_fit ON COMMIT DROP AS
  SELECT x.tp_event_id, e.id AS tevo_event_id, x.time_confirmed,
         (x.time_confirmed AND x.event_utc IS NOT NULL
          AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - x.event_utc)) <= 60) AS same_minute
    FROM _tc_cand x
    JOIN _tc_venue v ON v.tp_venue_id = x.tp_venue_id
    JOIN public.events e ON e.venue_id = v.tevo_venue_id
                        AND left(e.occurs_at_local, 10) = to_char(x.event_date, 'YYYY-MM-DD')
                        AND e.state IS DISTINCT FROM 'ignored'
   WHERE x.cur_tevo IS NULL
     AND NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = x.tp_event_id)
     AND public.tickpick_catalog_name_fits(x.name, x.performers, e.name, e.primary_performer_name);
  -- what every candidate still holds or picks, so nothing is claimed twice
  DROP TABLE IF EXISTS _tc_claimed;
  CREATE TEMP TABLE _tc_claimed ON COMMIT DROP AS
  SELECT x.cur_tevo AS tevo_event_id FROM _tc_cand x WHERE x.cur_tevo IS NOT NULL
  UNION
  SELECT p.tevo_event_id FROM _tc_pick p
  UNION
  SELECT c.tevo_event_id FROM public.tickpick_catalog_event c
   WHERE c.tevo_event_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM _tc_drop d WHERE d.tp_event_id = c.tp_event_id);
  WITH per AS (
    SELECT f.tp_event_id,
           count(*) AS n_fit,
           min(f.tevo_event_id) AS one_fit,
           count(*) FILTER (WHERE f.same_minute) AS n_minute,
           min(f.tevo_event_id) FILTER (WHERE f.same_minute) AS one_minute
      FROM _tc_fit f
     WHERE NOT EXISTS (SELECT 1 FROM _tc_claimed c WHERE c.tevo_event_id = f.tevo_event_id)
     GROUP BY f.tp_event_id
  ),
  pick AS (
    SELECT p.tp_event_id,
           CASE WHEN p.n_fit = 1 THEN p.one_fit WHEN p.n_minute = 1 THEN p.one_minute END AS tevo_event_id,
           CASE WHEN p.n_fit = 1 THEN 'venue_day_name' WHEN p.n_minute = 1 THEN 'venue_time_name' END AS method
      FROM per p
  ),
  uniq AS (                                        -- two catalogue events on one EVO event: neither
    SELECT p.* FROM pick p
     WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.tp_event_id <> p.tp_event_id)
  )
  INSERT INTO _tc_pick (tp_event_id, tevo_event_id, method)
  SELECT u.tp_event_id, u.tevo_event_id, u.method FROM uniq u
  ON CONFLICT DO NOTHING;
  v_out := v_out || jsonb_build_object(
    'picked', (SELECT count(*) FROM _tc_pick),
    'by_method', (SELECT coalesce(jsonb_object_agg(m, n), '{}'::jsonb) FROM (SELECT method m, count(*) n FROM _tc_pick GROUP BY 1) s),
    'ambiguous', (SELECT count(DISTINCT f.tp_event_id) FROM _tc_fit f WHERE NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = f.tp_event_id)),
    'unmatched', (SELECT count(*) FROM _tc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _tc_pick p WHERE p.tp_event_id = x.tp_event_id)),
    'no_venue', (SELECT count(*) FROM _tc_cand x WHERE x.cur_tevo IS NULL AND NOT EXISTS (SELECT 1 FROM _tc_venue v WHERE v.tp_venue_id = x.tp_venue_id)));

  IF p_apply THEN
    UPDATE public.tickpick_catalog_event c
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = p.method, tevo_matched_at = now()
      FROM _tc_pick p WHERE p.tp_event_id = c.tp_event_id;
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.tp_event_id, 'match', 'tickpick_catalog_event', p.tp_event_id::text, p.tevo_event_id, p.method FROM _tc_pick p;

    -- the venue pairings this run resolved, with their provenance, and how many matched events stand behind each
    WITH cnt AS (
      SELECT c.tp_venue_id, count(*) AS n
        FROM public.tickpick_catalog_event c JOIN public.events e ON e.id = c.tevo_event_id
        JOIN _tc_venue v ON v.tp_venue_id = c.tp_venue_id AND v.tevo_venue_id = e.venue_id
       GROUP BY c.tp_venue_id
    ),
    u AS (
      INSERT INTO public.tickpick_catalog_venue AS v (tp_venue_id, tevo_venue_id, method, events, derived_at)
      SELECT t.tp_venue_id, t.tevo_venue_id, t.method, coalesce(cnt.n, 0), now()
        FROM _tc_venue t LEFT JOIN cnt ON cnt.tp_venue_id = t.tp_venue_id
      ON CONFLICT (tp_venue_id) DO UPDATE
        SET tevo_venue_id = EXCLUDED.tevo_venue_id, method = EXCLUDED.method, events = EXCLUDED.events, derived_at = now()
        WHERE v.method IS DISTINCT FROM 'manual'
          AND (v.tevo_venue_id IS DISTINCT FROM EXCLUDED.tevo_venue_id OR v.method IS DISTINCT FROM EXCLUDED.method
               OR v.events IS DISTINCT FROM EXCLUDED.events)
      RETURNING v.tp_venue_id, v.tevo_venue_id, v.method, v.events)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'tickpick_catalog_venue', u.tp_venue_id::text, format('tevo_venue %s via %s (%s events)', u.tevo_venue_id, u.method, u.events) FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_written', v_n);

    -- 5. hub: the TickPick id on the hub rows of matched EVO events (fill-only; one TickPick id per EVO event)
    WITH tp AS (
      SELECT c.tevo_event_id, min(c.tp_event_id) AS tp_event_id
        FROM public.tickpick_catalog_event c
       WHERE c.tevo_event_id IS NOT NULL AND c.event_date >= current_date - 1
       GROUP BY c.tevo_event_id HAVING count(*) = 1
    ),
    u AS (
      UPDATE public.aq_event_map a SET tp_event_id = tp.tp_event_id
        FROM tp
       WHERE a.tevo_event_id = tp.tevo_event_id AND a.tp_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.tp_event_id = tp.tp_event_id AND o.tevo_event_id IS DISTINCT FROM tp.tevo_event_id)
       RETURNING a.aq_short_event_id, a.tevo_event_id, tp.tp_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'hub_tp', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_tp_filled', v_n);

    -- 6. orders: by id, fill-only; disagreements audited, never re-pointed
    WITH u AS (
      UPDATE public.tickpick_orders o
         SET tevo_event_id = c.tevo_event_id, matched_via = 'tp_catalog_id', match_confidence = 1.0, matched_at = now()
        FROM public.tickpick_catalog_event c
       WHERE o.tevo_event_id IS NULL AND (o.raw->'event'->>'event_id') ~ '^\d+$'
         AND c.tp_event_id = (o.raw->'event'->>'event_id')::bigint AND c.tevo_event_id IS NOT NULL
       RETURNING o.tp_order_id, c.tp_event_id, c.tevo_event_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, new_tevo)
    SELECT v_run, u.tp_event_id, 'order_tevo', 'tickpick_orders', u.tp_order_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_filled', v_n);
    INSERT INTO public.tickpick_catalog_audit (run_id, tp_event_id, action, target, target_key, old_tevo, new_tevo, note)
    SELECT v_run, c.tp_event_id, 'order_disagree', 'tickpick_orders', o.tp_order_id, o.tevo_event_id, c.tevo_event_id, coalesce(o.matched_via, '?')
      FROM public.tickpick_orders o
      JOIN public.tickpick_catalog_event c ON (o.raw->'event'->>'event_id') ~ '^\d+$' AND c.tp_event_id = (o.raw->'event'->>'event_id')::bigint
     WHERE o.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NOT NULL AND o.tevo_event_id <> c.tevo_event_id
       AND o.event_date >= now() - interval '1 day'
       AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_audit a
                        WHERE a.action = 'order_disagree' AND a.target_key = o.tp_order_id AND a.new_tevo = c.tevo_event_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('orders_disagree_new', v_n);

    -- 7. the venue xref: aq_venue_map.tickpick_venue_id (UNIQUE), fill-only, once two matched events corroborate the pairing
    WITH u AS (
      UPDATE public.aq_venue_map m SET tickpick_venue_id = v.tp_venue_id
        FROM public.tickpick_catalog_venue v
       WHERE v.tevo_venue_id = m.tevo_venue_id AND m.tickpick_venue_id IS NULL AND v.tevo_venue_id IS NOT NULL
         AND (v.method = 'manual' OR coalesce(v.events, 0) >= 2)
         AND NOT EXISTS (SELECT 1 FROM public.aq_venue_map o WHERE o.tickpick_venue_id = v.tp_venue_id)
         AND NOT EXISTS (SELECT 1 FROM public.tickpick_catalog_venue w WHERE w.tevo_venue_id = v.tevo_venue_id AND w.tp_venue_id <> v.tp_venue_id)
       RETURNING m.venue_short_id, m.tevo_venue_id, v.tp_venue_id)
    INSERT INTO public.tickpick_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_map', 'aq_venue_map', u.venue_short_id, 'tickpick_venue ' || u.tp_venue_id || ' on tevo_venue ' || u.tevo_venue_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venue_map_filled', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;
COMMENT ON FUNCTION public.tickpick_catalog_map(boolean) IS
  'Maps TickPick''s catalogue to EVO events (identity, then venue + local day + name, then same minute), fills aq_event_map.tp_event_id and tickpick_orders.tevo_event_id by id (fill-only) and learns the TickPick venue xref. apply=false dry-runs. Every change in tickpick_catalog_audit. Mig 20261117040000.';

-- ───────────────────────── the hourly step ─────────────────────────
CREATE OR REPLACE FUNCTION public.tickpick_catalog_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_window jsonb;
  v_walk   jsonb := NULL;
  v_map    jsonb;
  w        public.tickpick_catalog_sync;
BEGIN
  -- the next 60 days, every hour (a few pages); a window restarts when it finishes
  v_window := public.tickpick_catalog_pull('window', current_date, current_date + 60, 30);
  -- the two-year walk, a slice an hour; once through, rest a day before starting over
  SELECT * INTO w FROM public.tickpick_catalog_sync WHERE kind = 'walk';
  IF w.next_cursor IS NOT NULL OR w.finished_at IS NULL OR w.finished_at < now() - interval '24 hours' THEN
    v_walk := public.tickpick_catalog_pull('walk', current_date, current_date + 730, 15);
  END IF;
  v_map := public.tickpick_catalog_map(true);
  RETURN jsonb_build_object('window', v_window, 'walk', v_walk, 'map', v_map);
END $function$;
COMMENT ON FUNCTION public.tickpick_catalog_tick() IS
  'Hourly: pull the next 60 days of TickPick''s catalogue, a slice of the two-year walk, then tickpick_catalog_map(true). Cron tickpick_catalog_hourly. Mig 20261117040000.';

REVOKE ALL ON FUNCTION public.tickpick_catalog_name_fits(text, jsonb, text, text),
               public.tickpick_catalog_pull(text, date, date, integer),
               public.tickpick_catalog_map(boolean),
               public.tickpick_catalog_tick()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tickpick_catalog_name_fits(text, jsonb, text, text),
                          public.tickpick_catalog_pull(text, date, date, integer),
                          public.tickpick_catalog_map(boolean),
                          public.tickpick_catalog_tick()
  TO service_role;

-- hourly at :41 (the MLB mapper runs at :35, the SeatGeek day verifier at :26)
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tickpick_catalog_hourly') THEN
    PERFORM cron.unschedule('tickpick_catalog_hourly');
  END IF;
  PERFORM cron.schedule('tickpick_catalog_hourly', '41 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '150s'; SELECT public.tickpick_catalog_tick(); COMMIT;$j$);
END
$cron$;

COMMIT;

-- first pull + map, outside the DDL transaction so a slow page cannot hold the locks
SELECT public.tickpick_catalog_tick();
