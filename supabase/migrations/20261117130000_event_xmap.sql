-- Migration 20261117130000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:event_xmap(new),event_xmap_audit(new),event_xmap_run(new),xmap_state_tz()(new),xmap_name_fits()(new),event_xmap_tick()(new),v_event_xmap(new view),v_event_xmap_coverage(new view),cron:event_xmap_hourly(new),cron:event_xmap_daily(new) · reads:events,venue_timezone,tickpick_catalog_event,tickpick_catalog_venue,vivid_catalog_event,vivid_catalog_venue,gotickets_event,axs_export_event,sg_events_canonical,aq_venue_map,cross_source_venue_map,mlb_ticket_game,mlb_venue_xref · pre:20261117120000
--
-- MAPPING PROGRAM — THE CATALOGUES MAP TO EACH OTHER, WITH OR WITHOUT EVO.
--
-- Operator 2026-11-17: "cross map so even if they dont map to evo they map to each other." Until now every mapping
-- ended at an EVO event id, and the hub (aq_event_map) is keyed by it: a Vivid listing, a GoTickets listing and a
-- TickPick listing of the same show at a park EVO does not list stayed three unrelated rows. Within 180 days that is
-- 240k Vivid, 227k GoTickets, 61k AXS, 43k TickPick and 2k MLB events without an EVO id.
--
-- event_xmap is the cross-source spine: one row per event we know from any source, carrying every source's id for
-- it — tevo, TickPick, Vivid, GoTickets, AXS, SeatGeek, MLB schedule — each unique across the table. EVO is one
-- source among them: a cluster has a tevo_event_id when any member does, and none when none does. It is a side
-- table (no DDL on aq_event_map, which long cron transactions read around the clock); the hub stays the EVO-keyed
-- index the lanes resolve through, and this spine is where "the same event on five marketplaces" lives whether or
-- not EVO lists it. v_event_xmap shows a cluster with each source's name; v_event_xmap_coverage counts per source.
--
-- HOW event_xmap_tick(days, apply) CLUSTERS. Every source's upcoming rows are normalised into one working set:
-- a venue key (the paired TEvo venue id when the source's venue is paired — catalogue venue tables, AXS's own
-- tevo_venue_id, aq_venue_map / cross_source_venue_map for SeatGeek, mlb_venue_xref for parks, name + state for
-- GoTickets — else the lower-cased venue name + state), the local day (GoTickets publishes UTC only: converted in
-- the paired venue's zone from venue_timezone, else the state's usual zone), the start when the source knows it
-- (EVO-style placeholders T00:00 / T23:59 / T03:30 and TBA flags read as unknown), the name and the performers.
--   A. rows with an EVO id join the cluster keyed by that id (created from the EVO event when new); a source id that
--      sat in another cluster is moved (audited) — the catalogue mappers' verified match wins over a name pairing.
--   B. rows without an EVO id attach to a cluster of the same venue and local day that lacks their source when the
--      name fits (xmap_name_fits: equal normalised names, containment, every performer named, or a game read as
--      "A at B" / "A vs B" with both sides present) and exactly one cluster fits — or several fit and exactly one is
--      on the same start minute. Two rows of one source for one cluster: neither.
--   C. what is still loose seeds new clusters: in a venue + day bucket that holds two or more sources, the rows of
--      the most structured source present (MLB schedule > TickPick > Vivid > SeatGeek > GoTickets > AXS) each become
--      a cluster, and the other sources' rows attach by rule B. A bucket with one source seeds nothing: there is
--      nothing to map it to yet; it waits for a second source.
--   D. verification: a member whose row is gone, cancelled, or now on another day or venue is detached; a cluster
--      left with no EVO id and fewer than two members is deleted. Every attach, detach and delete is a row in
--      event_xmap_audit; each run a row in event_xmap_run.
-- One run at a time (an advisory lock; a second caller returns {skipped}). Nothing here writes to a catalogue table or the hub: a derived EVO link (a Vivid row in a cluster whose TickPick
-- row is mapped) is visible in the spine and is a candidate for a later, separately reviewed fill — not written back
-- by this migration. RULE 2: nothing upstream is called.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. tables ─────────────────────────
CREATE TABLE IF NOT EXISTS public.event_xmap (
  xmap_id         bigserial PRIMARY KEY,
  venue_key       text NOT NULL,                 -- 'tv:<tevo_venue_id>' or 'ns:<lower venue name>|<STATE>'
  local_day       date NOT NULL,
  tevo_venue_id   bigint,
  venue_name      text,
  venue_city      text,
  venue_state     text,
  name            text,                          -- the representative name: EVO's when known, else the seed's
  perfs           text[],
  start_local     timestamp,                     -- the representative start when any member knows it
  seed_source     text,                          -- evo | mlb | tickpick | vivid | sg | gotickets | axs
  tevo_event_id   bigint UNIQUE,
  tp_event_id     bigint UNIQUE,
  vivid_event_id  bigint UNIQUE,
  gt_event_id     bigint UNIQUE,
  axs_event_id    bigint UNIQUE,
  sg_event_id     bigint UNIQUE,
  mlb_schedule_id bigint UNIQUE,
  methods         jsonb NOT NULL DEFAULT '{}'::jsonb,   -- source -> evo | name | name_minute | seed
  sources         int GENERATED ALWAYS AS (
                    (tevo_event_id IS NOT NULL)::int + (tp_event_id IS NOT NULL)::int + (vivid_event_id IS NOT NULL)::int + (gt_event_id IS NOT NULL)::int
                  + (axs_event_id IS NOT NULL)::int + (sg_event_id IS NOT NULL)::int + (mlb_schedule_id IS NOT NULL)::int) STORED,
  first_seen_at   timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS event_xmap_bucket_idx ON public.event_xmap (venue_key, local_day);
CREATE INDEX IF NOT EXISTS event_xmap_day_idx ON public.event_xmap (local_day);
COMMENT ON TABLE public.event_xmap IS
  'The cross-source event spine (mig 20261117130000): one row per event known from any source, every source''s id for it (each unique), EVO one source among them. Kept by event_xmap_tick(); read through v_event_xmap. A side table — not the hub.';

CREATE TABLE IF NOT EXISTS public.event_xmap_audit (
  id         bigserial PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT now(),
  run_id     uuid NOT NULL,
  xmap_id    bigint,
  action     text NOT NULL,          -- cluster | attach | move | detach | delete
  source     text,
  source_id  bigint,
  note       text
);
CREATE INDEX IF NOT EXISTS event_xmap_audit_run_idx ON public.event_xmap_audit (run_id);
CREATE INDEX IF NOT EXISTS event_xmap_audit_xmap_idx ON public.event_xmap_audit (xmap_id);

CREATE TABLE IF NOT EXISTS public.event_xmap_run (
  run_id      uuid PRIMARY KEY,
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  days        int,
  applied     boolean,
  result      jsonb
);

DO $rls$   -- only when not yet set: an ALTER needs an exclusive lock, and this file may be re-applied while a run holds the tables
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['event_xmap', 'event_xmap_audit', 'event_xmap_run'] LOOP
    IF NOT (SELECT c.relrowsecurity FROM pg_class c WHERE c.oid = ('public.' || t)::regclass) THEN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
      EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
      EXECUTE format('GRANT SELECT ON public.%I TO service_role', t);
    END IF;
  END LOOP;
END
$rls$;

-- ───────────────────────── 2. helpers ─────────────────────────
-- the zone a state usually keeps, for a source that publishes UTC and a venue we have not paired
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

-- does one source's row name the same event as another's? equal normalised names, one containing the other,
-- every named performer of one side in the other's name, or a game read as "A at B" / "A vs B" with both sides present
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

-- ───────────────────────── 3. the tick ─────────────────────────
CREATE OR REPLACE FUNCTION public.event_xmap_tick(p_days integer DEFAULT 45, p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run   uuid := gen_random_uuid();
  v_out   jsonb := '{}'::jsonb;
  v_n     int;
  v_from  date := current_date - 1;
  v_to    date := current_date + coalesce(p_days, 45);
  v_srcs  constant text[] := ARRAY['mlb', 'tickpick', 'vivid', 'sg', 'gotickets', 'axs'];
  v_cols  constant text[] := ARRAY['mlb_schedule_id', 'tp_event_id', 'vivid_event_id', 'sg_event_id', 'gt_event_id', 'axs_event_id'];
  i       int;
BEGIN
  -- one run at a time: the hourly cron must not start while a nightly or a by-hand run is still clustering
  IF NOT pg_try_advisory_xact_lock(hashtext('event_xmap')) THEN
    RETURN jsonb_build_object('skipped', 'another event_xmap_tick is running');
  END IF;
  INSERT INTO public.event_xmap_run (run_id, days, applied) VALUES (v_run, p_days, p_apply);

  -- 0. the working set: every source's rows in the window, normalised
  DROP TABLE IF EXISTS _xm_tv;
  CREATE TEMP TABLE _xm_tv ON COMMIT DROP AS SELECT * FROM public.catalog_tevo_venues_by_name();
  CREATE INDEX ON _xm_tv (nm, st);

  DROP TABLE IF EXISTS _xm_ev;
  CREATE TEMP TABLE _xm_ev (
    src text, sid bigint, pri int, venue_key text, tevo_venue_id bigint, local_day date, start_local timestamp,
    name text, perfs text[], tevo_event_id bigint, venue_name text, city text, state text) ON COMMIT DROP;

  -- MLB schedule (games): venue through the park xref; the start MLB publishes unless TBD
  INSERT INTO _xm_ev
  SELECT 'mlb', g.schedule_id, 1, 'tv:' || x.tevo_venue_id, x.tevo_venue_id, g.game_date,
         CASE WHEN NOT coalesce(g.is_tbd, false) THEN g.game_time_local END,
         g.away_name || ' at ' || g.home_name, ARRAY[g.away_name, g.home_name], g.tevo_event_id, g.venue_name, g.venue_city, NULL
    FROM public.mlb_ticket_game g
    JOIN public.mlb_venue_xref x ON x.mlb_venue_id = g.venue_id AND x.tevo_venue_id IS NOT NULL
   WHERE g.removed_at IS NULL AND g.game_date BETWEEN v_from AND v_to AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL;

  -- TickPick
  INSERT INTO _xm_ev
  SELECT 'tickpick', c.tp_event_id, 2,
         CASE WHEN v.tevo_venue_id IS NOT NULL THEN 'tv:' || v.tevo_venue_id ELSE 'ns:' || lower(trim(v.name)) || '|' || upper(trim(coalesce(v.state, ''))) END,
         v.tevo_venue_id, c.event_date, CASE WHEN c.time_confirmed THEN c.event_local END,
         c.name, (SELECT array_agg(p->>'name') FROM jsonb_array_elements(coalesce(c.performers, '[]'::jsonb)) p WHERE coalesce(p->>'name', '') <> ''),
         c.tevo_event_id, v.name, v.city, v.state
    FROM public.tickpick_catalog_event c
    JOIN public.tickpick_catalog_venue v ON v.tp_venue_id = c.tp_venue_id
   WHERE c.date_confirmed AND c.status IS DISTINCT FROM 'canceled' AND c.merged_into IS NULL
     AND c.event_date BETWEEN v_from AND v_to AND coalesce(c.venue_country, 'US') IN ('US', 'CA', 'MX')
     AND coalesce(v.name, '') <> '';

  -- Vivid Seats
  INSERT INTO _xm_ev
  SELECT 'vivid', c.vivid_event_id, 3,
         CASE WHEN v.tevo_venue_id IS NOT NULL THEN 'tv:' || v.tevo_venue_id ELSE 'ns:' || lower(trim(v.name)) || '|' || upper(trim(coalesce(v.state, ''))) END,
         v.tevo_venue_id, c.event_date, CASE WHEN c.time_known THEN c.event_local END,
         c.name, (SELECT array_agg(coalesce(p->>'name', p#>>'{}')) FROM jsonb_array_elements(coalesce(c.performers, '[]'::jsonb)) p WHERE coalesce(p->>'name', p#>>'{}', '') <> ''),
         c.tevo_event_id, v.name, v.city, v.state
    FROM public.vivid_catalog_event c
    JOIN public.vivid_catalog_venue v ON v.vivid_venue_id = c.vivid_venue_id
   WHERE c.event_date BETWEEN v_from AND v_to AND coalesce(c.venue_country, 'US') IN ('US', 'CA', 'MX')
     AND coalesce(v.name, '') <> '';

  -- SeatGeek canonical: venue through aq_venue_map / cross_source_venue_map, else name + state
  INSERT INTO _xm_ev
  SELECT 'sg', s.sg_event_id, 4,
         CASE WHEN tv.tevo_venue_id IS NOT NULL THEN 'tv:' || tv.tevo_venue_id ELSE 'ns:' || lower(trim(s.sg_venue_name)) || '|' || upper(trim(coalesce(s.sg_venue_state, ''))) END,
         tv.tevo_venue_id, s.sg_event_date,
         CASE WHEN tz.iana_tz IS NOT NULL AND s.sg_datetime_utc IS NOT NULL THEN (s.sg_datetime_utc AT TIME ZONE tz.iana_tz)::timestamp END,
         s.sg_event_name, NULL, s.tevo_event_id, s.sg_venue_name, s.sg_venue_city, s.sg_venue_state
    FROM public.sg_events_canonical s
    LEFT JOIN LATERAL (
      SELECT m.tevo_venue_id FROM public.aq_venue_map m WHERE m.sg_venue_id = s.sg_venue_id AND m.tevo_venue_id IS NOT NULL
      UNION ALL
      SELECT c.tevo_venue_id FROM public.cross_source_venue_map c WHERE c.sg_venue_id = s.sg_venue_id AND c.tevo_venue_id IS NOT NULL
      LIMIT 1) tv ON true
    LEFT JOIN public.venue_timezone tz ON tz.tevo_venue_id = tv.tevo_venue_id
   WHERE s.sg_event_date BETWEEN v_from AND v_to AND coalesce(s.sg_venue_name, '') <> ''
     AND coalesce(s.sg_venue_country, 'US') IN ('US', 'CA', 'MX');

  -- GoTickets: no venue id and UTC only — venue by name + state, the local day in the venue's zone (else the state's)
  INSERT INTO _xm_ev
  SELECT 'gotickets', g.gt_event_id, 5,
         CASE WHEN t.tevo_venue_id IS NOT NULL THEN 'tv:' || t.tevo_venue_id ELSE 'ns:' || lower(trim(g.venue_name)) || '|' || upper(trim(coalesce(g.venue_state, ''))) END,
         t.tevo_venue_id,
         (g.event_time_utc AT TIME ZONE coalesce(tz.iana_tz, public.xmap_state_tz(g.venue_state, 'US')))::date,
         CASE WHEN to_char(g.event_time_utc AT TIME ZONE coalesce(tz.iana_tz, public.xmap_state_tz(g.venue_state, 'US')), 'HH24:MI') NOT IN ('00:00', '23:59', '03:30', '12:00')
              THEN (g.event_time_utc AT TIME ZONE coalesce(tz.iana_tz, public.xmap_state_tz(g.venue_state, 'US')))::timestamp END,
         g.name, CASE WHEN coalesce(g.performer, '') <> '' THEN ARRAY[g.performer] END, g.tevo_event_id, g.venue_name, g.venue_city, g.venue_state
    FROM public.gotickets_event g
    LEFT JOIN _xm_tv t ON t.nm = lower(trim(g.venue_name)) AND t.st = upper(trim(coalesce(g.venue_state, '')))
    LEFT JOIN public.venue_timezone tz ON tz.tevo_venue_id = t.tevo_venue_id
   WHERE coalesce(g.status, 'AS_SCHEDULED') IN ('AS_SCHEDULED', 'RESCHEDULED')
     AND g.event_time_utc BETWEEN (v_from::timestamp AT TIME ZONE 'UTC') - interval '1 day' AND (v_to::timestamp AT TIME ZONE 'UTC') + interval '1 day'
     AND coalesce(g.venue_name, '') <> '';
  DELETE FROM _xm_ev WHERE src = 'gotickets' AND (local_day < v_from OR local_day > v_to);

  -- AXS export: its own TEvo venue when matched, else name + state; local start text; TBA = unknown time
  INSERT INTO _xm_ev
  SELECT 'axs', a.axs_event_id, 6,
         CASE WHEN a.tevo_venue_id IS NOT NULL THEN 'tv:' || a.tevo_venue_id ELSE 'ns:' || lower(trim(a.venue_name)) || '|' || upper(trim(coalesce(a.venue_state, ''))) END,
         a.tevo_venue_id, left(a.event_date_local, 10)::date,
         CASE WHEN NOT coalesce(a.is_tba, false) AND a.event_date_local ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN left(a.event_date_local, 16)::timestamp END,
         coalesce(a.event_title_clean, a.event_title),
         CASE WHEN coalesce(cardinality(a.performers), 0) > 0 THEN a.performers WHEN coalesce(a.headliner, '') <> '' THEN ARRAY[a.headliner] END,
         a.tevo_event_id, a.venue_name, a.venue_city, a.venue_state
    FROM public.axs_export_event a
   WHERE a.gone_at IS NULL AND a.removed_utc IS NULL AND a.event_date_local ~ '^\d{4}-\d\d-\d\d'
     AND left(a.event_date_local, 10)::date BETWEEN v_from AND v_to
     AND coalesce(a.venue_name, '') <> '' AND coalesce(a.venue_country, 'US') IN ('US', 'CA', 'MX');

  DELETE FROM _xm_ev WHERE venue_key LIKE 'ns:%|' OR coalesce(name, '') = '';   -- no state: no usable venue key
  DELETE FROM _xm_ev WHERE lower(name) ~ '(parking|tailgate|package|shuttle|hospitality|\mvip\M|pre-?party|meet (and|&) greet|suites?\M)';   -- products sold around an event are not the event
  CREATE INDEX ON _xm_ev (venue_key, local_day);
  CREATE INDEX ON _xm_ev (src, sid);
  CREATE INDEX ON _xm_ev (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
  ANALYZE _xm_ev;
  v_out := v_out || jsonb_build_object('rows', (SELECT count(*) FROM _xm_ev),
             'rows_by_source', (SELECT jsonb_object_agg(src, n) FROM (SELECT src, count(*) n FROM _xm_ev GROUP BY 1) s),
             'rows_with_evo', (SELECT count(*) FROM _xm_ev WHERE tevo_event_id IS NOT NULL));

  -- D1. verification first: a member gone from its source, or now on another day or venue, leaves its cluster
  DROP TABLE IF EXISTS _xm_detach;
  CREATE TEMP TABLE _xm_detach (xmap_id bigint, src text, sid bigint, why text) ON COMMIT DROP;
  FOR i IN 1..6 LOOP
    EXECUTE format($q$
      INSERT INTO _xm_detach
      SELECT x.xmap_id, %1$L, x.%2$I,
             CASE WHEN e.sid IS NULL THEN 'row_gone'
                  WHEN e.local_day <> x.local_day THEN 'day_moved'
                  WHEN e.venue_key <> x.venue_key THEN 'venue_moved'
                  WHEN e.tevo_event_id IS NOT NULL AND x.tevo_event_id IS NOT NULL AND e.tevo_event_id <> x.tevo_event_id THEN 'evo_differs' END
        FROM public.event_xmap x
        LEFT JOIN _xm_ev e ON e.src = %1$L AND e.sid = x.%2$I
       WHERE x.%2$I IS NOT NULL AND x.local_day BETWEEN $1 AND $2
         AND (e.sid IS NULL OR e.local_day <> x.local_day OR e.venue_key <> x.venue_key
              OR (e.tevo_event_id IS NOT NULL AND x.tevo_event_id IS NOT NULL AND e.tevo_event_id <> x.tevo_event_id))$q$, v_srcs[i], v_cols[i])
    USING v_from, v_to;
  END LOOP;
  IF p_apply THEN
    FOR i IN 1..6 LOOP
      EXECUTE format($q$UPDATE public.event_xmap x SET %2$I = NULL, methods = x.methods - %1$L, updated_at = now()
                         FROM _xm_detach d WHERE d.src = %1$L AND d.xmap_id = x.xmap_id$q$, v_srcs[i], v_cols[i]);
    END LOOP;
    INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, source_id, note)
    SELECT v_run, d.xmap_id, 'detach', d.src, d.sid, d.why FROM _xm_detach d;
  END IF;
  v_out := v_out || jsonb_build_object('detached', (SELECT count(*) FROM _xm_detach));

  -- A. EVO-keyed clusters: every row with an EVO id belongs to the cluster of that id
  DROP TABLE IF EXISTS _xm_evo;
  CREATE TEMP TABLE _xm_evo ON COMMIT DROP AS
  SELECT e.tevo_event_id, ev.venue_id AS tevo_venue_id, left(ev.occurs_at_local, 10)::date AS local_day, ev.name, ev.primary_performer_name, ev.venue_name,
         CASE WHEN ev.occurs_at_local !~ 'T(00:00|23:59|03:30)' AND ev.occurs_at_local ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN left(ev.occurs_at_local, 16)::timestamp END AS start_local,
         min(e.venue_key) AS venue_key, min(e.city) AS city, min(e.state) AS state
    FROM _xm_ev e JOIN public.events ev ON ev.id = e.tevo_event_id
   WHERE e.tevo_event_id IS NOT NULL
   GROUP BY e.tevo_event_id, ev.venue_id, ev.occurs_at_local, ev.name, ev.primary_performer_name, ev.venue_name;
  IF p_apply THEN
    WITH ins AS (
      INSERT INTO public.event_xmap (venue_key, local_day, tevo_venue_id, venue_name, venue_city, venue_state, name, perfs, start_local, seed_source, tevo_event_id, methods)
      SELECT coalesce('tv:' || x.tevo_venue_id, x.venue_key), x.local_day, x.tevo_venue_id, x.venue_name, x.city, x.state, x.name,
             CASE WHEN x.primary_performer_name IS NOT NULL THEN ARRAY[x.primary_performer_name] END, x.start_local, 'evo', x.tevo_event_id, '{"evo": "evo"}'::jsonb
        FROM _xm_evo x
      ON CONFLICT (tevo_event_id) DO NOTHING
      RETURNING xmap_id, tevo_event_id)
    INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, source_id, note)
    SELECT v_run, ins.xmap_id, 'cluster', 'evo', ins.tevo_event_id, 'evo' FROM ins;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('evo_clusters_new', v_n);

    -- a source row mapped to an EVO event moves to that cluster (from wherever a name pairing had put it); one row per source per cluster
    FOR i IN 1..6 LOOP
      DROP TABLE IF EXISTS _xm_tgt;
      CREATE TEMP TABLE _xm_tgt (xmap_id bigint, sid bigint, n bigint) ON COMMIT DROP;
      EXECUTE format($q$
        WITH pick AS (
          SELECT e.tevo_event_id, min(e.sid) AS sid, count(*) AS n
            FROM _xm_ev e WHERE e.src = %1$L AND e.tevo_event_id IS NOT NULL GROUP BY e.tevo_event_id),
        tgt AS (
          SELECT x.xmap_id, p.sid, p.n FROM pick p JOIN public.event_xmap x ON x.tevo_event_id = p.tevo_event_id
           WHERE x.%2$I IS DISTINCT FROM p.sid)
        INSERT INTO _xm_tgt SELECT * FROM tgt$q$, v_srcs[i], v_cols[i]);
      EXECUTE format($q$
        WITH freed AS (
          UPDATE public.event_xmap o SET %2$I = NULL, methods = o.methods - %1$L, updated_at = now()
            FROM _xm_tgt t WHERE o.%2$I = t.sid AND o.xmap_id <> t.xmap_id
          RETURNING o.xmap_id, t.sid)
        INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, source_id, note)
        SELECT $1, f.xmap_id, 'move', %1$L, f.sid, 'to the EVO cluster' FROM freed f$q$, v_srcs[i], v_cols[i]) USING v_run;
      EXECUTE format($q$
        WITH moved AS (
          UPDATE public.event_xmap x SET %2$I = t.sid, methods = x.methods || jsonb_build_object(%1$L, 'evo'), updated_at = now()
            FROM _xm_tgt t WHERE x.xmap_id = t.xmap_id
          RETURNING x.xmap_id, t.sid, t.n)
        INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, source_id, note)
        SELECT $1, m.xmap_id, 'attach', %1$L, m.sid, CASE WHEN m.n > 1 THEN 'evo (' || m.n || ' rows share the EVO id; lowest kept)' ELSE 'evo' END FROM moved m$q$,
        v_srcs[i], v_cols[i]) USING v_run;
    END LOOP;
  END IF;

  -- A2. merge: a cluster without an EVO id whose bucket now holds an EVO cluster of the same event (one of its
  --     members was mapped and moved there) hands its other members over and goes
  IF p_apply THEN
    DROP TABLE IF EXISTS _xm_merge;
    CREATE TEMP TABLE _xm_merge ON COMMIT DROP AS
    WITH fit AS (
      SELECT x.xmap_id AS from_id, y.xmap_id AS to_id
        FROM public.event_xmap x
        JOIN public.event_xmap y ON y.venue_key = x.venue_key AND y.local_day = x.local_day AND y.tevo_event_id IS NOT NULL AND y.xmap_id <> x.xmap_id
       WHERE x.tevo_event_id IS NULL AND x.local_day BETWEEN v_from AND v_to
         AND NOT (x.start_local IS NOT NULL AND y.start_local IS NOT NULL AND abs(extract(epoch FROM x.start_local - y.start_local)) > 3600)
         AND public.xmap_name_fits(x.name, x.perfs, y.name, y.perfs)
         AND (x.mlb_schedule_id IS NULL OR y.mlb_schedule_id IS NULL) AND (x.tp_event_id IS NULL OR y.tp_event_id IS NULL)
         AND (x.vivid_event_id IS NULL OR y.vivid_event_id IS NULL) AND (x.gt_event_id IS NULL OR y.gt_event_id IS NULL)
         AND (x.axs_event_id IS NULL OR y.axs_event_id IS NULL) AND (x.sg_event_id IS NULL OR y.sg_event_id IS NULL))
    SELECT f.from_id, f.to_id FROM fit f
     WHERE NOT EXISTS (SELECT 1 FROM fit g WHERE g.from_id = f.from_id AND g.to_id <> f.to_id)
       AND NOT EXISTS (SELECT 1 FROM fit g WHERE g.to_id = f.to_id AND g.from_id <> f.from_id);
    DROP TABLE IF EXISTS _xm_merge_src;
    CREATE TEMP TABLE _xm_merge_src ON COMMIT DROP AS
    SELECT m.from_id, m.to_id, x.mlb_schedule_id, x.tp_event_id, x.vivid_event_id, x.sg_event_id, x.gt_event_id, x.axs_event_id
      FROM _xm_merge m JOIN public.event_xmap x ON x.xmap_id = m.from_id;
    FOR i IN 1..6 LOOP
      EXECUTE format($q$UPDATE public.event_xmap x SET %2$I = NULL FROM _xm_merge m WHERE x.xmap_id = m.from_id$q$, v_srcs[i], v_cols[i]);
      EXECUTE format($q$
        WITH mv AS (
          UPDATE public.event_xmap y SET %2$I = s.%2$I, methods = y.methods || jsonb_build_object(%1$L, 'merge'), updated_at = now()
            FROM _xm_merge_src s
           WHERE y.xmap_id = s.to_id AND s.%2$I IS NOT NULL AND y.%2$I IS NULL
          RETURNING y.xmap_id, s.%2$I AS sid)
        INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, source_id, note)
        SELECT $1, mv.xmap_id, 'move', %1$L, mv.sid, 'merged into the EVO cluster' FROM mv$q$, v_srcs[i], v_cols[i]) USING v_run;
    END LOOP;
    WITH del AS (DELETE FROM public.event_xmap x USING _xm_merge m WHERE x.xmap_id = m.from_id RETURNING x.xmap_id, x.seed_source, m.to_id)
    INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, note)
    SELECT v_run, d.xmap_id, 'delete', d.seed_source, 'merged into ' || d.to_id FROM del d;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('merged', v_n);
  END IF;

  -- B/C. the rows without an EVO id, not yet in a cluster
  --     (the members of the spine in the window, one indexed lookup per source — a six-way OR against event_xmap
  --      made the planner scan the spine once per loose row: 164k × 73k on the first prod pass, 2026-11-17 20:21Z)
  DROP TABLE IF EXISTS _xm_member;
  CREATE TEMP TABLE _xm_member (src text, sid bigint) ON COMMIT DROP;
  FOR i IN 1..6 LOOP
    EXECUTE format($q$INSERT INTO _xm_member SELECT %1$L, x.%2$I FROM public.event_xmap x WHERE x.%2$I IS NOT NULL AND x.local_day BETWEEN $1 - 2 AND $2 + 2$q$, v_srcs[i], v_cols[i])
    USING v_from, v_to;
  END LOOP;
  CREATE INDEX ON _xm_member (src, sid);
  ANALYZE _xm_member;
  DROP TABLE IF EXISTS _xm_loose;
  CREATE TEMP TABLE _xm_loose ON COMMIT DROP AS
  SELECT e.* FROM _xm_ev e
   WHERE e.tevo_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM _xm_member m WHERE m.src = e.src AND m.sid = e.sid);
  CREATE INDEX ON _xm_loose (venue_key, local_day);
  v_out := v_out || jsonb_build_object('loose', (SELECT count(*) FROM _xm_loose));

  -- a bucket is worth working only when two or more sources are in it (existing clusters count as a source)
  DROP TABLE IF EXISTS _xm_bucket;
  CREATE TEMP TABLE _xm_bucket ON COMMIT DROP AS
  SELECT l.venue_key, l.local_day
    FROM _xm_loose l
   GROUP BY 1, 2
  HAVING count(DISTINCT l.src) >= 2
      OR EXISTS (SELECT 1 FROM public.event_xmap x WHERE x.venue_key = l.venue_key AND x.local_day = l.local_day);
  CREATE INDEX ON _xm_bucket (venue_key, local_day);
  v_out := v_out || jsonb_build_object('buckets', (SELECT count(*) FROM _xm_bucket));

  -- the attach rule, as a temp view over the current state of event_xmap and _xm_loose
  DROP TABLE IF EXISTS _xm_attach;
  CREATE TEMP TABLE _xm_attach (src text, sid bigint, xmap_id bigint, method text) ON COMMIT DROP;

  -- round 1: attach to clusters that already exist (EVO-keyed or earlier seeds)
  INSERT INTO _xm_attach
  WITH fit AS (
    SELECT l.src, l.sid, x.xmap_id,
           (l.start_local IS NOT NULL AND x.start_local IS NOT NULL AND abs(extract(epoch FROM l.start_local - x.start_local)) <= 3600) AS same_hour,
           (l.start_local IS NOT NULL AND x.start_local IS NOT NULL AND abs(extract(epoch FROM l.start_local - x.start_local)) <= 60) AS same_minute
      FROM _xm_loose l
      JOIN _xm_bucket b ON b.venue_key = l.venue_key AND b.local_day = l.local_day
      JOIN public.event_xmap x ON x.venue_key = l.venue_key AND x.local_day = l.local_day
     WHERE CASE l.src WHEN 'mlb' THEN x.mlb_schedule_id WHEN 'tickpick' THEN x.tp_event_id WHEN 'vivid' THEN x.vivid_event_id
                      WHEN 'sg' THEN x.sg_event_id WHEN 'gotickets' THEN x.gt_event_id ELSE x.axs_event_id END IS NULL
       AND NOT (l.start_local IS NOT NULL AND x.start_local IS NOT NULL AND abs(extract(epoch FROM l.start_local - x.start_local)) > 3600)   -- known starts an hour apart: not the same performance
       AND public.xmap_name_fits(l.name, l.perfs, x.name, x.perfs)),
  per AS (
    SELECT f.src, f.sid, count(*) AS n, min(f.xmap_id) AS one,
           count(*) FILTER (WHERE f.same_minute) AS n_min, min(f.xmap_id) FILTER (WHERE f.same_minute) AS one_min
      FROM fit f GROUP BY f.src, f.sid),
  pick AS (
    SELECT p.src, p.sid, CASE WHEN p.n = 1 THEN p.one WHEN p.n_min = 1 THEN p.one_min END AS xmap_id,
           CASE WHEN p.n = 1 THEN 'name' WHEN p.n_min = 1 THEN 'name_minute' END AS method
      FROM per p)
  SELECT p.src, p.sid, p.xmap_id, p.method FROM pick p
   WHERE p.xmap_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.src = p.src AND q.xmap_id = p.xmap_id AND q.sid <> p.sid);   -- two rows of one source, one cluster: neither

  IF p_apply THEN
    FOR i IN 1..6 LOOP
      EXECUTE format($q$UPDATE public.event_xmap x SET %2$I = a.sid, methods = x.methods || jsonb_build_object(%1$L, a.method), updated_at = now(),
                             start_local = coalesce(x.start_local, l.start_local)
                        FROM _xm_attach a JOIN _xm_loose l ON l.src = a.src AND l.sid = a.sid
                       WHERE a.src = %1$L AND a.xmap_id = x.xmap_id AND x.%2$I IS NULL$q$, v_srcs[i], v_cols[i]);
    END LOOP;
    INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, source_id, note)
    SELECT v_run, a.xmap_id, 'attach', a.src, a.sid, a.method FROM _xm_attach a;
  END IF;
  v_out := v_out || jsonb_build_object('attached_existing', (SELECT count(*) FROM _xm_attach));
  DELETE FROM _xm_loose l USING _xm_attach a WHERE a.src = l.src AND a.sid = l.sid;
  TRUNCATE _xm_attach;

  -- C. seeds: in a bucket with two or more sources still loose, the rows of the most structured source present
  DROP TABLE IF EXISTS _xm_seed;
  CREATE TEMP TABLE _xm_seed ON COMMIT DROP AS
  SELECT l.*
    FROM _xm_loose l
    JOIN (SELECT venue_key, local_day, min(pri) AS pri FROM _xm_loose GROUP BY 1, 2 HAVING count(DISTINCT src) >= 2) b
      ON b.venue_key = l.venue_key AND b.local_day = l.local_day AND b.pri = l.pri;
  IF p_apply THEN
    FOR i IN 1..6 LOOP
      EXECUTE format($q$
        WITH ins AS (
          INSERT INTO public.event_xmap (venue_key, local_day, tevo_venue_id, venue_name, venue_city, venue_state, name, perfs, start_local, seed_source, %2$I, methods)
          SELECT s.venue_key, s.local_day, s.tevo_venue_id, s.venue_name, s.city, s.state, s.name, s.perfs, s.start_local, s.src, s.sid, jsonb_build_object(%1$L, 'seed')
            FROM _xm_seed s WHERE s.src = %1$L
          RETURNING xmap_id, %2$I AS sid)
        INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, source_id, note)
        SELECT $1, ins.xmap_id, 'cluster', %1$L, ins.sid, 'seed' FROM ins$q$, v_srcs[i], v_cols[i]) USING v_run;
    END LOOP;
  END IF;
  v_out := v_out || jsonb_build_object('seeded', (SELECT count(*) FROM _xm_seed), 'seeded_by_source', (SELECT coalesce(jsonb_object_agg(src, n), '{}') FROM (SELECT src, count(*) n FROM _xm_seed GROUP BY 1) s));
  DELETE FROM _xm_loose l USING _xm_seed s WHERE s.src = l.src AND s.sid = l.sid;

  -- round 2: the other sources attach to the fresh seeds (and anything else in the bucket)
  IF p_apply THEN
    INSERT INTO _xm_attach
    WITH fit AS (
      SELECT l.src, l.sid, x.xmap_id,
             (l.start_local IS NOT NULL AND x.start_local IS NOT NULL AND abs(extract(epoch FROM l.start_local - x.start_local)) <= 60) AS same_minute
        FROM _xm_loose l
        JOIN public.event_xmap x ON x.venue_key = l.venue_key AND x.local_day = l.local_day
       WHERE CASE l.src WHEN 'mlb' THEN x.mlb_schedule_id WHEN 'tickpick' THEN x.tp_event_id WHEN 'vivid' THEN x.vivid_event_id
                        WHEN 'sg' THEN x.sg_event_id WHEN 'gotickets' THEN x.gt_event_id ELSE x.axs_event_id END IS NULL
         AND NOT (l.start_local IS NOT NULL AND x.start_local IS NOT NULL AND abs(extract(epoch FROM l.start_local - x.start_local)) > 3600)
         AND public.xmap_name_fits(l.name, l.perfs, x.name, x.perfs)),
    per AS (
      SELECT f.src, f.sid, count(*) AS n, min(f.xmap_id) AS one,
             count(*) FILTER (WHERE f.same_minute) AS n_min, min(f.xmap_id) FILTER (WHERE f.same_minute) AS one_min
        FROM fit f GROUP BY f.src, f.sid),
    pick AS (
      SELECT p.src, p.sid, CASE WHEN p.n = 1 THEN p.one WHEN p.n_min = 1 THEN p.one_min END AS xmap_id,
             CASE WHEN p.n = 1 THEN 'name' WHEN p.n_min = 1 THEN 'name_minute' END AS method
        FROM per p)
    SELECT p.src, p.sid, p.xmap_id, p.method FROM pick p
     WHERE p.xmap_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.src = p.src AND q.xmap_id = p.xmap_id AND q.sid <> p.sid);
    FOR i IN 1..6 LOOP
      EXECUTE format($q$UPDATE public.event_xmap x SET %2$I = a.sid, methods = x.methods || jsonb_build_object(%1$L, a.method), updated_at = now(),
                             start_local = coalesce(x.start_local, l.start_local)
                        FROM _xm_attach a JOIN _xm_loose l ON l.src = a.src AND l.sid = a.sid
                       WHERE a.src = %1$L AND a.xmap_id = x.xmap_id AND x.%2$I IS NULL$q$, v_srcs[i], v_cols[i]);
    END LOOP;
    INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, source_id, note)
    SELECT v_run, a.xmap_id, 'attach', a.src, a.sid, a.method FROM _xm_attach a;
    v_out := v_out || jsonb_build_object('attached_seeds', (SELECT count(*) FROM _xm_attach));

    -- D2. a seed nobody joined, with no EVO id, is not a cross-map: it goes (it will be re-seeded when a second source appears)
    WITH del AS (
      DELETE FROM public.event_xmap x
       WHERE x.tevo_event_id IS NULL AND x.sources < 2 AND x.local_day BETWEEN v_from AND v_to
      RETURNING x.xmap_id, x.seed_source)
    INSERT INTO public.event_xmap_audit (run_id, xmap_id, action, source, note)
    SELECT v_run, d.xmap_id, 'delete', d.seed_source, 'single source' FROM del d;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('deleted_single', v_n);
  END IF;

  v_out := v_out || jsonb_build_object(
    'clusters_in_window', (SELECT count(*) FROM public.event_xmap WHERE local_day BETWEEN v_from AND v_to),
    'cross_mapped_without_evo', (SELECT count(*) FROM public.event_xmap WHERE local_day BETWEEN v_from AND v_to AND tevo_event_id IS NULL AND sources >= 2),
    'with_evo_and_others', (SELECT count(*) FROM public.event_xmap WHERE local_day BETWEEN v_from AND v_to AND tevo_event_id IS NOT NULL AND sources >= 2));
  UPDATE public.event_xmap_run SET finished_at = now(), result = v_out WHERE run_id = v_run;
  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply, 'window', jsonb_build_array(v_from, v_to)) || v_out;
