DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE TABLE events (id bigint primary key, name text, occurs_at_local timestamp);
CREATE TABLE n2s_evo_current (event_id bigint, tevo_ticket_group_id bigint, section text, row text, quantity int, retail_price numeric, splits int[], is_owned boolean, is_ancillary boolean, public_notes text, view_type text, pulled_at timestamptz default now());
CREATE TABLE n2s_gt_current (tevo_event_id bigint, gt_event_id bigint, gt_listing_id bigint, section text, section_id text, row text, quantity int, all_in_price numeric, splits int[], notes text, pulled_at timestamptz default now());
CREATE TABLE n2s_sg_current (tevo_event_id bigint, sg_event_id bigint, display_id text, sglid bigint, section text, row text, quantity int, retail_price_all_in numeric, splits jsonb, is_broker_owned boolean, has_limited_view boolean, seller_notes text, pulled_at timestamptz default now());
CREATE TABLE sg_events_canonical (sg_event_id bigint primary key, sg_url text);
CREATE TABLE n2s_mkt_pull (request_id bigserial, source text, tevo_event_id bigint, mkt_event_id text, fired_at timestamptz default now(), resolved_at timestamptz, status_code int, rows_persisted int);
CREATE FUNCTION seat_section_norm(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT lower(regexp_replace(p,'\s+','','g')) $$;
CREATE FUNCTION seat_row_kind(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN p ~ '^\d+$' THEN 'n' ELSE 'a' END $$;
CREATE FUNCTION seat_row_rank(p text) RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN p ~ '^\d+$' THEN p::int ELSE ascii(upper(p))-64 END $$;
CREATE FUNCTION n2s_pull_events(p_events bigint[], p_refresh_after interval DEFAULT '5 min') RETURNS TABLE(evo_fired int) LANGUAGE plpgsql AS $$
BEGIN INSERT INTO n2s_mkt_pull(source, tevo_event_id) SELECT 'evo', e FROM unnest(p_events) e; RETURN QUERY SELECT 1; END $$;
CREATE TABLE aq_event_map (id bigserial, tevo_event_id bigint, sh_event_id bigint);
CREATE SCHEMA IF NOT EXISTS net;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE TABLE net._http_response (id bigint primary key, status_code int, content text, timed_out boolean, error_msg text);
CREATE TABLE net.sent (id bigserial primary key, url text, params jsonb);
CREATE FUNCTION net.http_get(url text, params jsonb DEFAULT '{}', headers jsonb DEFAULT '{}', timeout_milliseconds int DEFAULT 5000) RETURNS bigint LANGUAGE sql AS $$ INSERT INTO net.sent(url, params) VALUES (url, params) RETURNING id $$;
CREATE FUNCTION get_app_secret(p text) RETURNS text LANGUAGE sql AS $$ SELECT 'secret-'||p $$;
CREATE TABLE n2s_items (n2s_id bigint, order_number text, n2s_order_key text, marketplace text, tevo_event_id bigint, event_name text, event_dt timestamp, venue text, section text, row text, qty int, price_per_ticket numeric, pulled_at timestamptz default now());
CREATE TABLE v_s4kcs_orders (source text, s4k_order_id text, tevo_event_id bigint, event_name text, event_date date, venue_name text, section text, row text, quantity int, price_per_ticket numeric, pulled_at timestamptz default now());
ALTER TABLE n2s_items ADD COLUMN is_terminal boolean DEFAULT false, ADD COLUMN status text DEFAULT 'n2s';
CREATE TABLE v_sub_orders (source text, order_id text, canonical_status text, is_open boolean);
CREATE FUNCTION cron_try_lock(p text) RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE cron.scheduled (name text primary key, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$ INSERT INTO cron.scheduled VALUES (name, schedule, command) ON CONFLICT (name) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING 1::bigint $$;
CREATE TABLE band_log (at timestamptz default now(), evs bigint[], iv interval);
CREATE OR REPLACE FUNCTION n2s_pull_events(p_events bigint[], p_refresh_after interval DEFAULT '5 min') RETURNS TABLE(evo_fired int) LANGUAGE plpgsql AS $$
BEGIN INSERT INTO band_log(evs, iv) VALUES (p_events, p_refresh_after); INSERT INTO n2s_mkt_pull(source, tevo_event_id) SELECT 'evo', e FROM unnest(p_events) e; RETURN QUERY SELECT 1; END $$;
CREATE FUNCTION collector_band(p_source text, p_scope text, p_hours numeric) RETURNS TABLE(band text, required_min integer) LANGUAGE sql AS $$
  SELECT v.band, v.m FROM (VALUES ('le3d',5,0,72),('le7d',15,72,168),('d8_14',30,168,336)) v(band, m, lo, hi) WHERE p_hours >= lo AND p_hours < hi $$;
ALTER TABLE events ADD COLUMN venue_id bigint, ADD COLUMN primary_performer_id bigint;
ALTER TABLE n2s_items ADD COLUMN timer_expires_at timestamptz, ADD COLUMN timer_expired boolean, ADD COLUMN alert_at timestamptz;
CREATE TABLE n2s_autobuy_exec (exec_id bigserial, order_number text);
CREATE TABLE zone_stub (performer_id bigint, venue_id bigint, section text, zone text);
CREATE FUNCTION n2s_zone_of(p_performer_id bigint, p_venue_id bigint, p_section text, p_row text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT zone FROM zone_stub WHERE performer_id = p_performer_id AND venue_id = p_venue_id AND section = p_section $$;
CREATE FUNCTION n2s_timer_open(p_expires_at timestamptz, p_expired boolean, p_alert_at timestamptz) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT NOT coalesce(p_expired, false) AND coalesce(p_expires_at, p_alert_at + interval '15 min') > now() $$;
CREATE TABLE gotickets_sales (gt_sale_id bigint primary key, gt_event_id bigint, event_name text, event_time_local timestamp, venue_name text, section text, row text, quantity int, unit_cost numeric, total_payout numeric, seller_status text, fulfilled boolean, raw jsonb default '{}', pulled_at timestamptz default now());
CREATE TABLE gotickets_event (gt_event_id bigint primary key, tevo_event_id bigint);
CREATE TABLE tickpick_orders (tp_order_id text primary key, event_name text, event_date timestamptz, section text, row text, quantity int, total numeric, order_status text, status text, tevo_event_id bigint, pulled_at timestamptz default now());
CREATE TABLE vivid_orders (vivid_order_id text primary key, event_name text, event_date timestamptz, section text, row text, quantity int, total numeric, status text, tevo_event_id bigint, pulled_at timestamptz default now());
CREATE TABLE seatgeek_orders (sg_order_id text primary key, status text, sg_event_name text, sg_venue text, sg_event_date date, sale_price numeric, sale_row text, sale_section text, sale_quantity int, tevo_event_id bigint, pulled_at timestamptz default now());
CREATE TABLE evo_orders (evo_order_id bigint primary key, state text, seller_brokerage_id bigint, pulled_at timestamptz default now());
CREATE TABLE evo_order_items (evo_order_id bigint, quantity int, price numeric, ticket_group_section text, ticket_group_row text, event_id bigint, event_name text, occurs_at timestamptz, venue_name text);
CREATE TABLE order_status_xref (source text, source_status text, canonical_status text, is_terminal boolean);
INSERT INTO order_status_xref VALUES ('tickpick','rejected','rejected',true),('tickpick','fulfilled','fulfilled',true),('vivid','CANCELLED','cancelled',true),('vivid','PENDING_SHIPMENT','accepted',false),('seatgeek','fulfilled','fulfilled',true),('seatgeek','confirmed','accepted',false),('evo','completed','fulfilled',true),('evo','accepted','accepted',false),('s4kcs','Cancelled','cancelled',true);
ALTER TABLE v_s4kcs_orders ADD COLUMN order_status text;
ALTER TABLE evo_orders ADD COLUMN buyer_brokerage_id bigint, ADD COLUMN tax numeric, ADD COLUMN subtotal numeric, ADD COLUMN evo_created_at timestamptz default now();
ALTER TABLE evo_order_items ADD COLUMN venue_id bigint;
