-- Stand-ins for what the ESPN ticket-link collector and map (mig 20261117160000) read and write: the TEvo mirror and
-- venue zones, the Vivid catalogue's event, venue and audit tables, pg_net (a GET is recorded, the test inserts the
-- response), pg_cron, and the helpers from earlier migrations copied as they are on prod.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text, venue_location text, primary_performer_name text);
CREATE TABLE public.venue_timezone (tevo_venue_id bigint PRIMARY KEY, iana_tz text, venue_name text);
CREATE TABLE public.vivid_catalog_event (vivid_event_id bigint PRIMARY KEY, name text, event_local timestamp, event_date date, vivid_venue_id bigint, tevo_event_id bigint, tevo_match_method text, tevo_matched_at timestamptz);
CREATE TABLE public.vivid_catalog_venue (vivid_venue_id bigint PRIMARY KEY, name text, city text, state text, country text, tevo_venue_id bigint, method text, events integer, derived_at timestamptz);
CREATE TABLE public.vivid_catalog_audit (id bigserial PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(), run_id uuid NOT NULL, vivid_event_id bigint, action text NOT NULL, target text NOT NULL,
                                         target_key text, old_tevo bigint, new_tevo bigint, note text);
CREATE FUNCTION public.safe_jsonb(p text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN p::jsonb; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;
CREATE FUNCTION public.event_mapper_norm_name(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(regexp_replace(lower(regexp_replace(regexp_replace(coalesce(p, ''), '\s*\([^)]*\)\s*', ' ', 'g'), '[^a-z0-9 ]', ' ', 'gi')), '\s+', ' ', 'g')) $$;
-- pg_net: a GET is recorded; the scenario inserts the response
CREATE SCHEMA IF NOT EXISTS net;
CREATE TABLE net._http_response (id bigint PRIMARY KEY, status_code int, content text, timed_out boolean, error_msg text, created timestamptz DEFAULT now());
CREATE TABLE net.sent (id bigserial PRIMARY KEY, url text, params jsonb);
CREATE FUNCTION net.http_get(url text, params jsonb DEFAULT '{}', headers jsonb DEFAULT '{}', timeout_milliseconds int DEFAULT 5000) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO net.sent(url, params) VALUES (url, params) RETURNING id $$;
-- pg_cron
CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;

-- helpers as on prod (migs 20261117130000, 20260917060000)
CREATE OR REPLACE FUNCTION public.xmap_state_tz(p_state text, p_country text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN upper(coalesce(p_country, 'US')) = 'MX' THEN 'America/Mexico_City'
    WHEN upper(p_state) IN ('BC') THEN 'America/Vancouver'
    WHEN upper(p_state) IN ('AB') THEN 'America/Edmonton'
    WHEN upper(p_state) IN ('SK') THEN 'America/Regina'
    WHEN upper(p_state) IN ('MB') THEN 'America/Winnipeg'
    WHEN upper(p_state) IN ('ON', 'QC') THEN 'America/Toronto'
    WHEN upper(p_state) IN ('NB', 'NS', 'PE') THEN 'America/Halifax'
    WHEN upper(p_state) IN ('NL') THEN 'America/St_Johns'
    WHEN upper(p_state) IN ('HI') THEN 'Pacific/Honolulu'
    WHEN upper(p_state) IN ('AK') THEN 'America/Anchorage'
    WHEN upper(p_state) IN ('CA', 'WA', 'OR', 'NV') THEN 'America/Los_Angeles'
    WHEN upper(p_state) IN ('AZ') THEN 'America/Phoenix'
    WHEN upper(p_state) IN ('MT', 'CO', 'UT', 'NM', 'ID', 'WY') THEN 'America/Denver'
    WHEN upper(p_state) IN ('TX', 'OK', 'KS', 'NE', 'SD', 'ND', 'MN', 'IA', 'MO', 'AR', 'LA', 'MS', 'AL', 'WI', 'IL', 'TN') THEN 'America/Chicago'
    ELSE 'America/New_York' END
$function$;
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
