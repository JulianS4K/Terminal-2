-- Migration 20261128100000 · level:data-collection · lane:a1 (the tickets.dev watches: ProVenue, SeatGeek primary) + D0 (sub_finder_health) · writes:provenue_catalogue_fill()(new),sgp_catalogue_fill()(new),tdev_watch_health()(new),sub_finder_health()(patched in place: the two watches graded by their own cadence),primary_poll_event(catalogue rows, source provenue / seatgeek_primary),cron tdev_catalogue_fill_daily(new) · reads:v_provenue_watch_games,v_sgp_watch_games,provenue_watch_poll,sgp_watch_poll,provenue_watch_config,sgp_watch_config
--
-- THE TWO tickets.dev WATCHES REACH THE CRM THE WAY THE AXS WATCH DOES.
-- Operator 2026-11-28: "fix 1 and 2, add the pinned calls too, then mimic axs calls for tickets.dev sg/provenue
-- sources" — 1 being GET /health reporting box_office_provenue `down`, 2 the CRM's guide not naming either source.
--
-- 1. THE CATALOGUE. The AXS watch publishes every event of its venues and reads only its list (mig 20261126060000):
--    an event it does not read is in GET /primary/events with listings_withheld 'not_polled' (poll_status
--    'pending'), so the CRM sees the whole schedule and which games carry listings. The tickets.dev watches only
--    published the games they had read (40 of 1,124 MLB games). provenue_catalogue_fill() and sgp_catalogue_fill()
--    put every game of v_provenue_watch_games / v_sgp_watch_games into primary_poll_event as a catalogue row
--    (watch = false, poll_status 'pending', announced_at set so the mapper's channel is not posted 1,300 events the
--    schedule already maps), take out the catalogue rows that left the view and were never read, and close a run
--    with every game of the view so the feed (which joins the source's current run) shows them. A read turns a
--    catalogue row into a read one through primary_poll_ingest as before. Publishing costs no capture. Nightly
--    (cron tdev_catalogue_fill_daily, 03:25 UTC, after the AXS fill) and once on apply.
--
-- 2. HEALTH. sub_finder_health() grades a box office down when none of its events has listings (served = 0) and
--    degraded when its last activity is older than 25 minutes. Both are right for a box office read on the
--    10-minute-to-hourly ladder and always wrong for these two: their plan (Starter: about 33 captures a day)
--    reads each game every week or two, and a game's listings are sent for about an hour after its read. So the
--    CRM's overall status read `down` from the first day. tdev_watch_health(source) grades them by what they can
--    do instead:
--      off       the watch's captures are switched off (sgp_watch_config.enabled / provenue_watch_config.enabled)
--      down      no read has succeeded for 2 days, or 8 of the last 10 reads failed
--      degraded  3 of the last 10 reads failed, or nothing was tried for 26 hours
--      ok        otherwise: reads go out every day and come back
--    with the day's reads against the day's cap, so the CRM can see the watch is working within its plan. It is
--    merged over the generic check (same name box_office_<source>, same fields). The patch is anchored on one
--    exact line of the live function and checked to hit it once; the rest of the function is not restated.
--
-- rollback: DELETE FROM primary_poll_event WHERE source IN ('provenue','seatgeek_primary') AND poll_status = 'pending'
--           AND poll_ok_at IS NULL; SELECT cron.unschedule('tdev_catalogue_fill_daily'); re-apply sub_finder_health()
--           from 20261124204030.

BEGIN;

-- ---------------------------------------------------------------- 1. the catalogue
CREATE OR REPLACE FUNCTION public.provenue_catalogue_fill()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_added integer; v_dropped integer; v_run integer;
BEGIN
  WITH ins AS (
    INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_local_time, start_utc, timezone,
                                           venue_name, venue_city, ticket_url, tevo_event_id, tevo_match_method, tevo_matched_at,
                                           announced_at, watch)
    SELECT 'provenue', g.pid, g.away_name || ' at ' || g.home_name, g.game_date,
           CASE WHEN g.game_time_local::text ~ 'T?\d{2}:\d{2}' THEN substring(g.game_time_local::text FROM 'T?(\d{2}:\d{2})')::time END,
           g.game_time_utc, g.time_zone_local, g.venue_name, g.venue_city, g.ticket_url, g.tevo_event_id,
           CASE WHEN g.tevo_event_id IS NOT NULL THEN 'mlb_schedule' END, CASE WHEN g.tevo_event_id IS NOT NULL THEN now() END,
           now(), false
      FROM public.v_provenue_watch_games g
    ON CONFLICT (source, source_event_id) DO NOTHING
    RETURNING 1)
  SELECT count(*) INTO v_added FROM ins;
  -- a catalogue row that left the watch's games (past, removed from the schedule, no longer ProVenue) and was never read
  WITH del AS (
    DELETE FROM public.primary_poll_event t
     WHERE t.source = 'provenue' AND NOT t.watch AND t.poll_ok_at IS NULL AND t.poll_status = 'pending'
       AND NOT EXISTS (SELECT 1 FROM public.v_provenue_watch_games g WHERE g.pid = t.source_event_id)
    RETURNING 1)
  SELECT count(*) INTO v_dropped FROM del;
  v_run := public.primary_poll_run_done('provenue', 'provenue-' || to_char(clock_timestamp(), 'YYYYMMDD"T"HH24MISS.US'),
             coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                         JOIN public.v_provenue_watch_games g ON g.pid = e.source_event_id
                        WHERE e.source = 'provenue'), '[]'::jsonb));
  RETURN jsonb_build_object('source', 'provenue', 'added', v_added, 'dropped', v_dropped, 'published', v_run);
