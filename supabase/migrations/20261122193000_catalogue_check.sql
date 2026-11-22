-- Migration 20261122193000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:catalogue_check_log(new),catalogue_check_source()(new),catalogue_check_stored()(new),catalogue_check_live()(new),catalogue_check()(new),catalogue_check_all()(new) · reads:events,aq_event_map,event_xref,tickpick_catalog_event,gotickets_event,vivid_catalog_event,vivid_catalog_sync,sg_events_canonical,axs_export_event,mlb_ticket_game,tm_discovery_event (when present),espn_ticket_game (when present) · pre:20261117040000,20261117070000
-- ============================================================================
-- Migration 20261122193000 — one call to check any marketplace's catalogue for one event
--
-- Lane:     A1 (data plane — mapping program)
-- Touches:  catalogue_check_log (W, new); events, aq_event_map, event_xref, tickpick_catalog_event,
--           gotickets_event, vivid_catalog_event, vivid_catalog_sync, sg_events_canonical, axs_export_event,
--           mlb_ticket_game, tm_discovery_event, espn_ticket_game (R); tm_discovery_quota (W — only through
--           the existing tm_discovery_call_allowed(), one count per Ticketmaster read)
-- Pre-reqs: 20261117040000 (TickPick catalogue), 20261117070000 (Vivid catalogue), 20260804230000 (GoTickets
--           catalogue), 20260509280000 (tevo_sign_get), 20260509080000 (get_app_secret). Vault: TEVO_API_TOKEN,
--           TEVO_SECRET, TICKPICK_API_TOKEN, GOTICKETS_ACCESS_ID, GOTICKETS_API_SECRET, 'TMR CLIENT ID' — the
--           ones the existing pulls already read. Hosts: api.ticketevolution.com, api.tickpick.com,
--           sc.gotickets.com, app.ticketmaster.com.
--
-- Operator 2026-11-22: "Each marketplace here should have a way to call for catalogue check" — and, asked what
-- the check should do: "Ticketmaster has a discovery feed we use, tickpick, vivid, gotickets, and evo all have
-- API for events". One database function, built on main, with the pieces that exist only on prod (the
-- Ticketmaster and ESPN tables of PR #1156) switched on by their presence.
--
-- WHAT WAS MISSING. Every catalogue is kept by a bulk pull on a timer (tickpick_catalog_pull pages a date window,
-- vivid_catalog_pull walks the whole catalogue, gt_catalog_sync reads a delta, tm_discovery_tick works a query
-- list, the EVO mirror is fed by the pollers). Nothing answers, for ONE event on ONE marketplace: is it in the
-- catalogue we hold, which EVO event is it mapped to, and does the marketplace itself still list it — now.
--
-- THE CALL.
--   catalogue_check(marketplace, source_event_id, tevo_event_id, live, min_interval) → jsonb
--     marketplace       evo | tickpick | gotickets | ticketmaster | vivid | seatgeek | axs | stubhub | seatdata |
--                       mlb | espn (the usual short forms too: tevo, tp, gt, tm, vividseats, sg, sh, sd).
--     source_event_id   the marketplace's own event id (text: Ticketmaster and ESPN ids are not numbers).
--     tevo_event_id     the EVO event id. Give either, or both. With only the EVO id, the marketplace's id is
--                       taken from its catalogue's own tevo_event_id, else from the hub (aq_event_map), else —
--                       ESPN — from event_xref.
--     live              default true: also ask the marketplace, where it can be asked for one event.
--   1. STORED. The catalogue row we hold (name, venue, start, status, last seen), its EVO mapping and the hub
--      row that carries the id. Read only.
--   2. LIVE — one GET of the marketplace's own single-event read, the request shape its existing pull or
--      client already sends (RULE 2: reads only; nothing here can write upstream):
--        evo           GET api.ticketevolution.com/v9/events/{id}             (signed, as tevo_venue_events_enqueue)
--        tickpick      GET api.tickpick.com/1.0/catalog/events/{id}           (Bearer, as tickpick_catalog_pull)
--        gotickets     GET sc.gotickets.com/rest/events/{id}                  (access id + secret, as gt_catalog_sync)
--        ticketmaster  GET app.ticketmaster.com/discovery/v2/events/{id}.json (the Discovery key; each read is
--                      counted against the day's Discovery budget through tm_discovery_call_allowed('discovery')
--                      and refused when that budget is spent)
--      Probed from prod 2026-11-22: all four answered 200 for a listed event; EVO, TickPick and Ticketmaster
--      answer 404 for an unknown id; GoTickets answered 429 on the second call inside a few seconds — a 429 is
--      reported as rate_limited, never as "not listed".
--      NOT ASKED LIVE, AND WHY — the answer is the stored catalogue, with its age:
--        vivid     the broker catalogue read returns whole pages and ignores every filter (RESOURCES_BIBLE §1);
--                  it cannot be asked for one event. The check reports when the last full pass finished.
--        seatgeek, axs   no single-event catalogue read is wired here (AXS arrives through the paid
--                  TicketsData export).
--        stubhub   the API is wired but switched off (operator 2026-11-13); we hold no catalogue, only the
--                  hub's id.   seatdata   paid per call; the hub's id only.
--        mlb, espn schedule feeds, kept whole by their own ticks.
--   3. VERDICT.
--        listed            the marketplace lists it and our catalogue row agrees
--        listed_changed    it lists it, and name / venue / start / status differ from our row (`differs`)
--        live_only         it lists it, our catalogue does not hold it yet (the next pull brings it)
--        gone_upstream     our catalogue holds it, the marketplace answers 404
--        not_listed        neither
--        in_catalogue / not_in_catalogue   stored answer only (live not asked, not possible, or it failed —
--                          see live.reason)
--        id_only / unknown_id   stubhub, seatdata: the hub carries the id, or not
--        no_id             asked by EVO id and we hold no id of that marketplace for the event
--        catalogue_not_installed   the marketplace's table is not in this database (Ticketmaster, ESPN before
--                          PR #1156)
--   The check WRITES NO CATALOGUE AND NO MAPPING: each catalogue table keeps its one writer (its pull), each
--   mapping its mapper. Its only write is one row per call in catalogue_check_log (rows older than 30 days are
--   dropped as it goes). A second live check of the same marketplace + id inside min_interval (60 s) is not sent
--   again; the stored answer is returned with the earlier live answer attached.
--
--   catalogue_check_all(tevo_event_id, live default false) → one row per marketplace for an EVO event.
--   catalogue_check_stored() / catalogue_check_live() are the two halves, callable on their own.
--
-- No cron, no change to any existing object. Scenario tests: tests/sql/catalogue_check (CI `Catalogue check SQL
-- scenarios`).
-- Rollback: DROP FUNCTION catalogue_check_all(bigint, boolean), catalogue_check(text, text, bigint, boolean, interval),
--   catalogue_check_live(text, text), catalogue_check_stored(text, text, bigint), catalogue_check_source(text);
--   DROP TABLE catalogue_check_log.
-- ============================================================================

