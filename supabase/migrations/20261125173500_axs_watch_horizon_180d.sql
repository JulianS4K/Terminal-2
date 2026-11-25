-- Migration 20261125173500 · level:data-collection · lane:A1 (data plane: the AXS watch, routed to this session by the operator) · writes:axs_watch_config(+watch_until_days),axs_watch_fill()(replaced: a horizon caps how far out a place may be spent),primary_poll_event(AXS rows beyond the horizon retired),axs_watch_audit(rows) · reads:axs_export_event,axs_watch_poll · pre:20261125150000 (the fill this re-creates)
--
-- A PLACE IS NOT SPENT MORE THAN 180 DAYS OUT.
-- Operator 2026-11-25: "180 days ceiling on events".
--
-- WHY A CEILING MATTERS MORE UNDER THE QUEUE. The operator's rule is that an event, once added, stays until a
-- date rule removes it, never because the ranking moved; the ranking only decides what joins next. Admission is
-- therefore near-permanent, and a slot given to an event 320 days out is a slot the queue cannot reach for 320
-- days. Measured 2026-11-25: the list reached to 2027-10-07 while 331 eligible events sat inside 120 days, so
-- the reach was an artefact of per-venue quotas walking the calendar, not of scarcity. A horizon bounds how
-- long one admission can hold a place.
--
-- WHY 180 AND NOT 120. Eligible events at the enabled venues, 2026-11-25: 331 within 120 days, 439 within 180,
-- 505 in all. Against target_events = 305 that is 26 spare at 120 days and 134 at 180 — the tighter ceiling
-- leaves the list one thin week away from not filling (RodeoHouston going off sale dropped it to 178 on
-- 2026-11-24), the looser one has real slack. 66 eligible events lie beyond 180 days.
--
-- WHAT IT DOES. axs_watch_config.watch_until_days (180; NULL means no ceiling) bounds the far end of the list
-- as watch_from bounds the near end:
--   * the fill does not PICK an event whose local date is more than watch_until_days out;
--   * the fill RETIRES a watched event beyond it (audit: retire / beyond_horizon).
-- Symmetric with stop_before_start (mig 20261125150000), which bounds the other end the same way, and a date
-- rule in the operator's sense — so retiring on it is the sanctioned removal reason, not a ranking eviction.
--
-- EFFECT ON APPLY. 30 watched events currently sit beyond 180 days and are retired at the next fill, freeing 30
-- places that the fill immediately gives to nearer eligible events. To grandfather them instead, set
-- watch_until_days = NULL before the fill runs and the list is left as it is.
--
-- NOT CHANGED HERE. watch_from is still 2026-12-01, so the next six days remain outside the list and the day-of
-- rung stays unused; that is a separate operator call.
--
-- rollback: UPDATE public.axs_watch_config SET watch_until_days = NULL;  (the ceiling stops binding at once;
--           retired events return at the next fill) or re-apply axs_watch_fill() from 20261125150000 and
--           ALTER TABLE public.axs_watch_config DROP COLUMN watch_until_days.

BEGIN;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS watch_until_days integer DEFAULT 180
  CHECK (watch_until_days IS NULL OR watch_until_days > 0);

UPDATE public.axs_watch_config SET watch_until_days = 180, updated_at = now()
 WHERE watch_until_days IS DISTINCT FROM 180;

COMMENT ON COLUMN public.axs_watch_config.watch_until_days IS
  'how many days out a place may be spent: the fill neither picks nor keeps an event beyond it (NULL = no ceiling). Bounds the far end as watch_from bounds the near end (mig 20261125173500)';

