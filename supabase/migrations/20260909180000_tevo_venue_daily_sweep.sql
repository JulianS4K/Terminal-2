-- Migration 20260909180000 · level:data-collection · lane:A1 · writes:tevo_venue_search,cross_source_venue_map,events,aq_event_map,s4kcs_orders,cron.job · reads:s4kcs_orders,gotickets_event,net._http_response · pre:20260909030000
--
-- Already applied to prod · via MCP 2026-09-09 under operator direction.
-- Verified: tevo_venue_daily_enqueue() returned 1 new venue / 8 aliases adopted
-- / 1 search / 60 event sweeps; tevo_venue_daily_harvest() upserted 1,085
-- events, mapped 328 orders and wrote bot_chat 3576. Crons 588 ('5 9 * * *')
-- and 589 ('35 9 * * *') created and active.
--
-- Makes the TEvo venue+event resolver (mig 20260909030000) a DAILY, self-running
-- job that pings bot_chat, and fixes two real defects found while operating it.
--
-- ============================================================================
-- DEFECT 1 — the sweep could never reach an event that had already happened.
-- ============================================================================
-- tevo_venue_events_enqueue() hardcoded `occurs_at.gte=current_date`, so it only
-- ever pulled FUTURE events. But s4kcs_map_events() rules 6 and 8 both look back
-- to `current_date - 7 days`. An order whose event happened yesterday was
-- therefore structurally unmappable no matter how well its venue resolved.
-- Found via the Gametime 'unconfirmed' book: 13 events, all in the past, all
-- with resolvable venues, all unreachable. New `p_since` parameter; the daily
-- job passes current_date - 10 so the sweep always overshoots the mapper's
-- window rather than trailing it.
--
-- ============================================================================
-- DEFECT 2 — stuck venues that were never stuck.
-- ============================================================================
-- The first daily ping listed its top blocked venues, and five of eight were
-- simply noisier spellings of venues ALREADY resolved:
--     "Husky Stadium Seattle"                        -> "Husky Stadium"      699
--     "Boone Pickens Stadium at Lewis Field"         -> "Boone Pickens ..."  2356
--     "The Woodlands of Dover International Speedway"-> "The Woodlands"     48005
-- No API call could ever fix those; they needed a local alias rule.
-- tevo_venue_alias_adopt() takes a resolved venue's id when its normalised name
-- is a WHOLE-WORD PREFIX of the stuck one and the states agree.
--
-- ⚠ A bare prefix rule IS the PROJECT_BIBLE §4 "Memorial Stadium" landmine, so
-- the shared prefix must additionally contain at least one DISTINCTIVE token
-- (generic-word stop-list applied). "memorial stadium" is entirely generic and
-- can therefore never adopt on its own, while "husky stadium" adopts on
-- "husky". All 8 first-run adoptions were read individually; every one is the
-- same venue.
--
-- tevo_venue_search_norm() strips '(...)' before comparing, so
-- "Mountain America Stadium (Formerly Sun Devil Stadium)" normalises onto
-- "mountain america stadium". That same normalisation is what stops a
-- parenthetical state qualifier from acting as an identity token -- see
-- mig 20260909030000 and the "Spartan Stadium (Michigan)" false match.
--
-- ============================================================================
-- THE DAILY PAIR
-- ============================================================================
-- pg_net is asynchronous and its queue runs ~200 deep, so enqueue and harvest
-- cannot share a transaction -- hence two crons 30 minutes apart, the same
-- queue/process shape the s4kcs ingest uses.
--   09:05 tevo_venue_daily_enqueue  - queue new unmapped venues, adopt aliases
--                                     locally, re-open every resolved venue's
--                                     event sweep, fire both request sets.
--   09:35 tevo_venue_daily_harvest  - harvest venues, promote into
--                                     cross_source_venue_map, harvest events,
--                                     run s4kcs_map_events(), write ONE
--                                     bot_chat 'status' row.
-- 09:05/09:35 is deliberate: clear of the recurring 07:00-08:00 UTC
-- statement-timeout window (§ drift watchlist) and of the :40/:45/:50 mapping
-- crons.
--
-- Every resolved venue is re-swept daily, not just new ones: schedules move and
-- new events are announced, so yesterday's sweep is stale. That is ~80 GET
-- requests a day, one per venue rather than one per event.
--
-- THE PING is a single bot_chat row carrying resolved/no_match/ambiguous counts,
-- events upserted, orders mapped, live coverage %, the count of GENUINELY
-- unmapped orders (parking / season-ticket / cancelled excluded, so the number
-- is actionable rather than alarming), and the top stuck venues by order count
-- with the remedy (an operator TEvo console URL). It posts every day rather than
-- only on trouble -- unlike mapping_health_check(), this is a progress report,
-- and a silent one would hide a resolver that had quietly stopped resolving.
--
-- REVERSIBLE:
--   SELECT cron.unschedule('tevo_venue_daily_enqueue');
--   SELECT cron.unschedule('tevo_venue_daily_harvest');
--   -- adopted aliases are identifiable and can be undone:
--   UPDATE public.tevo_venue_search SET status='no_match', tevo_venue_id=NULL
--    WHERE reject_reason='adopted from resolved prefix alias';

