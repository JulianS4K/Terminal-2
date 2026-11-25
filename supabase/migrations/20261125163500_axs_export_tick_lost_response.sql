-- Migration 20261125163500 · level:data-collection · lane:A1 (data plane: the AXS export/discovery feed, routed to this session by the operator) · writes:axs_export_tick()(replaced: a lost pg_net response no longer raises) · reads:net._http_response,axs_export_sync · pre:20261115010000 (the tick this re-creates)
--
-- A LOST pg_net RESPONSE NO LONGER KILLS THE AXS EXPORT FEED.
-- Operator 2026-11-25: "fix it yourself", after the monitor flagged the feed dead (bot_chat 7498).
--
-- WHAT BROKE. axs_export_tick (cron axs_export_tick_1m, job 698) failed 96 runs in a row, every minute from
-- 14:28:00Z to 16:31:00Z, with:
--   ERROR: record "r" is not assigned yet
--   DETAIL: The tuple structure of a not-yet-assigned record is indeterminate.
-- The AXS discovery/export feed was therefore dead for 2h03m: the full run froze on page 13 (65,000 rows,
-- pending_since 14:22Z), no incremental ran after 13:55Z, no event was discovered and no gone_at was marked.
--
-- WHY. The Postgres restart at 14:24:16Z dropped net._http_response: the tick was waiting on
-- pending_request_id 8448 while the newest surviving response id was 1558, so the row it wanted was gone.
-- That is the tick's own "lost" case, which mig 20261115010000 wrote a retry for:
--     SELECT x.status_code, x.content INTO r FROM net._http_response x WHERE x.id = s.pending_request_id;
--     IF NOT FOUND THEN ... r := NULL;  -- lost: retry below
--     j := CASE WHEN r IS NOT NULL THEN ... END;      -- raises here
-- `r` is a PL/pgSQL RECORD. A SELECT INTO that returns no row leaves it UNASSIGNED, and assigning NULL to a
-- RECORD does not make it a usable NULL row — it stays indeterminate. So `r IS NOT NULL` raised before the
-- retry could run. The intent was always for the lost case to be NULL-ish: the error text already said
-- coalesce(r.status_code::text, 'lost'). Only the mechanism was wrong.
--
-- It could not self-heal. tries stays 0 because the function raises before the UPDATE that increments it, so
-- the five-tries-then-stop path of mig 20261115010000 never engaged and every later tick hit the same line.
--
-- THE FIX. The response is read into scalars with a FOUND flag instead of a RECORD:
--   v_found boolean; v_status integer; v_content text;
--   SELECT ... INTO v_status, v_content ...;  v_found := FOUND;
-- and the three tests become NOT v_found / v_status / v_content. Behaviour is otherwise byte-identical: a
-- response still within 5 minutes returns 'waiting'; a lost or non-200 one retries with the same cursor and
-- increments tries; a 4xx that is not 429, or a sixth try, stops the run and records last_error. Nothing
-- about paging, credits or the upsert changes.
--
-- RECOVERY. On the next tick the lost page is retried from the cursor it held (page 13), so the frozen full
-- run resumes rather than restarting; if the page keeps failing, five tries then stop the run and the next
-- tick starts a fresh one.
--
-- Read-only towards TicketsData (RULE 2): the tick only GETs /events, through axs_export_fire, unchanged.
--
-- rollback: re-apply axs_export_tick() from 20261115010000 — but that restores the bug, so prefer fixing
--           forward. The function is the only object this migration touches; re-apply is a no-op.

BEGIN;

CREATE OR REPLACE FUNCTION public.axs_export_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s       public.axs_export_sync;
  v_found boolean; v_status integer; v_content text;
  j       jsonb;
  v_rows  int := 0;
  v_gone  int := 0;
  v_err   text;
BEGIN
  SELECT * INTO s FROM public.axs_export_sync WHERE id = 1 FOR UPDATE;

  -- 1. a page is in flight
  IF s.pending_request_id IS NOT NULL THEN
    -- scalars, not a RECORD: a lost response must stay testable. `r := NULL` on an unassigned RECORD left it
    -- indeterminate, so the next `r IS NOT NULL` raised and the tick could never take its own retry path.
    SELECT x.status_code, x.content INTO v_status, v_content FROM net._http_response x WHERE x.id = s.pending_request_id;
    v_found := FOUND;
    IF NOT v_found THEN
      IF s.pending_since > now() - interval '5 minutes' THEN
        RETURN jsonb_build_object('state', 'waiting', 'page', s.page);
      END IF;
      -- lost: v_status and v_content stay NULL and the branch below retries
    END IF;

    j := CASE WHEN v_found THEN public.safe_jsonb(v_content) END;
    IF NOT v_found OR v_status IS DISTINCT FROM 200 OR jsonb_typeof(j->'body'->'items') IS DISTINCT FROM 'array' THEN
      -- a 4xx will not change on retry; anything else gets 5 tries
      IF s.tries >= 5 OR (v_status BETWEEN 400 AND 499 AND v_status <> 429) THEN
        v_err := format('%s run stopped on page %s: http %s %s', s.run_kind, s.page,
                        coalesce(v_status::text, 'lost'), left(coalesce(v_content, ''), 200));
        UPDATE public.axs_export_sync
           SET run_kind = NULL, pending_request_id = NULL, tries = 0, cursor = NULL, updated_at = now(),
               last_error = v_err,
               last_full_error    = CASE WHEN s.run_kind = 'full' THEN v_err ELSE last_full_error END,
               last_full_error_at = CASE WHEN s.run_kind = 'full' THEN now() ELSE last_full_error_at END
         WHERE id = 1;
        RETURN jsonb_build_object('state', 'run_stopped', 'page', s.page, 'http', v_status);
      END IF;
      UPDATE public.axs_export_sync SET tries = tries + 1, pending_request_id = NULL, updated_at = now() WHERE id = 1;
      PERFORM public.axs_export_fire(s.page);              -- same cursor again
      RETURN jsonb_build_object('state', 'retry', 'page', s.page, 'http', v_status);
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

COMMIT;
