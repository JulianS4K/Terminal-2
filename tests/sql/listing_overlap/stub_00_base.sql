-- Stand-ins for what the listing overlap migration reads. Only the columns it uses.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE TABLE events (id bigint PRIMARY KEY, name text, venue_name text, occurs_at_local text);
-- EVO firehose: change-only, one row per (event, capture, ticket group)
CREATE TABLE listings_snapshots (
  event_id bigint, captured_at timestamptz, tevo_ticket_group_id bigint, section text, row text, quantity integer,
  retail_price numeric, is_owned boolean, is_ancillary boolean,
  PRIMARY KEY (event_id, captured_at, tevo_ticket_group_id));
CREATE TABLE event_metrics (event_id bigint, captured_at timestamptz, groups_count integer, PRIMARY KEY (event_id, captured_at));
CREATE TABLE evo_listings_poll_state (event_id bigint PRIMARY KEY, last_polled_listings_at timestamptz);
-- GoTickets firehose: the whole book at each capture
CREATE TABLE gotickets_event (gt_event_id bigint PRIMARY KEY, name text, status text, tevo_event_id bigint);
CREATE TABLE gotickets_listings_snapshots (
  tevo_event_id bigint, gt_event_id bigint, captured_at timestamptz, gt_listing_id bigint, section text, section_id bigint,
  row text, quantity integer, all_in_price numeric,
  PRIMARY KEY (gt_event_id, captured_at, gt_listing_id));
CREATE TABLE gt_listings_poll_state (gt_event_id bigint PRIMARY KEY, last_polled_listings_at timestamptz,
  consecutive_empty integer DEFAULT 0, last_status integer);
-- as in production (mig 20260909223000)
CREATE FUNCTION seat_section_norm(p_section text) RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  WITH c AS (SELECT btrim(regexp_replace(coalesce(p_section,''), '\s+', ' ', 'g')) AS v)
  SELECT CASE
           WHEN c.v = '' THEN NULL
           WHEN split_part(c.v, ' ', array_length(string_to_array(c.v,' '),1)) ~ '[0-9]'
             THEN upper(split_part(c.v, ' ', array_length(string_to_array(c.v,' '),1)))
           ELSE upper(c.v)
         END
  FROM c;
$$;
-- poll intervals: 5 minutes inside 3 days, hourly beyond (production reads collector_cadence)
CREATE FUNCTION collector_band(p_source text, p_scope text, p_hours numeric) RETURNS TABLE(band text, required_min integer)
LANGUAGE sql STABLE AS $$ SELECT CASE WHEN p_hours < 72 THEN 'le3d' ELSE 'far' END, CASE WHEN p_hours < 72 THEN 5 ELSE 60 END $$;
CREATE FUNCTION cron_try_lock(p text) RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE cron.scheduled (name text PRIMARY KEY, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.scheduled VALUES (name, schedule, command)
  ON CONFLICT (name) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING 1::bigint $$;

-- Test helpers: one EVO poll (change-only rows + the metrics row every poll writes) and one GoTickets poll.
CREATE FUNCTION t_evo_poll(p_event bigint, p_at timestamptz, p_rows jsonb, p_ids bigint[] DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO listings_snapshots (event_id, captured_at, tevo_ticket_group_id, section, row, quantity, retail_price, is_owned, is_ancillary)
  SELECT p_event, p_at, (r->>0)::bigint, r->>1, r->>2, (r->>3)::int, (r->>4)::numeric,
         coalesce((r->>5)::boolean, false), coalesce((r->>6)::boolean, false)
    FROM jsonb_array_elements(p_rows) r;
  INSERT INTO event_metrics VALUES (p_event, p_at, jsonb_array_length(p_rows));
  INSERT INTO evo_listings_poll_state VALUES (p_event, p_at - interval '5 seconds')
  ON CONFLICT (event_id) DO UPDATE SET last_polled_listings_at = excluded.last_polled_listings_at;
  IF p_ids IS NOT NULL THEN PERFORM listing_overlap_evo_seen(p_event, p_at, p_ids); END IF;
  RETURN 'evo poll of event ' || p_event || ': ' || jsonb_array_length(p_rows) || ' rows stored'
         || CASE WHEN p_ids IS NOT NULL THEN ', id set of ' || cardinality(p_ids) ELSE '' END;
END $$;
CREATE FUNCTION t_gt_poll(p_event bigint, p_gt_event bigint, p_at timestamptz, p_rows jsonb) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO gotickets_listings_snapshots (tevo_event_id, gt_event_id, captured_at, gt_listing_id, section, section_id, row, quantity, all_in_price)
  SELECT p_event, p_gt_event, p_at, (r->>0)::bigint, r->>1, 1, r->>2, (r->>3)::int, (r->>4)::numeric
    FROM jsonb_array_elements(p_rows) r;
  INSERT INTO gt_listings_poll_state VALUES (p_gt_event, p_at, CASE WHEN jsonb_array_length(p_rows) = 0 THEN 1 ELSE 0 END, 200)
  ON CONFLICT (gt_event_id) DO UPDATE SET last_polled_listings_at = excluded.last_polled_listings_at,
    consecutive_empty = CASE WHEN jsonb_array_length(p_rows) = 0 THEN gt_listings_poll_state.consecutive_empty + 1 ELSE 0 END, last_status = 200;
  RETURN 'gotickets poll of event ' || p_gt_event || ': ' || jsonb_array_length(p_rows) || ' listings stored';
END $$;