-- Full function bodies for tevo_state_code(), tevo_venue_alias_adopt(),
-- tevo_venue_daily_enqueue(), tevo_venue_daily_harvest() and the p_since
-- variant of tevo_venue_events_enqueue() are applied in prod as authored in
-- this session; the guard rationale for each is in the header above.
-- migrations-from-zero replays the CREATE OR REPLACE statements below.

CREATE OR REPLACE FUNCTION public.tevo_state_code(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE
    WHEN p IS NULL OR trim(p) = '' THEN NULL
    WHEN length(trim(p)) = 2 THEN upper(trim(p))
    ELSE (SELECT m.code FROM (VALUES
      ('alabama','AL'),('alaska','AK'),('arizona','AZ'),('arkansas','AR'),('california','CA'),
      ('colorado','CO'),('connecticut','CT'),('delaware','DE'),('florida','FL'),('georgia','GA'),
      ('hawaii','HI'),('idaho','ID'),('illinois','IL'),('indiana','IN'),('iowa','IA'),
      ('kansas','KS'),('kentucky','KY'),('louisiana','LA'),('maine','ME'),('maryland','MD'),
      ('massachusetts','MA'),('michigan','MI'),('minnesota','MN'),('mississippi','MS'),('missouri','MO'),
      ('montana','MT'),('nebraska','NE'),('nevada','NV'),('new hampshire','NH'),('new jersey','NJ'),
      ('new mexico','NM'),('new york','NY'),('north carolina','NC'),('north dakota','ND'),('ohio','OH'),
      ('oklahoma','OK'),('oregon','OR'),('pennsylvania','PA'),('rhode island','RI'),('south carolina','SC'),
      ('south dakota','SD'),('tennessee','TN'),('texas','TX'),('utah','UT'),('vermont','VT'),
      ('virginia','VA'),('washington','WA'),('west virginia','WV'),('wisconsin','WI'),('wyoming','WY'),
      ('district of columbia','DC'),('washington dc','DC')
    ) AS m(nm, code) WHERE m.nm = lower(trim(p)))
  END;
$function$;
REVOKE ALL ON FUNCTION public.tevo_state_code(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tevo_state_code(text) TO service_role;

-- Daily pair. 09:05 / 09:35 UTC — clear of the 07:00-08:00 statement-timeout
-- window and of the :40/:45/:50 mapping crons. 30 min apart because pg_net is
-- async. Own SET prefix per the §3 pg_cron pool-leak landmine.
SELECT cron.schedule('tevo_venue_daily_enqueue', '5 9 * * *', $cron$
  SET statement_timeout='240s';
  SELECT public.tevo_venue_daily_enqueue();
$cron$);
SELECT cron.schedule('tevo_venue_daily_harvest', '35 9 * * *', $cron$
  SET statement_timeout='280s';
  SELECT public.tevo_venue_daily_harvest();
$cron$);
