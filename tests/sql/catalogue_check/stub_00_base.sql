-- Stand-ins for what the catalogue check migration reads: the EVO mirror, the hub, each marketplace's
-- catalogue table (only the columns the check reads; shapes follow prod — events.occurs_at_local is TEXT
-- there, aq_event_map.axs_event_id is TEXT), event_xref, the vault, pgsql-http and the helpers.
-- tm_discovery_event and espn_ticket_game are NOT here: they exist only on prod (PR #1156), and the
-- scenario creates them part-way to show the check switching on when they appear.
-- The HTTP stand-in serves what the scenario loads into stub_http_page: the first row whose `match` is found
-- in the request URL (longest match first); no row = 404. Every request is logged in stub_http_log.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;

CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text,
                            venue_location text, last_seen timestamptz);
CREATE TABLE public.aq_event_map (id bigserial PRIMARY KEY, aq_short_event_id text UNIQUE, aq_source text, tevo_event_id bigint,
                                  sg_event_id bigint, sh_event_id bigint, vivid_event_id bigint, tm_event_id bigint, sd_event_id bigint,
                                  gotickets_event_id bigint, tp_event_id bigint, axs_event_id text);
CREATE TABLE public.event_xref (tevo_event_id bigint, espn_event_id text, espn_league text);

CREATE TABLE public.tickpick_catalog_event (tp_event_id bigint PRIMARY KEY, name text, status text, merged_into bigint, event_local timestamp,
                                            event_utc timestamptz, venue_name text, venue_city text, venue_state text, last_seen_at timestamptz,
                                            tevo_event_id bigint, tevo_match_method text);
CREATE TABLE public.gotickets_event (gt_event_id bigint PRIMARY KEY, name text, venue_name text, venue_city text, venue_state text,
                                     event_time_utc timestamptz, status text, tevo_event_id bigint, mapped_via text, updated_at timestamptz);
CREATE TABLE public.vivid_catalog_event (vivid_event_id bigint PRIMARY KEY, name text, event_local timestamp, venue_name text, venue_city text,
                                         venue_state text, last_seen_at timestamptz, tevo_event_id bigint, tevo_match_method text);
CREATE TABLE public.vivid_catalog_sync (id int PRIMARY KEY, pass_started_at timestamptz, pass_finished_at timestamptz);
CREATE TABLE public.sg_events_canonical (sg_event_id bigint PRIMARY KEY, sg_event_name text, sg_event_date date, sg_datetime_utc timestamptz,
                                         sg_venue_name text, sg_venue_city text, sg_venue_state text, tevo_event_id bigint, match_method text,
                                         updated_at timestamptz);
CREATE TABLE public.axs_export_event (axs_event_id bigint PRIMARY KEY, status text, event_title text, venue_name text, venue_city text,
                                      venue_state text, event_date_local text, last_seen_utc timestamptz, tevo_event_id bigint, match_method text,
                                      gone_at timestamptz);
CREATE TABLE public.mlb_ticket_game (schedule_id bigint PRIMARY KEY, home_name text, away_name text, venue_name text, venue_city text,
                                     game_time_local timestamp, game_time_utc timestamptz, status text, last_seen_at timestamptz,
                                     tevo_event_id bigint, tevo_match_method text);

-- helpers, as on prod in what they return
CREATE FUNCTION public.safe_jsonb(p text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN p::jsonb; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;
CREATE SCHEMA vault;
CREATE TABLE vault.decrypted_secrets (name text PRIMARY KEY, decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES ('TICKPICK_API_TOKEN', 'stub-tickpick'), ('GOTICKETS_ACCESS_ID', 'stub-gt-id'), ('GOTICKETS_API_SECRET', 'stub-gt-secret'),
                                           ('TEVO_API_TOKEN', 'stub-evo-token'), ('TEVO_SECRET', 'stub-evo-secret'), ('TMR CLIENT ID', 'stub-ticketmaster-key-0001');
CREATE FUNCTION public.get_app_secret(p_name text) RETURNS text LANGUAGE sql STABLE AS $$ SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = p_name $$;
CREATE FUNCTION public.tevo_sign_get(p_path text, p_query text, p_secret text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'sig(' || p_path || '?' || p_query || ')' $$;

-- pgsql-http
CREATE SCHEMA extensions;
CREATE TYPE extensions.http_header AS (field text, value text);
CREATE TYPE extensions.http_request AS (method text, uri text, headers extensions.http_header[], content_type text, content text);
CREATE TYPE extensions.http_response AS (status int, content_type text, headers extensions.http_header[], content text);
CREATE FUNCTION extensions.http_header(field text, value text) RETURNS extensions.http_header LANGUAGE sql IMMUTABLE AS $$ SELECT ROW(field, value)::extensions.http_header $$;
CREATE FUNCTION extensions.urlencode(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT replace(replace(replace(p, '%', '%25'), '&', '%26'), '=', '%3D') $$;
CREATE TABLE public.stub_http_page (id serial PRIMARY KEY, match text NOT NULL, status int NOT NULL DEFAULT 200, body text);
CREATE TABLE public.stub_http_log (id serial PRIMARY KEY, method text, uri text, headers text);
CREATE FUNCTION extensions.http(r extensions.http_request) RETURNS extensions.http_response LANGUAGE plpgsql AS $$
DECLARE p public.stub_http_page;
BEGIN
  INSERT INTO public.stub_http_log (method, uri, headers)
  VALUES (r.method, r.uri, (SELECT string_agg(h.field, ',' ORDER BY h.field) FROM unnest(r.headers) h));
  IF r.method <> 'GET' THEN RAISE EXCEPTION 'stub http: only GET is served, got %', r.method; END IF;
  SELECT * INTO p FROM public.stub_http_page s WHERE position(s.match IN r.uri) > 0 ORDER BY length(s.match) DESC, s.id LIMIT 1;
  IF NOT FOUND THEN RETURN ROW(404, 'application/json', NULL, '{"message":"not found"}')::extensions.http_response; END IF;
  RETURN ROW(p.status, 'application/json', NULL, p.body)::extensions.http_response;
END $$;
