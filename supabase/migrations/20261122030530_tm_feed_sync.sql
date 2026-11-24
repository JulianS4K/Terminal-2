-- Migration 20261122030530 · level:data-collection · lane:A1 (data plane — mapping program; routed to this session by the operator) · writes:tm_feed_file(new),tm_feed_event(new),tm_feed_seen(new),tm_discovery_event(+source,+official_seller,+brand_name,+transactable,+hot_event,+legacy_event_id,+legacy_venue_id,+promoter_names,+in_feed,+detail_wanted_at,+detail_reason,+detail_tries,+detail_read_at),tm_discovery_query(active),tm_feed_uri_ok(new),tm_feed_check(new),tm_feed_load(new),tm_feed_loaded(new),tm_feed_apply(new),tm_discovery_tick(),v_tm_discovery_feed · reads:vault.decrypted_secrets('TMR CLIENT ID'),app.ticketmaster.com/discovery-feed/v2 (GET),app.ticketmaster.com/discovery/v2 (GET) · pre:20261122015530
--
-- TICKETMASTER FROM ITS BULK FEED; THE SEARCH API ONLY FOR PRIMARY EVENTS THAT ARE NEW OR CHANGED.
-- Operator 2026-11-22: "Add the new info to the tm API except images and push out. Redesign tm polling using
-- this new data so we don't waste tokens, and only poll tm primary events , us and Canada".
--
-- WHAT WAS LEARNED (2026-11-22, read-only checks with our key):
--   - Discovery has no "changed since" filter and no last-modified field. But the Discovery Feed gives one file
--     per country with every event (GET /discovery-feed/v2/events: US 118,346 events in a 52 MB .csv.gz, CA
--     7,344 in 4 MB), with status, local date and time, venue id, and SOURCE: who really sells the event.
--     SOURCE 'ticketmaster' is Ticketmaster as the primary seller (58,261); 'tmr' is a resale-only page
--     (28,586, ids Z7r9j...), then universe, ticketweb, 'third-party primary', frontgate. Until now we could
--     not tell primary from resale: 43,761 of our 126,716 events are resale pages.
--   - The feed is not everything the search returns: 30,839 of our events are not in it, 21,219 of them resale
--     pages and 8,065 Universe. Of Ticketmaster-primary events about 1,000 are missing (2%).
--   - Feed and search disagree on on-sale / off-sale for 2,324 events, so a status is taken from the feed only
--     when the feed itself changed it, or when it is cancelled, postponed or rescheduled.
--   - The search takes many ids in one call (id=a,b,c: 150 asked, 150 returned).
--   - MIN_PRICE, MAX_PRICE and RESALE_EVENT_URL are columns of the feed but are empty in every row.
--
-- NOW.
--   1. The feed is read once a day by a worker in the web service (core/tm_feed_sync.py): tm_feed_check() asks
--      Ticketmaster for the file list (one call, the key stays in the database) and leases a file that is newer
--      than the last one loaded; the worker downloads it from S3 (no key) and sends the rows in batches to
--      tm_feed_load(); tm_feed_loaded() checks the count. Only new and changed rows are written.
--   2. tm_feed_apply(), called by the hourly tick, brings tm_discovery_event up to date: new events are added
--      (all sources), the feed's own columns are set, and a changed status, date, time or venue is taken over
--      (the trigger of 20261121171530 logs it to tm_discovery_change). So a change shows within a day.
--   3. The search API is called only for events with SOURCE 'ticketmaster', in the US and Canada, that are new
--      or that the feed shows changed: tm_discovery_tick() now reads them 100 at a time by id, for the detail
--      the feed does not carry (ticket limit, SafeTix, presales, doors, add-ons). No resale, Universe, TicketWeb
--      or third-party event is polled. The day-by-day queries are switched off.
--   The two daily ceilings stay (change 250, discovery 1,000). Expected use: about 80 calls for the first
--   load's new primary events, then a few dozen a day, instead of about 390.
--   4. /tm/events gains, after its existing columns: source, tm_primary, official_seller, brand_name,
--      transactable, hot_event, legacy_event_id, legacy_venue_id, promoter_names, in_feed, seatmap_url, outlets
--      and detail_read_at. The collector now keeps the seat map link and the outlets; images are still dropped.
--      An event that came from the feed and was never read through the search has null detail columns.
--
-- GET only (RULE 2): the feed list, the search, and (in Python) the S3 download of the file the list named.
-- The S3 address is checked against one fixed pattern here and again in tm_feed_client.py.
--
-- rollback: re-apply tm_discovery_tick() and v_tm_discovery_feed from 20261122015530 / 20261121171530 (the view
--           after DROP VIEW); UPDATE tm_discovery_query SET active = true WHERE label LIKE 'day:%' AND
--           public.tm_discovery_query_day(params) >= current_date; unset TM_FEED_SYNC_LIVE on the web service.
--           The new tables and columns may stay.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. tables ─────────────────────────
CREATE TABLE IF NOT EXISTS public.tm_feed_file (
  country     text NOT NULL,
  file_at     timestamptz NOT NULL,                 -- the feed's own last_updated for this file
  uri         text NOT NULL,
  md5         text,
  num_events  integer,
  seen_at     timestamptz NOT NULL DEFAULT now(),
  lease_until timestamptz,                          -- a worker is loading it until then
  tries       integer NOT NULL DEFAULT 0,
  rows_sent   integer,
  loaded_at   timestamptz,                          -- every row arrived and the count was checked
  applied_at  timestamptz,                          -- tm_discovery_event was brought up to date from it
  stats       jsonb,
  error       text,
  PRIMARY KEY (country, file_at)
);
COMMENT ON TABLE public.tm_feed_file IS 'Ticketmaster Discovery Feed files seen, loaded and applied, one row per country and file. Mig 20261122030530.';

CREATE TABLE IF NOT EXISTS public.tm_feed_event (
  tm_event_id       text PRIMARY KEY,
  country           text NOT NULL,
  source            text,
  status_code       text,
  local_date        date,
  local_time        time,
  tm_venue_id       text,
  "row"             jsonb NOT NULL,                 -- the feed's row, the columns we keep, short keys (tm_feed_client.py)
  row_hash          text NOT NULL,
  first_file_at     timestamptz NOT NULL,
  changed_file_at   timestamptz NOT NULL,           -- the file that last changed anything in the row
  status_changed_at timestamptz,                    -- the file in which the feed changed that field; null = never
  date_changed_at   timestamptz,
  time_changed_at   timestamptz,
  venue_changed_at  timestamptz,
  applied_file_at   timestamptz,                    -- = changed_file_at once tm_feed_apply() has handled the row
  gone_at           timestamptz                     -- no longer in the feed
);
CREATE INDEX IF NOT EXISTS tm_feed_event_pending_idx ON public.tm_feed_event (tm_event_id)
  WHERE applied_file_at IS DISTINCT FROM changed_file_at;
