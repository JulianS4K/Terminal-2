-- Migration 20261122210000 · level:data-collection · lane:A1 (data plane — mapping program; routed to this session by the operator) · writes:mapper_sync_run(new),mapper_sync_audit(new),mapper_source()(new),mapper_views_rebuild()(new),v_event_map(new view),v_venue_map(new view),v_venue_map_conflicts(new view),v_performer_map(new view),v_mapper_coverage(new view),event_map_lookup()(new),event_map_ids()(new),venue_map_resolve()(new),performer_map_resolve()(new),venue_map_sync()(new),performer_map_derive()(new),mapper_sync_tick()(new),cross_source_venue_map(rows + aliases + tickpick_venue_id, fill-only),performer_external_ids(rows for tickpick / vivid, insert-only),cron_policy,cron:mapper_sync_daily(new) · reads:events,aq_event_map,aq_venue_map,aq_performer_map,performer_metadata,seatgeek_performer_xref,performer_espn_team_xref,axs_event_performer_xref,mlb_ticket_team,mlb_ticket_game,mlb_venue_xref,tickpick_catalog_event,tickpick_catalog_venue,vivid_catalog_event,vivid_catalog_venue,gotickets_event,evo_gt_venue_link,sg_events_canonical,axs_export_event + when present: tm_discovery_event,tm_venue_xref,tm_attraction_xref,espn_ticket_game,event_xref,event_xmap · pre:20261117090000
-- ============================================================================
-- Migration 20261122210000 — one front door per mapper (event, venue, performer) across every source, and the stores feed each other
--
-- Lane:     A1 (data plane — mapping program)
-- Touches:  mapper_sync_run (W, new), mapper_sync_audit (W, new), cross_source_venue_map (W — new rows, aliases and
--           tickpick_venue_id, fill-only), performer_external_ids (W — insert-only rows for sources 'tickpick' and
--           'vivid'), cron_policy (W), cron.job (W — mapper_sync_daily); every catalogue, venue and performer store (R)
-- Pre-reqs: 20261117040000 / 20261117070000 (TickPick, Vivid catalogues + venue tables), 20261117000000 (MLB),
--           20261103090000 (AXS export), 20260915210000 (evo_gt_venue_link), 20260516240000 (cross_source_venue_map),
--           20260911200000 (event_mapper_norm_name / event_mapper_overlap), 20260515250000 (cron_policy gate).
--           No vault secret, no upstream call.
--
-- Operator 2026-11-22: "Consolidate all the mappers you found, event, performer, venue for each source available and
-- test, apply to main" — asked how deep: one front door per mapper plus sync; built on main with the prod-only pieces
-- (PR #1156: Ticketmaster, ESPN ticket links, the spine) switched on by their presence; merge and apply to prod.
-- Of the two syncs the performer one is switched on and the venue one ships as a report: see the measurements below.
--
-- WHAT WAS FOUND (prod, read-only, 2026-11-22).
--   EVENTS      nine matchers write event -> EVO links, each into its own table with its own method column; there is no
--               one place to ask "which EVO event is this listing" or "what is this EVO event's id on every source".
--   VENUES      pairings live in about thirteen tables. The shared resolver (the one that maps CRM orders, N2S items and
--               the GoTickets / SeatGeek catalogues) looks a venue up through cross_source_venue_resolve(), which reads
--               only cross_source_venue_map: 1,498 TEvo venues. The catalogue venue tables beside it pair 5,174 TEvo
--               venues (TickPick 4,540 venue ids, Vivid 7,761, Ticketmaster 2,823, GoTickets 3,560, AXS 3,061, MLB 109);
--               3,875 of those TEvo venues are not in cross_source_venue_map at all, so the resolver cannot use them.
--   PERFORMERS  pairings live in eight tables and five functions resolve an id. TickPick (14,357 distinct performer ids
--               in the next 60 days) and Vivid (29,746) are paired nowhere, though both catalogues carry the ids on
--               every event and ~70-85 k of their events are already matched to an EVO event that names its performers.
--
-- WHAT THIS ADDS. Nothing existing is changed: no matcher, no resolver, no schedule. Everything here is new.
--   THE FRONT DOORS — one per mapper, every source through the same call:
--     event_map_lookup(source, id)            which EVO event is this listing? (each source's own verified match first —
--                                             event_mapper_identity where it knows the source — then the source's
--                                             catalogue table; plus the internal event key where the spine exists)
--     event_map_ids(tevo_event_id)            this EVO event's id on every source, one row each
--     venue_map_resolve(source, id, name, city, state)   which TEvo venue? by the source's venue id across every store
--                                             (one answer or 'conflict'), then by name through cross_source_venue_resolve,
--                                             then by an equal name + state in any catalogue venue table (one or nothing)
--     performer_map_resolve(source, id, name, fuzzy)     which TEvo performer? by id across the stores, then by an exact
--                                             name; the similarity guess (event_mapper_performer_id) only when asked
--     v_event_map / v_venue_map / v_performer_map        every source's rows in one shape (source, source id, name, the
--                                             TEvo id, method, the table it came from); v_venue_map_conflicts = a source
--                                             venue id two stores pair to different TEvo venues; v_mapper_coverage =
--                                             per mapper and source, how many are mapped.
--     Sources: tickpick, vivid, gotickets, seatgeek, axs, mlb, stubhub, seatdata — and ticketmaster and espn where their
--     tables exist. mapper_views_rebuild() builds the views from the tables present, so they pick the prod-only tables
--     up on prod today and on a main-only database once PR #1156 lands (the daily job re-checks).
--   THE SYNC — the stores feed each other:
--     venue_map_sync(apply, limit)   copies catalogue venue pairings into cross_source_venue_map, the table the shared
--                                    resolver reads. A TEvo venue paired by a strong method in any catalogue, or by a
--                                    weak one in two, gets a row (name and location from the EVO mirror; the name key
--                                    is the table's own generated column) — unless that name is already taken in the
--                                    state, by the table or by any other venue the EVO mirror holds (then a name alone
--                                    cannot tell them apart: skipped, counted). The source's venue name becomes an alias (TickPick,
--                                    Vivid, GoTickets — from a strong pairing only; never a parking name, never a name
--                                    that would point two ways in one state) and TickPick's venue id is filled where the
--                                    pairing is strong and one-to-one. A source venue id two stores pair differently is
--                                    left out until it is settled (v_venue_map_conflicts).
--                                    Fill-only: nothing existing is overwritten.
--     performer_map_derive(apply)    learns TickPick and Vivid performer ids from events both sides already agree on:
--                                    the catalogue's lead performer (TickPick Headliner / Home Team, Vivid master) with
--                                    the EVO event's primary performer, and any catalogue performer whose name equals a
--                                    performer the EVO event lists. Judged as the SeatGeek deriver judges (four fifths
--                                    of the evidence on one performer, names overlapping, both directions unique), and
--                                    one event is enough only when the names are the same; two ids with equal evidence
--                                    for one performer: neither. Insert-only into
--                                    performer_external_ids (sources 'tickpick', 'vivid').
--     Both are dry runs unless apply is true, write an audit row per change (mapper_sync_audit) and a row per run
--     (mapper_sync_run). mapper_sync_tick(apply, venues) runs both; cron mapper_sync_daily at 10:52 UTC, gated by
--     cron_should_fire.
--
-- WHAT THE SAME LOGIC MEASURED ON PROD BEFORE ANYTHING WAS WRITTEN (read-only, 2026-11-22):
--   performer_map_derive   209,078 catalogue performer rows on matched events -> 200,188 evidence pairs -> about 14,000
--                          ids to learn (TickPick ~5,900 of 8,095 performers seen, Vivid ~8,300 of 9,725), under a
--                          minute. Declined: names that do not fit (687), evidence split between performers (368),
--                          one event with a different name (518), two ids for one performer (166). Two rules came out
--                          of reading the sample: a "... Parking" performer is not the act, and one event is enough
--                          only when the names are equal once normalised. SWITCHED ON: the daily job applies it.
--   venue_map_sync         18,890 pairings, 5,161 TEvo venues, 5,029 eligible, 1,291 already in the table: 3,738 new
--                          rows (3,531 of them agreed by two or more sources), none skipped for a taken name. BUT the
--                          unmapped rows the shared resolver is working on today name 184 distinct venues, the
--                          resolver already finds 172 of them, and the copy would newly resolve NONE: for today's
--                          backlog the venue is not what is missing. And the copy has a cost — cross_source_venue_resolve
--                          reads aliases and name prefixes by scanning the whole table (no index serves `?` or LIKE on
--                          either side), so 3.5 times the rows is 3.5 times the scan on every miss, inside mappers that
--                          already run near their statement ceilings on a disk-bound database. So it ships as a tool
--                          and a daily REPORT, NOT SWITCHED ON: mapper_sync_tick(true, true), or venue_map_sync(true),
--                          is the one call that turns it on once a source shows venue names the resolver misses.
--
-- RULE 2: nothing upstream is called. No DDL on any existing table.
-- Rollback: cron.unschedule('mapper_sync_daily'); DELETE FROM cron_policy WHERE jobname = 'mapper_sync_daily';
--   the sync's writes reverse from mapper_sync_audit (action 'venue_row' -> delete that cross_source_venue_map row;
--   'venue_alias' / 'venue_id' -> remove that alias / clear that id; 'performer_id' -> delete that
--   performer_external_ids row); DROP the five views, the eight functions and the two tables named above.
-- ============================================================================

