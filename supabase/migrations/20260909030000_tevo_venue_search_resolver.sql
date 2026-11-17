-- Migration 20260909030000 · level:data-collection · lane:A1 · writes:tevo_venue_search,cross_source_venue_map,events · reads:s4kcs_orders,net._http_response · pre:20260909021500
--
-- Already applied to prod · via MCP 2026-09-09 under operator direction.
-- Verified end to end: 125 venue names queued -> 80 resolved / 36 no_match /
-- 9 ambiguous; 80 promoted into cross_source_venue_map and all 80 now return
-- their id from cross_source_venue_resolve(); the venue sweep then pulled
-- 1,114 events across 80 venues into the `events` mirror, and s4kcs_map_events()
-- rule 8 mapped 972 orders off them. Future CRM order coverage 90.4% -> 93.8%
-- (25,727/27,414).
--
-- THE TEvo VENUE + EVENT RESOLVER. Closes the last structural gap in the
-- mapping chain: CRM venue names TEvo knows under a different string.
--
-- ============================================================================
-- THE ROOT CAUSE THIS FIXES
-- ============================================================================
-- 297 hub rows for college events sat on result='no_results' from the
-- aq-to-tevo bridge, and the events looked absent from TEvo. They were not.
-- The bridge searches `/v9/events?name=...`, and that parameter needs a
-- NEAR-EXACT name -- measured live 2026-09-09:
--
--   GET /v9/events?name=South+Dakota+State+Jackrabbits+Football  -> 0 entries
--   GET /v9/searches?entities=venues&q=Jackrabbits               -> performer
--        15492 "South Dakota State Jackrabbits Football", whose venue is
--        33170 "Dana Dykhouse Stadium", Brookings SD, with upcoming events
--        2026-09-12 .. 2026-11-21
--
-- Same event, same API, different endpoint. `/v9/searches` is FUZZY; `name=`
-- is not. That one distinction is why a whole segment looked unmappable.
--
-- ⚠ AND IT NEEDS NO EDGE FUNCTION. This was previously carried as blocked on an
-- edge-fn deploy because TEvo requires HMAC-signed requests. It does not:
-- `tevo_sign_get()` + pg_net do it from plain SQL. Everything here is SQL.
--
-- ============================================================================
-- TWO SIGNING LANDMINES (both cost a 401 before they were found)
-- ============================================================================
-- 1. QUERY PARAMS MUST BE ALPHABETICAL. The HMAC signs the query string as
--    sent, so 'q=X&entities=venues' 401s while 'entities=venues&q=X' passes.
--    Every query string built below is assembled in sorted order deliberately.
-- 2. tevo_sign_get(p_path, ...) PREPENDS the host itself -- it signs
--    'GET api.ticketevolution.com' || p_path. So p_path is '/v9/searches',
--    NOT 'api.ticketevolution.com/v9/searches'. Passing the host doubles it
--    and every request 401s.
--
-- ============================================================================
-- WHY THE HARVEST HAS TWO PATHS WITH DIFFERENT GUARDS
-- ============================================================================
-- `entities=venues` is NOT honoured -- the endpoint returns Performers too, so
-- `_type` must be checked. Worse, many college venues are never returned as a
-- Venue at all; they exist only NESTED inside a Performer's `venue` object:
--
--   "Memorial Stadium Nebraska" -> performer "Nebraska Cornhuskers Football"
--        -> venue 1093 "Memorial Stadium - NE", Lincoln NE     (correct)
--   same response  -> performer "NHL Stadium Series"
--        -> venue 7074 "MetLife Stadium", East Rutherford NJ   (junk)
--
-- So the two paths cannot share a guard:
--   * direct (_type='Venue'): >=1 DISTINCTIVE token (generic venue words
--     removed via the mig 20260908203500 stop-list), state optional.
--   * nested: state agreement MANDATORY, plus >=2 shared tokens counting
--     generic words. "Memorial Stadium Nebraska" vs "Memorial Stadium - NE"
--     in NE passes on memorial+stadium; MetLife fails on stadium alone.
-- Then exactly ONE distinct venue id must survive, or the row is 'ambiguous'.
--
-- ============================================================================
-- A FALSE MATCH THIS ACTUALLY PRODUCED, AND THE FIX
-- ============================================================================
-- The first run resolved "Spartan Stadium (Michigan)" -> venue 1002 "Michigan
-- Stadium", Ann Arbor MI. WRONG: Spartan Stadium is Michigan STATE's, in East
-- Lansing. Both are in MI so the state guard could not separate them, and
-- "michigan" -- taken from the CRM's PARENTHETICAL disambiguator -- was the
-- only distinctive token. Caught by hand-auditing all 80 resolutions, then
-- unbound. tevo_venue_search_norm() now strips '(...)' before tokenising, so a
-- parenthetical can never again supply the matching token. All 7 resolutions
-- that leaned on a state-name token were re-checked; the other 6 are correct
-- (the Nebraska pair via the state-verified nested path, and Commonwealth
-- Stadium -> Kroger Field / Jones AT&T -> Galaxy Stadium, which are real
-- renames matched through TEvo's `keywords` field).
-- "TPC of Scottsdale" -> "Coors Light Birds Nest At TPC Scottsdale" was also
-- rejected in the same audit: that is a hospitality venue AT the course.
--
-- ============================================================================
-- THE SWEEP, AND WHY THE VENUE IDS ALONE WERE WORTH ALMOST NOTHING
-- ============================================================================
-- Promoting 80 venue ids into cross_source_venue_map moved coverage by TWO
-- orders. A venue id does not map an event -- the EVENTS were still missing
-- from the mirror. tevo_venue_events_* then pulls /v9/events?venue_id=... per
-- resolved venue (ONE call per venue, not per event) and upserts into `events`;
-- rule 8 (mig 20260909012000) does the rest. 1,114 events -> 972 orders.
--
-- occurs_at_local is stored as the LOCAL wall clock with the offset dropped
-- (left(...,19)), because rule 8 reads left(occurs_at_local,10) as the local
-- date. Converting to UTC here would shift evening events a day and re-create
-- the PROJECT_BIBLE §3 mixed-timezone landmine inside the mirror.
--
-- REVERSIBLE:
--   UPDATE public.s4kcs_orders SET tevo_event_id=NULL, map_method=NULL,
--          map_confidence=NULL, mapped_at=NULL
--    WHERE map_method='mirror_venue_id_date_nameguard';
--   DELETE FROM public.cross_source_venue_map
--    WHERE id_provenance->>'tevo_venue_id' LIKE '%tevo_venue_search%';
--   DROP TABLE public.tevo_venue_search CASCADE;
--   -- `events` rows are a mirror refill and are left in place: they are the
--   -- same rows TEvo's own ingest would fetch, keyed on TEvo's event id.

CREATE TABLE IF NOT EXISTS public.tevo_venue_search (
  venue_name_raw   text PRIMARY KEY,
  state_hint       text,
  state_code       text,
  crm_orders       integer NOT NULL DEFAULT 0,
  request_id       bigint,
  requested_at     timestamptz,
  tevo_venue_id    bigint,
  tevo_venue_name  text,
  tevo_location    text,
  status           text NOT NULL DEFAULT 'pending',
  reject_reason    text,
  ev_request_id      bigint,
  ev_status          text,
  ev_events_upserted integer,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tevo_venue_search_status_ck
    CHECK (status IN ('pending','requested','resolved','no_match','ambiguous','error'))
);
CREATE INDEX IF NOT EXISTS tevo_venue_search_status_idx ON public.tevo_venue_search (status);
CREATE INDEX IF NOT EXISTS tevo_venue_search_req_idx    ON public.tevo_venue_search (request_id)
  WHERE request_id IS NOT NULL;

COMMENT ON TABLE public.tevo_venue_search IS
  'TEvo venue-id + event resolution queue. /v9/searches does FUZZY matching; /v9/events?name= does NOT (needs a near-exact name, which is why the aq-to-tevo bridge returned no_results on 297 college hub rows). Signed with tevo_sign_get() and fired via pg_net from plain SQL - no edge function.';

-- Strips parenthetical qualifiers before tokenising. "Spartan Stadium
-- (Michigan)" must not offer "michigan" as its distinctive token - that bound
-- Michigan STATE's stadium to venue 1002, Michigan Stadium in Ann Arbor.
CREATE OR REPLACE FUNCTION public.tevo_venue_search_norm(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT trim(regexp_replace(lower(regexp_replace(
           regexp_replace(public.unaccent(coalesce(p,'')), '\([^)]*\)', ' ', 'g'),
           '[^a-zA-Z0-9 ]', ' ', 'g')), '\s+', ' ', 'g'));
$function$;
REVOKE ALL ON FUNCTION public.tevo_venue_search_norm(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tevo_venue_search_norm(text) TO service_role;

-- NOTE: tevo_venue_search_enqueue / tevo_venue_search_harvest /
-- tevo_venue_events_enqueue / tevo_venue_events_harvest are applied in prod as
-- authored during this session. Their bodies carry the two signing landmines in
-- comments (alphabetical query params; tevo_sign_get prepends the host, so
-- p_path is '/v9/searches'). See the header for the guard design.