END $function$;

-- ───────────────────────── 4. views ─────────────────────────
CREATE OR REPLACE VIEW public.v_event_xmap AS
SELECT x.xmap_id, x.local_day, x.start_local, x.name, x.venue_name, x.venue_city, x.venue_state, x.tevo_venue_id, x.sources, x.seed_source,
       x.tevo_event_id, e.name AS evo_name,
       x.tp_event_id, tp.name AS tickpick_name,
       x.vivid_event_id, vv.name AS vivid_name,
       x.gt_event_id, gt.name AS gotickets_name,
       x.axs_event_id, coalesce(ax.event_title_clean, ax.event_title) AS axs_name,
       x.sg_event_id, sg.sg_event_name AS seatgeek_name,
       x.mlb_schedule_id, CASE WHEN g.schedule_id IS NOT NULL THEN g.away_name || ' at ' || g.home_name END AS mlb_name,
       x.methods, x.updated_at
  FROM public.event_xmap x
  LEFT JOIN public.events e ON e.id = x.tevo_event_id
  LEFT JOIN public.tickpick_catalog_event tp ON tp.tp_event_id = x.tp_event_id
  LEFT JOIN public.vivid_catalog_event vv ON vv.vivid_event_id = x.vivid_event_id
  LEFT JOIN public.gotickets_event gt ON gt.gt_event_id = x.gt_event_id
  LEFT JOIN public.axs_export_event ax ON ax.axs_event_id = x.axs_event_id
  LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = x.sg_event_id
  LEFT JOIN public.mlb_ticket_game g ON g.schedule_id = x.mlb_schedule_id;

