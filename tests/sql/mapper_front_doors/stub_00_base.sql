-- Stand-ins for what the mapper front doors migration reads and writes outside its own objects: the EVO mirror,
-- the hub, every catalogue with its venue table, the venue and performer stores, the venue resolver and the name
-- helpers (bodies as on prod), pg_cron and the cron policy table. Only the columns the migration reads; types
-- follow prod (events.occurs_at_local TEXT, aq_event_map.axs_event_id TEXT, tm / espn ids TEXT,
-- cross_source_venue_map.canonical_name and sources_count GENERATED).
-- tm_discovery_event, tm_venue_xref, tm_attraction_xref, espn_ticket_game and event_xref are NOT here: they exist
-- only on prod (PR #1156). The scenario creates them part-way to show the views picking them up.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;

CREATE TABLE public.events (id bigint PRIMARY KEY, name text, occurs_at_local text, state text, venue_id bigint, venue_name text,
                            venue_location text, primary_performer_id bigint, primary_performer_name text, performer_ids bigint[],
                            last_seen timestamptz);
CREATE TABLE public.aq_event_map (id bigserial PRIMARY KEY, aq_short_event_id text UNIQUE, event_name text, event_date timestamp, imported_at timestamptz,
                                  aq_source text, tevo_event_id bigint, sg_event_id bigint, sh_event_id bigint, vivid_event_id bigint, tm_event_id bigint,
                                  sd_event_id bigint, gotickets_event_id bigint, tp_event_id bigint, axs_event_id text);
CREATE TABLE public.aq_venue_map (venue_short_id text PRIMARY KEY, venue_name text, city text, state text, tevo_venue_id bigint UNIQUE,
                                  sg_venue_id bigint UNIQUE, tickpick_venue_id bigint UNIQUE, axs_venue_id bigint);
CREATE TABLE public.cross_source_venue_map (
  tevo_venue_id bigint PRIMARY KEY, tevo_venue_name text NOT NULL, tevo_venue_location text,
  canonical_name text GENERATED ALWAYS AS (lower(regexp_replace(tevo_venue_name, '[^a-z0-9]+', '', 'gi'))) STORED,
  city text, state text, country text, sg_aliases jsonb DEFAULT '[]', sg_venue_id bigint, tickpick_aliases jsonb DEFAULT '[]', tickpick_venue_id bigint,
  vivid_aliases jsonb DEFAULT '[]',
  sources_count int GENERATED ALWAYS AS (1 + (jsonb_array_length(coalesce(sg_aliases, '[]')) > 0)::int + (jsonb_array_length(coalesce(tickpick_aliases, '[]')) > 0)::int
                                           + (jsonb_array_length(coalesce(vivid_aliases, '[]')) > 0)::int) STORED,
  created_at timestamptz DEFAULT now(), updated_at timestamptz DEFAULT now(), gotickets_aliases jsonb NOT NULL DEFAULT '[]',
  id_provenance jsonb NOT NULL DEFAULT '{}', crm_aliases jsonb NOT NULL DEFAULT '[]', gotickets_venue_id bigint, venue_short_id text);

CREATE TABLE public.tickpick_catalog_event (tp_event_id bigint PRIMARY KEY, name text, event_date date, performers jsonb, last_seen_at timestamptz,
                                            tevo_event_id bigint, tevo_match_method text);
CREATE TABLE public.tickpick_catalog_venue (tp_venue_id bigint PRIMARY KEY, name text, city text, state text, tevo_venue_id bigint, method text);
CREATE TABLE public.vivid_catalog_event (vivid_event_id bigint PRIMARY KEY, name text, event_date date, performers jsonb, last_seen_at timestamptz,
                                         tevo_event_id bigint, tevo_match_method text);
CREATE TABLE public.vivid_catalog_venue (vivid_venue_id bigint PRIMARY KEY, name text, city text, state text, tevo_venue_id bigint, method text);
CREATE TABLE public.gotickets_event (gt_event_id bigint PRIMARY KEY, name text, event_time_utc timestamptz, tevo_event_id bigint, mapped_via text, updated_at timestamptz);
CREATE TABLE public.evo_gt_venue_link (tevo_venue_id bigint PRIMARY KEY, gt_venue_key text UNIQUE, gt_venue_name text, gt_venue_city text, gt_venue_state text, method text);
CREATE TABLE public.sg_events_canonical (sg_event_id bigint PRIMARY KEY, sg_event_name text, sg_event_date date, tevo_event_id bigint, match_method text, updated_at timestamptz);
CREATE TABLE public.axs_export_event (axs_event_id bigint PRIMARY KEY, event_title text, event_date_local text, venue_id bigint, venue_name text, venue_city text,
                                      venue_state text, last_seen_utc timestamptz, tevo_event_id bigint, tevo_venue_id bigint, match_method text, gone_at timestamptz);
CREATE TABLE public.mlb_ticket_game (schedule_id bigint PRIMARY KEY, home_name text, away_name text, venue_name text, game_date date, last_seen_at timestamptz,
                                     tevo_event_id bigint, tevo_match_method text);
CREATE TABLE public.mlb_venue_xref (mlb_venue_id int PRIMARY KEY, venue_name text, venue_city text, tevo_venue_id bigint, method text);
CREATE TABLE public.mlb_ticket_team (team_id int PRIMARY KEY, full_name text, tevo_performer_id bigint);

CREATE TABLE public.performer_metadata (performer_id bigint PRIMARY KEY, name text);
CREATE TABLE public.performer_external_ids (performer_id bigint NOT NULL, source text NOT NULL, external_id text NOT NULL, external_name text, league text,
                                            meta jsonb, set_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (performer_id, source));
CREATE UNIQUE INDEX pei_reverse_uniq ON public.performer_external_ids (source, external_id, coalesce(league, '__no_league__'));
CREATE TABLE public.aq_performer_map (performer_short_id text PRIMARY KEY, performer_name text, tevo_performer_id bigint, aliases text[]);
CREATE TABLE public.seatgeek_performer_xref (tevo_performer_id bigint, sg_performer_name text, match_method text);
CREATE TABLE public.performer_espn_team_xref (tevo_performer_id bigint, espn_team_id text, espn_league text, match_method text);
CREATE TABLE public.axs_event_performer_xref (axs_event_id text, axs_artist_id text, axs_performer text, tevo_performer_id bigint, match_method text);

-- name helpers, bodies as on prod (migs 20260911200000)
CREATE FUNCTION public.event_mapper_norm_name(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT trim(regexp_replace(
           lower(regexp_replace(regexp_replace(coalesce(p, ''), '\s*\([^)]*\)\s*', ' ', 'g'),
                                '[^a-z0-9 ]', ' ', 'gi')),
           '\s+', ' ', 'g')) $$;
CREATE FUNCTION public.event_mapper_overlap(p_needle_norm text, p_hay text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $fn$
  WITH t AS (SELECT DISTINCT tok FROM unnest(string_to_array(coalesce(p_needle_norm, ''), ' ')) tok WHERE length(tok) > 2),
       h AS (SELECT lower(regexp_replace(coalesce(p_hay, ''), '[^a-z0-9 ]', ' ', 'gi')) AS hay)
  SELECT round((SELECT count(*) FROM t, h WHERE h.hay ~ ('\m' || t.tok || '\M'))::numeric / NULLIF((SELECT count(*) FROM t), 0), 3);
$fn$;
-- the legacy similarity lookup: here, a prefix guess, so the scenario can tell it apart from an exact answer
CREATE FUNCTION public.event_mapper_performer_id(p_name text) RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT performer_id FROM public.performer_metadata WHERE lower(name) LIKE lower(left(trim(p_name), 5)) || '%' ORDER BY performer_id LIMIT 1 $$;
-- the resolver's identity stage, as far as the scenario needs it: the hub
CREATE FUNCTION public.event_mapper_identity(p_source text, p_source_event_id bigint) RETURNS TABLE(tevo_event_id bigint, method text) LANGUAGE sql STABLE AS $$
  SELECT p_source_event_id, 'identity_tevo'::text WHERE p_source IN ('tevo', 'evo')
  UNION ALL
  SELECT a.tevo_event_id, 'identity_hub'::text FROM public.aq_event_map a
   WHERE a.tevo_event_id IS NOT NULL
     AND ((p_source = 'tickpick' AND a.tp_event_id = p_source_event_id) OR (p_source = 'stubhub' AND a.sh_event_id = p_source_event_id)
       OR (p_source = 'seatdata' AND a.sd_event_id = p_source_event_id))
   LIMIT 1 $$;
-- the shared venue resolver, body as on prod (mig 20260908235500) without the state-code whitelist
CREATE FUNCTION public.cross_source_venue_resolve(p_venue_name text, p_city text DEFAULT NULL, p_state text DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE v_canonical text; v_id bigint; v_n integer; v_st text;
BEGIN
  IF p_venue_name IS NULL OR p_venue_name = '' THEN RETURN NULL; END IF;
  v_canonical := lower(regexp_replace(p_venue_name, '[^a-z0-9]+', '', 'gi'));
  v_st := upper(nullif(trim(coalesce(p_state, (regexp_match(p_venue_name, '[,-]\s*([A-Za-z]{2})\s*$'))[1])), ''));
  SELECT tevo_venue_id INTO v_id FROM public.cross_source_venue_map
   WHERE canonical_name = v_canonical AND (p_city IS NULL OR city IS NULL OR lower(city) = lower(p_city))
     AND (v_st IS NULL OR state IS NULL OR state !~ '^[A-Z]{2}$' OR upper(state) = v_st) LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  SELECT tevo_venue_id INTO v_id FROM public.cross_source_venue_map
   WHERE (sg_aliases ? p_venue_name OR tickpick_aliases ? p_venue_name OR vivid_aliases ? p_venue_name OR gotickets_aliases ? p_venue_name OR crm_aliases ? p_venue_name)
     AND (v_st IS NULL OR state IS NULL OR state !~ '^[A-Z]{2}$' OR upper(state) = v_st) LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  SELECT count(DISTINCT tevo_venue_id) INTO v_n FROM public.cross_source_venue_map
   WHERE (canonical_name LIKE v_canonical || '%' OR v_canonical LIKE canonical_name || '%')
     AND (v_st IS NULL OR state IS NULL OR state !~ '^[A-Z]{2}$' OR upper(state) = v_st);
  IF coalesce(v_n, 0) <> 1 THEN RETURN NULL; END IF;
  SELECT tevo_venue_id INTO v_id FROM public.cross_source_venue_map
   WHERE (canonical_name LIKE v_canonical || '%' OR v_canonical LIKE canonical_name || '%')
     AND (v_st IS NULL OR state IS NULL OR state !~ '^[A-Z]{2}$' OR upper(state) = v_st)
   ORDER BY length(canonical_name) DESC LIMIT 1;
  RETURN v_id;
END $$;

-- pg_cron + the policy gate's table
CREATE SCHEMA cron;
CREATE TABLE cron.job (jobid bigserial PRIMARY KEY, jobname text UNIQUE, schedule text, command text);
CREATE FUNCTION cron.schedule(name text, schedule text, command text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO cron.job (jobname, schedule, command) VALUES (name, schedule, command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = excluded.schedule, command = excluded.command RETURNING jobid $$;
CREATE FUNCTION cron.unschedule(name text) RETURNS boolean LANGUAGE sql AS $$ DELETE FROM cron.job WHERE jobname = name RETURNING true $$;
CREATE TABLE public.cron_policy (jobname text PRIMARY KEY, peak_hours_et int[] NOT NULL, peak_min_interval_min int NOT NULL, offpeak_min_interval_min int NOT NULL,
                                 work_check_sql text, daily_max_fires int, enabled boolean NOT NULL DEFAULT true, notes text, updated_at timestamptz NOT NULL DEFAULT now());
