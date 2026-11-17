-- Migration 20261115010000 · level:data-collection · lane:A1 (AXS export) · writes:axs_export_sync(+cursor,last_full_error,last_full_error_at),axs_export_fire,axs_export_tick · reads:net._http_response,vault (get_app_secret) · pre:20261114000000
--
-- AXS export: page with TicketsData's cursor instead of page numbers, so the daily full run finishes.
--
-- WHY. The daily full AXS export (axs_export_tick, cron axs_export_tick_1m) has not finished since
-- 2026-11-09 (axs_export_sync.last_full_done_at). TicketsData now refuses a page that skips more
-- than 100,000 rows: GET /events?platform=axs&mode=all&limit=2000&page=55 →
--   400 "page too deep: page x limit may skip at most 100000 rows; use cursor paging (next_cursor)".
-- The US export is 137,227 events (2026-11-15), so page 52 onward failed; the tick retried that page
-- 5 times and stopped the run, and the next hourly incremental cleared last_error on landing, so the
-- failure was invisible. Effects: the tail of the export (~35k events) stopped refreshing, and no run
-- reached the end, so events removed from AXS were never marked gone_at after 2026-11-09.
--
-- THE FIX.
--   · Every run pages by cursor: the first request has no cursor, each next request sends the
--     previous response's body.next_cursor (verified 2026-11-15: 200, next_cursor 'axs_<id>', no depth
--     limit). axs_export_sync.cursor holds it; a retry re-sends the same cursor.
--   · Full runs ask for 5000 rows a page (the API maximum; ~28 pages instead of ~69), incrementals 2000.
--   · A stopped FULL run keeps its reason in last_full_error / last_full_error_at, which a later
--     incremental does not clear (last_error still clears as before).
--   · A 4xx answer is not retried (it will not change); it stops the run at once with the body.
--   · This migration asks for a fresh full run on the next tick (last_full_started_at := NULL) unless one
--     is in flight.
-- Both functions were created on prod without a migration; their full source is now in the repo.
-- Credits: 1 per page, charged through td_charge_credit as before. GET only (RULE 2).

BEGIN;

ALTER TABLE public.axs_export_sync
  ADD COLUMN IF NOT EXISTS cursor             text,
  ADD COLUMN IF NOT EXISTS last_full_error    text,
  ADD COLUMN IF NOT EXISTS last_full_error_at timestamptz;

CREATE OR REPLACE FUNCTION public.axs_export_fire(p_page integer)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s     public.axs_export_sync;
  v_req bigint;