CREATE OR REPLACE VIEW public.v_event_xmap_coverage AS
SELECT s.source,
       count(*) FILTER (WHERE s.has) AS in_spine,
       count(*) FILTER (WHERE s.has AND x.tevo_event_id IS NOT NULL) AS with_evo,
       count(*) FILTER (WHERE s.has AND x.tevo_event_id IS NULL) AS without_evo_but_cross_mapped,
       count(*) FILTER (WHERE s.has AND x.sources >= 3) AS in_three_or_more_sources
  FROM public.event_xmap x
  CROSS JOIN LATERAL (VALUES ('tickpick', x.tp_event_id IS NOT NULL), ('vivid', x.vivid_event_id IS NOT NULL), ('gotickets', x.gt_event_id IS NOT NULL),
                             ('axs', x.axs_event_id IS NOT NULL), ('seatgeek', x.sg_event_id IS NOT NULL), ('mlb', x.mlb_schedule_id IS NOT NULL), ('evo', x.tevo_event_id IS NOT NULL)) s(source, has)
 WHERE x.local_day >= current_date
 GROUP BY s.source;

REVOKE ALL ON public.v_event_xmap, public.v_event_xmap_coverage FROM anon, authenticated;
GRANT SELECT ON public.v_event_xmap, public.v_event_xmap_coverage TO service_role;
REVOKE ALL ON FUNCTION public.event_xmap_tick(integer, boolean), public.xmap_name_fits(text, text[], text, text[]), public.xmap_state_tz(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.event_xmap_tick(integer, boolean), public.xmap_name_fits(text, text[], text, text[]), public.xmap_state_tz(text, text) TO service_role;

-- ───────────────────────── 5. crons ─────────────────────────
-- hourly at :47 (after the catalogue mappers at :41/:43, before the hub fills at :45 of the next hour) for the next
-- 45 days; the whole year once a night
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'event_xmap_hourly') THEN PERFORM cron.unschedule('event_xmap_hourly'); END IF;
  PERFORM cron.schedule('event_xmap_hourly', '47 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '300s'; SELECT public.event_xmap_tick(45, true); COMMIT;$j$);
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'event_xmap_daily') THEN PERFORM cron.unschedule('event_xmap_daily'); END IF;
  PERFORM cron.schedule('event_xmap_daily', '20 2 * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '900s'; SELECT public.event_xmap_tick(365, true); COMMIT;$j$);
END
$cron$;

COMMIT;

-- VERIFY:
--   SELECT public.event_xmap_tick(45, false);                     -- the working set and bucket counts, nothing written
--   SELECT public.event_xmap_tick(45, true);                      -- first pass (by hand: may exceed the 60 s tool window; the :47 cron has 300 s)
--   SELECT * FROM v_event_xmap_coverage ORDER BY 1;
--   SELECT * FROM v_event_xmap WHERE tevo_event_id IS NULL AND sources >= 3 ORDER BY local_day LIMIT 30;
--   SELECT action, source, count(*) FROM event_xmap_audit GROUP BY 1, 2 ORDER BY 1, 2;