COMMENT ON TABLE public.tm_feed_event IS 'Our copy of Ticketmaster''s Discovery Feed (US, CA): one row per event, written only when the feed''s row is new or changed. Mig 20261122030530.';

-- the ids in the file being loaded: needed to see which events left the feed. Not worth a WAL record.
CREATE UNLOGGED TABLE IF NOT EXISTS public.tm_feed_seen (
  country     text NOT NULL,
  tm_event_id text NOT NULL,
  PRIMARY KEY (country, tm_event_id)
);

ALTER TABLE public.tm_feed_file  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tm_feed_event ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tm_feed_seen  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tm_feed_file, public.tm_feed_event, public.tm_feed_seen FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.tm_feed_file, public.tm_feed_event TO service_role;

DO $do$
BEGIN
  IF to_regclass('public.tm_discovery_event') IS NULL THEN
    RAISE NOTICE 'tm_discovery_event is not here yet: its feed columns are not added';
    RETURN;
  END IF;
  ALTER TABLE public.tm_discovery_event
    ADD COLUMN IF NOT EXISTS source           text,
    ADD COLUMN IF NOT EXISTS official_seller  boolean,
    ADD COLUMN IF NOT EXISTS brand_name       text,
    ADD COLUMN IF NOT EXISTS transactable     boolean,
    ADD COLUMN IF NOT EXISTS hot_event        boolean,
    ADD COLUMN IF NOT EXISTS legacy_event_id  text,
    ADD COLUMN IF NOT EXISTS legacy_venue_id  text,
    ADD COLUMN IF NOT EXISTS promoter_names   text[],
    ADD COLUMN IF NOT EXISTS in_feed          boolean,
    ADD COLUMN IF NOT EXISTS detail_wanted_at timestamptz,
    ADD COLUMN IF NOT EXISTS detail_reason    text,
    ADD COLUMN IF NOT EXISTS detail_tries     integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS detail_read_at   timestamptz;
  CREATE INDEX IF NOT EXISTS tm_discovery_event_detail_idx ON public.tm_discovery_event (detail_reason, local_date, tm_event_id)
    WHERE detail_wanted_at IS NOT NULL;
END
$do$;

