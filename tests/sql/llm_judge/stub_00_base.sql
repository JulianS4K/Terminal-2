-- Stand-ins for what the language-model judge (mig 20261117120000) reads and writes outside its own tables: the
-- TEvo mirror, the TickPick / Vivid catalogues and audits, the MLB schedule tables, the vault, pgsql-http, pg_cron.
-- Shapes follow prod (events.occurs_at_local is TEXT there). The HTTP stand-in serves the page whose `match` is
-- found in the request URL OR BODY (longest match first) — so a canned model answer is keyed on a case id in the
-- prompt; POST is allowed here (the judge only ever POSTs to generativelanguage.googleapis.com).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text, venue_location text,
                            primary_performer_id bigint, primary_performer_name text, performer_ids bigint[]);
CREATE INDEX events_local_day_idx ON public.events (left(occurs_at_local, 10));
CREATE FUNCTION public.safe_jsonb(p text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN p::jsonb; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;

-- the catalogues, as far as the judge reads and writes them
CREATE TABLE public.tickpick_catalog_event (tp_event_id bigint PRIMARY KEY, name text, status text, merged_into bigint, event_local timestamp, event_utc timestamptz,
                                            date_confirmed boolean DEFAULT true, time_confirmed boolean DEFAULT true, event_date date, cat_parent text, cat_child text, cat_grandchild text, tp_venue_id bigint,
                                            venue_country text, performers jsonb, tevo_event_id bigint, tevo_match_method text, tevo_matched_at timestamptz);
CREATE TABLE public.tickpick_catalog_venue (tp_venue_id bigint PRIMARY KEY, name text, city text, state text, country text, timezone text, tevo_venue_id bigint,
                                            method text, events int, first_seen_at timestamptz DEFAULT now(), last_seen_at timestamptz DEFAULT now(), derived_at timestamptz);
CREATE TABLE public.tickpick_catalog_audit (id bigserial PRIMARY KEY, at timestamptz DEFAULT now(), run_id uuid, tp_event_id bigint, action text, target text, target_key text,
                                            old_tevo bigint, new_tevo bigint, note text);
CREATE TABLE public.vivid_catalog_event (vivid_event_id bigint PRIMARY KEY, name text, event_local timestamp, event_date date, time_known boolean DEFAULT true, timezone text,
                                         vivid_venue_id bigint, venue_country text, category text, event_type text, performers jsonb, tevo_event_id bigint, tevo_match_method text, tevo_matched_at timestamptz);
CREATE TABLE public.vivid_catalog_venue (vivid_venue_id bigint PRIMARY KEY, name text, city text, state text, country text, timezone text, tevo_venue_id bigint,
                                         method text, events int, first_seen_at timestamptz DEFAULT now(), last_seen_at timestamptz DEFAULT now(), derived_at timestamptz);
CREATE TABLE public.vivid_catalog_audit (id bigserial PRIMARY KEY, at timestamptz DEFAULT now(), run_id uuid, vivid_event_id bigint, action text, target text, target_key text,
                                         old_tevo bigint, new_tevo bigint, note text);
CREATE TABLE public.mlb_ticket_event (schedule_id bigint PRIMARY KEY, team_id int, title text, descr text, event_type text, event_date date, event_time_local timestamp, is_tbd boolean,
                                      venue_id int, venue_name text, venue_city text, tevo_event_id bigint, tevo_match_method text, tevo_matched_at timestamptz,
                                      changed_at timestamptz DEFAULT now(), removed_at timestamptz);
CREATE TABLE public.mlb_ticket_game (schedule_id bigint PRIMARY KEY, venue_id int, game_date date, tevo_event_id bigint, removed_at timestamptz);
CREATE TABLE public.mlb_venue_xref (mlb_venue_id int PRIMARY KEY, tevo_venue_id bigint, method text);
CREATE TABLE public.mlb_map_audit (id bigserial PRIMARY KEY, at timestamptz DEFAULT now(), run_id uuid, schedule_id bigint, action text, target text, target_key text,
                                   old_tevo bigint, new_tevo bigint, note text);
-- the mappers the migration redefines are not run here; what they reference at creation time is nothing (plpgsql)

-- vault
CREATE SCHEMA vault;
CREATE TABLE vault.decrypted_secrets (name text PRIMARY KEY, decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES ('GEMINI_API_KEY', 'AIzaSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTUBSTU');

-- pgsql-http: pages keyed on a substring of the URL or the request body
CREATE SCHEMA extensions;
CREATE TYPE extensions.http_header AS (field text, value text);
CREATE TYPE extensions.http_request AS (method text, uri text, headers extensions.http_header[], content_type text, content text);
CREATE TYPE extensions.http_response AS (status int, content_type text, headers extensions.http_header[], content text);
CREATE FUNCTION extensions.http_header(field text, value text) RETURNS extensions.http_header LANGUAGE sql IMMUTABLE AS $$ SELECT ROW(field, value)::extensions.http_header $$;
CREATE TABLE public.stub_http_page (id serial PRIMARY KEY, match text NOT NULL, status int NOT NULL DEFAULT 200, body text);
CREATE TABLE public.stub_http_log (id serial PRIMARY KEY, method text, uri text, key_header text, body text);
CREATE FUNCTION extensions.http(r extensions.http_request) RETURNS extensions.http_response LANGUAGE plpgsql AS $$
DECLARE p public.stub_http_page; k text;
BEGIN
  SELECT h.value INTO k FROM unnest(r.headers) h WHERE h.field = 'x-goog-api-key';
  INSERT INTO public.stub_http_log (method, uri, key_header, body) VALUES (r.method, r.uri, k, r.content);
  SELECT * INTO p FROM public.stub_http_page s
   WHERE position(s.match IN r.uri || ' ' || coalesce(public.safe_jsonb(r.content)->'contents'->0->'parts'->0->>'text', r.content, '')) > 0
   ORDER BY length(s.match) DESC, s.id LIMIT 1;
  IF NOT FOUND THEN RETURN ROW(404, 'text/plain', NULL, 'stub: no page')::extensions.http_response; END IF;
  RETURN ROW(p.status, 'application/json', NULL, p.body)::extensions.http_response;
END $$;
-- a model answer as Gemini wraps it
CREATE FUNCTION public.stub_gemini(p_answer jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT jsonb_build_object('candidates', jsonb_build_array(jsonb_build_object('content', jsonb_build_object('parts', jsonb_build_array(jsonb_build_object('text', p_answer::text)), 'role', 'model'), 'finishReason', 'STOP')),
                            'usageMetadata', jsonb_build_object('promptTokenCount', 700, 'candidatesTokenCount', 90))::text $$;

-- pg_cron
CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;