END $function$;

CREATE OR REPLACE FUNCTION public.sgp_catalogue_fill()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_added integer; v_dropped integer; v_run integer;
BEGIN
  WITH ins AS (
    INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_local_time, start_utc, timezone,
                                           venue_name, venue_city, venue_state, ticket_url, tevo_event_id, tevo_match_method,
                                           tevo_matched_at, announced_at, watch)
    SELECT 'seatgeek_primary', g.sg_event_id, g.name,
           CASE WHEN g.event_local ~ '^\d{4}-\d{2}-\d{2}' THEN left(g.event_local, 10)::date ELSE (g.event_utc)::date END,
           CASE WHEN g.event_local ~ 'T\d{2}:\d{2}' THEN substring(g.event_local FROM 'T(\d{2}:\d{2})')::time END,
           g.event_utc, g.timezone, g.venue_name, g.venue_city, g.venue_state, g.url, g.tevo_event_id,
           CASE WHEN g.tevo_event_id IS NOT NULL THEN 'sg_canonical' END, CASE WHEN g.tevo_event_id IS NOT NULL THEN now() END,
           now(), false
      FROM public.v_sgp_watch_games g
     WHERE g.name !~* 'if necessary|date tbd'       -- playoff placeholders are not games yet
    ON CONFLICT (source, source_event_id) DO NOTHING
    RETURNING 1)
  SELECT count(*) INTO v_added FROM ins;
  WITH del AS (
    DELETE FROM public.primary_poll_event t
     WHERE t.source = 'seatgeek_primary' AND NOT t.watch AND t.poll_ok_at IS NULL AND t.poll_status = 'pending'
       AND NOT EXISTS (SELECT 1 FROM public.v_sgp_watch_games g WHERE g.sg_event_id = t.source_event_id AND g.name !~* 'if necessary|date tbd')
    RETURNING 1)
  SELECT count(*) INTO v_dropped FROM del;
  v_run := public.primary_poll_run_done('seatgeek_primary', 'seatgeek_primary-' || to_char(clock_timestamp(), 'YYYYMMDD"T"HH24MISS.US'),
             coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                         JOIN public.v_sgp_watch_games g ON g.sg_event_id = e.source_event_id
                        WHERE e.source = 'seatgeek_primary'), '[]'::jsonb));
  RETURN jsonb_build_object('source', 'seatgeek_primary', 'added', v_added, 'dropped', v_dropped, 'published', v_run);
END $function$;

REVOKE ALL ON FUNCTION public.provenue_catalogue_fill() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sgp_catalogue_fill() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.provenue_catalogue_fill() TO service_role;
GRANT EXECUTE ON FUNCTION public.sgp_catalogue_fill() TO service_role;