-- ---------------------------------------------------------------------------------------------------------
-- 1. Run log and audit
-- ---------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.mapper_sync_run (
  run_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind        text        NOT NULL,            -- venue_map_sync | performer_map_derive | views
  applied     boolean     NOT NULL DEFAULT false,
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  ms          integer,
  result      jsonb
);
CREATE TABLE IF NOT EXISTS public.mapper_sync_audit (
  audit_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id     bigint      NOT NULL,
  at         timestamptz NOT NULL DEFAULT now(),
  action     text        NOT NULL,             -- venue_row | venue_alias | venue_id | performer_id
  source     text,
  source_id  text,
  tevo_id    bigint      NOT NULL,
  detail     jsonb
);
CREATE INDEX IF NOT EXISTS mapper_sync_audit_run_idx  ON public.mapper_sync_audit (run_id);
CREATE INDEX IF NOT EXISTS mapper_sync_audit_tevo_idx ON public.mapper_sync_audit (action, tevo_id);
ALTER TABLE public.mapper_sync_run   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mapper_sync_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mapper_sync_run, public.mapper_sync_audit FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.mapper_sync_run TO service_role;
GRANT SELECT, INSERT ON public.mapper_sync_audit TO service_role;
COMMENT ON TABLE public.mapper_sync_run IS
  'One row per run of venue_map_sync / performer_map_derive / mapper_views_rebuild: dry run or applied, duration, counts. Mig 20261122210000.';
COMMENT ON TABLE public.mapper_sync_audit IS
  'Every write the mapper sync makes: a venue row, alias or id added to cross_source_venue_map, a performer id added to performer_external_ids — by run, reversible from here. Mig 20261122210000.';

