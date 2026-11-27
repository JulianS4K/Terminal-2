-- Stand-ins for what the ProVenue watch (mig 20261127230000) reads around its own tables: the MLB schedule
-- (mlb_ticket_game, the columns the watch reads), the vault, and pg_net's response headers.
CREATE SCHEMA IF NOT EXISTS vault;
CREATE TABLE vault.decrypted_secrets (name text PRIMARY KEY, decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES ('tickets.dev', 'test-key');
CREATE TABLE public.mlb_ticket_game (
  schedule_id bigint, mlb_game_id text, sport_id integer, game_type text, season integer, game_date date,
  game_time_utc timestamptz, game_time_local text, time_zone_local text, home_abbrev text, away_abbrev text,
  home_name text, away_name text, venue_name text, venue_city text, ticket_url text, primary_seller text,
  primary_event_id text, ticket_url_kind text, on_sale_start timestamp, on_sale_end timestamp,
  tevo_event_id bigint, removed_at timestamptz);
ALTER TABLE net._http_response ADD COLUMN headers jsonb;
ALTER TABLE net.sent ADD COLUMN headers jsonb;
CREATE OR REPLACE FUNCTION net.http_get(url text, params jsonb DEFAULT '{}', headers jsonb DEFAULT '{}', timeout_milliseconds int DEFAULT 5000) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO net.sent(url, params, headers, timeout_ms) VALUES (url, params, headers, timeout_milliseconds) RETURNING id $$;
