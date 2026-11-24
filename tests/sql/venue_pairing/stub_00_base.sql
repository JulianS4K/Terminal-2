-- Stand-ins for what the venue pairer (mig 20261117140000) reads and writes: the TEvo mirror, the two catalogues'
-- venue, event and audit tables, the AXS export's venue columns, pg_cron. Shapes follow prod.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text, venue_location text, primary_performer_name text);

CREATE TABLE public.tickpick_catalog_venue (tp_venue_id bigint PRIMARY KEY, name text, city text, state text, country text, timezone text, tevo_venue_id bigint, method text, events integer,
                                            first_seen_at timestamptz NOT NULL DEFAULT now(), last_seen_at timestamptz NOT NULL DEFAULT now(), derived_at timestamptz);
CREATE TABLE public.tickpick_catalog_event (tp_event_id bigint PRIMARY KEY, name text, status text, merged_into bigint, date_confirmed boolean DEFAULT true, event_date date, tp_venue_id bigint);
CREATE TABLE public.tickpick_catalog_audit (id bigserial PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(), run_id uuid NOT NULL, tp_event_id bigint, action text NOT NULL, target text NOT NULL,
                                            target_key text, old_tevo bigint, new_tevo bigint, note text);
CREATE TABLE public.vivid_catalog_venue (vivid_venue_id bigint PRIMARY KEY, name text, city text, state text, country text, timezone text, tevo_venue_id bigint, method text, events integer,
                                         first_seen_at timestamptz NOT NULL DEFAULT now(), last_seen_at timestamptz NOT NULL DEFAULT now(), derived_at timestamptz);
CREATE TABLE public.vivid_catalog_event (vivid_event_id bigint PRIMARY KEY, name text, event_date date, vivid_venue_id bigint);
CREATE TABLE public.vivid_catalog_audit (id bigserial PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(), run_id uuid NOT NULL, vivid_event_id bigint, action text NOT NULL, target text NOT NULL,
                                         target_key text, old_tevo bigint, new_tevo bigint, note text);
CREATE TABLE public.axs_export_event (axs_event_id bigint PRIMARY KEY, venue_name text, venue_city text, venue_state text, tevo_venue_id bigint, gone_at timestamptz);
-- Ticketmaster Discovery (mig 20261117180000), the pairer's third source since mig 20261118002000: text venue ids
CREATE TABLE public.tm_venue_xref (tm_venue_id text PRIMARY KEY, name text, city text, state text, country text, tevo_venue_id bigint, method text, events int, derived_at timestamptz);
CREATE TABLE public.tm_discovery_event (tm_event_id text PRIMARY KEY, name text, local_date date, tm_venue_id text, is_product boolean NOT NULL DEFAULT false, status_code text);
CREATE TABLE public.tm_discovery_audit (id bigserial PRIMARY KEY, at timestamptz NOT NULL DEFAULT now(), run_id uuid NOT NULL, action text NOT NULL, target text, target_key text, tevo_event_id bigint, method text, note text);

-- pg_cron
CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;