-- ---------------------------------------------------------------- 2. health, by the watch's own cadence
CREATE OR REPLACE FUNCTION public.tdev_watch_health(p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_enabled boolean; v_cap integer; v_today integer; v_last_try timestamptz; v_last_ok timestamptz; v_failed integer; v_settled integer;
  v_st text; v_detail text;
BEGIN
  IF p_source = 'provenue' THEN
    SELECT c.enabled, c.daily_cap INTO v_enabled, v_cap FROM public.provenue_watch_config c;
    SELECT max(p.fired_at), max(p.checked_at) FILTER (WHERE p.outcome IN ('ok', 'empty', 'not_on_sale')),
           count(*) FILTER (WHERE p.fired_at >= date_trunc('day', now()))
      INTO v_last_try, v_last_ok, v_today FROM public.provenue_watch_poll p;
    SELECT count(*) FILTER (WHERE x.outcome NOT IN ('ok', 'empty', 'not_on_sale')), count(*) INTO v_failed, v_settled
      FROM (SELECT p.outcome FROM public.provenue_watch_poll p WHERE p.checked_at IS NOT NULL ORDER BY p.checked_at DESC LIMIT 10) x;
  ELSIF p_source = 'seatgeek_primary' THEN
    SELECT c.enabled, c.daily_cap INTO v_enabled, v_cap FROM public.sgp_watch_config c;
    SELECT max(p.fired_at), max(p.checked_at) FILTER (WHERE p.outcome IN ('ok', 'empty', 'not_on_sale')),
           count(*) FILTER (WHERE p.fired_at >= date_trunc('day', now()))
      INTO v_last_try, v_last_ok, v_today FROM public.sgp_watch_poll p;
    SELECT count(*) FILTER (WHERE x.outcome NOT IN ('ok', 'empty', 'not_on_sale')), count(*) INTO v_failed, v_settled
      FROM (SELECT p.outcome FROM public.sgp_watch_poll p WHERE p.checked_at IS NOT NULL ORDER BY p.checked_at DESC LIMIT 10) x;
  ELSE
    RETURN NULL;
  END IF;

  IF NOT coalesce(v_enabled, false) THEN
    v_st := 'off'; v_detail := 'reading is switched off at S4K: the games are listed without listings';
  ELSIF v_settled >= 5 AND v_failed >= 8 THEN
    v_st := 'down'; v_detail := 'the reads are failing: no listings are being refreshed';
  ELSIF v_last_ok IS NULL OR v_last_ok < now() - interval '2 days' THEN
    v_st := 'down'; v_detail := 'no game has been read for 2 days';
  ELSIF v_failed >= 3 THEN
    v_st := 'degraded'; v_detail := 'some reads failed: their games carry no listings until read again';
  ELSIF v_last_try < now() - interval '26 hours' THEN
    v_st := 'degraded'; v_detail := 'nothing was read for over a day';
  ELSE
    v_st := 'ok'; v_detail := NULL;
  END IF;

  RETURN jsonb_build_object(
    'status', v_st, 'detail', v_detail,
    'last_at', v_last_try, 'age_seconds', round(extract(epoch FROM now() - v_last_try)),
    'ok_within_seconds', 93600, 'down_after_seconds', 172800,
    'reads_today', v_today, 'reads_per_day', v_cap,
    'cadence', 'read through tickets.dev within a daily plan, soonest game first: each game is read when its turn comes and its '
               || 'listings are sent for about an hour after the read, so most games show listings_withheld at any moment');
END $function$;
REVOKE ALL ON FUNCTION public.tdev_watch_health(text) FROM PUBLIC, anon, authenticated;

-- the patch: after the generic box-office check is built, a tickets.dev watch's own grading is merged over it
DO $surgery$
DECLARE
  v_src text; v_anchor text := $a$'events_never_readable', v_box.unreadable);$a$;
  v_hits integer;
BEGIN
  IF to_regprocedure('public.sub_finder_health(bigint)') IS NULL THEN
    RAISE NOTICE 'sub_finder_health(bigint) not here: health patch skipped';
    RETURN;
  END IF;
  SELECT pg_get_functiondef('public.sub_finder_health(bigint)'::regprocedure) INTO v_src;
  IF position('tdev_watch_health' in v_src) > 0 THEN
    RAISE NOTICE 'sub_finder_health already grades the tickets.dev watches';
    RETURN;
  END IF;
  v_hits := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'sub_finder_health: expected the anchor once, found % times', v_hits;
  END IF;
  v_src := replace(v_src, v_anchor, v_anchor || $p$
      -- the tickets.dev watches (ProVenue, SeatGeek primary) are graded by their own cadence (mig 20261128100000)
      IF v_box.source IN ('provenue', 'seatgeek_primary') THEN
        v_checks := jsonb_set(v_checks, ARRAY[(jsonb_array_length(v_checks) - 1)::text],
                              (v_checks -> -1) || coalesce(public.tdev_watch_health(v_box.source), '{}'::jsonb));
      END IF;$p$);
  EXECUTE v_src;
END $surgery$;

-- ---------------------------------------------------------------- the nightly catalogue, and once now
SELECT cron.schedule('tdev_catalogue_fill_daily', '25 3 * * *',
                     $$SELECT public.provenue_catalogue_fill(); SELECT public.sgp_catalogue_fill();$$);
SELECT public.provenue_catalogue_fill();
SELECT public.sgp_catalogue_fill();

COMMIT;
