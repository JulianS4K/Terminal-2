-- Migration 20261125150000 · level:data-collection · lane:A1 (data plane: the AXS watch, routed to this session by the operator) · writes:axs_watch_config(+stop_before_start),axs_watch_fill()(replaced: an event is retired before it starts, not after),axs_watch_next()(replaced: an event that starts within stop_before_start is not read),primary_poll_event(AXS rows: retired by the fill),axs_watch_audit(rows) · reads:axs_export_event,axs_watch_poll · pre:20261125023030 (the fill this re-creates),20261125021000 (the next() this re-creates)
--
-- AN AXS EVENT LEAVES THE WATCH SIX HOURS BEFORE IT STARTS, NOT SIX HOURS AFTER.
-- Operator 2026-11-25: "retire 6 hours before event instead of after".
--
-- WHAT IT WAS. Two separate rules governed the end of an event's life in the watch:
--   * READS already stopped at the start. primary_poll_ended(start_utc, event_date) (mig 20261124041030,
--     operator "fix the game day wart, end it at tipoff") is true from start_utc, and primary_poll_due() does
--     not return an event it is true for. So the last read of an event was the one before tip-off.
--   * THE ROW was retired by the nightly fill six hours AFTER the start
--     (coalesce(event_date_utc, start_utc, event_date + 1) < now() - interval '6 hours', audit note 'passed'),
--     and the fill would re-add it while event_date_utc > now(). The six hours were a grace before deletion.
-- So nothing was read between tip-off and the deletion; the window simply held a row nobody used.
--
-- WHAT IT IS NOW. One rule, stop_before_start (axs_watch_config, default 6 hours), applied in three places:
--   * the fill RETIRES a watched event once its start is within stop_before_start
--     (audit note 'starts_soon', replacing 'passed'), so its place goes to another event the same night;
--   * the fill does not PICK an event whose start is within stop_before_start, so a retired one does not
--     come straight back;
--   * axs_watch_next() does not hand an event to the worker inside that window, so the reads stop at the
--     six-hour mark rather than at tip-off. Without this the change would only bite at the next nightly
--     fill and the last six hours would still be read.
-- An event with no start time keeps the date fallback (event_date + 1), so it leaves six hours before
-- midnight after its date, i.e. during the evening it is held.
--
-- WHAT THIS COSTS AND SAVES. The six hours before a start are the busiest for a box office, so this gives up
-- the last reads before the doors; that is the operator's call. It returns each event's place to the list
-- six hours earlier and saves the reads it would have spent in that window (at the hot cadence of 30 minutes,
-- about 12 reads an event).
--
-- KNOWN SIDE EFFECT, not changed here. The two feed views (v_primary_poll_events_feed,
-- v_primary_poll_listings_feed, owned by D0) decide freshness from primary_poll_ended plus listing_max_age
-- (35 minutes) and listing_grace (20 minutes). With the reads stopping six hours out, an event's listings go
-- stale about an hour after its last read, so for roughly the last five hours before a start the feed reports
-- listings_withheld = 'poll_stale' rather than 'event_started'. Giving that window its own reason
-- ('starts_soon') is a change to D0's views and is left for the operator to route.
--
-- rollback: ALTER TABLE public.axs_watch_config DROP COLUMN stop_before_start;
--           re-apply axs_watch_fill() from 20261125023030 and axs_watch_next() from 20261125021000.
--           Events retired early come back at the next fill.

BEGIN;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS stop_before_start interval NOT NULL DEFAULT interval '6 hours'
  CHECK (stop_before_start >= interval '0');

COMMENT ON COLUMN public.axs_watch_config.stop_before_start IS
  'how long before an event starts the watch lets it go: it is not read, not picked, and retired by the fill (mig 20261125150000)';

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


