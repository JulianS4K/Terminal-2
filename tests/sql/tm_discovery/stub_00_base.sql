-- Stand-ins for what the Ticketmaster Discovery collector and match (mig 20261117180000) read and write: the TEvo mirror,
-- venue zones, the performer map, the vault, pgsql-http (a GET is logged and answered from stub_http_page), pg_cron,
-- and the helpers from earlier migrations copied as they are on prod.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text, venue_location text, primary_performer_name text);
CREATE TABLE public.venue_timezone (tevo_venue_id bigint PRIMARY KEY, iana_tz text, venue_name text);
CREATE TABLE public.aq_performer_map (performer_short_id text PRIMARY KEY, performer_name text, tevo_performer_id bigint);
CREATE FUNCTION public.safe_jsonb(p text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN p::jsonb; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;
CREATE FUNCTION public.event_mapper_norm_name(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(regexp_replace(lower(regexp_replace(regexp_replace(coalesce(p, ''), '\s*\([^)]*\)\s*', ' ', 'g'), '[^a-z0-9 ]', ' ', 'gi')), '\s+', ' ', 'g')) $$;
-- vault
CREATE SCHEMA vault;
CREATE TABLE vault.decrypted_secrets (name text PRIMARY KEY, decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES ('TMR CLIENT ID', 'STUBKEYSTUBKEYSTUBKEYSTUBKEY1234'), ('TMR AT', 'never-read');
-- pgsql-http: the GET is logged; the answer comes from stub_http_page (longest matching text in the uri wins)
CREATE SCHEMA extensions;
CREATE TYPE extensions.http_header AS (field text, value text);
CREATE TYPE extensions.http_request AS (method text, uri text, headers extensions.http_header[], content_type text, content text);
CREATE TYPE extensions.http_response AS (status int, content_type text, headers extensions.http_header[], content text);
CREATE FUNCTION extensions.http_header(field text, value text) RETURNS extensions.http_header LANGUAGE sql IMMUTABLE AS $$ SELECT ROW(field, value)::extensions.http_header $$;
CREATE FUNCTION extensions.http_set_curlopt(curlopt text, value text) RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
CREATE FUNCTION extensions.urlencode(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT replace(replace(replace(replace(replace(p, '%', '%25'), ' ', '%20'), '&', '%26'), ',', '%2C'), ':', '%3A') $$;
CREATE TABLE public.stub_http_page (id serial PRIMARY KEY, match text NOT NULL, status int NOT NULL DEFAULT 200, body text);
CREATE TABLE public.stub_http_log (id serial PRIMARY KEY, method text, uri text);
CREATE FUNCTION extensions.http(r extensions.http_request) RETURNS extensions.http_response LANGUAGE plpgsql AS $$
DECLARE p public.stub_http_page;
BEGIN
  INSERT INTO public.stub_http_log (method, uri) VALUES (r.method, r.uri);
  SELECT * INTO p FROM public.stub_http_page s WHERE position(s.match IN r.uri) > 0 ORDER BY length(s.match) DESC, s.id LIMIT 1;
  IF NOT FOUND THEN RETURN ROW(404, 'text/plain', NULL, 'stub: no page')::extensions.http_response; END IF;
  RETURN ROW(p.status, 'application/json', NULL, p.body)::extensions.http_response;
END $$;
-- pg_cron
CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;

-- helpers as on prod (migs 20261117130000, 20261117140000, 20260917060000)
CREATE OR REPLACE FUNCTION public.xmap_name_fits(p_a text, p_a_perfs text[], p_b text, p_b_perfs text[])
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH n AS (
    SELECT public.event_mapper_norm_name(p_a) AS a, public.event_mapper_norm_name(p_b) AS b),
  sides AS (
    SELECT regexp_split_to_array(n.a, '\s+(at|vs\.?|v)\s+') AS sa, regexp_split_to_array(n.b, '\s+(at|vs\.?|v)\s+') AS sb FROM n)
  SELECT n.a <> '' AND n.b <> '' AND (
           n.a = n.b
        OR (length(n.a) >= 8 AND length(n.b) <= 2.2 * length(n.a) AND position(n.a IN n.b) > 0)
        OR (length(n.b) >= 8 AND length(n.a) <= 2.2 * length(n.b) AND position(n.b IN n.a) > 0)
        OR (coalesce(cardinality(p_a_perfs), 0) > 0 AND NOT EXISTS (
              SELECT 1 FROM unnest(p_a_perfs) p WHERE public.event_mapper_norm_name(p) = '' OR position(public.event_mapper_norm_name(p) IN n.b) = 0))
        OR (coalesce(cardinality(p_b_perfs), 0) > 0 AND NOT EXISTS (
              SELECT 1 FROM unnest(p_b_perfs) p WHERE public.event_mapper_norm_name(p) = '' OR position(public.event_mapper_norm_name(p) IN n.a) = 0))
        OR (cardinality(sides.sa) = 2 AND cardinality(sides.sb) = 2
            AND ((sides.sa[1] = sides.sb[1] AND sides.sa[2] = sides.sb[2]) OR (sides.sa[1] = sides.sb[2] AND sides.sa[2] = sides.sb[1])))
        OR (cardinality(sides.sa) = 2 AND length(sides.sa[1]) >= 4 AND length(sides.sa[2]) >= 4
            AND position(sides.sa[1] IN n.b) > 0 AND position(sides.sa[2] IN n.b) > 0)
        OR (cardinality(sides.sb) = 2 AND length(sides.sb[1]) >= 4 AND length(sides.sb[2]) >= 4
            AND position(sides.sb[1] IN n.a) > 0 AND position(sides.sb[2] IN n.a) > 0))
    FROM n, sides
$function$;
CREATE OR REPLACE FUNCTION public.catalog_venue_norm(p_name text, p_city text, p_state text, p_strip_city boolean DEFAULT true)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT coalesce((
    SELECT string_agg(CASE t WHEN 'theatre' THEN 'theater' WHEN 'centre' THEN 'center' WHEN 'ctr' THEN 'center'
                             WHEN 'amphitheatre' THEN 'amphitheater' WHEN 'amph' THEN 'amphitheater' WHEN 'pac' THEN 'performing arts center' ELSE t END, ' ' ORDER BY o)
      FROM unnest(string_to_array(regexp_replace(replace(replace(replace(lower(coalesce(p_name, '')), '&', ' and '), '''', ''), '’', ''), '[^a-z0-9]+', ' ', 'g'), ' ')) WITH ORDINALITY u(t, o)
     WHERE t <> ''
       AND t NOT IN ('the', 'at', 'of', 'in', 'on', 'hotel', 'casino', 'resort', 'complex', 'and', 'parking')
       AND (NOT p_strip_city OR t <> ALL (string_to_array(lower(coalesce(p_city, '')), ' ')))
       AND t <> lower(coalesce(p_state, ''))), '')
$function$;
CREATE OR REPLACE FUNCTION public.tevo_event_utc(p_occurs_at_local text, p_venue_id bigint)
RETURNS timestamptz
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT CASE
           WHEN p_occurs_at_local IS NULL OR p_occurs_at_local !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' THEN NULL
           WHEN p_occurs_at_local ~ '(Z|[+-]\d\d:?\d\d)$' THEN p_occurs_at_local::timestamptz
           ELSE (SELECT (p_occurs_at_local::timestamp AT TIME ZONE v.iana_tz)
                   FROM public.venue_timezone v WHERE v.tevo_venue_id = p_venue_id)
         END;
$fn$;