-- ───────────────────────── 2. the feed: check, load, count ─────────────────────────
-- the only address a feed file may be downloaded from (tm_feed_client.py checks the same pattern)
CREATE OR REPLACE FUNCTION public.tm_feed_uri_ok(p_uri text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(p_uri ~ '^https://s3\.amazonaws\.com/[A-Za-z0-9.-]+\.tmaws-feeds/[0-9]{8}/EVENTS_RAW-(US|CA)-[0-9a-f-]{36}-[0-9_-]+\.csv\.gz$', false)
$function$;

-- ask Ticketmaster which feed files exist (one GET, counted against the discovery budget) and lease, per
-- country, the newest file if it has not been loaded. The key never leaves the database.
CREATE OR REPLACE FUNCTION public.tm_feed_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_key   text;
  v_resp  extensions.http_response;
  j       jsonb;
  c       text;
  f       jsonb;
  v_files jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('tm_feed_check')) THEN
    RETURN jsonb_build_object('files', '[]'::jsonb, 'skipped', 'another check is running');
  END IF;
  IF EXISTS (SELECT 1 FROM public.tm_feed_file WHERE loaded_at IS NULL AND lease_until > now()) THEN
    RETURN jsonb_build_object('files', '[]'::jsonb, 'skipped', 'a file is being loaded');
  END IF;
  SELECT trim(decrypted_secret) INTO v_key FROM vault.decrypted_secrets WHERE name = 'TMR CLIENT ID' LIMIT 1;
  IF v_key IS NULL OR length(v_key) < 16 THEN
    RETURN jsonb_build_object('files', '[]'::jsonb, 'skipped', 'no usable key');
  END IF;
  IF NOT public.tm_discovery_call_allowed('discovery') THEN
    RETURN jsonb_build_object('files', '[]'::jsonb, 'skipped', 'daily Discovery budget reached');
  END IF;
  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '6000');
  v_resp := extensions.http(('GET', 'https://app.ticketmaster.com/discovery-feed/v2/events?apikey=' || extensions.urlencode(v_key),
                             ARRAY[]::extensions.http_header[], NULL, NULL)::extensions.http_request);
  j := public.safe_jsonb(v_resp.content);
  INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
  VALUES (gen_random_uuid(), 'call', 'tm_feed_file', 'discovery-feed', format('http %s', v_resp.status));
  IF v_resp.status <> 200 OR j->'countries' IS NULL THEN
    RETURN jsonb_build_object('files', '[]'::jsonb, 'skipped', format('feed list answered http %s', v_resp.status));
  END IF;
  FOREACH c IN ARRAY ARRAY['US', 'CA'] LOOP
    f := j->'countries'->c->'CSV';
    IF public.tm_feed_uri_ok(f->>'uri') AND f->>'last_updated' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN
      INSERT INTO public.tm_feed_file (country, file_at, uri, md5, num_events)
      VALUES (c, (f->>'last_updated')::timestamptz, f->>'uri', f->>'compressed_md5_checksum',
              CASE WHEN f->>'num_events' ~ '^[0-9]+$' THEN (f->>'num_events')::int END)
      ON CONFLICT (country, file_at) DO NOTHING;
    END IF;
  END LOOP;
  -- per country: the newest file, if it is not loaded yet and has not failed three times
  WITH newest AS (
    SELECT DISTINCT ON (t.country) t.country, t.file_at FROM public.tm_feed_file t ORDER BY t.country, t.file_at DESC),
  leased AS (
    UPDATE public.tm_feed_file t SET lease_until = now() + interval '30 minutes', tries = t.tries + 1, error = NULL
      FROM newest n
     WHERE t.country = n.country AND t.file_at = n.file_at AND t.loaded_at IS NULL AND t.tries < 3
    RETURNING t.country, t.file_at, t.uri, t.md5, t.num_events)
  SELECT coalesce(jsonb_agg(jsonb_build_object('country', l.country, 'file_at', to_char(l.file_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                               'uri', l.uri, 'md5', l.md5, 'num_events', l.num_events) ORDER BY l.country), '[]'::jsonb)
    INTO v_files FROM leased l;
  -- a fresh load starts from an empty list of seen ids
  DELETE FROM public.tm_feed_seen s WHERE s.country IN (SELECT x->>'country' FROM jsonb_array_elements(v_files) x);
  RETURN jsonb_build_object('files', v_files);
END $function$;

-- one batch of rows from the file a worker holds the lease on. A row is written only when it is new or differs
-- from our copy; which of status, date, time and venue the feed changed is remembered for tm_feed_apply().
CREATE OR REPLACE FUNCTION public.tm_feed_load(p_country text, p_file_at timestamp with time zone, p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  UPDATE public.tm_feed_file t SET lease_until = now() + interval '30 minutes'
   WHERE t.country = p_country AND t.file_at = p_file_at AND t.loaded_at IS NULL AND t.lease_until > now();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'tm_feed_load: no live lease on the % file of %', p_country, p_file_at;
  END IF;
  WITH r AS (
    SELECT x AS j, x->>'id' AS id,
           CASE WHEN x->>'ld' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN (x->>'ld')::date END AS ld,
           CASE WHEN x->>'lt' ~ '^[0-9]{2}:[0-9]{2}' THEN (x->>'lt')::time END AS lt
      FROM jsonb_array_elements(p_rows) x WHERE coalesce(x->>'id', '') <> ''),
  seen AS (
    INSERT INTO public.tm_feed_seen (country, tm_event_id) SELECT p_country, r.id FROM r ON CONFLICT DO NOTHING)
  INSERT INTO public.tm_feed_event AS t (tm_event_id, country, source, status_code, local_date, local_time, tm_venue_id,
                                         "row", row_hash, first_file_at, changed_file_at)
  SELECT DISTINCT ON (r.id) r.id, p_country, r.j->>'src', r.j->>'st', r.ld, r.lt, nullif(r.j->>'vid', ''), r.j, md5(r.j::text), p_file_at, p_file_at
    FROM r ORDER BY r.id
  ON CONFLICT (tm_event_id) DO UPDATE SET
    country = EXCLUDED.country, source = EXCLUDED.source, "row" = EXCLUDED."row", row_hash = EXCLUDED.row_hash,
    changed_file_at = p_file_at, gone_at = NULL,
    status_changed_at = CASE WHEN t.status_code IS DISTINCT FROM EXCLUDED.status_code THEN p_file_at ELSE t.status_changed_at END,
    date_changed_at   = CASE WHEN t.local_date  IS DISTINCT FROM EXCLUDED.local_date  THEN p_file_at ELSE t.date_changed_at END,
    time_changed_at   = CASE WHEN t.local_time  IS DISTINCT FROM EXCLUDED.local_time  THEN p_file_at ELSE t.time_changed_at END,
    venue_changed_at  = CASE WHEN t.tm_venue_id IS DISTINCT FROM EXCLUDED.tm_venue_id THEN p_file_at ELSE t.venue_changed_at END,
    status_code = EXCLUDED.status_code, local_date = EXCLUDED.local_date, local_time = EXCLUDED.local_time, tm_venue_id = EXCLUDED.tm_venue_id
  WHERE t.row_hash IS DISTINCT FROM EXCLUDED.row_hash OR t.gone_at IS NOT NULL;
  SELECT jsonb_array_length(p_rows) INTO v_n;
  RETURN v_n;
END $function$;

-- the worker sent every row: check the count, then the file waits for tm_feed_apply()
CREATE OR REPLACE FUNCTION public.tm_feed_loaded(p_country text, p_file_at timestamp with time zone, p_rows_sent integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_seen integer;
  v_want integer;
BEGIN
  SELECT count(*) INTO v_seen FROM public.tm_feed_seen WHERE country = p_country;
  SELECT num_events INTO v_want FROM public.tm_feed_file
   WHERE country = p_country AND file_at = p_file_at AND loaded_at IS NULL AND lease_until > now() FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no live lease on that file');
  END IF;
  -- every row of the file must be here: a short file would mark thousands of events as gone
  IF v_seen <> p_rows_sent OR v_seen < 0.98 * coalesce(v_want, v_seen) OR v_seen = 0 THEN
    UPDATE public.tm_feed_file SET lease_until = NULL, error = format('count: %s seen, %s sent, %s in the list', v_seen, p_rows_sent, v_want)
     WHERE country = p_country AND file_at = p_file_at;
    RETURN jsonb_build_object('ok', false, 'error', 'row count does not match', 'seen', v_seen, 'sent', p_rows_sent, 'listed', v_want);
  END IF;
  UPDATE public.tm_feed_file SET loaded_at = now(), lease_until = NULL, rows_sent = p_rows_sent WHERE country = p_country AND file_at = p_file_at;
  RETURN jsonb_build_object('ok', true, 'seen', v_seen);
END $function$;

-- ───────────────────────── 3. bring tm_discovery_event up to date from the feed ─────────────────────────
-- Called by the hourly tick (as postgres: an 8-second API call could not do the first load). Handles up to
-- p_limit rows that are new or changed in the feed, then, when none is left, marks what left the feed.
CREATE OR REPLACE FUNCTION public.tm_feed_apply(p_limit integer DEFAULT 60000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_new   integer := 0;
  v_upd   integer := 0;
  v_done  integer := 0;
  v_left  integer;
  v_gone  integer := 0;
  r       record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.tm_feed_file WHERE loaded_at IS NOT NULL AND applied_at IS NULL) THEN
    RETURN jsonb_build_object('pending_files', 0);
  END IF;
  WITH p AS MATERIALIZED (
    SELECT f.*, f."row" AS j FROM public.tm_feed_event f
     WHERE f.applied_file_at IS DISTINCT FROM f.changed_file_at
       -- only files whose load is complete
       AND EXISTS (SELECT 1 FROM public.tm_feed_file t WHERE t.country = f.country AND t.loaded_at IS NOT NULL AND t.applied_at IS NULL)
       AND NOT EXISTS (SELECT 1 FROM public.tm_feed_file t WHERE t.country = f.country AND t.loaded_at IS NULL AND t.lease_until > now())
     ORDER BY f.tm_event_id LIMIT greatest(coalesce(p_limit, 60000), 1) FOR UPDATE),
  ins AS (
    -- an event we do not hold yet, whatever its source. Only a Ticketmaster-primary one is read through the search.
    INSERT INTO public.tm_discovery_event AS t (
      tm_event_id, name, url, local_date, local_time, start_utc, time_tba, status_code,
      tm_venue_id, venue_name, venue_city, venue_state, venue_country, venue_timezone,
      attractions, attraction_names, segment, genre, sub_genre, public_onsale, is_product, last_seen_at,
      source, official_seller, brand_name, transactable, hot_event, legacy_event_id, legacy_venue_id, promoter_names, in_feed,
      detail_wanted_at, detail_reason)
    SELECT p.tm_event_id, p.j->>'name', p.j->>'url', p.local_date, p.local_time,
           CASE WHEN p.j->>'start' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (p.j->>'start')::timestamptz END,
           p.local_time IS NULL, p.status_code,
           p.tm_venue_id, p.j->>'vname', p.j->>'vcity', p.j->>'vstate', p.j->>'vcc', p.j->>'vtz',
           (SELECT jsonb_agg(jsonb_build_object('id', nullif(a.id, ''), 'name', a.name) ORDER BY a.ord)
              FROM unnest(string_to_array(p.j->>'aname', '|'), string_to_array(p.j->>'aid', '|')) WITH ORDINALITY a(name, id, ord)
             WHERE coalesce(a.name, '') <> ''),
           (SELECT array_agg(a.name ORDER BY a.ord) FROM unnest(string_to_array(p.j->>'aname', '|')) WITH ORDINALITY a(name, ord) WHERE a.name <> ''),
           nullif(p.j->>'seg', ''), nullif(p.j->>'gen', ''), nullif(p.j->>'sub', ''),
           CASE WHEN p.j->>'on' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (p.j->>'on')::timestamptz END,
           (coalesce(p.j->>'name', '') ~* '(parking|tailgate|package|shuttle|hospitality|\mvip\M|suites?\M|fan fest|meet (and|&) greet)'
            OR coalesce(p.j->>'gen', '') ~* 'parking' OR coalesce(p.j->>'seg', '') ~* 'undefined'),
           now(),
           p.source, (p.j->>'off')::boolean, nullif(p.j->>'brand', ''), (p.j->>'tx')::boolean, (p.j->>'hot')::boolean,
           nullif(p.j->>'lid', ''), nullif(p.j->>'lvid', ''),
           (SELECT array_agg(DISTINCT x) FROM unnest(string_to_array(p.j->>'prom', '|')) x WHERE x <> ''), true,
           CASE WHEN p.source = 'ticketmaster' THEN now() END, CASE WHEN p.source = 'ticketmaster' THEN 'new' END
      FROM p
     WHERE NOT EXISTS (SELECT 1 FROM public.tm_discovery_event d WHERE d.tm_event_id = p.tm_event_id)
    ON CONFLICT (tm_event_id) DO NOTHING
    RETURNING 1),
  upd AS (
    UPDATE public.tm_discovery_event d SET
      source = p.source, official_seller = (p.j->>'off')::boolean, brand_name = nullif(p.j->>'brand', ''),
      transactable = (p.j->>'tx')::boolean, hot_event = (p.j->>'hot')::boolean,
      legacy_event_id = nullif(p.j->>'lid', ''), legacy_venue_id = nullif(p.j->>'lvid', ''),
      promoter_names = (SELECT array_agg(DISTINCT x) FROM unnest(string_to_array(p.j->>'prom', '|')) x WHERE x <> ''),
      in_feed = true,
      -- a status: when the feed itself changed it since we last applied, or when it is one nobody disputes.
      -- Feed and search disagree on on-sale / off-sale for about 2% of events; the feed's first word is not taken.
      status_code = CASE WHEN p.status_code IN ('cancelled', 'postponed', 'rescheduled')
                           OR (p.applied_file_at IS NOT NULL AND p.status_changed_at > p.applied_file_at)
                         THEN coalesce(p.status_code, d.status_code) ELSE d.status_code END,
      local_date = coalesce(p.local_date, d.local_date),
      -- a time: when the feed changed it, or when we hold a firm time and the feed's differs. A time the search
      -- flags "to be announced" is not replaced by the feed's placeholder.
      local_time = CASE WHEN p.local_time IS NOT NULL
                         AND ((p.applied_file_at IS NOT NULL AND p.time_changed_at > p.applied_file_at)
                              OR (d.local_time IS NOT NULL AND NOT coalesce(d.time_tba, false)))
                        THEN p.local_time ELSE d.local_time END,
      tm_venue_id = coalesce(p.tm_venue_id, d.tm_venue_id),
      venue_name  = CASE WHEN p.tm_venue_id IS DISTINCT FROM d.tm_venue_id THEN coalesce(nullif(p.j->>'vname', ''), d.venue_name) ELSE d.venue_name END,
      venue_city  = CASE WHEN p.tm_venue_id IS DISTINCT FROM d.tm_venue_id THEN coalesce(nullif(p.j->>'vcity', ''), d.venue_city) ELSE d.venue_city END,
      venue_state = CASE WHEN p.tm_venue_id IS DISTINCT FROM d.tm_venue_id THEN coalesce(nullif(p.j->>'vstate', ''), d.venue_state) ELSE d.venue_state END,
      -- a new date undoes the match, as the search's own upsert does
      tevo_event_id     = CASE WHEN p.local_date IS DISTINCT FROM d.local_date AND p.local_date IS NOT NULL THEN NULL ELSE d.tevo_event_id END,
      tevo_match_method = CASE WHEN p.local_date IS DISTINCT FROM d.local_date AND p.local_date IS NOT NULL THEN NULL ELSE d.tevo_match_method END,
      tevo_matched_at   = CASE WHEN p.local_date IS DISTINCT FROM d.local_date AND p.local_date IS NOT NULL THEN NULL ELSE d.tevo_matched_at END,
      -- the search is asked again only for a Ticketmaster-primary event the feed shows changed
      detail_wanted_at = CASE WHEN p.source = 'ticketmaster' AND p.applied_file_at IS NOT NULL
                               AND greatest(p.status_changed_at, p.date_changed_at, p.time_changed_at, p.venue_changed_at) > p.applied_file_at
                              THEN now() ELSE d.detail_wanted_at END,
      detail_reason    = CASE WHEN p.source = 'ticketmaster' AND p.applied_file_at IS NOT NULL
                               AND greatest(p.status_changed_at, p.date_changed_at, p.time_changed_at, p.venue_changed_at) > p.applied_file_at
                              THEN 'change' ELSE d.detail_reason END,
      detail_tries     = CASE WHEN p.source = 'ticketmaster' AND p.applied_file_at IS NOT NULL
                               AND greatest(p.status_changed_at, p.date_changed_at, p.time_changed_at, p.venue_changed_at) > p.applied_file_at
                              THEN 0 ELSE d.detail_tries END
      FROM p WHERE d.tm_event_id = p.tm_event_id
    RETURNING 1),
  done AS (
    UPDATE public.tm_feed_event f SET applied_file_at = f.changed_file_at FROM p WHERE f.tm_event_id = p.tm_event_id RETURNING 1)
  SELECT (SELECT count(*) FROM ins), (SELECT count(*) FROM upd), (SELECT count(*) FROM done) INTO v_new, v_upd, v_done;

  SELECT count(*) INTO v_left FROM public.tm_feed_event f
   WHERE f.applied_file_at IS DISTINCT FROM f.changed_file_at
     AND EXISTS (SELECT 1 FROM public.tm_feed_file t WHERE t.country = f.country AND t.loaded_at IS NOT NULL AND t.applied_at IS NULL);
  IF v_left = 0 THEN
    -- every row is handled: what the newest loaded file of a country no longer lists has left the feed
    FOR r IN SELECT DISTINCT t.country FROM public.tm_feed_file t WHERE t.loaded_at IS NOT NULL AND t.applied_at IS NULL
                AND NOT EXISTS (SELECT 1 FROM public.tm_feed_file l WHERE l.country = t.country AND l.loaded_at IS NULL AND l.lease_until > now()) LOOP
      IF EXISTS (SELECT 1 FROM public.tm_feed_seen s WHERE s.country = r.country) THEN
        WITH g AS (
          UPDATE public.tm_feed_event f SET gone_at = now()
           WHERE f.country = r.country AND f.gone_at IS NULL
             AND NOT EXISTS (SELECT 1 FROM public.tm_feed_seen s WHERE s.country = f.country AND s.tm_event_id = f.tm_event_id)
          RETURNING f.tm_event_id),
        d AS (UPDATE public.tm_discovery_event e SET in_feed = false FROM g WHERE e.tm_event_id = g.tm_event_id AND e.in_feed RETURNING 1)
        SELECT v_gone + (SELECT count(*) FROM g) INTO v_gone;
        DELETE FROM public.tm_feed_seen s WHERE s.country = r.country;
      END IF;
      UPDATE public.tm_feed_file t SET applied_at = now(),
             stats = jsonb_build_object('new', v_new, 'updated', v_upd, 'gone', v_gone)
       WHERE t.country = r.country AND t.loaded_at IS NOT NULL AND t.applied_at IS NULL;
    END LOOP;
  END IF;
  RETURN jsonb_build_object('new', v_new, 'updated', v_upd, 'handled', v_done, 'left', v_left, 'gone', v_gone);
END $function$;

-- ───────────────────────── 4. the tick: apply the feed, then read primary events by id ─────────────────────────
-- the day-by-day queries are not read any more: the feed finds new and changed events
UPDATE public.tm_discovery_query SET active = false WHERE active AND (label LIKE 'day:%' OR label LIKE 'seg:%');

CREATE OR REPLACE FUNCTION public.tm_discovery_tick(p_calls integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run    uuid := gen_random_uuid();
  v_key    text;
  v_ids    text[];
  v_tried  text[] := '{}';                         -- ids asked for in this run: not asked twice in one run
  v_url    text;
  v_resp   extensions.http_response;
  j        jsonb;
  v_rows   int;
  v_calls  int := 0;
  v_landed int := 0;
  v_events int := 0;
  v_refused int := 0;
  v_errors int := 0;
  v_match  int := 0;
  i        int;
  v_kind   text;                                   -- which budget pays for this call: 'change' or 'discovery'
  v_started timestamptz := clock_timestamp();
  v_change_left boolean;
  v_disc_left   boolean;
  v_change int := 0;
  v_feed   jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('tm_discovery_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another tm_discovery_tick is running');
  END IF;

  -- THE FEED FIRST. A loaded feed file is applied here; a run that had rows to apply makes no search call, so
  -- the first load (about 125,000 rows) has the whole run to itself.
  v_feed := public.tm_feed_apply(60000);
  IF coalesce((v_feed->>'handled')::int, 0) > 0 THEN
    v_match := public.tm_discovery_match(5000);
    RETURN jsonb_build_object('run_id', v_run, 'feed', v_feed, 'calls', 0, 'matched', v_match);
  END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'TMR CLIENT ID' LIMIT 1;
  IF v_key IS NULL OR length(trim(v_key)) < 16 THEN
    INSERT INTO public.tm_discovery_audit (run_id, action, note) VALUES (v_run, 'refused', 'no usable key in the vault (TMR CLIENT ID)');
    RETURN jsonb_build_object('run_id', v_run, 'error', 'no usable key');
  END IF;
  v_key := trim(v_key);

  INSERT INTO public.tm_discovery_quota (day) VALUES (current_date) ON CONFLICT (day) DO NOTHING;
  SELECT t.change_calls < least(t.change_cap, 250), t.calls < least(t.cap, 1000)
    INTO v_change_left, v_disc_left FROM public.tm_discovery_quota t WHERE t.day = current_date;

  FOR i IN 1..greatest(coalesce(p_calls, 0), 0) LOOP
    EXIT WHEN clock_timestamp() - v_started > interval '200 seconds';
    v_kind := NULL; v_ids := NULL;

    -- ONLY TICKETMASTER-PRIMARY EVENTS, US AND CANADA (operator 2026-11-22), and only the ones the feed flagged:
    -- first those it shows changed (the change budget), then those new to us (the discovery budget). Up to 100
    -- ids a call; soonest event first.
    IF v_change_left THEN
      SELECT array_agg(z.tm_event_id) INTO v_ids FROM (
        SELECT e.tm_event_id FROM public.tm_discovery_event e
         WHERE e.detail_wanted_at IS NOT NULL AND e.detail_reason = 'change' AND e.source = 'ticketmaster'
           AND e.venue_country IN ('US', 'CA') AND e.tm_event_id <> ALL (v_tried)
         ORDER BY e.local_date, e.tm_event_id LIMIT 100 FOR UPDATE SKIP LOCKED) z;
      IF v_ids IS NOT NULL THEN v_kind := 'change'; END IF;
    END IF;
    IF v_kind IS NULL AND v_disc_left THEN
      SELECT array_agg(z.tm_event_id) INTO v_ids FROM (
        SELECT e.tm_event_id FROM public.tm_discovery_event e
         WHERE e.detail_wanted_at IS NOT NULL AND e.detail_reason = 'new' AND e.source = 'ticketmaster'
           AND e.venue_country IN ('US', 'CA') AND e.tm_event_id <> ALL (v_tried)
         ORDER BY e.local_date, e.tm_event_id LIMIT 100 FOR UPDATE SKIP LOCKED) z;
      IF v_ids IS NOT NULL THEN v_kind := 'discovery'; END IF;
    END IF;
    EXIT WHEN v_kind IS NULL;

    IF NOT public.tm_discovery_call_allowed(v_kind) THEN
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
      VALUES (v_run, 'refused', 'tm_discovery_event', v_ids[1], 'daily Discovery ' || v_kind || ' budget reached');
      v_refused := v_refused + 1;
      IF v_kind = 'change' THEN v_change_left := false; ELSE v_disc_left := false; END IF;
      CONTINUE;
    END IF;
    IF v_kind = 'change' THEN v_change := v_change + 1; END IF;
    v_calls := v_calls + 1;
    v_tried := v_tried || v_ids;
    -- whatever happens to this call, these ids have been tried once more; three tries and an id is left alone
    UPDATE public.tm_discovery_event e
       SET detail_tries = e.detail_tries + 1,
           detail_wanted_at = CASE WHEN e.detail_tries + 1 >= 3 THEN NULL ELSE e.detail_wanted_at END
     WHERE e.tm_event_id = ANY (v_ids);

    v_url := 'https://app.ticketmaster.com/discovery/v2/events.json?size=200&includeTBA=yes&includeTBD=yes&id=' ||
             extensions.urlencode(array_to_string(v_ids, ',')) || '&apikey=' || extensions.urlencode(v_key);
    PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');
    BEGIN
      v_resp := extensions.http(('GET', v_url, ARRAY[]::extensions.http_header[], NULL, NULL)::extensions.http_request);
    EXCEPTION WHEN OTHERS THEN
      v_resp := NULL;
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
      VALUES (v_run, 'call', 'tm_discovery_event', v_ids[1], format('%s ids: http error %s', cardinality(v_ids), left(SQLERRM, 200)));
      v_errors := v_errors + 1;
      CONTINUE;
    END;
    j := public.safe_jsonb(v_resp.content);
    IF v_resp.status <> 200 OR j IS NULL OR j->'page' IS NULL THEN
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
      VALUES (v_run, 'call', 'tm_discovery_event', v_ids[1], format('%s ids: http %s', cardinality(v_ids), v_resp.status));
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    WITH ev AS (
      SELECT e FROM jsonb_array_elements(coalesce(j->'_embedded'->'events', '[]'::jsonb)) e WHERE coalesce(e->>'id', '') <> ''),
    x AS (
      SELECT ev.e, ev.e->'_embedded'->'venues'->0 AS v, ev.e->'classifications'->0 AS c,
             (SELECT jsonb_agg(jsonb_build_object('id', a->>'id', 'name', a->>'name')) FROM jsonb_array_elements(coalesce(ev.e->'_embedded'->'attractions', '[]'::jsonb)) a) AS attrs,
             (SELECT array_agg(a->>'name') FROM jsonb_array_elements(coalesce(ev.e->'_embedded'->'attractions', '[]'::jsonb)) a WHERE coalesce(a->>'name', '') <> '') AS attr_names
        FROM ev)
    INSERT INTO public.tm_discovery_event AS t (
      tm_event_id, name, url, local_date, local_time, start_utc, date_tbd, time_tba, status_code,
      tm_venue_id, venue_name, venue_city, venue_state, venue_country, venue_timezone,
      attractions, attraction_names, segment, genre, sub_genre, public_onsale, presales, ticket_limit, products, is_product, raw, last_seen_at)
    SELECT x.e->>'id', x.e->>'name', x.e->>'url',
           CASE WHEN x.e->'dates'->'start'->>'localDate' ~ '^\d{4}-\d\d-\d\d$' THEN (x.e->'dates'->'start'->>'localDate')::date END,
           CASE WHEN x.e->'dates'->'start'->>'localTime' ~ '^\d\d:\d\d' THEN (x.e->'dates'->'start'->>'localTime')::time END,
           CASE WHEN x.e->'dates'->'start'->>'dateTime' ~ '^\d{4}-\d\d-\d\dT' THEN (x.e->'dates'->'start'->>'dateTime')::timestamptz END,
           CASE WHEN jsonb_typeof(x.e->'dates'->'start'->'dateTBD') = 'boolean' THEN (x.e->'dates'->'start'->>'dateTBD')::boolean END,
           CASE WHEN jsonb_typeof(x.e->'dates'->'start'->'timeTBA') = 'boolean' THEN (x.e->'dates'->'start'->>'timeTBA')::boolean END,
           x.e->'dates'->'status'->>'code',
           x.v->>'id', x.v->>'name', x.v->'city'->>'name', x.v->'state'->>'stateCode', x.v->'country'->>'countryCode', x.v->>'timezone',
           x.attrs, x.attr_names, x.c->'segment'->>'name', x.c->'genre'->>'name', x.c->'subGenre'->>'name',
           CASE WHEN x.e->'sales'->'public'->>'startDateTime' ~ '^\d{4}-\d\d-\d\dT' THEN (x.e->'sales'->'public'->>'startDateTime')::timestamptz END,
           x.e->'sales'->'presales', x.e->'ticketLimit'->>'info',
           CASE WHEN jsonb_typeof(x.e->'products') = 'array' THEN jsonb_array_length(x.e->'products') END,
           (coalesce(x.e->>'name', '') ~* '(parking|tailgate|package|shuttle|hospitality|\mvip\M|suites?\M|fan fest|meet (and|&) greet)'
            OR coalesce(x.c->'genre'->>'name', '') ~* 'parking' OR coalesce(x.c->'segment'->>'name', '') ~* 'undefined'),
           x.e - '_links' - 'images' - 'promoters' - 'promoter' - 'ageRestrictions' - 'accessibility',   -- seatmap and outlets are kept since 20261122030530
           now()
      FROM x
    ON CONFLICT (tm_event_id) DO UPDATE SET
      name = EXCLUDED.name, url = EXCLUDED.url, local_date = EXCLUDED.local_date, local_time = EXCLUDED.local_time, start_utc = EXCLUDED.start_utc,
      date_tbd = EXCLUDED.date_tbd, time_tba = EXCLUDED.time_tba, status_code = EXCLUDED.status_code,
      tm_venue_id = EXCLUDED.tm_venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city, venue_state = EXCLUDED.venue_state,
      venue_country = EXCLUDED.venue_country, venue_timezone = EXCLUDED.venue_timezone,
      attractions = EXCLUDED.attractions, attraction_names = EXCLUDED.attraction_names, segment = EXCLUDED.segment, genre = EXCLUDED.genre, sub_genre = EXCLUDED.sub_genre,
      public_onsale = EXCLUDED.public_onsale, presales = EXCLUDED.presales, ticket_limit = EXCLUDED.ticket_limit, products = EXCLUDED.products, is_product = EXCLUDED.is_product,
      raw = EXCLUDED.raw, last_seen_at = now(), detail_read_at = now(), detail_wanted_at = NULL, detail_tries = 0,
      tevo_event_id     = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_event_id END,
      tevo_match_method = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_match_method END,
      tevo_matched_at   = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_matched_at END;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
    VALUES (v_run, 'call', 'tm_discovery_event', v_ids[1], format('%s ids asked (%s), %s events', cardinality(v_ids), v_kind, v_rows));
    v_landed := v_landed + 1; v_events := v_events + v_rows;
  END LOOP;

  IF v_landed > 0 THEN v_match := public.tm_discovery_match(5000); END IF;
  RETURN jsonb_build_object('run_id', v_run, 'feed', v_feed, 'calls', v_calls, 'change_calls', v_change, 'landed', v_landed, 'events', v_events,
                            'errors', v_errors, 'refused', v_refused, 'matched', v_match,
                            'budget_today', (SELECT jsonb_build_object('discovery_calls', calls, 'discovery_cap', least(cap, 1000),
                                                                       'change_calls', change_calls, 'change_cap', least(change_cap, 250), 'refused', refused)
                                               FROM public.tm_discovery_quota WHERE day = current_date));
END $function$;

REVOKE ALL ON FUNCTION public.tm_feed_uri_ok(text), public.tm_feed_check(), public.tm_feed_load(text, timestamp with time zone, jsonb),
  public.tm_feed_loaded(text, timestamp with time zone, integer), public.tm_feed_apply(integer), public.tm_discovery_tick(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tm_feed_uri_ok(text), public.tm_feed_check(), public.tm_feed_load(text, timestamp with time zone, jsonb),
  public.tm_feed_loaded(text, timestamp with time zone, integer), public.tm_feed_apply(integer), public.tm_discovery_tick(integer)
  TO service_role;

-- ───────────────────────── 5. the feed view: what the bulk feed adds, after the existing columns ─────────────────────────
DO $do$
DECLARE
  v_unaccent text := coalesce((SELECT quote_ident(n.nspname) || '.unaccent'
                                 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                WHERE p.proname = 'unaccent' AND p.pronargs = 1
                                  AND p.proargtypes[0] = 'text'::regtype
                                ORDER BY n.nspname LIMIT 1), '');
BEGIN
  IF to_regclass('public.tm_discovery_event') IS NULL OR to_regclass('public.v_tm_discovery_feed') IS NULL THEN
    RAISE NOTICE 'tm_discovery_event / v_tm_discovery_feed are not here yet: the feed view is not changed';
    RETURN;
  END IF;
  EXECUTE replace($v$
    CREATE OR REPLACE VIEW public.v_tm_discovery_feed
    WITH (security_invoker = true) AS
    SELECT e.tm_event_id,
           e.name,
           e.url AS ticket_url,
           e.local_date AS event_date,
           to_char(e.local_time, 'HH24:MI') AS start_local_time,
           e.start_utc,
           e.date_tbd,
           e.time_tba,
           e.status_code AS status,
           e.segment,
           e.genre,
           e.sub_genre,
           e.tm_venue_id,
           e.venue_name,
           e.venue_city,
           e.venue_state,
           e.venue_country,
           e.venue_timezone,
           e.attraction_names,
           e.public_onsale,
           e.presales,
           e.ticket_limit,
           coalesce(e.is_product, false) AS is_product,
           e.tevo_event_id,
           e.tevo_match_method,
           ev.name AS tevo_event_name,
           ev.occurs_at_local AS tevo_start_local,
           CASE WHEN e.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || e.tevo_event_id END AS terminal_path,
           e.first_seen_at,
           -- when Ticketmaster last showed us the event: a search read, or the newest bulk file that lists it
           greatest(e.last_seen_at, CASE WHEN e.in_feed THEN ff.at END) AS last_seen_at,
           greatest(e.first_seen_at, e.tevo_matched_at, ch.at) AS changed_at,
           -- ── everything else Ticketmaster returns for the event (mig 20261118223540) ──
           CASE WHEN e.raw->'sales'->'public'->>'endDateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'sales'->'public'->>'endDateTime')::timestamptz END AS public_onsale_end,
           tl.nums AS ticket_limit_numbers,
           CASE WHEN (SELECT count(DISTINCT n) FROM unnest(tl.nums) n) = 1 THEN tl.nums[1] END AS ticket_limit_count,
           CASE WHEN e.raw IS NOT NULL THEN coalesce(e.raw->'ticketing'->'safeTix'->>'enabled' = 'true', false) END AS safetix,
           CASE WHEN e.raw IS NOT NULL THEN coalesce(e.raw->'ticketing'->'allInclusivePricing'->>'enabled' = 'true', false) END AS all_in_pricing,
           CASE WHEN e.raw->'dates'->'end'->>'localDate' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                THEN (e.raw->'dates'->'end'->>'localDate')::date END AS end_date,
           left(e.raw->'dates'->'end'->>'localTime', 5) AS end_local_time,
           CASE WHEN e.raw->'dates'->'end'->>'dateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'dates'->'end'->>'dateTime')::timestamptz END AS end_utc,
           CASE WHEN e.raw IS NOT NULL THEN coalesce(e.raw->'dates'->>'spanMultipleDays' = 'true', false) END AS spans_multiple_days,
           CASE WHEN e.raw->'dates'->'access'->>'startDateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'dates'->'access'->>'startDateTime')::timestamptz END AS access_start_utc,
           CASE WHEN e.raw->'dates'->'access'->>'endDateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'dates'->'access'->>'endDateTime')::timestamptz END AS access_end_utc,
           left(e.raw->'doorsTimes'->>'localTime', 5) AS doors_local_time,
           CASE WHEN e.raw->'doorsTimes'->>'dateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN (e.raw->'doorsTimes'->>'dateTime')::timestamptz END AS doors_utc,
           e.raw->>'pleaseNote' AS please_note,
           e.raw->>'info' AS info,
           e.raw->>'description' AS description,
           e.raw->'linkMoreInfo'->>'url' AS more_info_url,
           e.raw->'ticketTextLines'->'en-us' AS ticket_text,
           e.raw->'classifications'->0->'type'->>'name' AS classification_type,
           e.raw->'classifications'->0->'subType'->>'name' AS classification_sub_type,
           (e.raw->'classifications'->0->>'family' = 'true') AS family,
           (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                     'id', a->>'id', 'name', a->>'name', 'url', a->>'url',
                     'upcoming_events', CASE WHEN a->'upcomingEvents'->>'_total' ~ '^[0-9]+$' THEN (a->'upcomingEvents'->>'_total')::int END,
                     'links', a->'externalLinks')))
              FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.raw->'_embedded'->'attractions') = 'array'
                                             THEN e.raw->'_embedded'->'attractions' ELSE '[]'::jsonb END) a) AS attractions,
           (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                     'id', p->>'id', 'name', p->>'name', 'url', p->>'url', 'type', p->>'type')))
              FROM jsonb_array_elements(CASE WHEN jsonb_typeof(e.raw->'products') = 'array'
                                             THEN e.raw->'products' ELSE '[]'::jsonb END) p) AS products,
           v.v->'address'->>'line1' AS venue_address,
           v.v->>'postalCode' AS venue_postal_code,
           CASE WHEN v.v->'location'->>'latitude' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v.v->'location'->>'latitude')::numeric END AS venue_latitude,
           CASE WHEN v.v->'location'->>'longitude' ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (v.v->'location'->>'longitude')::numeric END AS venue_longitude,
           v.v->>'url' AS venue_url,
           (SELECT jsonb_agg(mk->>'name') FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v.v->'markets') = 'array'
                                                                     THEN v.v->'markets' ELSE '[]'::jsonb END) mk) AS venue_markets,
           CASE WHEN v.v->'upcomingEvents'->>'_total' ~ '^[0-9]+$' THEN (v.v->'upcomingEvents'->>'_total')::int END AS venue_upcoming_events,
           v.v->'boxOfficeInfo' AS venue_box_office,
           v.v->>'parkingDetail' AS venue_parking,
           v.v->'generalInfo' AS venue_general_info,
           v.v->>'accessibleSeatingDetail' AS venue_accessible_seating,
           v.v->'ada' AS venue_ada,
           -- what `q` searches: name, teams or performers, venue and city, lower case, accents removed
           lower(@UNACCENT@(concat_ws(' ', e.name, array_to_string(e.attraction_names, ' '), e.venue_name, e.venue_city))) AS search_text,
           -- ── from Ticketmaster's bulk feed (mig 20261122030530) ──
           e.source,
           (e.source = 'ticketmaster') AS tm_primary,
           e.official_seller,
           e.brand_name,
           e.transactable,
           e.hot_event,
           e.legacy_event_id,
           e.legacy_venue_id,
           e.promoter_names,
           e.in_feed,
           e.raw->'seatmap'->>'staticUrl' AS seatmap_url,
           CASE WHEN jsonb_typeof(e.raw->'outlets') = 'array' THEN e.raw->'outlets' END AS outlets,
           e.detail_read_at
      FROM public.tm_discovery_event e
      LEFT JOIN public.events ev ON ev.id = e.tevo_event_id
      -- the last change we detected to its status, date, time or venue (tm_discovery_change)
      LEFT JOIN (SELECT c.tm_event_id, max(c.detected_at) AS at
                   FROM public.tm_discovery_change c GROUP BY c.tm_event_id) ch ON ch.tm_event_id = e.tm_event_id
      -- the newest bulk file applied for the event's country (two rows: US, CA)
      LEFT JOIN (SELECT t.country, max(t.file_at) AS at FROM public.tm_feed_file t
                  WHERE t.applied_at IS NOT NULL GROUP BY t.country) ff ON ff.country = e.venue_country
      LEFT JOIN LATERAL (SELECT e.raw->'_embedded'->'venues'->0 AS v) v ON true
      -- the numbers in Ticketmaster's ticket-limit sentence, in the order it gives them
      LEFT JOIN LATERAL (SELECT array_agg(coalesce(mt[1], mt[2], mt[3])::int) AS nums
                           FROM regexp_matches(e.ticket_limit,
                                  '([0-9]{1,3})\)?\s*-?\s*ticket limit|ticket limits? of ([0-9]{1,3})|limit of ([0-9]{1,3})', 'gi') mt) tl ON true
     WHERE e.local_date >= CURRENT_DATE - 1
  $v$, '@UNACCENT@', v_unaccent);
  EXECUTE 'REVOKE ALL ON public.v_tm_discovery_feed FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT SELECT ON public.v_tm_discovery_feed TO service_role';
END
$do$;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- VERIFY: SELECT country, file_at, num_events, rows_sent, loaded_at, applied_at, stats, error FROM tm_feed_file ORDER BY file_at DESC LIMIT 4;
--   SELECT source, count(*) FROM tm_discovery_event GROUP BY 1 ORDER BY 2 DESC;
--   SELECT detail_reason, count(*) FROM tm_discovery_event WHERE detail_wanted_at IS NOT NULL GROUP BY 1;
--   SELECT day, calls, change_calls FROM tm_discovery_quota ORDER BY day DESC LIMIT 5;