-- The worker is not handed an event that starts within stop_before_start, so the reads stop at the six-hour
-- mark instead of at tip-off (primary_poll_ended). Otherwise this change would only bite at the nightly fill.
CREATE OR REPLACE FUNCTION public.axs_watch_next(p_limit integer DEFAULT NULL, p_worker text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  v_budget jsonb; v_cap integer; v_fired_today integer; v_errors integer; v_newest text; v_due jsonb;
  v_n integer := 0; v_events jsonb := '[]'::jsonb; t record;
BEGIN
  -- the config row is locked for the call: two workers asking at once take turns, and only one gets the lease
  SELECT * INTO v_cfg FROM public.axs_watch_config FOR UPDATE;
  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'paused');
  END IF;
  IF v_cfg.reader <> 'worker' THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'reason', 'the database reads (axs_watch_config.reader)');
  END IF;
  IF p_worker IS NOT NULL THEN
    IF v_cfg.worker_id IS NOT NULL AND v_cfg.worker_id <> p_worker AND v_cfg.worker_lease_until > now() THEN
      RETURN jsonb_build_object('events', '[]'::jsonb, 'hold_s', 10, 'reason', 'another worker holds the lease',
                                'lease_holder', v_cfg.worker_id, 'lease_until', v_cfg.worker_lease_until);
    END IF;
    UPDATE public.axs_watch_config SET worker_id = p_worker, worker_lease_until = now() + make_interval(secs => v_cfg.worker_lease_s) WHERE id;
  END IF;
  v_budget := public.axs_watch_budget();
  v_cap := (v_budget->>'daily_cap')::integer;
  v_fired_today := (v_budget->>'fired_today')::integer;
  -- upstream trouble: three of the last ten reads failed upstream and so did the newest; try again in a minute
  SELECT count(*) FILTER (WHERE x.outcome IN ('upstream_error', 'timeout', 'lost')), max(x.outcome) FILTER (WHERE x.rn = 1)
    INTO v_errors, v_newest
    FROM (SELECT p.outcome, row_number() OVER (ORDER BY p.checked_at DESC) AS rn
            FROM public.axs_watch_poll p WHERE p.checked_at IS NOT NULL ORDER BY p.checked_at DESC LIMIT 10) x;
  IF v_errors >= v_cfg.upstream_errors_max AND v_newest IN ('upstream_error', 'timeout', 'lost') THEN
    RETURN jsonb_build_object('events', '[]'::jsonb, 'hold_s', 60, 'upstream_errors', v_errors,
                              'daily_cap', v_cap, 'fired_today', v_fired_today);
  END IF;
  v_due := public.primary_poll_due('axs', coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                                                      WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL), '[]'::jsonb));
  FOR t IN SELECT e.source_event_id, e.ticket_url, e.poll_interval, e.event_date
             FROM public.primary_poll_event e
            WHERE e.source = 'axs' AND e.ticket_url IS NOT NULL
              AND e.source_event_id IN (SELECT jsonb_array_elements_text(v_due))
              AND NOT EXISTS (SELECT 1 FROM public.axs_watch_poll p WHERE p.axs_event_id = e.source_event_id AND p.checked_at IS NULL)
              -- not inside stop_before_start: the reads stop six hours before the start, not at tip-off (mig 20261125150000)
              AND (coalesce(e.start_utc, (e.event_date + 1)::timestamptz) IS NULL
                   OR coalesce(e.start_utc, (e.event_date + 1)::timestamptz) > now() + v_cfg.stop_before_start)
            ORDER BY e.next_poll_at NULLS FIRST, e.event_date NULLS LAST, e.source_event_id
  LOOP
    EXIT WHEN v_n >= least(coalesce(p_limit, v_cfg.worker_batch), v_cfg.worker_batch);
    IF v_fired_today + v_n >= v_cap THEN
      -- over the day's share: only an event on a hot cadence, and only up to the overrun
      CONTINUE WHEN t.poll_interval IS NULL OR t.poll_interval > v_cfg.hot_every;
      CONTINUE WHEN v_fired_today + v_n >= v_cap + (v_cap * v_cfg.hot_overrun_pct) / 100;
    END IF;
    v_events := v_events || jsonb_build_object('id', t.source_event_id, 'url', t.ticket_url,
                                               'every_min', (extract(epoch FROM t.poll_interval) / 60)::integer);
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('events', v_events, 'spacing_ms', v_cfg.read_spacing_ms, 'upstream_errors', v_errors,
                            'daily_cap', v_cap, 'fired_today', v_fired_today, 'pool_remaining', v_budget->'pool_remaining',
                            'lease_s', CASE WHEN p_worker IS NOT NULL THEN v_cfg.worker_lease_s END);
END $function$;

COMMIT;
