-- Stand-ins for what the cross-source spine (mig 20261117130000) reads: the TEvo mirror and venue zones, the six
-- catalogues as far as the spine reads them, the venue maps, pg_cron, and the two helpers from earlier migrations.
-- Shapes follow prod (events.occurs_at_local and axs_export_event.event_date_local are TEXT there).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text, venue_location text,
                            primary_performer_id bigint, primary_performer_name text, performer_ids bigint[]);
CREATE TABLE public.venue_timezone (tevo_venue_id bigint PRIMARY KEY, iana_tz text, venue_name text);
-- as on prod
CREATE FUNCTION public.event_mapper_norm_name(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(regexp_replace(lower(regexp_replace(regexp_replace(coalesce(p, ''), '\s*\([^)]*\)\s*', ' ', 'g'), '[^a-z0-9 ]', ' ', 'gi')), '\s+', ' ', 'g')) $$;
-- TEvo venues whose name is unique within a state (mig 20261117080000)
CREATE FUNCTION public.catalog_tevo_venues_by_name() RETURNS TABLE(nm text, st text, tevo_venue_id bigint) LANGUAGE sql STABLE AS $$
  SELECT lower(trim(venue_name)), upper(trim(regexp_replace(venue_location, '^.*,\s*', ''))), min(venue_id)
    FROM public.events WHERE venue_id IS NOT NULL AND venue_name IS NOT NULL AND venue_location LIKE '%,%'
   GROUP BY 1, 2 HAVING count(DISTINCT venue_id) = 1 $$;

-- the catalogues
CREATE TABLE public.tickpick_catalog_event (tp_event_id bigint PRIMARY KEY, name text, status text, merged_into bigint, event_local timestamp, date_confirmed boolean DEFAULT true,
                                            time_confirmed boolean DEFAULT true, event_date date, tp_venue_id bigint, venue_country text, performers jsonb, tevo_event_id bigint);
CREATE TABLE public.tickpick_catalog_venue (tp_venue_id bigint PRIMARY KEY, name text, city text, state text, country text, tevo_venue_id bigint, method text);
CREATE TABLE public.vivid_catalog_event (vivid_event_id bigint PRIMARY KEY, name text, event_local timestamp, event_date date, time_known boolean DEFAULT true,
                                         vivid_venue_id bigint, venue_country text, performers jsonb, tevo_event_id bigint);
CREATE TABLE public.vivid_catalog_venue (vivid_venue_id bigint PRIMARY KEY, name text, city text, state text, country text, tevo_venue_id bigint, method text);
CREATE TABLE public.gotickets_event (gt_event_id bigint PRIMARY KEY, name text, performer text, venue_name text, venue_city text, venue_state text, event_time_utc timestamptz,
                                     status text, tevo_event_id bigint);
CREATE TABLE public.axs_export_event (axs_event_id bigint PRIMARY KEY, event_title text, event_title_clean text, headliner text, performers text[], venue_name text, venue_city text,
                                      venue_state text, venue_country text, event_date_local text, is_tba boolean, removed_utc timestamptz, gone_at timestamptz,
                                      tevo_event_id bigint, tevo_venue_id bigint);
CREATE TABLE public.sg_events_canonical (sg_event_id bigint PRIMARY KEY, sg_event_name text, sg_event_date date, sg_datetime_utc timestamptz, sg_venue_id bigint,
                                         sg_venue_name text, sg_venue_city text, sg_venue_state text, sg_venue_country text, tevo_event_id bigint);
CREATE TABLE public.mlb_ticket_game (schedule_id bigint PRIMARY KEY, game_date date, game_time_local timestamp, is_tbd boolean, venue_id int, venue_name text, venue_city text,
                                     home_name text, away_name text, tevo_event_id bigint, removed_at timestamptz);
CREATE TABLE public.mlb_venue_xref (mlb_venue_id int PRIMARY KEY, tevo_venue_id bigint);
CREATE TABLE public.aq_venue_map (venue_short_id text PRIMARY KEY, tevo_venue_id bigint, sg_venue_id bigint);
CREATE TABLE public.cross_source_venue_map (tevo_venue_id bigint, sg_venue_id bigint);

-- pg_cron
CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;
-- ESPN's games with their Vivid links (mig 20261117160000), the spine's seventh source (mig 20261117170000)
CREATE TABLE public.espn_ticket_game (espn_event_id text PRIMARY KEY, espn_league text, name text, game_at_utc timestamptz, time_valid boolean, status text, home_team_id text, home_name text,
                                      away_team_id text, away_name text, venue_name text, venue_city text, venue_state text, vivid_production_id bigint, vivid_venue_id bigint, tevo_event_id bigint);
-- Ticketmaster's catalogue (mig 20261117180000), the spine's eighth source (mig 20261117190000)
CREATE TABLE public.tm_discovery_event (tm_event_id text PRIMARY KEY, name text, local_date date, local_time time, date_tbd boolean, time_tba boolean, status_code text, tm_venue_id text,
                                        venue_name text, venue_city text, venue_state text, venue_country text, attraction_names text[], is_product boolean NOT NULL DEFAULT false, tevo_event_id bigint, seller text, channel text);
CREATE TABLE public.tm_venue_xref (tm_venue_id text PRIMARY KEY, tevo_venue_id bigint);
-- the primary box-office feed (PR #1180, mig 20261123171030): the columns the mapper and the spine read
CREATE TABLE public.primary_poll_event (source text NOT NULL, source_event_id text NOT NULL, name text, event_date date, start_local_time time, start_utc timestamptz, timezone text,
                                        venue_name text, venue_city text, venue_state text, tevo_event_id bigint, tevo_match_method text, tevo_matched_at timestamptz,
                                        PRIMARY KEY (source, source_event_id));