CREATE OR REPLACE FUNCTION public.axs_watch_fill(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_cfg public.axs_watch_config%ROWTYPE;
  v     record;
  v_have integer; v_room integer; v_need integer; v_added integer; v_retired integer := 0; v_total_added integer := 0;
  v_short jsonb := '[]'::jsonb;
  v_kept integer; v_borrowed integer; v_returned integer := 0; v_backfilled integer := 0;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('axs_watch_fill')) THEN
    RETURN jsonb_build_object('skipped', 'another axs_watch_fill is running');
  END IF;
  SELECT * INTO v_cfg FROM public.axs_watch_config;

  -- 1. retire: the event starts within stop_before_start, the export no longer lists it or no longer says AXS
  --    sells it, three reads in a row said AXS does not sell it (not_axs) or it is over (expired), or it is not
  --    on sale yet (mig 20261125013030): its last read said so, or the discovery feed marks it as an upcoming
  --    sale and no read has found tickets
  DROP TABLE IF EXISTS _aw_retire;
  CREATE TEMP TABLE _aw_retire ON COMMIT DROP AS
  SELECT t.source_event_id, t.venue_name,
         CASE WHEN e.axs_event_id IS NULL THEN 'not_in_export'
              WHEN e.gone_at IS NOT NULL OR e.removed_utc IS NOT NULL THEN 'gone'
              WHEN NOT coalesce(e.axs_ticketed, false) THEN 'not_axs_sold'
              WHEN coalesce(e.event_date_utc, t.start_utc, (t.event_date + 1)::timestamptz) < now() + v_cfg.stop_before_start THEN 'starts_soon'
              WHEN v_cfg.watch_until_days IS NOT NULL
                   AND coalesce(t.event_date, (e.event_date_utc)::date) > current_date + v_cfg.watch_until_days THEN 'beyond_horizon'
              WHEN public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status)
                   OR (public.axs_watch_upcoming_sale(e.status, e.onsale_utc, v_cfg.onsale_delay) AND NOT (t.poll_status = 'ok' AND coalesce(t.listing_count, 0) > 0))
                   THEN 'not_on_sale'
              ELSE 'not_axs_or_expired' END AS why
    FROM public.primary_poll_event t
    LEFT JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id
    -- the last read; one made before the event's on-sale date says nothing about the sale, and is not counted
    LEFT JOIN LATERAL (SELECT w.outcome, w.error FROM public.axs_watch_poll w
                        WHERE w.axs_event_id = t.source_event_id AND w.checked_at IS NOT NULL
                          AND (e.onsale_utc IS NULL OR w.checked_at > e.onsale_utc)
                        ORDER BY w.checked_at DESC LIMIT 1) lr ON true
   WHERE t.source = 'axs'
     AND (e.axs_event_id IS NULL OR e.gone_at IS NOT NULL OR e.removed_utc IS NOT NULL OR NOT coalesce(e.axs_ticketed, false)
          OR coalesce(e.event_date_utc, t.start_utc, (t.event_date + 1)::timestamptz) < now() + v_cfg.stop_before_start
          OR (v_cfg.watch_until_days IS NOT NULL
              AND coalesce(t.event_date, (e.event_date_utc)::date) > current_date + v_cfg.watch_until_days)
          OR public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status)
          OR (public.axs_watch_upcoming_sale(e.status, e.onsale_utc, v_cfg.onsale_delay) AND NOT (t.poll_status = 'ok' AND coalesce(t.listing_count, 0) > 0))
          OR (SELECT count(*) = 3 AND bool_and(w.outcome IN ('not_axs', 'expired'))
                FROM (SELECT w.outcome FROM public.axs_watch_poll w
                       WHERE w.axs_event_id = t.source_event_id AND w.checked_at IS NOT NULL
                       ORDER BY w.fired_at DESC LIMIT 3) w));
  SELECT count(*) INTO v_retired FROM _aw_retire;
  IF p_apply THEN
    INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
    SELECT v_run, 'retire', r.source_event_id, r.venue_name, r.why FROM _aw_retire r;
    DELETE FROM public.primary_poll_event t USING _aw_retire r WHERE t.source = 'axs' AND t.source_event_id = r.source_event_id;
    -- the export's match arriving later than the row: fill-only, as the mapper does for the other sources
    UPDATE public.primary_poll_event t
       SET tevo_event_id = e.tevo_event_id, tevo_match_method = 'axs_export', tevo_matched_at = now()
      FROM public.axs_export_event e
     WHERE t.source = 'axs' AND t.tevo_event_id IS NULL
       AND e.axs_event_id::text = t.source_event_id AND e.tevo_event_id IS NOT NULL;
  END IF;

  -- the watched events that stay, each venue's in date order: one past its venue's quota holds a borrowed place
  DROP TABLE IF EXISTS _aw_keep;
  CREATE TEMP TABLE _aw_keep ON COMMIT DROP AS
  SELECT k.source_event_id, k.venue_name, k.venue_id, k.event_date_utc, k.rn > coalesce(k.quota, 0) AS borrowed
    FROM (SELECT t.source_event_id, t.venue_name, e.venue_id, e.event_date_utc, wv.quota,
                 row_number() OVER (PARTITION BY e.venue_id ORDER BY e.event_date_utc, e.axs_event_id) AS rn
            FROM public.primary_poll_event t
            JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id
            LEFT JOIN public.axs_watch_venue wv ON wv.axs_venue_id = e.venue_id AND wv.enabled
           WHERE t.source = 'axs'
             AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = t.source_event_id)) k;
  SELECT count(*), count(*) FILTER (WHERE k.borrowed) INTO v_kept, v_borrowed FROM _aw_keep k;

  -- the events that may join, at every enabled venue: one rule for the venues' own places and for the backfill
  DROP TABLE IF EXISTS _aw_cand;
  CREATE TEMP TABLE _aw_cand ON COMMIT DROP AS
  SELECT e.axs_event_id, e.venue_id, e.event_title, e.event_date_local, e.event_date_utc, e.event_timezone, e.venue_name, e.venue_city,
         e.venue_state, e.event_url, e.tevo_event_id
    FROM public.axs_export_event e
    JOIN public.axs_watch_venue wv ON wv.axs_venue_id = e.venue_id AND wv.enabled
   WHERE e.gone_at IS NULL AND e.removed_utc IS NULL AND coalesce(e.axs_ticketed, false)
     -- an event inside stop_before_start is not picked, so one retired for starting soon does not come back
     AND e.event_date_utc > now() + v_cfg.stop_before_start AND e.event_url IS NOT NULL
     AND e.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' AND left(e.event_date_local, 10)::date >= v_cfg.watch_from
     -- the horizon: nothing further out than watch_until_days takes a place (NULL = no ceiling)
     AND (v_cfg.watch_until_days IS NULL
          OR left(e.event_date_local, 10)::date <= current_date + v_cfg.watch_until_days)
     AND public.axs_watch_rule_ok(e.major_category, e.event_title)
     AND NOT EXISTS (SELECT 1 FROM _aw_keep k WHERE k.source_event_id = e.axs_event_id::text)
     AND NOT EXISTS (SELECT 1 FROM _aw_retire r WHERE r.source_event_id = e.axs_event_id::text)
     -- not an upcoming sale: the discovery feed marks it as one (until onsale_delay after its on-sale date; with
     -- no date, while labelled Coming Soon), or the event's last read (within not_on_sale_recheck, 7 days, and made
     -- after its on-sale date, if it has one) said it is not on sale. After that it is tried once more.
     AND NOT public.axs_watch_upcoming_sale(e.status, e.onsale_utc, v_cfg.onsale_delay)
     AND NOT EXISTS (SELECT 1
                       FROM (SELECT w.outcome, w.error, w.checked_at FROM public.axs_watch_poll w
                              WHERE w.axs_event_id = e.axs_event_id::text AND w.checked_at IS NOT NULL
                              ORDER BY w.checked_at DESC LIMIT 1) lr
                      WHERE lr.checked_at > now() - v_cfg.not_on_sale_recheck
                        AND (e.onsale_utc IS NULL OR lr.checked_at > e.onsale_utc)
                        AND public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status))
     -- not an event TicketsData has said three times (in the 14 days the ledger keeps) that AXS does not sell or that is over
     AND (SELECT count(*) FROM public.axs_watch_poll w WHERE w.axs_event_id = e.axs_event_id::text AND w.outcome IN ('not_axs', 'expired')) < 3;

  DROP TABLE IF EXISTS _aw_pick;
  CREATE TEMP TABLE _aw_pick ON COMMIT DROP AS SELECT c.*, false AS backfill FROM _aw_cand c WHERE false;

  -- 2. refill each venue to its quota, soonest first, within the list's size (a borrowed place counts as free)
  -- smallest quota first: when the list's size caps the total, the biggest venue gives, not the operator's two Soldier Field picks
  FOR v IN SELECT * FROM public.axs_watch_venue WHERE enabled ORDER BY quota, axs_venue_id LOOP
    SELECT count(*) INTO v_have FROM _aw_keep k WHERE k.venue_id = v.axs_venue_id;
    v_room := v_cfg.target_events - (v_kept - v_borrowed) - v_total_added;
    v_need := least(greatest(v.quota - v_have, 0), greatest(v_room, 0));
    CONTINUE WHEN v_need = 0;
    WITH p AS (
      INSERT INTO _aw_pick
      SELECT c.*, false FROM _aw_cand c WHERE c.venue_id = v.axs_venue_id ORDER BY c.event_date_utc, c.axs_event_id LIMIT v_need
      RETURNING 1)
    SELECT count(*) INTO v_added FROM p;
    DELETE FROM _aw_cand c USING _aw_pick p WHERE c.axs_event_id = p.axs_event_id;
    IF v_added < v_need THEN
      v_short := v_short || jsonb_build_object('venue', v.venue_name, 'quota', v.quota, 'short_by', v_need - v_added);
      IF p_apply THEN
        INSERT INTO public.axs_watch_audit (run_id, action, venue, note)
        VALUES (v_run, 'short', v.venue_name, format('quota %s, %s eligible upcoming events short', v.quota, v_need - v_added));
      END IF;
    END IF;
    v_total_added := v_total_added + v_added;
  END LOOP;

  -- 3. give back: the venues' own picks come first, so a borrowed place goes when the list is over its size,
  --    the furthest event first
  v_returned := least(greatest(v_kept + v_total_added - v_cfg.target_events, 0), v_borrowed);
  IF v_returned > 0 THEN
    DROP TABLE IF EXISTS _aw_back;
    CREATE TEMP TABLE _aw_back ON COMMIT DROP AS
    SELECT k.source_event_id, k.venue_name FROM _aw_keep k WHERE k.borrowed ORDER BY k.event_date_utc DESC, k.source_event_id DESC LIMIT v_returned;
    IF p_apply THEN
      INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
      SELECT v_run, 'retire', b.source_event_id, b.venue_name, 'backfill_returned' FROM _aw_back b;
      DELETE FROM public.primary_poll_event t USING _aw_back b WHERE t.source = 'axs' AND t.source_event_id = b.source_event_id;
    END IF;
  END IF;

  -- 4. backfill: the places still free go to the other eligible events, whatever their venue's quota, soonest first
  v_room := v_cfg.target_events - (v_kept - v_returned) - v_total_added;
  IF v_cfg.backfill AND v_room > 0 THEN
    WITH p AS (
      INSERT INTO _aw_pick
      SELECT c.*, true FROM _aw_cand c ORDER BY c.event_date_utc, c.axs_event_id LIMIT v_room
      RETURNING 1)
    SELECT count(*) INTO v_backfilled FROM p;
  END IF;

  IF p_apply AND (v_total_added + v_backfilled) > 0 THEN
    INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_local_time, start_utc, timezone,
        venue_name, venue_city, venue_state, ticket_url, tevo_event_id, tevo_match_method, tevo_matched_at, announced_at)
    SELECT 'axs', p.axs_event_id::text, p.event_title,
           CASE WHEN p.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN left(p.event_date_local, 10)::date END,
           CASE WHEN p.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}' THEN substr(p.event_date_local, 12, 5)::time END,
           p.event_date_utc, p.event_timezone, p.venue_name, p.venue_city, p.venue_state, p.event_url,
           p.tevo_event_id, CASE WHEN p.tevo_event_id IS NOT NULL THEN 'axs_export' END,
           CASE WHEN p.tevo_event_id IS NOT NULL THEN now() END,
           now()                       -- the mapper is not asked: the export's own match is the AXS match
      FROM _aw_pick p
    ON CONFLICT (source, source_event_id) DO NOTHING;
    INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
    SELECT v_run, 'add', p.axs_event_id::text, p.venue_name,
           CASE WHEN p.backfill THEN 'backfill: ' ELSE '' END || left(p.event_date_local, 16) || ' ' || p.event_title
      FROM _aw_pick p;
  END IF;

  -- 5. the run: the feed serves the watched events and no other; the ledger forgets old requests
  IF p_apply THEN
    PERFORM public.primary_poll_run_done('axs', replace(v_run::text, '-', ''),
              coalesce((SELECT jsonb_agg(t.source_event_id) FROM public.primary_poll_event t WHERE t.source = 'axs'), '[]'::jsonb));
    DELETE FROM public.axs_watch_poll WHERE fired_at < now() - interval '14 days';
    DELETE FROM public.axs_watch_audit WHERE at < now() - interval '90 days';
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object('run', v_run, 'apply', p_apply, 'retired', v_retired + v_returned, 'added', v_total_added + v_backfilled,
           'backfilled', nullif(v_backfilled, 0), 'returned', nullif(v_returned, 0),
           'watched', CASE WHEN p_apply THEN (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = 'axs')
                           ELSE (SELECT count(*) FROM public.primary_poll_event t WHERE t.source = 'axs') - v_retired - v_returned + v_total_added + v_backfilled END,
           'short', v_short));
END $function$;

COMMIT;
