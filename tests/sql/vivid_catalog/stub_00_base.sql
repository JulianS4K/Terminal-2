-- Stand-ins for what the Vivid catalogue migration reads and writes outside its own tables: the TEvo mirror, the
-- hub, our Vivid order book, the vault, pgsql-http, pg_cron and the helpers (incl. the TickPick migration's generic
-- name rule). The HTTP stand-in serves pages the scenario loads into stub_http_page: the first row whose `match`
-- is found in the request URL (longest match first). The 5.2 s pacing between pages is real here (a few seconds per scenario).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text, venue_location text,
                            primary_performer_id bigint, primary_performer_name text, performer_ids bigint[]);
CREATE INDEX events_local_day_idx ON public.events (left(occurs_at_local, 10));
CREATE TABLE public.aq_event_map (id bigserial PRIMARY KEY, aq_short_event_id text UNIQUE, event_name text, venue_name text, event_date timestamp,
                                  category text, aq_source text, imported_at timestamptz, tevo_event_id bigint, tevo_venue_id bigint,
                                  primary_source text, sg_event_id bigint, vivid_event_id bigint, tp_event_id bigint);
CREATE TABLE public.vivid_orders (vivid_order_id text PRIMARY KEY, event_name text, event_date timestamptz, status text, quantity int,
                                  tevo_event_id bigint, raw jsonb, aq_short_event_id text);
-- venue zone unknown to the stub: the local wall time is read as UTC (the scenario gives Vivid venues timezone UTC)
CREATE FUNCTION public.tevo_event_utc(p_occurs_at_local text, p_venue_id bigint) RETURNS timestamptz LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_occurs_at_local ~ '[+-]\d\d:\d\d$' THEN p_occurs_at_local::timestamptz
              ELSE (p_occurs_at_local::timestamp AT TIME ZONE 'UTC') END $$;
CREATE FUNCTION public.event_mapper_norm_name(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(regexp_replace(lower(regexp_replace(regexp_replace(coalesce(p, ''), '\s*\([^)]*\)\s*', ' ', 'g'), '[^a-z0-9 ]', ' ', 'gi')), '\s+', ' ', 'g')) $$;
-- the generic name rule from mig 20261117040000, as on prod
CREATE FUNCTION public.tickpick_catalog_name_fits(p_tp_name text, p_tp_performers jsonb, p_evo_name text, p_evo_performer text)
 RETURNS boolean LANGUAGE sql STABLE AS $function$
  WITH n AS (SELECT public.event_mapper_norm_name(p_tp_name) AS a, public.event_mapper_norm_name(p_evo_name) AS b, public.event_mapper_norm_name(p_evo_performer) AS bp),
  perf AS (SELECT count(*) AS n_all, count(*) FILTER (WHERE length(x.nm) >= 3 AND position(x.nm IN (SELECT b FROM n)) > 0) AS n_in
             FROM (SELECT public.event_mapper_norm_name(p->>'name') AS nm FROM jsonb_array_elements(coalesce(p_tp_performers, '[]'::jsonb)) p WHERE coalesce(p->>'name', '') <> '') x)
  SELECT CASE WHEN n.a = '' OR n.b = '' THEN false
              WHEN (n.a ~ '(parking|tailgate|shuttle)') <> (n.b ~ '(parking|tailgate|shuttle)') THEN false
              WHEN n.a = n.b THEN true
              WHEN length(n.a) >= 4 AND position(n.a IN n.b) > 0 THEN true
              WHEN length(n.b) >= 4 AND position(n.b IN n.a) > 0 THEN true
              WHEN perf.n_all > 0 AND perf.n_in = perf.n_all THEN true
              WHEN length(n.bp) >= 4 AND position(n.bp IN n.a) > 0 THEN true
              ELSE false END FROM n, perf $function$;
CREATE FUNCTION public.safe_jsonb(p text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN p::jsonb; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;

CREATE SCHEMA vault;
CREATE TABLE vault.decrypted_secrets (name text PRIMARY KEY, decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES ('VIVID_API_TOKEN', 'stub-vivid-token');

CREATE SCHEMA extensions;
CREATE TYPE extensions.http_header AS (field text, value text);
CREATE TYPE extensions.http_request AS (method text, uri text, headers extensions.http_header[], content_type text, content text);
CREATE TYPE extensions.http_response AS (status int, content_type text, headers extensions.http_header[], content text);
CREATE FUNCTION extensions.http_header(field text, value text) RETURNS extensions.http_header LANGUAGE sql IMMUTABLE AS $$ SELECT ROW(field, value)::extensions.http_header $$;
CREATE TABLE public.stub_http_page (id serial PRIMARY KEY, match text NOT NULL, status int NOT NULL DEFAULT 200, body text);
CREATE TABLE public.stub_http_log (id serial PRIMARY KEY, method text, uri text, auth text);
CREATE FUNCTION extensions.http(r extensions.http_request) RETURNS extensions.http_response LANGUAGE plpgsql AS $$
DECLARE p public.stub_http_page; a text;
BEGIN
  SELECT h.value INTO a FROM unnest(r.headers) h WHERE h.field = 'Api-token';
  INSERT INTO public.stub_http_log (method, uri, auth) VALUES (r.method, r.uri, a);
  IF r.method <> 'GET' THEN RAISE EXCEPTION 'stub http: only GET is served, got %', r.method; END IF;
  SELECT * INTO p FROM public.stub_http_page s WHERE position(s.match IN r.uri) > 0 ORDER BY length(s.match) DESC, s.id LIMIT 1;
  IF NOT FOUND THEN RETURN ROW(404, 'text/plain', NULL, 'stub: no page for ' || r.uri)::extensions.http_response; END IF;
  RETURN ROW(p.status, 'application/json', NULL, p.body)::extensions.http_response;
END $$;

CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;

-- the other catalogues, as far as v_event_catalogues (mig 20261117080000) reads them
CREATE TABLE IF NOT EXISTS public.sg_events_canonical (sg_event_id bigint PRIMARY KEY, tevo_event_id bigint, sg_event_date date, updated_at timestamptz);
CREATE TABLE IF NOT EXISTS public.gotickets_event (gt_event_id bigint PRIMARY KEY, tevo_event_id bigint, event_time_utc timestamptz, status text, updated_at timestamptz);
CREATE TABLE IF NOT EXISTS public.axs_export_event (axs_event_id bigint PRIMARY KEY, tevo_event_id bigint, gone_at timestamptz, event_date_local text, venue_country text, matched_at timestamptz);
CREATE TABLE IF NOT EXISTS public.mlb_ticket_game (schedule_id bigint PRIMARY KEY, tevo_event_id bigint, game_date date, last_seen_at timestamptz);
CREATE TABLE IF NOT EXISTS public.tickpick_catalog_event (tp_event_id bigint PRIMARY KEY, tevo_event_id bigint, event_date date, status text, venue_country text, last_seen_at timestamptz);
