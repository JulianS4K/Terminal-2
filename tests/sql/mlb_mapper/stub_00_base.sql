-- Stand-ins for what the MLB schedule migrations read and write outside their own tables: the TEvo
-- mirror, the hub, the SeatGeek catalogue, the performer registries, pg_net, pg_cron and the helpers.
-- Shapes follow prod (events.occurs_at_local is TEXT there; the hub's event_date is a bare timestamp).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS extensions;
-- pgsql-http, as far as the alert digest (mig 20261117060000) declares it; never called by a scenario
CREATE TYPE extensions.http_header AS (field text, value text);
CREATE TYPE extensions.http_request AS (method text, uri text, headers extensions.http_header[], content_type text, content text);
CREATE TYPE extensions.http_response AS (status int, content_type text, headers extensions.http_header[], content text);
CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text,
                            primary_performer_id bigint, primary_performer_name text, performer_ids bigint[]);
CREATE INDEX events_local_day_idx ON public.events (left(occurs_at_local, 10));
CREATE TABLE public.aq_event_map (id bigserial PRIMARY KEY, aq_short_event_id text UNIQUE, event_name text, venue_name text, event_date timestamp,
                                  category text, aq_source text, imported_at timestamptz, tevo_event_id bigint, tevo_venue_id bigint, tevo_performer_id bigint,
                                  primary_source text, sg_event_id bigint, sh_event_id bigint, vivid_event_id bigint, tm_event_id bigint, gotickets_event_id bigint);
CREATE TABLE public.sg_events_canonical (sg_event_id bigint PRIMARY KEY, sg_event_name text, sg_event_date date, sg_datetime_utc timestamptz, sg_category text,
                                         sg_url text, tevo_event_id bigint, match_method text, match_confidence numeric, matched_at timestamptz, updated_at timestamptz);
CREATE TABLE public.team_xref (tevo_performer_id bigint, tevo_name text, espn_team_id text, espn_league text);
CREATE TABLE public.entity_performer_map (tevo_performer_id bigint, tevo_performer_name text);
-- venue zone unknown to the stub: the local wall time is read as UTC (the scenario writes MLB's UTC the same way)
CREATE FUNCTION public.tevo_event_utc(p_occurs_at_local text, p_venue_id bigint) RETURNS timestamptz LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_occurs_at_local ~ '[+-]\d\d:\d\d$' THEN p_occurs_at_local::timestamptz
              ELSE (p_occurs_at_local::timestamp AT TIME ZONE 'UTC') END $$;
-- as on prod (mig 20260510…): SYS-<md5 of name|venue|start>, system_seed, no overwrite
CREATE FUNCTION public.create_system_aq_event(p_source text, p_event_name text, p_venue_name text, p_event_date timestamptz, p_source_event_id bigint)
 RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_new_id text;
BEGIN
  v_new_id := 'SYS-' || substring(md5(coalesce(p_event_name,'') || '|' || coalesce(p_venue_name,'') || '|' ||
                                      coalesce(to_char(p_event_date::timestamptz, 'YYYY-MM-DD"T"HH24:MI'),'')) from 1 for 10);
  INSERT INTO public.aq_event_map (aq_short_event_id, event_name, venue_name, event_date, category, aq_source, imported_at)
  VALUES (v_new_id, p_event_name, p_venue_name, p_event_date::timestamp, p_source, 'system_seed', now())
  ON CONFLICT (aq_short_event_id) DO NOTHING;
  RETURN v_new_id;
END $$;
CREATE FUNCTION public.safe_jsonb(p text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN p::jsonb; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;
CREATE SCHEMA IF NOT EXISTS net;
CREATE TABLE net._http_response (id bigint PRIMARY KEY, status_code int, content text, timed_out boolean, error_msg text, created timestamptz DEFAULT now());
CREATE TABLE net.sent (id bigserial PRIMARY KEY, url text, params jsonb);
CREATE FUNCTION net.http_get(url text, params jsonb DEFAULT '{}', headers jsonb DEFAULT '{}', timeout_milliseconds int DEFAULT 5000) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO net.sent(url, params) VALUES (url, params) RETURNING id $$;
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;
