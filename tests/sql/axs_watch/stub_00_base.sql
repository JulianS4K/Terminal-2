-- Stand-ins for what the box-office poll migrations and the AXS watch (mig 20261124190000) read and write around
-- their own tables: the AXS export, pg_net (a GET is recorded, the scenario inserts the response), pg_cron, the vault
-- helper, the TicketsData credit ledger and bot_chat. The poll's own tables and functions come from the real migrations.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;   -- gen_random_uuid on older servers
CREATE FUNCTION public.safe_jsonb(p text) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN p::jsonb; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;
-- the vault helper: the test never sees a real secret
CREATE FUNCTION public.get_app_secret(p_name text) RETURNS text LANGUAGE sql STABLE AS $$ SELECT 'secret-' || p_name $$;
-- bot_chat: a post is recorded and nothing else
CREATE TABLE public.bot_chat_posts (id bigserial PRIMARY KEY, level text, lane text, event_type text, message text, meta jsonb);
CREATE FUNCTION public.bot_chat_log(p_level text, p_lane text, p_event_type text, p_message text, p_related_pr integer DEFAULT NULL,
                                    p_related_mig text DEFAULT NULL, p_in_reply_to bigint DEFAULT NULL, p_meta jsonb DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO public.bot_chat_posts (level, lane, event_type, message, meta) VALUES (p_level, p_lane, p_event_type, p_message, p_meta) RETURNING id $$;
-- the TicketsData credit ledger (mig 20260527050000) and its charge (mig 20260609120000), as on prod
CREATE TABLE public.ticketsdata_credit_usage (
  id bigserial PRIMARY KEY, called_at timestamptz NOT NULL DEFAULT now(), credits integer NOT NULL DEFAULT 1, event_id bigint,
  platform text, endpoint text, status_code integer, quota_remaining integer, reports integer NOT NULL DEFAULT 0, reports_remaining integer);
CREATE FUNCTION public.td_charge_credit(p_n integer DEFAULT 1, p_event_id bigint DEFAULT NULL, p_platform text DEFAULT NULL,
                                        p_endpoint text DEFAULT '/fetch', p_status_code integer DEFAULT NULL, p_quota_remaining integer DEFAULT NULL,
                                        p_reports integer DEFAULT 0, p_reports_remaining integer DEFAULT NULL)
RETURNS void LANGUAGE sql VOLATILE AS $$
  INSERT INTO public.ticketsdata_credit_usage (credits, event_id, platform, endpoint, status_code, quota_remaining, reports, reports_remaining)
  VALUES (p_n, p_event_id, p_platform, p_endpoint, p_status_code, p_quota_remaining, coalesce(p_reports, 0), p_reports_remaining) $$;
-- the AXS export (mig 20261103090000): the columns the watch reads
CREATE TABLE public.axs_export_event (
  axs_event_id bigint PRIMARY KEY, type text, ticketer text, axs_ticketed boolean, status text, event_title text, headliner text,
  performers text[], genre text, major_category text, venue_id bigint, venue_name text, venue_city text, venue_state text,
  event_date_local text, event_date_utc timestamptz, event_timezone text, is_tba boolean, removed_utc timestamptz, event_url text,
  tevo_event_id bigint, tevo_venue_id bigint, match_method text, matched_at timestamptz,
  first_synced_at timestamptz NOT NULL DEFAULT now(), last_synced_at timestamptz NOT NULL DEFAULT now(), gone_at timestamptz);
-- pg_net: a GET is recorded; the scenario inserts the response
CREATE SCHEMA IF NOT EXISTS net;
CREATE TABLE net._http_response (id bigint PRIMARY KEY, status_code int, content text, timed_out boolean, error_msg text, created timestamptz DEFAULT now());
CREATE TABLE net.sent (id bigserial PRIMARY KEY, url text, params jsonb, timeout_ms int);
CREATE FUNCTION net.http_get(url text, params jsonb DEFAULT '{}', headers jsonb DEFAULT '{}', timeout_milliseconds int DEFAULT 5000) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO net.sent(url, params, timeout_ms) VALUES (url, params, timeout_milliseconds) RETURNING id $$;
-- pg_cron
CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;