BEGIN
  SELECT * INTO s FROM public.axs_export_sync WHERE id = 1;
  -- p_page only counts pages now; position comes from the cursor (none on a run's first request)
  SELECT net.http_get(
           url := 'https://ticketsdata.com/events',
           params := coalesce(s.run_params, '{}'::jsonb)
                     || jsonb_build_object('platform', 'axs', 'mode', 'all',
                          'username', public.get_app_secret(p_name => 'TICKETSDATA_USERNAME'),
                          'password', public.get_app_secret(p_name => 'TICKETSDATA_PASSWORD'))
                     || CASE WHEN s.cursor IS NOT NULL THEN jsonb_build_object('cursor', s.cursor)
                             ELSE '{}'::jsonb END,
           timeout_milliseconds := 120000) INTO v_req;
  UPDATE public.axs_export_sync
     SET page = p_page, pending_request_id = v_req, pending_since = now(), updated_at = now()
   WHERE id = 1;
  RETURN v_req;
END $function$;

CREATE OR REPLACE FUNCTION public.axs_export_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s       public.axs_export_sync;
  r       record;
  j       jsonb;
  v_rows  int := 0;
  v_gone  int := 0;
  v_err   text;
BEGIN
  SELECT * INTO s FROM public.axs_export_sync WHERE id = 1 FOR UPDATE;

  -- 1. a page is in flight
  IF s.pending_request_id IS NOT NULL THEN
    SELECT x.status_code, x.content INTO r FROM net._http_response x WHERE x.id = s.pending_request_id;
    IF NOT FOUND THEN
      IF s.pending_since > now() - interval '5 minutes' THEN
        RETURN jsonb_build_object('state', 'waiting', 'page', s.page);
      END IF;
      r := NULL;                                           -- lost: retry below
    END IF;

    j := CASE WHEN r IS NOT NULL THEN public.safe_jsonb(r.content) END;
    IF r IS NULL OR r.status_code IS DISTINCT FROM 200 OR jsonb_typeof(j->'body'->'items') IS DISTINCT FROM 'array' THEN
      -- a 4xx will not change on retry; anything else gets 5 tries
      IF s.tries >= 5 OR (r.status_code BETWEEN 400 AND 499 AND r.status_code <> 429) THEN
        v_err := format('%s run stopped on page %s: http %s %s', s.run_kind, s.page,
                        coalesce(r.status_code::text, 'lost'), left(coalesce(r.content, ''), 200));
        UPDATE public.axs_export_sync
           SET run_kind = NULL, pending_request_id = NULL, tries = 0, cursor = NULL, updated_at = now(),
               last_error = v_err,
               last_full_error    = CASE WHEN s.run_kind = 'full' THEN v_err ELSE last_full_error END,
               last_full_error_at = CASE WHEN s.run_kind = 'full' THEN now() ELSE last_full_error_at END
         WHERE id = 1;
        RETURN jsonb_build_object('state', 'run_stopped', 'page', s.page, 'http', r.status_code);
      END IF;
      UPDATE public.axs_export_sync SET tries = tries + 1, pending_request_id = NULL, updated_at = now() WHERE id = 1;
      PERFORM public.axs_export_fire(s.page);              -- same cursor again
      RETURN jsonb_build_object('state', 'retry', 'page', s.page, 'http', r.status_code);
    END IF;

    -- landed: upsert the page
    INSERT INTO public.axs_export_event AS e (
      axs_event_id, type, ticketer, axs_ticketed, status, event_title, event_title_clean, headliner,
      performers, performer_ids, tour_title, genre, major_category, age_restriction,
      venue_id, venue_name, venue_address, venue_city, venue_state, venue_country, venue_postal_code,
      venue_lat, venue_lon, event_date_local, event_date_utc, event_timezone, is_tba,
      announce_utc, onsale_utc, presale_utc, first_seen_utc, last_seen_utc, removed_utc, event_url,
      last_synced_at, gone_at)
    SELECT (i->>'event_id')::bigint, i->>'type', i->>'ticketer', (i->>'axs_ticketed')::boolean, i->>'status',
           i->>'event_title', i->>'event_title_clean', i->>'headliner',
           CASE WHEN jsonb_typeof(i->'performers') = 'array'
                THEN ARRAY(SELECT jsonb_array_elements_text(i->'performers')) END,
           CASE WHEN jsonb_typeof(i->'performer_ids') = 'array'
                THEN ARRAY(SELECT (p #>> '{}')::bigint FROM jsonb_array_elements(i->'performer_ids') p
                            WHERE (p #>> '{}') ~ '^\d+$') END,
           i->>'tour_title', i->>'genre', i->>'major_category', i->>'age_restriction',
           (i->>'venue_id')::bigint, i->>'venue_name', i->>'venue_address', i->>'venue_city',
           i->>'venue_state', i->>'venue_country', i->>'venue_postal_code',
           (i->>'venue_lat')::numeric, (i->>'venue_lon')::numeric,
           i->>'event_date_local', (i->>'event_date_utc')::timestamptz, i->>'event_timezone',
           (i->>'is_tba')::boolean, (i->>'announce_utc')::timestamptz, (i->>'onsale_utc')::timestamptz,
           (i->>'presale_utc')::timestamptz, (i->>'first_seen_utc')::timestamptz,
           (i->>'last_seen_utc')::timestamptz, (i->>'removed_utc')::timestamptz, i->>'event_url',
           now(), NULL
      FROM jsonb_array_elements(j->'body'->'items') i
     WHERE (i->>'event_id') ~ '^\d+$'
    ON CONFLICT (axs_event_id) DO UPDATE SET
      type = EXCLUDED.type, ticketer = EXCLUDED.ticketer, axs_ticketed = EXCLUDED.axs_ticketed,
      status = EXCLUDED.status, event_title = EXCLUDED.event_title,
      event_title_clean = EXCLUDED.event_title_clean, headliner = EXCLUDED.headliner,
      performers = EXCLUDED.performers, performer_ids = EXCLUDED.performer_ids,
      tour_title = EXCLUDED.tour_title, genre = EXCLUDED.genre, major_category = EXCLUDED.major_category,
      age_restriction = EXCLUDED.age_restriction, venue_id = EXCLUDED.venue_id,
      venue_name = EXCLUDED.venue_name, venue_address = EXCLUDED.venue_address,
      venue_city = EXCLUDED.venue_city, venue_state = EXCLUDED.venue_state,
      venue_country = EXCLUDED.venue_country, venue_postal_code = EXCLUDED.venue_postal_code,
      venue_lat = EXCLUDED.venue_lat, venue_lon = EXCLUDED.venue_lon,
      event_date_local = EXCLUDED.event_date_local, event_date_utc = EXCLUDED.event_date_utc,
      event_timezone = EXCLUDED.event_timezone, is_tba = EXCLUDED.is_tba,
      announce_utc = EXCLUDED.announce_utc, onsale_utc = EXCLUDED.onsale_utc,
      presale_utc = EXCLUDED.presale_utc, first_seen_utc = EXCLUDED.first_seen_utc,
      last_seen_utc = EXCLUDED.last_seen_utc, removed_utc = EXCLUDED.removed_utc,
      event_url = EXCLUDED.event_url, last_synced_at = now(), gone_at = NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    PERFORM public.td_charge_credit(1, NULL, 'AXS', '/events?mode=all', 200, (j->>'quota_remaining')::int);

    UPDATE public.axs_export_sync
       SET pending_request_id = NULL, tries = 0, pages_in_run = pages_in_run + 1,
           rows_in_run = rows_in_run + v_rows, last_error = NULL, updated_at = now()
     WHERE id = 1;

    IF coalesce((j->'body'->>'has_more')::boolean, false) AND coalesce(j->'body'->>'next_cursor', '') <> '' THEN
      UPDATE public.axs_export_sync SET cursor = j->'body'->>'next_cursor' WHERE id = 1;
      PERFORM public.axs_export_fire(s.page + 1);
      RETURN jsonb_build_object('state', 'page_landed', 'page', s.page, 'rows', v_rows);
    END IF;

    -- run finished (no more pages)
    IF s.run_kind = 'full' THEN
      UPDATE public.axs_export_event e SET gone_at = now()
       WHERE e.gone_at IS NULL AND e.last_synced_at < s.run_started_at;
      GET DIAGNOSTICS v_gone = ROW_COUNT;
      UPDATE public.axs_export_sync
         SET last_full_done_at = now(), last_full_error = NULL, last_full_error_at = NULL
       WHERE id = 1;
    ELSE
      UPDATE public.axs_export_sync SET last_incr_done_at = now() WHERE id = 1;
    END IF;
    UPDATE public.axs_export_sync SET run_kind = NULL, cursor = NULL, updated_at = now() WHERE id = 1;
    RETURN jsonb_build_object('state', 'run_done', 'kind', s.run_kind, 'pages', s.pages_in_run + 1,
                              'rows', s.rows_in_run + v_rows, 'gone', v_gone);
  END IF;

  -- 2. idle: start a run when one is due
  IF NOT public.td_budget_ok() THEN
    RETURN jsonb_build_object('state', 'budget_blocked');
  END IF;
  IF s.last_full_started_at IS NULL OR s.last_full_started_at < now() - interval '23 hours' THEN
    UPDATE public.axs_export_sync
       SET run_kind = 'full', run_started_at = now(), last_full_started_at = now(),
           run_params = jsonb_build_object('country', 'US', 'type', 'all', 'limit', '5000'),
           cursor = NULL, pages_in_run = 0, rows_in_run = 0, tries = 0
     WHERE id = 1;
  ELSIF coalesce(s.last_incr_started_at, s.last_full_started_at) < now() - interval '1 hour' THEN
    UPDATE public.axs_export_sync
       SET run_kind = 'incremental', run_started_at = now(), last_incr_started_at = now(),
           run_params = jsonb_build_object('country', 'US', 'type', 'all', 'limit', '2000',
                          'new_since', to_char(coalesce(s.last_incr_started_at, s.last_full_started_at)
                                               - interval '30 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
           cursor = NULL, pages_in_run = 0, rows_in_run = 0, tries = 0
     WHERE id = 1;
  ELSE
    RETURN jsonb_build_object('state', 'idle');
  END IF;
  PERFORM public.axs_export_fire(1);
  RETURN jsonb_build_object('state', 'run_started');
END $function$;

REVOKE ALL ON FUNCTION public.axs_export_fire(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.axs_export_tick() FROM PUBLIC, anon, authenticated;

-- A full run on the next tick, unless a run is in flight (it starts after that one ends).
UPDATE public.axs_export_sync SET last_full_started_at = NULL WHERE id = 1 AND run_kind IS NULL;

COMMIT;