-- ---------------------------------------------------------------------------------------------------------
-- 1. The log: one row per check
-- ---------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.catalogue_check_log (
  check_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  checked_at      timestamptz NOT NULL DEFAULT now(),
  marketplace     text        NOT NULL,
  source_event_id text,
  tevo_event_id   bigint,
  live_asked      boolean     NOT NULL DEFAULT false,
  http_status     integer,
  verdict         text        NOT NULL,
  ms              integer,
  result          jsonb       NOT NULL
);
CREATE INDEX IF NOT EXISTS catalogue_check_log_key_idx ON public.catalogue_check_log (marketplace, source_event_id, checked_at DESC);
CREATE INDEX IF NOT EXISTS catalogue_check_log_at_idx  ON public.catalogue_check_log (checked_at);
ALTER TABLE public.catalogue_check_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.catalogue_check_log FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.catalogue_check_log TO service_role;
COMMENT ON TABLE public.catalogue_check_log IS
  'One row per catalogue_check() call: marketplace, ids, whether the marketplace was asked, its HTTP status, the verdict and the whole answer. Kept 30 days by the function itself. Mig 20261122193000.';

-- ---------------------------------------------------------------------------------------------------------
-- 2. Marketplace names
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.catalogue_check_source(p_marketplace text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE lower(regexp_replace(coalesce(p_marketplace, ''), '[^A-Za-z]', '', 'g'))
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
         END
$function$;
COMMENT ON FUNCTION public.catalogue_check_source(text) IS
  'A marketplace name as catalogue_check() knows it (evo | tickpick | gotickets | ticketmaster | vivid | seatgeek | axs | stubhub | seatdata | mlb | espn), from the usual spellings and short forms; NULL when unknown. Mig 20261122193000.';

-- ---------------------------------------------------------------------------------------------------------
-- 3. The stored half: the catalogue row we hold, its EVO mapping, the hub row
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.catalogue_check_stored(p_marketplace text, p_source_event_id text DEFAULT NULL, p_tevo_event_id bigint DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_src     text := public.catalogue_check_source(p_marketplace);
  v_id      text := nullif(trim(coalesce(p_source_event_id, '')), '');
  v_from    text;
  v_fmt     constant text := 'YYYY-MM-DD"T"HH24:MI';
  v_table   text;      -- the catalogue table (NULL: we hold no catalogue of this marketplace)
  v_idcol   text;      -- its id column
  v_seen    text;      -- its last-seen column
  v_numeric boolean := true;   -- the id is a bigint
  v_hubcol  text;      -- the hub column that carries this marketplace's id (NULL: none)
  v_hubnum  boolean := true;
  v_sel     text;      -- the row, as jsonb, alias c
  v_here    boolean;
  v_row     jsonb;
  v_hub     jsonb;
  v_n       int := 0;
  v_note    text;
BEGIN
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'catalogue_check: unknown marketplace % (evo | tickpick | gotickets | ticketmaster | vivid | seatgeek | axs | stubhub | seatdata | mlb | espn)', p_marketplace;
  END IF;
  v_from := CASE WHEN v_id IS NOT NULL THEN 'given' END;

  IF v_src = 'evo' THEN
    v_table := 'events'; v_idcol := 'id'; v_seen := 'last_seen'; v_hubcol := 'tevo_event_id';
    v_sel := $q$jsonb_build_object('name', c.name, 'venue', c.venue_name,
               'city', nullif(trim(split_part(c.venue_location, ',', 1)), ''), 'state', nullif(trim(split_part(c.venue_location, ',', 2)), ''),
               'start_local', left(c.occurs_at_local, 16), 'status', c.state, 'last_seen_at', c.last_seen,
               'tevo_event_id', c.id, 'tevo_match_method', 'identity')$q$;
  ELSIF v_src = 'tickpick' THEN
    v_table := 'tickpick_catalog_event'; v_idcol := 'tp_event_id'; v_seen := 'last_seen_at'; v_hubcol := 'tp_event_id';
    v_sel := format($q$jsonb_build_object('name', c.name, 'venue', c.venue_name, 'city', c.venue_city, 'state', c.venue_state,
               'start_local', to_char(c.event_local, %1$L), 'start_utc', to_char(c.event_utc AT TIME ZONE 'UTC', %1$L),
               'status', c.status, 'merged_into', c.merged_into, 'last_seen_at', c.last_seen_at,
               'tevo_event_id', c.tevo_event_id, 'tevo_match_method', c.tevo_match_method)$q$, v_fmt);
  ELSIF v_src = 'gotickets' THEN
    v_table := 'gotickets_event'; v_idcol := 'gt_event_id'; v_seen := 'updated_at'; v_hubcol := 'gotickets_event_id';
    v_sel := format($q$jsonb_build_object('name', c.name, 'venue', c.venue_name, 'city', c.venue_city, 'state', c.venue_state,
               'start_utc', to_char(c.event_time_utc AT TIME ZONE 'UTC', %1$L), 'status', c.status, 'last_seen_at', c.updated_at,
               'tevo_event_id', c.tevo_event_id, 'tevo_match_method', c.mapped_via)$q$, v_fmt);
  ELSIF v_src = 'ticketmaster' THEN
    -- the hub's tm_event_id is a number from another Ticketmaster id system, not the Discovery id: not used here
    v_table := 'tm_discovery_event'; v_idcol := 'tm_event_id'; v_seen := 'last_seen_at'; v_numeric := false;
    v_sel := format($q$jsonb_build_object('name', c.name, 'venue', c.venue_name, 'city', c.venue_city, 'state', c.venue_state,
               'start_local', to_char(c.local_date, 'YYYY-MM-DD') || coalesce('T' || to_char(c.local_time, 'HH24:MI'), ''),
               'start_utc', to_char(c.start_utc AT TIME ZONE 'UTC', %1$L), 'status', c.status_code, 'last_seen_at', c.last_seen_at,
               'tevo_event_id', c.tevo_event_id, 'tevo_match_method', c.tevo_match_method)$q$, v_fmt);
  ELSIF v_src = 'vivid' THEN
    v_table := 'vivid_catalog_event'; v_idcol := 'vivid_event_id'; v_seen := 'last_seen_at'; v_hubcol := 'vivid_event_id';
    v_sel := format($q$jsonb_build_object('name', c.name, 'venue', c.venue_name, 'city', c.venue_city, 'state', c.venue_state,
               'start_local', to_char(c.event_local, %1$L), 'last_seen_at', c.last_seen_at,
               'tevo_event_id', c.tevo_event_id, 'tevo_match_method', c.tevo_match_method)$q$, v_fmt);
  ELSIF v_src = 'seatgeek' THEN
    v_table := 'sg_events_canonical'; v_idcol := 'sg_event_id'; v_seen := 'updated_at'; v_hubcol := 'sg_event_id';
    v_sel := format($q$jsonb_build_object('name', c.sg_event_name, 'venue', c.sg_venue_name, 'city', c.sg_venue_city, 'state', c.sg_venue_state,
               'start_utc', to_char(c.sg_datetime_utc AT TIME ZONE 'UTC', %1$L), 'start_date', c.sg_event_date, 'last_seen_at', c.updated_at,
               'tevo_event_id', c.tevo_event_id, 'tevo_match_method', c.match_method)$q$, v_fmt);
  ELSIF v_src = 'axs' THEN
    v_table := 'axs_export_event'; v_idcol := 'axs_event_id'; v_seen := 'last_seen_utc'; v_hubcol := 'axs_event_id'; v_hubnum := false;
    v_sel := $q$jsonb_build_object('name', c.event_title, 'venue', c.venue_name, 'city', c.venue_city, 'state', c.venue_state,
               'start_local', left(c.event_date_local, 16), 'status', c.status, 'gone_at', c.gone_at, 'last_seen_at', c.last_seen_utc,
               'tevo_event_id', c.tevo_event_id, 'tevo_match_method', c.match_method)$q$;
  ELSIF v_src = 'mlb' THEN
    v_table := 'mlb_ticket_game'; v_idcol := 'schedule_id'; v_seen := 'last_seen_at';
    v_sel := format($q$jsonb_build_object('name', c.away_name || ' at ' || c.home_name, 'venue', c.venue_name, 'city', c.venue_city,
               'start_local', to_char(c.game_time_local, %1$L), 'start_utc', to_char(c.game_time_utc AT TIME ZONE 'UTC', %1$L),
               'status', c.status, 'last_seen_at', c.last_seen_at,
               'tevo_event_id', c.tevo_event_id, 'tevo_match_method', c.tevo_match_method)$q$, v_fmt);
  ELSIF v_src = 'espn' THEN
    v_table := 'espn_ticket_game'; v_idcol := 'espn_event_id'; v_seen := 'last_seen_at'; v_numeric := false;
    v_sel := format($q$jsonb_build_object('name', c.name, 'venue', c.venue_name, 'city', c.venue_city, 'state', c.venue_state,
               'start_utc', to_char(c.game_at_utc AT TIME ZONE 'UTC', %1$L), 'status', c.status, 'last_seen_at', c.last_seen_at,
               'tevo_event_id', c.tevo_event_id, 'tevo_match_method', c.tevo_match_method)$q$, v_fmt);
  ELSIF v_src = 'stubhub' THEN
    v_hubcol := 'sh_event_id';
  ELSIF v_src = 'seatdata' THEN
    v_hubcol := 'sd_event_id';
  END IF;
  v_here := v_table IS NOT NULL AND to_regclass('public.' || v_table) IS NOT NULL;

  -- asked by EVO id alone: this marketplace's id for the event — its catalogue's own mapping first, then the hub
  IF v_id IS NULL AND p_tevo_event_id IS NOT NULL THEN
    IF v_src = 'evo' THEN
      v_id := p_tevo_event_id::text; v_from := 'tevo';
    ELSE
      IF v_here THEN
        EXECUTE format('SELECT (array_agg(c.%1$I::text ORDER BY c.%2$I DESC NULLS LAST, c.%1$I))[1], count(*)::int FROM public.%3$I c WHERE c.tevo_event_id = $1',
                       v_idcol, v_seen, v_table)
           INTO v_id, v_n USING p_tevo_event_id;
        IF v_id IS NOT NULL THEN v_from := 'catalogue'; END IF;
      END IF;
      IF v_id IS NULL AND v_hubcol IS NOT NULL THEN
        EXECUTE format('SELECT a.%1$I::text FROM public.aq_event_map a WHERE a.tevo_event_id = $1 AND a.%1$I IS NOT NULL
                         ORDER BY (a.aq_source = ''aq_curated'') DESC NULLS LAST, a.aq_short_event_id LIMIT 1', v_hubcol)
           INTO v_id USING p_tevo_event_id;
        IF v_id IS NOT NULL THEN v_from := 'hub'; END IF;
      END IF;
      IF v_id IS NULL AND v_src = 'espn' AND to_regclass('public.event_xref') IS NOT NULL THEN
        EXECUTE 'SELECT x.espn_event_id FROM public.event_xref x WHERE x.tevo_event_id = $1 ORDER BY x.espn_event_id LIMIT 1'
           INTO v_id USING p_tevo_event_id;
        IF v_id IS NOT NULL THEN v_from := 'event_xref'; END IF;
      END IF;
    END IF;
  END IF;

  IF v_id IS NOT NULL AND v_numeric AND v_table IS NOT NULL AND v_id !~ '^\d{1,18}$' THEN
    v_note := 'the id is not a number';
  ELSIF v_id IS NOT NULL AND v_here THEN
    EXECUTE format('SELECT jsonb_strip_nulls(%s) FROM public.%I c WHERE c.%I = $1%s LIMIT 1',
                   v_sel, v_table, v_idcol, CASE WHEN v_numeric THEN '::bigint' ELSE '' END)
       INTO v_row USING v_id;
  END IF;

  -- the hub row that carries this id
  IF v_id IS NOT NULL AND v_hubcol IS NOT NULL AND (NOT v_hubnum OR v_id ~ '^\d{1,18}$') THEN
    EXECUTE format('SELECT jsonb_build_object(''aq_short_event_id'', a.aq_short_event_id, ''tevo_event_id'', a.tevo_event_id)
                      FROM public.aq_event_map a WHERE a.%I = $1%s
                     ORDER BY (a.tevo_event_id IS NOT NULL) DESC, (a.aq_source = ''aq_curated'') DESC NULLS LAST, a.aq_short_event_id LIMIT 1',
                   v_hubcol, CASE WHEN v_hubnum THEN '::bigint' ELSE '' END)
       INTO v_hub USING v_id;
  ELSIF v_id IS NOT NULL AND v_src = 'espn' AND to_regclass('public.event_xref') IS NOT NULL THEN
    EXECUTE 'SELECT jsonb_build_object(''via'', ''event_xref'', ''tevo_event_id'', x.tevo_event_id) FROM public.event_xref x WHERE x.espn_event_id = $1 LIMIT 1'
       INTO v_hub USING v_id;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'marketplace', v_src,
    'catalogue', v_table,
    'catalogue_installed', CASE WHEN v_table IS NOT NULL THEN v_here END,
    'source_event_id', v_id,
    'id_from', v_from,
    'in_catalogue', CASE WHEN v_table IS NOT NULL THEN v_row IS NOT NULL END,
    'stored', v_row,
    'other_ids_for_event', CASE WHEN v_n > 1 THEN v_n - 1 END,
    'hub', v_hub,
    'tevo_event_id', coalesce((v_row->>'tevo_event_id')::bigint, (v_hub->>'tevo_event_id')::bigint),
    'note', v_note));
END $function$;
COMMENT ON FUNCTION public.catalogue_check_stored(text, text, bigint) IS
  'The stored half of catalogue_check(): the catalogue row we hold for one event of one marketplace (name, venue, start, status, last seen), its EVO mapping and the hub row carrying the id. Given only an EVO id, finds the marketplace''s id through its catalogue, the hub, or event_xref (ESPN). Reads only. Mig 20261122193000.';

-- ---------------------------------------------------------------------------------------------------------
-- 4. The live half: one GET of the marketplace's own single-event read
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.catalogue_check_live(p_marketplace text, p_source_event_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_src  text := public.catalogue_check_source(p_marketplace);
  v_id   text := nullif(trim(coalesce(p_source_event_id, '')), '');
  v_url  text;
  v_hdr  extensions.http_header[] := ARRAY[]::extensions.http_header[];
  v_tok  text;
  v_sec  text;
  v_ok   boolean;
  r      extensions.http_response;
  j      jsonb;
  v_ev   jsonb;
  v_t0   timestamptz;
  v_ms   int;
  v_pass jsonb;
BEGIN
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'catalogue_check: unknown marketplace % (evo | tickpick | gotickets | ticketmaster | vivid | seatgeek | axs | stubhub | seatdata | mlb | espn)', p_marketplace;
  END IF;

  IF v_src NOT IN ('evo', 'tickpick', 'gotickets', 'ticketmaster') THEN
    IF v_src = 'vivid' AND to_regclass('public.vivid_catalog_sync') IS NOT NULL THEN
      EXECUTE 'SELECT jsonb_build_object(''pass_started_at'', s.pass_started_at, ''pass_finished_at'', s.pass_finished_at) FROM public.vivid_catalog_sync s ORDER BY s.id LIMIT 1'
         INTO v_pass;
    END IF;
    RETURN jsonb_strip_nulls(jsonb_build_object('supported', false, 'asked', false,
      'reason', CASE v_src
                  WHEN 'vivid'    THEN 'whole_catalogue_only'      -- the broker read returns pages and ignores every filter
                  WHEN 'seatgeek' THEN 'no_single_event_read'
                  WHEN 'axs'      THEN 'no_single_event_read'      -- arrives through the paid TicketsData export
                  WHEN 'stubhub'  THEN 'api_switched_off'
                  WHEN 'seatdata' THEN 'paid_per_call'
                  ELSE 'schedule_feed_only' END,                   -- mlb, espn
      'catalogue_pass', v_pass));
  END IF;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('supported', true, 'asked', false, 'reason', 'no_id');
  END IF;
  -- the id goes into the URL: nothing but an id may pass
  IF (v_src = 'ticketmaster' AND v_id !~ '^[A-Za-z0-9_-]{6,40}$') OR (v_src <> 'ticketmaster' AND v_id !~ '^\d{1,18}$') THEN
    RETURN jsonb_build_object('supported', true, 'asked', false, 'reason', 'id_not_valid');
  END IF;

  IF v_src = 'evo' THEN
    v_tok := public.get_app_secret('TEVO_API_TOKEN');
    v_sec := public.get_app_secret('TEVO_SECRET');
    IF v_tok IS NULL OR v_sec IS NULL THEN RETURN jsonb_build_object('supported', true, 'asked', false, 'reason', 'no_credentials'); END IF;
    v_url := 'https://api.ticketevolution.com/v9/events/' || v_id;
    v_hdr := ARRAY[extensions.http_header('X-Token', v_tok),
                   extensions.http_header('X-Signature', public.tevo_sign_get('/v9/events/' || v_id, '', v_sec)),
                   extensions.http_header('Accept', 'application/json')];
  ELSIF v_src = 'tickpick' THEN
    SELECT decrypted_secret INTO v_tok FROM vault.decrypted_secrets WHERE name = 'TICKPICK_API_TOKEN';
    IF v_tok IS NULL THEN RETURN jsonb_build_object('supported', true, 'asked', false, 'reason', 'no_credentials'); END IF;
    v_url := 'https://api.tickpick.com/1.0/catalog/events/' || v_id;
    v_hdr := ARRAY[extensions.http_header('Authorization', 'Bearer ' || v_tok),
                   extensions.http_header('Accept', 'application/json')];
  ELSIF v_src = 'gotickets' THEN
    SELECT trim(decrypted_secret) INTO v_tok FROM vault.decrypted_secrets WHERE name = 'GOTICKETS_ACCESS_ID';
    SELECT trim(decrypted_secret) INTO v_sec FROM vault.decrypted_secrets WHERE name = 'GOTICKETS_API_SECRET';
    IF v_tok IS NULL OR v_sec IS NULL THEN RETURN jsonb_build_object('supported', true, 'asked', false, 'reason', 'no_credentials'); END IF;
    v_url := 'https://sc.gotickets.com/rest/events/' || v_id;
    v_hdr := ARRAY[extensions.http_header('X-Api-Access-Id', v_tok),
                   extensions.http_header('X-Api-Access-Secret', v_sec),
                   extensions.http_header('Accept', 'application/json')];
  ELSE  -- ticketmaster
    SELECT trim(decrypted_secret) INTO v_tok FROM vault.decrypted_secrets WHERE name = 'TMR CLIENT ID' LIMIT 1;
    IF v_tok IS NULL OR length(v_tok) < 16 THEN RETURN jsonb_build_object('supported', true, 'asked', false, 'reason', 'no_credentials'); END IF;
    -- one read = one call of the day's Discovery budget, counted where tm_discovery_tick counts its own
    IF to_regprocedure('public.tm_discovery_call_allowed(text)') IS NOT NULL THEN
      EXECUTE 'SELECT public.tm_discovery_call_allowed(''discovery'')' INTO v_ok;
      IF NOT coalesce(v_ok, false) THEN
        RETURN jsonb_build_object('supported', true, 'asked', false, 'reason', 'daily_budget_reached');
      END IF;
    END IF;
    v_url := 'https://app.ticketmaster.com/discovery/v2/events/' || v_id || '.json?apikey=' || extensions.urlencode(v_tok);
  END IF;

  PERFORM set_config('http.timeout_msec', '15000', true);
  v_t0 := clock_timestamp();
  BEGIN
    r := extensions.http(('GET', v_url, v_hdr, NULL, NULL)::extensions.http_request);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('supported', true, 'asked', true, 'reason', 'request_failed',
                              'error', left(regexp_replace(SQLERRM, 'apikey=[^&[:space:]]+', 'apikey=…', 'g'), 200));
  END;
  v_ms := (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int;
  j := public.safe_jsonb(r.content);

  IF r.status = 200 AND jsonb_typeof(j) = 'object' THEN
    v_ev := CASE v_src
      WHEN 'evo' THEN jsonb_build_object('name', j->>'name', 'venue', j#>>'{venue,name}',
             'city', j#>>'{venue,address,locality}', 'state', j#>>'{venue,address,region}',
             'start_local', left(j->>'occurs_at_local', 16), 'status', j->>'state')
      WHEN 'tickpick' THEN jsonb_build_object('name', j->>'name', 'venue', j#>>'{venue,name}',
             'city', j#>>'{venue,city}', 'state', j#>>'{venue,state}',
             'start_local', left(j->>'event_date', 16), 'start_utc', left(j->>'event_date_utc', 16),
             'status', lower(j->>'status'), 'merged_into', nullif(j->>'merged_into', ''))
      WHEN 'gotickets' THEN jsonb_build_object('name', j->>'name', 'venue', j->>'venueName',
             'city', j->>'venueCity', 'state', j->>'venueState',
             'start_local', left(j->>'eventTimeLocal', 16), 'start_utc', left(j->>'eventTimeUtc', 16),
             'status', j->>'status')
      ELSE jsonb_build_object('name', j->>'name', 'venue', j#>>'{_embedded,venues,0,name}',
             'city', j#>>'{_embedded,venues,0,city,name}', 'state', j#>>'{_embedded,venues,0,state,stateCode}',
             'start_local', (j#>>'{dates,start,localDate}') || coalesce('T' || left(j#>>'{dates,start,localTime}', 5), ''),
             'start_utc', left(j#>>'{dates,start,dateTime}', 16),
             'status', j#>>'{dates,status,code}')
    END;
    RETURN jsonb_build_object('supported', true, 'asked', true, 'http', r.status, 'found', true, 'ms', v_ms,
                              'event', jsonb_strip_nulls(v_ev));
  ELSIF r.status = 404 THEN
    RETURN jsonb_build_object('supported', true, 'asked', true, 'http', 404, 'found', false, 'ms', v_ms);
  ELSE
    -- 429 and everything else: no answer either way
    RETURN jsonb_build_object('supported', true, 'asked', true, 'http', r.status, 'ms', v_ms,
                              'reason', CASE WHEN r.status = 429 THEN 'rate_limited' ELSE 'http_' || coalesce(r.status::text, 'none') END);
  END IF;
END $function$;
COMMENT ON FUNCTION public.catalogue_check_live(text, text) IS
  'The live half of catalogue_check(): one GET of the marketplace''s own single-event read for evo, tickpick, gotickets and ticketmaster (the request shapes the existing pulls and clients send; a Ticketmaster read is counted against the day''s Discovery budget). found = true on 200, false on 404; a 429 or any other answer is reported as a reason, never as "not listed". The other marketplaces answer supported = false with the reason. Read-only upstream (RULE 2). Mig 20261122193000.';

-- ---------------------------------------------------------------------------------------------------------
-- 5. The call
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.catalogue_check(p_marketplace text, p_source_event_id text DEFAULT NULL, p_tevo_event_id bigint DEFAULT NULL,
                                                  p_live boolean DEFAULT true, p_min_interval interval DEFAULT interval '60 seconds')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_src     text := public.catalogue_check_source(p_marketplace);
  v_given   text := nullif(trim(coalesce(p_source_event_id, '')), '');
  v_t0      timestamptz := clock_timestamp();
  v_can     boolean;
  v_st      jsonb;
  v_live    jsonb;
  v_id      text;
  v_in      boolean;
  v_found   boolean;
  v_s       jsonb;
  v_e       jsonb;
  v_diff    text[] := ARRAY[]::text[];
  v_verdict text;
  v_res     jsonb;
  v_prev    record;
  k         text;
BEGIN
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'catalogue_check: unknown marketplace % (evo | tickpick | gotickets | ticketmaster | vivid | seatgeek | axs | stubhub | seatdata | mlb | espn)', p_marketplace;
  END IF;
  IF v_given IS NULL AND p_tevo_event_id IS NULL THEN
    RAISE EXCEPTION 'catalogue_check: pass the marketplace''s own event id, an EVO event id, or both';
  END IF;
  v_can := v_src IN ('evo', 'tickpick', 'gotickets', 'ticketmaster');

  v_st := public.catalogue_check_stored(v_src, v_given, p_tevo_event_id);
  v_id := v_st->>'source_event_id';
  v_in := (v_st->>'in_catalogue')::boolean;
  v_s  := v_st->'stored';

  IF NOT coalesce(p_live, false) THEN
    v_live := jsonb_build_object('supported', v_can, 'asked', false, 'reason', 'not_requested');
  ELSIF NOT v_can THEN
    v_live := public.catalogue_check_live(v_src, v_id);
  ELSIF v_id IS NULL THEN
    v_live := jsonb_build_object('supported', true, 'asked', false, 'reason', 'no_id');
  ELSE
    -- the same marketplace + id was asked a moment ago: do not send it again
    SELECT l.checked_at, l.result->'live' AS live INTO v_prev
      FROM public.catalogue_check_log l
     WHERE l.marketplace = v_src AND l.source_event_id = v_id AND l.live_asked
       AND l.checked_at > now() - coalesce(p_min_interval, interval '60 seconds')
     ORDER BY l.checked_at DESC LIMIT 1;
    IF FOUND THEN
      v_live := jsonb_build_object('supported', true, 'asked', false, 'reason', 'checked_recently',
                                   'last_checked_at', v_prev.checked_at, 'last', v_prev.live);
    ELSE
      v_live := public.catalogue_check_live(v_src, v_id);
    END IF;
  END IF;
  v_found := (v_live->>'found')::boolean;   -- NULL: not asked, or no answer either way
  v_e     := v_live->'event';

  -- what differs between our row and the marketplace's answer (only where both sides have a value)
  IF v_found IS TRUE AND v_s IS NOT NULL THEN
    FOREACH k IN ARRAY ARRAY['name', 'venue', 'status'] LOOP
      IF v_s ? k AND v_e ? k AND lower(trim(regexp_replace(v_s->>k, '\s+', ' ', 'g'))) IS DISTINCT FROM lower(trim(regexp_replace(v_e->>k, '\s+', ' ', 'g'))) THEN
        v_diff := array_append(v_diff, k);
      END IF;
    END LOOP;
    IF v_s ? 'start_local' AND v_e ? 'start_local' THEN
      IF v_s->>'start_local' IS DISTINCT FROM v_e->>'start_local' THEN v_diff := array_append(v_diff, 'start'); END IF;
    ELSIF v_s ? 'start_utc' AND v_e ? 'start_utc' THEN
      IF v_s->>'start_utc' IS DISTINCT FROM v_e->>'start_utc' THEN v_diff := array_append(v_diff, 'start'); END IF;
    END IF;
    IF v_e ? 'merged_into' AND (v_e->>'merged_into') IS DISTINCT FROM (v_s->>'merged_into') THEN v_diff := array_append(v_diff, 'merged_into'); END IF;
  END IF;

  v_verdict := CASE
    WHEN v_found IS TRUE  THEN CASE WHEN coalesce(v_in, false) THEN CASE WHEN cardinality(v_diff) = 0 THEN 'listed' ELSE 'listed_changed' END
                                    ELSE 'live_only' END
    WHEN v_found IS FALSE THEN CASE WHEN coalesce(v_in, false) THEN 'gone_upstream' ELSE 'not_listed' END
    WHEN (v_st->>'catalogue_installed')::boolean IS FALSE THEN 'catalogue_not_installed'
    WHEN v_id IS NULL THEN 'no_id'
    WHEN NOT (v_st ? 'catalogue') THEN CASE WHEN v_st ? 'hub' THEN 'id_only' ELSE 'unknown_id' END
    WHEN v_in THEN 'in_catalogue'
    ELSE 'not_in_catalogue' END;

  v_res := jsonb_strip_nulls(jsonb_build_object(
    'marketplace', v_src,
    'verdict', v_verdict,
    'source_event_id', v_id,
    'id_from', v_st->'id_from',
    'tevo_event_id', v_st->'tevo_event_id',
    'mapping_agrees', CASE WHEN p_tevo_event_id IS NOT NULL AND v_given IS NOT NULL AND v_st ? 'tevo_event_id'
                           THEN (v_st->>'tevo_event_id')::bigint = p_tevo_event_id END,
    'catalogue', v_st->'catalogue',
    'in_catalogue', v_st->'in_catalogue',
    'stored', v_s,
    'age_hours', CASE WHEN v_s ? 'last_seen_at' THEN round((extract(epoch FROM now() - (v_s->>'last_seen_at')::timestamptz) / 3600.0)::numeric, 1) END,
    'other_ids_for_event', v_st->'other_ids_for_event',
    'hub', v_st->'hub',
    'live', v_live,
    'differs', CASE WHEN cardinality(v_diff) > 0 THEN to_jsonb(v_diff) END,
    'note', v_st->'note',
    'checked_at', now()));

  INSERT INTO public.catalogue_check_log (marketplace, source_event_id, tevo_event_id, live_asked, http_status, verdict, ms, result)
  VALUES (v_src, v_id, coalesce(p_tevo_event_id, (v_st->>'tevo_event_id')::bigint), coalesce((v_live->>'asked')::boolean, false),
          (v_live->>'http')::int, v_verdict, (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int, v_res);
  -- keep 30 days, pruned as it goes (about one call in fifty)
  IF random() < 0.02 THEN
    DELETE FROM public.catalogue_check_log WHERE checked_at < now() - interval '30 days';
  END IF;
  RETURN v_res;
END $function$;
COMMENT ON FUNCTION public.catalogue_check(text, text, bigint, boolean, interval) IS
  'Check one marketplace''s catalogue for one event (evo | tickpick | gotickets | ticketmaster | vivid | seatgeek | axs | stubhub | seatdata | mlb | espn), by the marketplace''s own event id, an EVO event id, or both. Returns the catalogue row we hold, its EVO mapping and hub row, and — live, for evo / tickpick / gotickets / ticketmaster — the marketplace''s own answer for that one event, with what differs. Verdict: listed | listed_changed | live_only | gone_upstream | not_listed | in_catalogue | not_in_catalogue | id_only | unknown_id | no_id | catalogue_not_installed. Writes no catalogue and no mapping; one row per call in catalogue_check_log. Read-only upstream (RULE 2). Mig 20261122193000.';

-- ---------------------------------------------------------------------------------------------------------
-- 6. One EVO event across every marketplace
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.catalogue_check_all(p_tevo_event_id bigint, p_live boolean DEFAULT false)
 RETURNS TABLE(marketplace text, verdict text, source_event_id text, result jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE m text; v jsonb;
BEGIN
  IF p_tevo_event_id IS NULL THEN RAISE EXCEPTION 'catalogue_check_all: an EVO event id is required'; END IF;
  FOREACH m IN ARRAY ARRAY['evo', 'seatgeek', 'gotickets', 'vivid', 'tickpick', 'axs', 'ticketmaster', 'stubhub', 'seatdata', 'mlb', 'espn'] LOOP
    v := public.catalogue_check(m, NULL, p_tevo_event_id, p_live);
    marketplace := m; verdict := v->>'verdict'; source_event_id := v->>'source_event_id'; result := v;
    RETURN NEXT;
  END LOOP;
END $function$;
COMMENT ON FUNCTION public.catalogue_check_all(bigint, boolean) IS
  'catalogue_check() for one EVO event on every marketplace, one row each. live defaults to false (stored answers only); with live = true it sends up to four reads (evo, gotickets, tickpick, ticketmaster). Mig 20261122193000.';

-- SECURITY DEFINER convention (PROJECT_BIBLE §2.8): the REVOKE is the enforcement
REVOKE EXECUTE ON FUNCTION public.catalogue_check_source(text)                              FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.catalogue_check_stored(text, text, bigint)                FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.catalogue_check_live(text, text)                          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.catalogue_check(text, text, bigint, boolean, interval)    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.catalogue_check_all(bigint, boolean)                      FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.catalogue_check_source(text)                              TO service_role;
GRANT  EXECUTE ON FUNCTION public.catalogue_check_stored(text, text, bigint)                TO service_role;
GRANT  EXECUTE ON FUNCTION public.catalogue_check_live(text, text)                          TO service_role;
GRANT  EXECUTE ON FUNCTION public.catalogue_check(text, text, bigint, boolean, interval)    TO service_role;
GRANT  EXECUTE ON FUNCTION public.catalogue_check_all(bigint, boolean)                      TO service_role;

-- VERIFY (after apply):
--   SELECT public.catalogue_check('tickpick', '8348114');                    -- listed, live.http 200
--   SELECT public.catalogue_check('evo', NULL, 3556879);                     -- listed
--   SELECT public.catalogue_check('tickpick', '999999999');                  -- not_listed, live.http 404
--   SELECT marketplace, verdict, source_event_id FROM public.catalogue_check_all(3556879);
--   SELECT marketplace, verdict, live_asked, http_status, ms FROM public.catalogue_check_log ORDER BY check_id DESC LIMIT 20;