-- ---------------------------------------------------------------------------------------------------------
-- 2. Source names
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mapper_source(p_source text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE lower(regexp_replace(coalesce(p_source, ''), '[^A-Za-z]', '', 'g'))
           WHEN 'evo' THEN 'evo' WHEN 'tevo' THEN 'evo' WHEN 'ticketevolution' THEN 'evo'
           WHEN 'tickpick' THEN 'tickpick' WHEN 'tp' THEN 'tickpick'
           WHEN 'gotickets' THEN 'gotickets' WHEN 'gt' THEN 'gotickets'
           WHEN 'ticketmaster' THEN 'ticketmaster' WHEN 'tm' THEN 'ticketmaster'
           WHEN 'vivid' THEN 'vivid' WHEN 'vividseats' THEN 'vivid'
           WHEN 'seatgeek' THEN 'seatgeek' WHEN 'sg' THEN 'seatgeek'
           WHEN 'axs' THEN 'axs'
           WHEN 'stubhub' THEN 'stubhub' WHEN 'sh' THEN 'stubhub'
           WHEN 'seatdata' THEN 'seatdata' WHEN 'sd' THEN 'seatdata'
           WHEN 'mlb' THEN 'mlb'
           WHEN 'espn' THEN 'espn'
           WHEN 'ticketsdev' THEN 'tickets_dev' WHEN 'tdev' THEN 'tickets_dev'
         END
$function$;
COMMENT ON FUNCTION public.mapper_source(text) IS
  'A source name as the mapper front doors know it (evo | tickpick | gotickets | ticketmaster | vivid | seatgeek | axs | stubhub | seatdata | mlb | espn | tickets_dev), from the usual spellings and short forms; NULL when unknown. Mig 20261122210000.';

-- ---------------------------------------------------------------------------------------------------------
-- 3. The views, built from the tables that exist
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mapper_views_rebuild(p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  has_tm_ev   boolean := to_regclass('public.tm_discovery_event') IS NOT NULL;
  has_tm_ven  boolean := to_regclass('public.tm_venue_xref') IS NOT NULL;
  has_tm_att  boolean := to_regclass('public.tm_attraction_xref') IS NOT NULL;
  has_espn    boolean := to_regclass('public.espn_ticket_game') IS NOT NULL;
  has_xref    boolean := to_regclass('public.event_xref') IS NOT NULL;
  has_gt_link boolean := to_regclass('public.evo_gt_venue_link') IS NOT NULL;
  has_axs_pf  boolean := to_regclass('public.axs_event_performer_xref') IS NOT NULL;
  v_sig   text;
  v_old   text;
  ev      text;
  ven     text;
  perf    text;
BEGIN
  v_sig := format('tm_ev=%s tm_ven=%s tm_att=%s espn=%s xref=%s gt_link=%s axs_pf=%s',
                  has_tm_ev, has_tm_ven, has_tm_att, has_espn, has_xref, has_gt_link, has_axs_pf);
  IF to_regclass('public.v_mapper_coverage') IS NOT NULL THEN
    v_old := obj_description('public.v_mapper_coverage'::regclass, 'pg_class');
  END IF;
  IF NOT p_force AND v_old IS NOT NULL AND position('[' || v_sig || ']' IN v_old) > 0 THEN
    RETURN jsonb_build_object('rebuilt', false, 'sources', v_sig);
  END IF;

  -- ── events: one row per source listing ──
  ev := $q$
    SELECT 'tickpick'::text AS source, c.tp_event_id::text AS source_event_id, c.name, c.event_date AS event_day,
           c.tevo_event_id, c.tevo_match_method AS method, 'tickpick_catalog_event'::text AS origin, c.last_seen_at
      FROM public.tickpick_catalog_event c
    UNION ALL
    SELECT 'vivid', c.vivid_event_id::text, c.name, c.event_date, c.tevo_event_id, c.tevo_match_method, 'vivid_catalog_event', c.last_seen_at
      FROM public.vivid_catalog_event c
    UNION ALL
    SELECT 'gotickets', c.gt_event_id::text, c.name, (c.event_time_utc AT TIME ZONE 'UTC')::date, c.tevo_event_id, c.mapped_via, 'gotickets_event', c.updated_at
      FROM public.gotickets_event c
    UNION ALL
    SELECT 'seatgeek', c.sg_event_id::text, c.sg_event_name, c.sg_event_date, c.tevo_event_id, c.match_method, 'sg_events_canonical', c.updated_at
      FROM public.sg_events_canonical c
    UNION ALL
    SELECT 'axs', c.axs_event_id::text, c.event_title,
           CASE WHEN c.event_date_local ~ '^\d{4}-\d\d-\d\d' THEN left(c.event_date_local, 10)::date END,
           c.tevo_event_id, c.match_method, 'axs_export_event', c.last_seen_utc
      FROM public.axs_export_event c WHERE c.gone_at IS NULL
    UNION ALL
    SELECT 'mlb', c.schedule_id::text, c.away_name || ' at ' || c.home_name, c.game_date, c.tevo_event_id, c.tevo_match_method, 'mlb_ticket_game', c.last_seen_at
      FROM public.mlb_ticket_game c
    UNION ALL
    SELECT 'stubhub', a.sh_event_id::text, a.event_name, a.event_date::date, a.tevo_event_id, 'hub', 'aq_event_map', a.imported_at
      FROM public.aq_event_map a WHERE a.sh_event_id IS NOT NULL
    UNION ALL
    SELECT 'seatdata', a.sd_event_id::text, a.event_name, a.event_date::date, a.tevo_event_id, 'hub', 'aq_event_map', a.imported_at
      FROM public.aq_event_map a WHERE a.sd_event_id IS NOT NULL$q$;
  IF has_tm_ev THEN
    ev := ev || $q$
    UNION ALL
    SELECT 'ticketmaster', c.tm_event_id, c.name, c.local_date, c.tevo_event_id, c.tevo_match_method, 'tm_discovery_event', c.last_seen_at
      FROM public.tm_discovery_event c$q$;
  END IF;
  IF has_espn THEN
    ev := ev || $q$
    UNION ALL
    SELECT 'espn', c.espn_event_id, c.name, (c.game_at_utc AT TIME ZONE 'UTC')::date, c.tevo_event_id, c.tevo_match_method, 'espn_ticket_game', c.last_seen_at
      FROM public.espn_ticket_game c$q$;
  ELSIF has_xref THEN
    ev := ev || $q$
    UNION ALL
    SELECT 'espn', x.espn_event_id, NULL::text, NULL::date, x.tevo_event_id, x.match_method, 'event_xref', x.matched_at
      FROM public.event_xref x$q$;
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_event_map WITH (security_invoker = true) AS' || ev;

  -- ── venues: one row per source venue, per store that holds it ──
  ven := $q$
    SELECT 'tickpick'::text AS source, v.tp_venue_id::text AS source_venue_id, v.name AS venue_name, v.city, v.state,
           v.tevo_venue_id, v.method, 'tickpick_catalog_venue'::text AS origin
      FROM public.tickpick_catalog_venue v
    UNION ALL
    SELECT 'vivid', v.vivid_venue_id::text, v.name, v.city, v.state, v.tevo_venue_id, v.method, 'vivid_catalog_venue'
      FROM public.vivid_catalog_venue v
    UNION ALL
    SELECT 'mlb', v.mlb_venue_id::text, v.venue_name, v.venue_city, NULL::text, v.tevo_venue_id, v.method, 'mlb_venue_xref'
      FROM public.mlb_venue_xref v
    UNION ALL
    SELECT 'axs', x.venue_id::text, max(x.venue_name), max(x.venue_city), max(x.venue_state),
           CASE WHEN count(DISTINCT x.tevo_venue_id) = 1 THEN max(x.tevo_venue_id) END,
           CASE WHEN count(DISTINCT x.tevo_venue_id) = 1 THEN 'axs_export' WHEN count(DISTINCT x.tevo_venue_id) > 1 THEN 'conflict' END,
           'axs_export_event'
      FROM public.axs_export_event x WHERE x.venue_id IS NOT NULL AND x.gone_at IS NULL GROUP BY x.venue_id
    UNION ALL
    SELECT 'tickpick', m.tickpick_venue_id::text, m.tevo_venue_name, m.city, m.state, m.tevo_venue_id, 'id', 'cross_source_venue_map'
      FROM public.cross_source_venue_map m WHERE m.tickpick_venue_id IS NOT NULL
    UNION ALL
    SELECT 'seatgeek', m.sg_venue_id::text, m.tevo_venue_name, m.city, m.state, m.tevo_venue_id, 'id', 'cross_source_venue_map'
      FROM public.cross_source_venue_map m WHERE m.sg_venue_id IS NOT NULL
    UNION ALL
    SELECT 'gotickets', m.gotickets_venue_id::text, m.tevo_venue_name, m.city, m.state, m.tevo_venue_id, 'id', 'cross_source_venue_map'
      FROM public.cross_source_venue_map m WHERE m.gotickets_venue_id IS NOT NULL
    UNION ALL
    SELECT 'tickpick', a.tickpick_venue_id::text, a.venue_name, a.city, a.state, a.tevo_venue_id, 'id', 'aq_venue_map'
      FROM public.aq_venue_map a WHERE a.tickpick_venue_id IS NOT NULL
    UNION ALL
    SELECT 'seatgeek', a.sg_venue_id::text, a.venue_name, a.city, a.state, a.tevo_venue_id, 'id', 'aq_venue_map'
      FROM public.aq_venue_map a WHERE a.sg_venue_id IS NOT NULL$q$;
  IF has_gt_link THEN
    ven := ven || $q$
    UNION ALL
    SELECT 'gotickets', l.gt_venue_key, l.gt_venue_name, l.gt_venue_city, l.gt_venue_state, l.tevo_venue_id, l.method, 'evo_gt_venue_link'
      FROM public.evo_gt_venue_link l$q$;
  END IF;
  IF has_tm_ven THEN
    ven := ven || $q$
    UNION ALL
    SELECT 'ticketmaster', v.tm_venue_id, v.name, v.city, v.state, v.tevo_venue_id, v.method, 'tm_venue_xref'
      FROM public.tm_venue_xref v$q$;
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_venue_map WITH (security_invoker = true) AS' || ven;
  EXECUTE $q$CREATE OR REPLACE VIEW public.v_venue_map_conflicts WITH (security_invoker = true) AS
    SELECT m.source, m.source_venue_id, max(m.venue_name) AS venue_name, max(m.city) AS city, max(m.state) AS state,
           count(DISTINCT m.tevo_venue_id) AS tevo_venues,
           jsonb_agg(DISTINCT jsonb_build_object('tevo_venue_id', m.tevo_venue_id, 'origin', m.origin, 'method', m.method)) AS pairings
      FROM public.v_venue_map m
     WHERE m.tevo_venue_id IS NOT NULL AND m.source_venue_id IS NOT NULL
     GROUP BY m.source, m.source_venue_id
    HAVING count(DISTINCT m.tevo_venue_id) > 1$q$;

  -- ── performers: one row per source performer, per store that holds it ──
  perf := $q$
    SELECT x.source::text AS source, x.external_id::text AS source_performer_id, x.external_name AS performer_name,
           x.performer_id AS tevo_performer_id, coalesce(x.meta->>'derived_by', 'external_ids') AS method,
           'performer_external_ids'::text AS origin
      FROM public.performer_external_ids x
    UNION ALL
    SELECT 'seatgeek', NULL::text, s.sg_performer_name, s.tevo_performer_id, s.match_method, 'seatgeek_performer_xref'
      FROM public.seatgeek_performer_xref s
    UNION ALL
    SELECT 'espn', t.espn_league || ':' || t.espn_team_id, NULL::text, t.tevo_performer_id, t.match_method, 'performer_espn_team_xref'
      FROM public.performer_espn_team_xref t
    UNION ALL
    SELECT 'mlb', t.team_id::text, t.full_name, t.tevo_performer_id, 'team', 'mlb_ticket_team'
      FROM public.mlb_ticket_team t
    UNION ALL
    SELECT 'aq', a.performer_short_id, a.performer_name, a.tevo_performer_id, 'curated', 'aq_performer_map'
      FROM public.aq_performer_map a$q$;
  IF has_axs_pf THEN
    perf := perf || $q$
    UNION ALL
    SELECT 'axs', x.axs_artist_id::text, max(x.axs_performer), max(x.tevo_performer_id), max(x.match_method), 'axs_event_performer_xref'
      FROM public.axs_event_performer_xref x WHERE x.axs_artist_id IS NOT NULL GROUP BY x.axs_artist_id$q$;
  END IF;
  IF has_tm_att THEN
    perf := perf || $q$
    UNION ALL
    SELECT 'ticketmaster', t.tm_attraction_id, t.name, t.tevo_performer_id, t.method, 'tm_attraction_xref'
      FROM public.tm_attraction_xref t$q$;
  END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_performer_map WITH (security_invoker = true) AS' || perf;

  -- ── coverage: per mapper and source, how many are mapped (events: today on) ──
  EXECUTE $q$CREATE OR REPLACE VIEW public.v_mapper_coverage WITH (security_invoker = true) AS
    SELECT 'event'::text AS mapper, e.source, count(*) AS total, count(e.tevo_event_id) AS mapped,
           round(100.0 * count(e.tevo_event_id) / nullif(count(*), 0), 1) AS mapped_pct
      FROM public.v_event_map e WHERE e.event_day >= current_date GROUP BY e.source
    UNION ALL
    SELECT 'venue', v.source, count(DISTINCT v.source_venue_id), count(DISTINCT v.source_venue_id) FILTER (WHERE v.tevo_venue_id IS NOT NULL),
           round(100.0 * count(DISTINCT v.source_venue_id) FILTER (WHERE v.tevo_venue_id IS NOT NULL) / nullif(count(DISTINCT v.source_venue_id), 0), 1)
      FROM public.v_venue_map v WHERE v.source_venue_id IS NOT NULL GROUP BY v.source
    UNION ALL
    SELECT 'performer', p.source, count(*), count(p.tevo_performer_id),
           round(100.0 * count(p.tevo_performer_id) / nullif(count(*), 0), 1)
      FROM public.v_performer_map p GROUP BY p.source$q$;

  EXECUTE 'REVOKE ALL ON public.v_event_map, public.v_venue_map, public.v_venue_map_conflicts, public.v_performer_map, public.v_mapper_coverage FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT SELECT ON public.v_event_map, public.v_venue_map, public.v_venue_map_conflicts, public.v_performer_map, public.v_mapper_coverage TO service_role';
  EXECUTE format('COMMENT ON VIEW public.v_event_map IS %L',
    'Every source''s event listings in one shape: source, source_event_id, name, event_day (GoTickets and ESPN: the UTC day), the EVO event it is mapped to, the matcher''s method and the table it came from. Built by mapper_views_rebuild() from the tables present. Mig 20261122210000.');
  EXECUTE format('COMMENT ON VIEW public.v_venue_map IS %L',
    'Every source''s venues in one shape, one row per store that holds the venue: source, source_venue_id, name, city, state, the TEvo venue, method, origin table. v_venue_map_conflicts lists a source venue id that two stores pair to different TEvo venues. Mig 20261122210000.');
  EXECUTE format('COMMENT ON VIEW public.v_performer_map IS %L',
    'Every source''s performers in one shape, one row per store: source, source_performer_id (NULL where the store is keyed by name), name, the TEvo performer, method, origin table. Mig 20261122210000.');
  EXECUTE format('COMMENT ON VIEW public.v_mapper_coverage IS %L',
    'Per mapper (event | venue | performer) and source: total, mapped, mapped_pct. Events from today on. Reads every catalogue: seconds, not for a page load. [' || v_sig || '] Mig 20261122210000.');

  INSERT INTO public.mapper_sync_run (kind, applied, finished_at, ms, result)
  VALUES ('views', true, now(), 0, jsonb_build_object('sources', v_sig));
  RETURN jsonb_build_object('rebuilt', true, 'sources', v_sig);
END $function$;
COMMENT ON FUNCTION public.mapper_views_rebuild(boolean) IS
  'Builds v_event_map, v_venue_map, v_venue_map_conflicts, v_performer_map and v_mapper_coverage from the tables that exist (Ticketmaster, ESPN, the GoTickets venue link and the AXS performer table join when present). Does nothing when the set of tables is the one the views were last built for, unless forced. Mig 20261122210000.';

-- ---------------------------------------------------------------------------------------------------------
-- 4. Event front door
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_map_lookup(p_source text, p_source_event_id text)
 RETURNS TABLE(source text, source_event_id text, tevo_event_id bigint, method text, origin text, event_key bigint)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_src   text := public.mapper_source(p_source);
  v_id    text := nullif(trim(coalesce(p_source_event_id, '')), '');
  v_num   boolean;
  v_tevo  bigint;
  v_meth  text;
  v_orig  text;
  v_key   bigint;
  v_table text; v_idcol text; v_mcol text; v_text boolean := false;
BEGIN
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'event_map_lookup: unknown source % (evo | tickpick | vivid | gotickets | seatgeek | axs | mlb | ticketmaster | espn | stubhub | seatdata)', p_source;
  END IF;
  IF v_id IS NULL THEN RETURN; END IF;
  v_num := v_id ~ '^\d{1,18}$';

  -- 1. the resolver's identity stage: each source's own verified match first, the hub second (on prod, the spine last)
  IF v_num AND v_src IN ('evo', 'tickpick', 'vivid', 'gotickets', 'seatgeek', 'stubhub', 'seatdata', 'espn')
     AND to_regprocedure('public.event_mapper_identity(text,bigint)') IS NOT NULL THEN
    EXECUTE 'SELECT i.tevo_event_id, i.method FROM public.event_mapper_identity($1, $2) i LIMIT 1'
       INTO v_tevo, v_meth USING CASE v_src WHEN 'evo' THEN 'tevo' ELSE v_src END, v_id::bigint;
    IF v_tevo IS NOT NULL THEN v_orig := 'event_mapper_identity'; END IF;
  END IF;

  -- 2. the source's own catalogue table
  IF v_tevo IS NULL THEN
    IF    v_src = 'tickpick'     THEN v_table := 'tickpick_catalog_event'; v_idcol := 'tp_event_id';    v_mcol := 'tevo_match_method';
    ELSIF v_src = 'vivid'        THEN v_table := 'vivid_catalog_event';    v_idcol := 'vivid_event_id'; v_mcol := 'tevo_match_method';
    ELSIF v_src = 'gotickets'    THEN v_table := 'gotickets_event';        v_idcol := 'gt_event_id';    v_mcol := 'mapped_via';
    ELSIF v_src = 'seatgeek'     THEN v_table := 'sg_events_canonical';    v_idcol := 'sg_event_id';    v_mcol := 'match_method';
    ELSIF v_src = 'axs'          THEN v_table := 'axs_export_event';       v_idcol := 'axs_event_id';   v_mcol := 'match_method';
    ELSIF v_src = 'mlb'          THEN v_table := 'mlb_ticket_game';        v_idcol := 'schedule_id';    v_mcol := 'tevo_match_method';
    ELSIF v_src = 'ticketmaster' THEN v_table := 'tm_discovery_event';     v_idcol := 'tm_event_id';    v_mcol := 'tevo_match_method'; v_text := true;
    ELSIF v_src = 'espn'         THEN v_table := 'espn_ticket_game';       v_idcol := 'espn_event_id';  v_mcol := 'tevo_match_method'; v_text := true;
    END IF;
    IF v_table IS NOT NULL AND to_regclass('public.' || v_table) IS NOT NULL AND (v_text OR v_num) THEN
      EXECUTE format('SELECT c.tevo_event_id, c.%I FROM public.%I c WHERE c.%I = $1%s AND c.tevo_event_id IS NOT NULL LIMIT 1',
                     v_mcol, v_table, v_idcol, CASE WHEN v_text THEN '' ELSE '::bigint' END)
         INTO v_tevo, v_meth USING v_id;
      IF v_tevo IS NOT NULL THEN v_orig := v_table; END IF;
    END IF;
    IF v_tevo IS NULL AND v_src = 'espn' AND to_regclass('public.event_xref') IS NOT NULL THEN
      EXECUTE 'SELECT x.tevo_event_id, x.match_method FROM public.event_xref x WHERE x.espn_event_id = $1 LIMIT 1'
         INTO v_tevo, v_meth USING v_id;
      IF v_tevo IS NOT NULL THEN v_orig := 'event_xref'; END IF;
    END IF;
  END IF;

  -- 3. the internal event key, where the spine exists (an event EVO does not list still has one)
  IF v_src = 'ticketmaster' AND to_regprocedure('public.event_key_lookup_tm(text)') IS NOT NULL THEN
    EXECUTE 'SELECT public.event_key_lookup_tm($1)' INTO v_key USING v_id;
  ELSIF v_num AND v_src NOT IN ('stubhub', 'seatdata') AND to_regprocedure('public.event_key_lookup(text,bigint)') IS NOT NULL THEN
    EXECUTE 'SELECT public.event_key_lookup($1, $2)' INTO v_key USING CASE v_src WHEN 'evo' THEN 'tevo' ELSE v_src END, v_id::bigint;
  END IF;

  IF v_tevo IS NULL AND v_key IS NULL THEN RETURN; END IF;
  source := v_src; source_event_id := v_id; tevo_event_id := v_tevo; method := v_meth; origin := v_orig; event_key := v_key;
  RETURN NEXT;
END $function$;
COMMENT ON FUNCTION public.event_map_lookup(text, text) IS
  'The event mapper''s front door: which EVO event is this source listing? Any source (evo | tickpick | vivid | gotickets | seatgeek | axs | mlb | ticketmaster | espn | stubhub | seatdata), its own event id as text. Answers from event_mapper_identity where that knows the source (the source''s verified match, the hub, on prod the spine), else from the source''s catalogue table; event_key is the internal event key where the spine exists. No row when the listing is unknown or unmapped. Reads only. Mig 20261122210000.';

CREATE OR REPLACE FUNCTION public.event_map_ids(p_tevo_event_id bigint)
 RETURNS TABLE(source text, source_event_id text, name text, method text, origin text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r record;
BEGIN
  IF p_tevo_event_id IS NULL THEN RETURN; END IF;
  -- each source's catalogue rows that carry this EVO id (every one of these columns is indexed)
  FOR r IN
    SELECT * FROM (VALUES
      ('tickpick',     'tickpick_catalog_event', 'tp_event_id',    'name',          'tevo_match_method'),
      ('vivid',        'vivid_catalog_event',    'vivid_event_id', 'name',          'tevo_match_method'),
      ('gotickets',    'gotickets_event',        'gt_event_id',    'name',          'mapped_via'),
      ('seatgeek',     'sg_events_canonical',    'sg_event_id',    'sg_event_name', 'match_method'),
      ('axs',          'axs_export_event',       'axs_event_id',   'event_title',   'match_method'),
      ('mlb',          'mlb_ticket_game',        'schedule_id',    'venue_name',    'tevo_match_method'),
      ('ticketmaster', 'tm_discovery_event',     'tm_event_id',    'name',          'tevo_match_method'),
      ('espn',         'espn_ticket_game',       'espn_event_id',  'name',          'tevo_match_method')
    ) t(src, tbl, idcol, namecol, mcol)
  LOOP
    CONTINUE WHEN to_regclass('public.' || r.tbl) IS NULL;
    RETURN QUERY EXECUTE format(
      'SELECT %L::text, c.%I::text, %s, c.%I::text, %L::text FROM public.%I c WHERE c.tevo_event_id = $1 %s ORDER BY 2',
      r.src, r.idcol,
      CASE WHEN r.src = 'mlb' THEN 'c.away_name || '' at '' || c.home_name' ELSE format('c.%I::text', r.namecol) END,
      r.mcol, r.tbl, r.tbl,
      CASE WHEN r.src = 'axs' THEN 'AND c.gone_at IS NULL' ELSE '' END)
      USING p_tevo_event_id;
  END LOOP;
  IF to_regclass('public.espn_ticket_game') IS NULL AND to_regclass('public.event_xref') IS NOT NULL THEN
    RETURN QUERY EXECUTE
      'SELECT ''espn''::text, x.espn_event_id::text, NULL::text, x.match_method::text, ''event_xref''::text FROM public.event_xref x WHERE x.tevo_event_id = $1'
      USING p_tevo_event_id;
  END IF;
  -- the hub: ids no catalogue of ours carries (StubHub, SeatData), and any id a catalogue row above did not give
  RETURN QUERY
    SELECT h.src, h.id, h.event_name, 'hub'::text, 'aq_event_map'::text
      FROM (SELECT DISTINCT ON (u.src, u.id) u.src, u.id, a.event_name
              FROM public.aq_event_map a
              CROSS JOIN LATERAL (VALUES ('stubhub', a.sh_event_id::text), ('seatdata', a.sd_event_id::text),
                                         ('tickpick', a.tp_event_id::text), ('vivid', a.vivid_event_id::text),
                                         ('gotickets', a.gotickets_event_id::text), ('seatgeek', a.sg_event_id::text),
                                         ('axs', a.axs_event_id::text)) u(src, id)
             WHERE a.tevo_event_id = p_tevo_event_id AND u.id IS NOT NULL
             ORDER BY u.src, u.id) h
     WHERE h.src IN ('stubhub', 'seatdata')
        OR NOT EXISTS (SELECT 1 FROM public.v_event_map m
                        WHERE m.tevo_event_id = p_tevo_event_id AND m.source = h.src AND m.source_event_id = h.id);
END $function$;
COMMENT ON FUNCTION public.event_map_ids(bigint) IS
  'The event mapper''s front door, the other way: an EVO event''s id on every source, one row per source id, from each source''s catalogue table and the hub (StubHub and SeatData ids live only in the hub). Reads only. Mig 20261122210000.';

-- ---------------------------------------------------------------------------------------------------------
-- 5. Venue front door
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.venue_map_resolve(p_source text DEFAULT NULL, p_source_venue_id text DEFAULT NULL, p_name text DEFAULT NULL,
                                                    p_city text DEFAULT NULL, p_state text DEFAULT NULL)
 RETURNS TABLE(tevo_venue_id bigint, method text, origin text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_src  text := public.mapper_source(p_source);
  v_id   text := nullif(trim(coalesce(p_source_venue_id, '')), '');
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_n    int;
  v_tevo bigint;
  v_orig text;
BEGIN
  IF p_source IS NOT NULL AND v_src IS NULL THEN
    RAISE EXCEPTION 'venue_map_resolve: unknown source % (tickpick | vivid | gotickets | seatgeek | axs | mlb | ticketmaster)', p_source;
  END IF;

  -- 1. the source's own venue id, across every store that holds it: one answer, or a conflict
  IF v_src IS NOT NULL AND v_id IS NOT NULL THEN
    SELECT count(DISTINCT m.tevo_venue_id), max(m.tevo_venue_id), string_agg(DISTINCT m.origin, ', ' ORDER BY m.origin)
      INTO v_n, v_tevo, v_orig
      FROM public.v_venue_map m
     WHERE m.source = v_src AND m.source_venue_id = v_id AND m.tevo_venue_id IS NOT NULL;
    IF v_n = 1 THEN
      tevo_venue_id := v_tevo; method := 'id'; origin := v_orig; RETURN NEXT; RETURN;
    ELSIF v_n > 1 THEN
      tevo_venue_id := NULL; method := 'conflict'; origin := v_orig; RETURN NEXT; RETURN;
    END IF;
  END IF;

  IF v_name IS NULL THEN RETURN; END IF;

  -- 2. the name, the way the shared resolver reads it
  v_tevo := public.cross_source_venue_resolve(v_name, p_city, p_state);
  IF v_tevo IS NOT NULL THEN
    tevo_venue_id := v_tevo; method := 'name'; origin := 'cross_source_venue_map'; RETURN NEXT; RETURN;
  END IF;

  -- 3. an equal name in the same state in any source's venue table: one TEvo venue or nothing
  IF nullif(trim(coalesce(p_state, '')), '') IS NOT NULL THEN
    SELECT count(DISTINCT m.tevo_venue_id), max(m.tevo_venue_id), string_agg(DISTINCT m.origin, ', ' ORDER BY m.origin)
      INTO v_n, v_tevo, v_orig
      FROM public.v_venue_map m
     WHERE m.tevo_venue_id IS NOT NULL
       AND lower(trim(m.venue_name)) = lower(v_name)
       AND upper(trim(m.state)) = upper(trim(p_state))
       AND (p_city IS NULL OR m.city IS NULL OR lower(trim(m.city)) = lower(trim(p_city)));
    IF v_n = 1 THEN
      tevo_venue_id := v_tevo; method := 'catalogue_name'; origin := v_orig; RETURN NEXT; RETURN;
    END IF;
  END IF;
  RETURN;
END $function$;
COMMENT ON FUNCTION public.venue_map_resolve(text, text, text, text, text) IS
  'The venue mapper''s front door: which TEvo venue? By a source''s own venue id across every store (method id; conflict when two stores disagree), then by name through cross_source_venue_resolve (name), then by an equal name + state in any source''s venue table when exactly one TEvo venue carries it (catalogue_name). No row when nothing answers. Reads only. Mig 20261122210000.';

-- ---------------------------------------------------------------------------------------------------------
-- 6. Performer front door
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.performer_map_resolve(p_source text DEFAULT NULL, p_source_performer_id text DEFAULT NULL, p_name text DEFAULT NULL,
                                                        p_fuzzy boolean DEFAULT false)
 RETURNS TABLE(tevo_performer_id bigint, method text, origin text)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_src  text := public.mapper_source(p_source);
  v_id   text := nullif(trim(coalesce(p_source_performer_id, '')), '');
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_n    int;
  v_perf bigint;
  v_orig text;
BEGIN
  IF p_source IS NOT NULL AND v_src IS NULL THEN
    RAISE EXCEPTION 'performer_map_resolve: unknown source % (tickpick | vivid | gotickets | seatgeek | axs | mlb | ticketmaster | espn | tickets_dev)', p_source;
  END IF;

  -- 1. the source's own performer id, across every store: one answer, or a conflict
  IF v_src IS NOT NULL AND v_id IS NOT NULL THEN
    SELECT count(DISTINCT m.tevo_performer_id), max(m.tevo_performer_id), string_agg(DISTINCT m.origin, ', ' ORDER BY m.origin)
      INTO v_n, v_perf, v_orig
      FROM public.v_performer_map m
     WHERE m.source = v_src AND m.source_performer_id = v_id AND m.tevo_performer_id IS NOT NULL;
    IF v_n = 1 THEN
      tevo_performer_id := v_perf; method := 'id'; origin := v_orig; RETURN NEXT; RETURN;
    ELSIF v_n > 1 THEN
      tevo_performer_id := NULL; method := 'conflict'; origin := v_orig; RETURN NEXT; RETURN;
    END IF;
  END IF;

  IF v_name IS NULL THEN RETURN; END IF;

  -- 2. an exact name: the TEvo performer list, then every store's own names and aliases — one performer or nothing
  SELECT count(DISTINCT pm.performer_id), max(pm.performer_id) INTO v_n, v_perf
    FROM public.performer_metadata pm WHERE lower(trim(pm.name)) = lower(v_name);
  IF v_n = 1 THEN
    tevo_performer_id := v_perf; method := 'name'; origin := 'performer_metadata'; RETURN NEXT; RETURN;
  END IF;
  SELECT count(DISTINCT z.pid), max(z.pid), string_agg(DISTINCT z.orig, ', ' ORDER BY z.orig) INTO v_n, v_perf, v_orig
    FROM (SELECT m.tevo_performer_id AS pid, m.origin AS orig
            FROM public.v_performer_map m
           WHERE m.tevo_performer_id IS NOT NULL AND lower(trim(m.performer_name)) = lower(v_name)
          UNION ALL
          SELECT a.tevo_performer_id, 'aq_performer_map'
            FROM public.aq_performer_map a
           WHERE a.tevo_performer_id IS NOT NULL
             AND lower(v_name) = ANY (SELECT lower(trim(x)) FROM unnest(coalesce(a.aliases, '{}'::text[])) x)) z;
  IF v_n = 1 THEN
    tevo_performer_id := v_perf; method := 'name'; origin := v_orig; RETURN NEXT; RETURN;
  END IF;

  -- 3. only when asked: the similarity guess the legacy lookup makes
  IF coalesce(p_fuzzy, false) AND to_regprocedure('public.event_mapper_performer_id(text)') IS NOT NULL THEN
    EXECUTE 'SELECT public.event_mapper_performer_id($1)' INTO v_perf USING v_name;
    IF v_perf IS NOT NULL THEN
      tevo_performer_id := v_perf; method := 'fuzzy'; origin := 'event_mapper_performer_id'; RETURN NEXT; RETURN;
    END IF;
  END IF;
  RETURN;
END $function$;
COMMENT ON FUNCTION public.performer_map_resolve(text, text, text, boolean) IS
  'The performer mapper''s front door: which TEvo performer? By a source''s own performer id across every store (method id; conflict when stores disagree), then by an exact name in the TEvo performer list or any store''s names and aliases when exactly one performer carries it (name); the similarity guess of event_mapper_performer_id only when fuzzy is true (fuzzy). No row when nothing answers. Reads only. Mig 20261122210000.';

-- ---------------------------------------------------------------------------------------------------------
-- 7. Venue sync: catalogue pairings into the table the shared resolver reads
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.venue_map_sync(p_apply boolean DEFAULT false, p_limit integer DEFAULT 1000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run     bigint;
  v_t0      timestamptz := clock_timestamp();
  v_pairs   int; v_venues int; v_weak int; v_taken int; v_noname int;
  v_rows    int := 0; v_alias int := 0; v_ids int := 0; v_wait int := 0;
  v_res     jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('venue_map_sync')) THEN
    RETURN jsonb_build_object('skipped', 'another venue_map_sync is running');
  END IF;
  PERFORM set_config('statement_timeout', '240000', true);
  IF to_regclass('public.v_venue_map') IS NULL THEN PERFORM public.mapper_views_rebuild(true); END IF;

  -- every pairing a catalogue store holds; parking venues never (their own venue rows, not names to resolve)
  DROP TABLE IF EXISTS _vm_pairs;
  CREATE TEMP TABLE _vm_pairs ON COMMIT DROP AS
  SELECT m.source AS src, m.source_venue_id AS src_id, trim(m.venue_name) AS src_name, m.state AS src_state,
         m.tevo_venue_id AS tevo_id, m.method,
         -- strong: the pairing stands on its own. weak: it counts only when a second source names the same TEvo venue.
         (coalesce(m.method, '') IN ('manual', 'aq_venue_map', 'cross_source', 'name_state', 'pair_eq_city', 'pair_sibling',
                                     'norm_city', 'crosswalk_alias', 'sibling_catalog')
          OR m.source = 'mlb') AS strong
    FROM public.v_venue_map m
   WHERE m.tevo_venue_id IS NOT NULL AND m.source_venue_id IS NOT NULL
     AND m.origin NOT IN ('cross_source_venue_map', 'aq_venue_map')
     AND coalesce(m.method, '') NOT IN ('pair_parking', 'conflict', 'llm_judge')
     AND coalesce(m.venue_name, '') !~* 'parking'
     -- a source venue id that two stores pair to different TEvo venues is somebody's mistake: not copied until it is settled
     AND NOT EXISTS (SELECT 1 FROM public.v_venue_map_conflicts x WHERE x.source = m.source AND x.source_venue_id = m.source_venue_id);
  CREATE INDEX ON _vm_pairs (tevo_id);
  SELECT count(*), count(DISTINCT tevo_id) INTO v_pairs, v_venues FROM _vm_pairs;

  -- every venue name a source uses, paired or not, and every venue the EVO mirror holds: what a name could also mean
  DROP TABLE IF EXISTS _vm_names;
  CREATE TEMP TABLE _vm_names ON COMMIT DROP AS
  SELECT DISTINCT m.source AS src, lower(trim(m.venue_name)) AS lname, upper(nullif(trim(m.state), '')) AS state, m.tevo_venue_id AS tevo_id
    FROM public.v_venue_map m
   WHERE m.origin NOT IN ('cross_source_venue_map', 'aq_venue_map') AND coalesce(trim(m.venue_name), '') <> '';
  CREATE INDEX ON _vm_names (lname);
  DROP TABLE IF EXISTS _vm_evo;
  CREATE TEMP TABLE _vm_evo ON COMMIT DROP AS
  SELECT DISTINCT ON (e.venue_id) e.venue_id AS tevo_id, e.venue_name, e.venue_location,
         lower(regexp_replace(e.venue_name, '[^a-z0-9]+', '', 'gi')) AS canon,
         upper(nullif(trim(split_part(e.venue_location, ',', 2)), '')) AS state
    FROM public.events e
   WHERE e.venue_id IS NOT NULL AND e.venue_name IS NOT NULL
   ORDER BY e.venue_id, e.last_seen DESC NULLS LAST;
  CREATE INDEX ON _vm_evo (canon);
  CREATE INDEX ON _vm_evo (tevo_id);

  -- the TEvo venues worth a row: paired strongly somewhere, or weakly by two sources
  DROP TABLE IF EXISTS _vm_venue;
  CREATE TEMP TABLE _vm_venue ON COMMIT DROP AS
  SELECT p.tevo_id, bool_or(p.strong) AS strong, count(DISTINCT p.src) AS n_src,
         array_agg(DISTINCT p.src ORDER BY p.src) AS srcs
    FROM _vm_pairs p GROUP BY p.tevo_id;
  SELECT count(*) INTO v_weak FROM _vm_venue v WHERE NOT v.strong AND v.n_src < 2;
  DELETE FROM _vm_venue v WHERE NOT v.strong AND v.n_src < 2;

  -- NEW ROWS: a TEvo venue the table does not hold, named from the EVO mirror
  DROP TABLE IF EXISTS _vm_new;
  CREATE TEMP TABLE _vm_new ON COMMIT DROP AS
  SELECT v.tevo_id, v.n_src, v.srcs, e.venue_name AS tevo_name, e.venue_location AS tevo_location,
         nullif(trim(split_part(e.venue_location, ',', 1)), '') AS city,
         nullif(trim(split_part(e.venue_location, ',', 2)), '') AS state,
         lower(regexp_replace(e.venue_name, '[^a-z0-9]+', '', 'gi')) AS canon,
         NULL::text AS skip
    FROM _vm_venue v
    LEFT JOIN _vm_evo e ON e.tevo_id = v.tevo_id
   WHERE NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m WHERE m.tevo_venue_id = v.tevo_id);
  UPDATE _vm_new n SET skip = 'no_name' WHERE n.tevo_name IS NULL OR coalesce(n.canon, '') = '';
  -- a name already taken in the state — by the table, or by any other venue the EVO mirror holds, paired or not — cannot
  -- be told apart by name: it does not go in
  UPDATE _vm_new n SET skip = 'name_taken'
   WHERE n.skip IS NULL
     AND (EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                   WHERE m.canonical_name = n.canon
                     AND (m.state IS NULL OR n.state IS NULL OR upper(m.state) = upper(n.state)))
       OR EXISTS (SELECT 1 FROM _vm_evo o
                   WHERE o.tevo_id <> n.tevo_id AND o.canon = n.canon
                     AND (o.state IS NULL OR n.state IS NULL OR o.state = upper(n.state))));
  SELECT count(*) FILTER (WHERE skip = 'name_taken'), count(*) FILTER (WHERE skip = 'no_name') INTO v_taken, v_noname FROM _vm_new;
  DELETE FROM _vm_new WHERE skip IS NOT NULL;
  -- the most-corroborated venues first; the rest wait for the next run
  SELECT greatest(count(*) - greatest(coalesce(p_limit, 1000), 0), 0) INTO v_wait FROM _vm_new;
  DELETE FROM _vm_new n
   WHERE n.tevo_id IN (SELECT o.tevo_id FROM _vm_new o ORDER BY o.n_src DESC, o.tevo_id OFFSET greatest(coalesce(p_limit, 1000), 0));
  SELECT count(*) INTO v_rows FROM _vm_new;

  -- ALIASES: the source's own name for the venue, where the row exists (or is about to) and the name is not its key already
  DROP TABLE IF EXISTS _vm_alias;
  CREATE TEMP TABLE _vm_alias ON COMMIT DROP AS
  WITH tgt AS (
    SELECT m.tevo_venue_id AS tevo_id, m.canonical_name AS canon, m.state FROM public.cross_source_venue_map m
    UNION ALL
    SELECT n.tevo_id, n.canon, n.state FROM _vm_new n),
  cand AS (
    SELECT DISTINCT p.src, p.src_name AS alias, p.tevo_id, t.state
      FROM _vm_pairs p JOIN tgt t ON t.tevo_id = p.tevo_id
      JOIN _vm_venue v ON v.tevo_id = p.tevo_id
     WHERE p.src IN ('tickpick', 'vivid', 'gotickets')
       AND p.strong                       -- a weak pairing can help a venue earn its row; its name is not taken on as an alias
       AND coalesce(p.src_name, '') <> ''
       AND lower(regexp_replace(p.src_name, '[^a-z0-9]+', '', 'gi')) <> t.canon)
  SELECT c.src, c.alias, c.tevo_id, c.state
    FROM cand c
   WHERE -- the name means one venue only in that state: no source uses it for a venue paired elsewhere, or not paired at all…
         NOT EXISTS (SELECT 1 FROM _vm_names o
                      WHERE o.lname = lower(c.alias) AND o.tevo_id IS DISTINCT FROM c.tevo_id
                        AND (o.state IS NULL OR c.state IS NULL OR o.state = upper(c.state)))
         -- …it is not another venue's own name in that state (the name wins before any alias is read)…
     AND NOT EXISTS (SELECT 1 FROM _vm_evo t2
                      WHERE t2.tevo_id <> c.tevo_id AND t2.canon = lower(regexp_replace(c.alias, '[^a-z0-9]+', '', 'gi'))
                        AND (t2.state IS NULL OR c.state IS NULL OR t2.state = upper(c.state)))
         -- …and the table does not already resolve that string to another venue
     AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                      WHERE m.tevo_venue_id <> c.tevo_id
                        AND (m.state IS NULL OR c.state IS NULL OR upper(m.state) = upper(c.state))
                        AND (m.sg_aliases ? c.alias OR m.tickpick_aliases ? c.alias OR m.vivid_aliases ? c.alias
                             OR m.gotickets_aliases ? c.alias OR m.crm_aliases ? c.alias))
         -- …and not there already
     AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                      WHERE m.tevo_venue_id = c.tevo_id
                        AND CASE c.src WHEN 'tickpick' THEN m.tickpick_aliases ? c.alias
                                       WHEN 'vivid'    THEN m.vivid_aliases ? c.alias
                                       ELSE m.gotickets_aliases ? c.alias END);
  SELECT count(*) INTO v_alias FROM _vm_alias;

  -- TICKPICK VENUE ID: one TickPick venue, one TEvo venue, the slot empty and the id unused
  DROP TABLE IF EXISTS _vm_tpid;
  CREATE TEMP TABLE _vm_tpid ON COMMIT DROP AS
  SELECT p.tevo_id, min(p.src_id)::bigint AS tp_id
    FROM _vm_pairs p
   WHERE p.src = 'tickpick' AND p.strong AND p.src_id ~ '^\d{1,18}$'
     AND (EXISTS (SELECT 1 FROM public.cross_source_venue_map m WHERE m.tevo_venue_id = p.tevo_id AND m.tickpick_venue_id IS NULL)
          OR EXISTS (SELECT 1 FROM _vm_new n WHERE n.tevo_id = p.tevo_id))
     AND NOT EXISTS (SELECT 1 FROM _vm_pairs o WHERE o.src = 'tickpick' AND o.src_id = p.src_id AND o.tevo_id <> p.tevo_id)
     AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m WHERE m.tickpick_venue_id::text = p.src_id)
   GROUP BY p.tevo_id
  HAVING count(DISTINCT p.src_id) = 1;
  SELECT count(*) INTO v_ids FROM _vm_tpid;

  v_res := jsonb_build_object('applied', coalesce(p_apply, false), 'pairings_read', v_pairs, 'tevo_venues_paired', v_venues,
             'new_rows', v_rows, 'aliases', v_alias, 'tickpick_ids', v_ids,
             'waiting_for_next_run', v_wait, 'skipped_weak_single_source', v_weak,
             'skipped_name_taken_in_state', v_taken, 'skipped_no_evo_name', v_noname);

  IF coalesce(p_apply, false) THEN
    INSERT INTO public.mapper_sync_run (kind, applied) VALUES ('venue_map_sync', true) RETURNING run_id INTO v_run;

    INSERT INTO public.cross_source_venue_map (tevo_venue_id, tevo_venue_name, tevo_venue_location, city, state, country, id_provenance)
    SELECT n.tevo_id, n.tevo_name, n.tevo_location, n.city, n.state, 'US',
           jsonb_build_object('venue_map_sync', jsonb_build_object('run_id', v_run, 'sources', to_jsonb(n.srcs), 'at', now()))
      FROM _vm_new n
    ON CONFLICT (tevo_venue_id) DO NOTHING;
    INSERT INTO public.mapper_sync_audit (run_id, action, tevo_id, detail)
    SELECT v_run, 'venue_row', n.tevo_id, jsonb_build_object('name', n.tevo_name, 'location', n.tevo_location, 'sources', to_jsonb(n.srcs))
      FROM _vm_new n;

    UPDATE public.cross_source_venue_map m
       SET tickpick_aliases  = coalesce(m.tickpick_aliases, '[]'::jsonb)
                               || coalesce((SELECT jsonb_agg(a.alias ORDER BY a.alias) FROM _vm_alias a WHERE a.tevo_id = m.tevo_venue_id AND a.src = 'tickpick'), '[]'::jsonb),
           vivid_aliases     = coalesce(m.vivid_aliases, '[]'::jsonb)
                               || coalesce((SELECT jsonb_agg(a.alias ORDER BY a.alias) FROM _vm_alias a WHERE a.tevo_id = m.tevo_venue_id AND a.src = 'vivid'), '[]'::jsonb),
           gotickets_aliases = coalesce(m.gotickets_aliases, '[]'::jsonb)
                               || coalesce((SELECT jsonb_agg(a.alias ORDER BY a.alias) FROM _vm_alias a WHERE a.tevo_id = m.tevo_venue_id AND a.src = 'gotickets'), '[]'::jsonb),
           updated_at = now()
     WHERE m.tevo_venue_id IN (SELECT a.tevo_id FROM _vm_alias a);
    INSERT INTO public.mapper_sync_audit (run_id, action, source, source_id, tevo_id, detail)
    SELECT v_run, 'venue_alias', a.src, a.alias, a.tevo_id, jsonb_build_object('state', a.state) FROM _vm_alias a;

    UPDATE public.cross_source_venue_map m
       SET tickpick_venue_id = t.tp_id, updated_at = now(),
           id_provenance = coalesce(m.id_provenance, '{}'::jsonb)
                           || jsonb_build_object('tickpick', jsonb_build_object('method', 'venue_map_sync', 'run_id', v_run, 'derived_at', now()))
      FROM _vm_tpid t
     WHERE m.tevo_venue_id = t.tevo_id AND m.tickpick_venue_id IS NULL;
    INSERT INTO public.mapper_sync_audit (run_id, action, source, source_id, tevo_id)
    SELECT v_run, 'venue_id', 'tickpick', t.tp_id::text, t.tevo_id FROM _vm_tpid t;

    UPDATE public.mapper_sync_run SET finished_at = now(), result = v_res,
           ms = (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int
     WHERE run_id = v_run;
    v_res := v_res || jsonb_build_object('run_id', v_run);
  END IF;
  RETURN v_res;
END $function$;
COMMENT ON FUNCTION public.venue_map_sync(boolean, integer) IS
  'Copies the catalogue venue pairings (TickPick, Vivid, GoTickets link, AXS, MLB, Ticketmaster when present) into cross_source_venue_map, the table cross_source_venue_resolve — and so the shared event resolver — reads. A TEvo venue paired strongly in one catalogue or weakly in two gets a row unless its name is already taken in the state; source venue names become aliases where they point one way only; TickPick''s venue id is filled where one-to-one. Fill-only, audited in mapper_sync_audit, at most limit new rows a run. apply = false reports the counts and writes nothing. Mig 20261122210000.';

-- ---------------------------------------------------------------------------------------------------------
-- 8. Performer derive: TickPick and Vivid performer ids from events both sides already agree on
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.performer_map_derive(p_apply boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run  bigint;
  v_t0   timestamptz := clock_timestamp();
  v_res  jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('performer_map_derive')) THEN
    RETURN jsonb_build_object('skipped', 'another performer_map_derive is running');
  END IF;
  PERFORM set_config('statement_timeout', '240000', true);

  -- every catalogue performer on an event that is matched to an EVO event
  DROP TABLE IF EXISTS _pm_cat;
  CREATE TEMP TABLE _pm_cat ON COMMIT DROP AS
  SELECT z.*, public.event_mapper_norm_name(z.ext_name) AS nn
    FROM (SELECT 'tickpick'::text AS src, c.tp_event_id AS ev_id, c.tevo_event_id AS tevo_ev,
                 p->>'performer_id' AS ext_id, p->>'name' AS ext_name,
                 (p->>'role') IN ('Headliner', 'Home Team') AS lead
            FROM public.tickpick_catalog_event c
            CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(c.performers) = 'array' THEN c.performers ELSE '[]'::jsonb END) p
           WHERE c.tevo_event_id IS NOT NULL AND (p->>'performer_id') ~ '^\d{1,18}$' AND coalesce(p->>'name', '') <> ''
             AND (p->>'name') !~* 'parking'
          UNION ALL
          SELECT 'vivid', c.vivid_event_id, c.tevo_event_id, p->>'performerId', p->>'name', coalesce((p->>'master')::boolean, false)
            FROM public.vivid_catalog_event c
            CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(c.performers) = 'array' THEN c.performers ELSE '[]'::jsonb END) p
           WHERE c.tevo_event_id IS NOT NULL AND (p->>'performerId') ~ '^\d{1,18}$' AND coalesce(p->>'name', '') <> ''
             AND (p->>'name') !~* 'parking') z;      -- "Coachella Music Festival Parking" is a product, not the festival
  CREATE INDEX ON _pm_cat (tevo_ev);

  -- the performers each of those EVO events lists (its primary one flagged), read once per event
  DROP TABLE IF EXISTS _pm_evp;
  CREATE TEMP TABLE _pm_evp ON COMMIT DROP AS
  SELECT e.id AS tevo_ev, u.pid AS tevo_pid,
         coalesce(pm.name, CASE WHEN u.pid = e.primary_performer_id THEN e.primary_performer_name END) AS tevo_pname,
         public.event_mapper_norm_name(coalesce(pm.name, CASE WHEN u.pid = e.primary_performer_id THEN e.primary_performer_name END)) AS nn,
         (u.pid = e.primary_performer_id) AS is_primary
    FROM (SELECT DISTINCT tevo_ev FROM _pm_cat) d
    JOIN public.events e ON e.id = d.tevo_ev
    CROSS JOIN LATERAL (SELECT DISTINCT x AS pid
                          FROM unnest(coalesce(e.performer_ids, '{}'::bigint[]) || e.primary_performer_id) x
                         WHERE x IS NOT NULL) u
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = u.pid
   WHERE coalesce(pm.name, CASE WHEN u.pid = e.primary_performer_id THEN e.primary_performer_name END) IS NOT NULL;
  CREATE INDEX ON _pm_evp (tevo_ev);

  -- evidence, one row per (catalogue event, catalogue performer, TEvo performer):
  --   lead  the catalogue's lead performer with the EVO event's primary performer
  --   name  any catalogue performer whose name equals a performer the EVO event lists
  DROP TABLE IF EXISTS _pm_pairs;
  CREATE TEMP TABLE _pm_pairs ON COMMIT DROP AS
  SELECT DISTINCT c.src, c.ev_id, c.ext_id, c.ext_name, p.tevo_pid, p.tevo_pname
    FROM _pm_cat c JOIN _pm_evp p ON p.tevo_ev = c.tevo_ev
   WHERE (c.lead AND p.is_primary) OR (c.nn <> '' AND p.nn = c.nn);

  DROP TABLE IF EXISTS _pm_judged;
  CREATE TEMP TABLE _pm_judged ON COMMIT DROP AS
  WITH tally AS (
    SELECT src, ext_id, max(ext_name) AS ext_name, tevo_pid, max(tevo_pname) AS tevo_pname,
           count(*) AS n, sum(count(*)) OVER (PARTITION BY src, ext_id) AS tot,
           row_number() OVER (PARTITION BY src, ext_id ORDER BY count(*) DESC, tevo_pid) AS rk
      FROM _pm_pairs GROUP BY src, ext_id, tevo_pid),
  best AS (
    SELECT t.src, t.ext_id, t.ext_name, t.tevo_pid, t.tevo_pname, t.n,
           round(t.n::numeric / t.tot, 3) AS shr,
           -- the overlap counts words of three letters or more; a name with none ("U2") is judged on equality alone
           coalesce(round(public.event_mapper_overlap(public.event_mapper_norm_name(t.ext_name),
                                                      public.event_mapper_norm_name(t.tevo_pname)), 3),
                    CASE WHEN public.event_mapper_norm_name(t.ext_name) = public.event_mapper_norm_name(t.tevo_pname) THEN 1 ELSE 0 END) AS ovl
      FROM tally t WHERE t.rk = 1)
  SELECT b.src, b.ext_id, b.ext_name, b.tevo_pid, b.tevo_pname, b.n, b.shr, b.ovl,
         CASE WHEN b.shr < 0.8 THEN 'decline_split'
              WHEN b.ovl < 0.5 THEN 'decline_name'
              -- one event is enough only when the names are the same once normalised: every word of "Bill Cherry" is in
              -- "Bill Cherry's The Final Curtain - An Elvis Tribute", and that is not the same act
              WHEN b.n < 2 AND public.event_mapper_norm_name(b.ext_name) <> public.event_mapper_norm_name(b.tevo_pname) THEN 'decline_thin'
              -- both directions are unique (the table's keys): a slot taken by another id or another performer is a decline
              WHEN EXISTS (SELECT 1 FROM public.performer_external_ids x
                            WHERE x.performer_id = b.tevo_pid AND x.source = b.src AND x.external_id = b.ext_id) THEN 'already'
              WHEN EXISTS (SELECT 1 FROM public.performer_external_ids x
                            WHERE x.performer_id = b.tevo_pid AND x.source = b.src) THEN 'decline_taken'
              WHEN EXISTS (SELECT 1 FROM public.performer_external_ids x
                            WHERE x.source = b.src AND x.external_id = b.ext_id) THEN 'decline_reverse'
              ELSE 'write' END AS act
    FROM best b;
  -- two catalogue ids of one source wanting the same TEvo performer in this run (a performer holds one id per source):
  -- the one with strictly more behind it; on equal evidence neither
  DROP TABLE IF EXISTS _pm_rival;
  CREATE TEMP TABLE _pm_rival ON COMMIT DROP AS
  SELECT w.src, w.ext_id
    FROM (SELECT j.src, j.ext_id,
                 rank()   OVER (PARTITION BY j.src, j.tevo_pid ORDER BY j.n DESC, j.ovl DESC) AS rk,
                 count(*) OVER (PARTITION BY j.src, j.tevo_pid, j.n, j.ovl) AS ties
            FROM _pm_judged j WHERE j.act = 'write') w
   WHERE w.rk > 1 OR w.ties > 1;
  UPDATE _pm_judged j SET act = 'decline_rival'
    FROM _pm_rival r WHERE r.src = j.src AND r.ext_id = j.ext_id;

  SELECT jsonb_build_object('applied', coalesce(p_apply, false),
           'catalogue_performers_seen', (SELECT count(DISTINCT (src, ext_id)) FROM _pm_cat),
           'by_source', coalesce((SELECT jsonb_object_agg(z.src, z.acts)
                                    FROM (SELECT y.src, jsonb_object_agg(y.act, y.n) AS acts
                                            FROM (SELECT j.src, j.act, count(*) AS n FROM _pm_judged j GROUP BY 1, 2) y
                                           GROUP BY y.src) z), '{}'::jsonb))
    INTO v_res;

  IF coalesce(p_apply, false) THEN
    INSERT INTO public.mapper_sync_run (kind, applied) VALUES ('performer_map_derive', true) RETURNING run_id INTO v_run;
    WITH ins AS (
      INSERT INTO public.performer_external_ids (performer_id, source, external_id, external_name, meta, set_at)
      SELECT j.tevo_pid, j.src, j.ext_id, j.ext_name,
             jsonb_build_object('derived_by', 'performer_map_derive', 'run_id', v_run,
                                'evidence', j.n, 'share', j.shr, 'name_overlap', j.ovl), now()
        FROM _pm_judged j WHERE j.act = 'write'
      ON CONFLICT DO NOTHING
      RETURNING performer_id, source, external_id, external_name)
    INSERT INTO public.mapper_sync_audit (run_id, action, source, source_id, tevo_id, detail)
    SELECT v_run, 'performer_id', i.source, i.external_id, i.performer_id, jsonb_build_object('name', i.external_name) FROM ins i;
    v_res := v_res || jsonb_build_object('run_id', v_run,
               'written', (SELECT count(*) FROM public.mapper_sync_audit a WHERE a.run_id = v_run AND a.action = 'performer_id'));
    UPDATE public.mapper_sync_run SET finished_at = now(), result = v_res,
           ms = (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int
     WHERE run_id = v_run;
  END IF;
  RETURN v_res;
END $function$;
COMMENT ON FUNCTION public.performer_map_derive(boolean) IS
  'Learns TickPick and Vivid performer ids from catalogue events already matched to an EVO event: the catalogue''s lead performer (TickPick Headliner / Home Team, Vivid master) with the EVO event''s primary performer, and any catalogue performer whose name equals a performer the EVO event lists. Kept when four fifths of an id''s evidence names one TEvo performer, the names overlap (one event is enough only when they are the same) and neither side is already paired differently. Insert-only into performer_external_ids (sources tickpick, vivid), audited in mapper_sync_audit. apply = false reports the counts and writes nothing. Mig 20261122210000.';

-- ---------------------------------------------------------------------------------------------------------
-- 9. The daily pass
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mapper_sync_tick(p_apply boolean DEFAULT true, p_venues boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_views jsonb; v_venue jsonb; v_perf jsonb;
BEGIN
  -- each step in its own scope: one failing does not cost the others their day
  BEGIN v_views := public.mapper_views_rebuild(false);
  EXCEPTION WHEN OTHERS THEN v_views := jsonb_build_object('error', left(SQLERRM, 300)); END;
  -- the venue copy writes only when asked for (see the header: no measured gain yet, and a cost); otherwise it reports
  BEGIN v_venue := public.venue_map_sync(coalesce(p_apply, false) AND coalesce(p_venues, false), 1000);
  EXCEPTION WHEN OTHERS THEN v_venue := jsonb_build_object('error', left(SQLERRM, 300)); END;
  BEGIN v_perf := public.performer_map_derive(p_apply);
  EXCEPTION WHEN OTHERS THEN v_perf := jsonb_build_object('error', left(SQLERRM, 300)); END;
  INSERT INTO public.mapper_sync_run (kind, applied, finished_at, result)
  VALUES ('tick', coalesce(p_apply, false), now(), jsonb_build_object('views', v_views, 'venue_map_sync', v_venue, 'performer_map_derive', v_perf));
  RETURN jsonb_build_object('views', v_views, 'venue_map_sync', v_venue, 'performer_map_derive', v_perf);
END $function$;
COMMENT ON FUNCTION public.mapper_sync_tick(boolean, boolean) IS
  'The mapper sync''s daily pass: mapper_views_rebuild (only when the set of tables changed), performer_map_derive(apply), and venue_map_sync — as a report unless venues is true. Each in its own scope; the three results in one mapper_sync_run row (kind tick). Cron mapper_sync_daily 10:52 UTC calls (true, false). Mig 20261122210000.';

-- SECURITY DEFINER convention (PROJECT_BIBLE §2.8): the REVOKE is the enforcement
REVOKE EXECUTE ON FUNCTION public.mapper_source(text)                                    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mapper_views_rebuild(boolean)                          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.event_map_lookup(text, text)                           FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.event_map_ids(bigint)                                  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.venue_map_resolve(text, text, text, text, text)        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.performer_map_resolve(text, text, text, boolean)       FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.venue_map_sync(boolean, integer)                       FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.performer_map_derive(boolean)                          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mapper_sync_tick(boolean, boolean)                     FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mapper_source(text)                                    TO service_role;
GRANT  EXECUTE ON FUNCTION public.mapper_views_rebuild(boolean)                          TO service_role;
GRANT  EXECUTE ON FUNCTION public.event_map_lookup(text, text)                           TO service_role;
GRANT  EXECUTE ON FUNCTION public.event_map_ids(bigint)                                  TO service_role;
GRANT  EXECUTE ON FUNCTION public.venue_map_resolve(text, text, text, text, text)        TO service_role;
GRANT  EXECUTE ON FUNCTION public.performer_map_resolve(text, text, text, boolean)       TO service_role;
GRANT  EXECUTE ON FUNCTION public.venue_map_sync(boolean, integer)                       TO service_role;
GRANT  EXECUTE ON FUNCTION public.performer_map_derive(boolean)                          TO service_role;
GRANT  EXECUTE ON FUNCTION public.mapper_sync_tick(boolean, boolean)                     TO service_role;

-- the views, from what this database holds
SELECT public.mapper_views_rebuild(true);

-- the daily job, behind the policy gate
DO $cron$
BEGIN
  INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, enabled, notes)
  VALUES ('mapper_sync_daily', '{}'::int[], 1200, 1200, true,
          'TickPick / Vivid performer ids from matched events + a report of the venue pairings not yet in cross_source_venue_map (mapper_sync_tick), mig 20261122210000')
  ON CONFLICT (jobname) DO UPDATE SET enabled = true, notes = EXCLUDED.notes, updated_at = now();
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mapper_sync_daily') THEN
    PERFORM cron.unschedule('mapper_sync_daily');
  END IF;
  PERFORM cron.schedule('mapper_sync_daily', '52 10 * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '600s'; DO $b$ BEGIN IF NOT public.cron_should_fire('mapper_sync_daily') THEN RETURN; END IF; PERFORM public.mapper_sync_tick(true, false); END $b$; COMMIT;$j$);
END
$cron$;

-- VERIFY (after apply):
--   SELECT * FROM public.v_mapper_coverage ORDER BY 1, 2;
--   SELECT public.venue_map_sync(false);          -- dry run: what would be copied
--   SELECT public.performer_map_derive(false);    -- dry run: what would be learned
--   SELECT * FROM public.event_map_ids(3556879);
--   SELECT * FROM public.mapper_sync_run ORDER BY run_id DESC LIMIT 5;
