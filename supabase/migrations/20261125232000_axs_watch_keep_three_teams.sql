-- Migration 20261125232000 · level:data-collection · lane:a1 (AXS watch list) · writes:axs_watch_config(+keep_regex),axs_watch_rule_ok()(replaced),axs_watch_fill()(replaced),axs_watch_cadence(reseeded) · reads:axs_export_event,primary_poll_event
--
-- ============================================================================
-- Migration 20261125232000 — the AXS watch holds three teams and nothing else
--
-- Lane:     a1 (AXS watch list)
-- Touches:  axs_watch_config (+keep_regex, watch_from), axs_watch_rule_ok() (REPLACED),
--           axs_watch_fill() (REPLACED — one new retire reason), axs_watch_cadence
--           (intervals re-seeded for the smaller list).
-- pre:      20261125214500 (axs_watch_cadence must exist to be re-seeded).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes which events the
-- existing reader is told to read, and how often.
--
-- ── WHAT THE OPERATOR ASKED FOR ───────────────────────────────────────────
-- Operator 2026-11-25: "poll kings, knights, rockets first and only push out those
-- events", then "Just poll these first", then "No just poll these remove rest for now".
-- The third message settles it: the other events come OUT of the watch, they are not
-- demoted to a slow band. "for now" is why this is one regex on the config and not a
-- rewrite — putting the old list back is an UPDATE of one column.
--
-- ── WHY A TITLE RULE AND NOT A VENUE LIST ─────────────────────────────────
-- The three teams play at three AXS venues, but those venues are not three teams:
-- Crypto.com Arena, Toyota Center and T-Mobile Arena carry 135 watched events, of which
-- 84 are team games and 51 are Disney On Ice, Trans-Siberian Orchestra, UFC 335, PBR,
-- KPop Demon Hunters, Nickelback and the rest. Disabling the other venues would have
-- kept all 51. So the gate is on the title, which is also what makes it self-maintaining:
-- as the schedule extends, next season's games match and join at the 03:20Z fill, while
-- a concert booked into the same arena never does.
--
-- Checked against the live export (2026-11-25 23:1xZ): 89 eligible events match, all
-- three at their home venues — 32 Kings (Crypto.com), 29 Rockets (Toyota Center),
-- 28 Golden Knights (T-Mobile Arena), 2026-11-28 to 2027-04-10. No away game of the
-- three sits at another AXS venue today, but the rule is deliberately NOT venue-pinned,
-- so one would be picked up if AXS starts selling it.
--
-- ── watch_from WAS HIDING THE NEAREST GAMES ───────────────────────────────
-- watch_from stood at 2026-12-01, a floor on the event date, so the three fixtures on
-- 11-28 and 11-29 — the closest and therefore the most valuable listings on the list —
-- could not be watched at all. It moves to 2026-11-25 (today). A floor in the past is
-- no restriction, which is the state this should have been in; it is left as a date
-- rather than dropped so the operator can re-raise it.
--
-- ── THE LADDER TIGHTENS, BECAUSE THE LIST IS A THIRD THE SIZE ─────────────
-- 20261125214500 sized its bands for 275-305 events. With 89 the same budgets buy a much
-- fresher read, so every band comes down:
--
--   days out    events   was      now     reads/h
--   <= 2             0   15 min   10 min        -
--   2 - 7            6   20 min   10 min     36.0
--   7 - 14           5   30 min   15 min     20.0
--   14 - 30          6   45 min   20 min     18.0
--   30 - 60         22   90 min   30 min     44.0
--   60 - 120        37    3 h     60 min     37.0
--   120 +           13    6 h      2 h        6.5
--   TOTAL           89                      162 /h    3,876 /day
--
-- The totals are deliberately the same 162 reads/h as before: the whole gain is spent on
-- freshness, not on load. Against the budgets this had to fit:
--   CPU / processing: 47% of an average hour's measured 339 reads, 78% of the worst hour
--     observed today (207, a restart hour), so it still holds THROUGH a restart hour.
--   Daily: 3,876 against the TicketsData daily gate's ~5,878 (7,500 / 1.276) — 66%.
--   Freshness where it is bought: a game inside a week goes from a 20-minute read to 10,
--     and one inside 60 days from 90 minutes to 30.
-- The near bands cannot crowd: three teams play at most ~3 home games each in any week,
-- so the 10-minute band holds ~9 events in the worst case (54 reads/h), not 89.
--
-- ⚠ hot_every (30 min) still bounds the over-cap branch of axs_watch_next(). With this
-- ladder "hot" means an event inside 60 days — 39 of the 89 — which is the intended
-- triage. Lower a band below 30 minutes and more events qualify; raise one above and
-- they stop.
--
-- ── WHAT LEAVES, AND WHAT GOES WITH IT ────────────────────────────────────
-- The fill retires the 221 events that no longer match, through the SAME path it already
-- uses for an event that leaves the export: an audit row then a DELETE from
-- primary_poll_event. primary_poll_listing is ON DELETE CASCADE, so their stored listings
-- (~49,000 rows) go with them — that is existing behaviour for every retirement, not
-- something this migration invents. The push-out follows the watch: both
-- v_primary_poll_listings_feed and the catalogue feed serve what is watched, so removing
-- the events is what makes "only push out those events" true, with no change to the
-- shape of what is sent.
--
-- The stop rules are untouched: stop_before_start (6 h), watch_until_days (180),
-- the upcoming-sale exclusion and onsale_delay all still apply on top of the keep rule.
-- target_events stays at 305. It no longer binds (89 << 305), so each venue's quota run
-- will log a 'short' audit row — noise, not an error, and left alone so that restoring
-- the old list needs only keep_regex cleared.
-- ============================================================================

BEGIN;

-- ── 1. the keep rule ──────────────────────────────────────────────────────
ALTER TABLE public.axs_watch_config ADD COLUMN IF NOT EXISTS keep_regex text;
COMMENT ON COLUMN public.axs_watch_config.keep_regex IS
  'When set, ONLY events whose title matches this regex are watched — applied to new candidates and to events already on the list (mig 20261125232000). NULL = no restriction. Case-insensitive.';

-- The gate every candidate passes, and (from this migration) every watched event keeps
-- passing: a title, not excluded, inside the sports rule, and inside keep_regex if one is set.
CREATE OR REPLACE FUNCTION public.axs_watch_rule_ok(p_category text, p_title text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(p_title, '') <> ''
     AND p_title !~* (SELECT c.exclude_regex FROM public.axs_watch_config c)
     AND (coalesce(p_category, '') <> 'Sports' OR p_title ~* (SELECT c.sports_keep_regex FROM public.axs_watch_config c))
     AND coalesce(p_title ~* (SELECT c.keep_regex FROM public.axs_watch_config c), true)
$function$;

UPDATE public.axs_watch_config
   SET keep_regex = '(\mla kings\M|los angeles kings|vegas golden knights|houston rockets)',
       watch_from = '2026-11-25'::date;

-- ── 2. the ladder, re-sized for 89 events ─────────────────────────────────
UPDATE public.axs_watch_cadence c SET every = v.every, set_at = now()
  FROM (VALUES ('d0_2',    interval '10 minutes'),
               ('d2_7',    interval '10 minutes'),
               ('d7_14',   interval '15 minutes'),
               ('d14_30',  interval '20 minutes'),
               ('d30_60',  interval '30 minutes'),
               ('d60_120', interval '60 minutes'),
               ('d120_up', interval '2 hours')) AS v(band, every)
 WHERE c.band = v.band;

-- ── 3. the fill retires what the keep rule no longer covers ───────────────
-- One change from the form applied as 20261125013030: the _aw_retire set gains a
-- 'not_kept' arm, so a change to keep_regex (or to exclude_regex / sports_keep_regex)
-- takes events OFF the list at the next fill, not only off the candidate list. Without
-- it the 221 non-team events would have sat on the watch forever, read and pushed out,
-- because nothing in the retire set looked at the rules.
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

  -- 1. retire: the event starts within stop_before_start or lies beyond the horizon, the export no longer lists
  --    it or no longer says AXS sells it, the watch rules no longer cover it (mig 20261125232000), three reads in
  --    a row said AXS does not sell it (not_axs) or it is over (expired), or it is not on sale yet (mig 20261125013030)
  DROP TABLE IF EXISTS _aw_retire;
  CREATE TEMP TABLE _aw_retire ON COMMIT DROP AS
  SELECT t.source_event_id, t.venue_name,
         CASE WHEN e.axs_event_id IS NULL THEN 'not_in_export'
              WHEN e.gone_at IS NOT NULL OR e.removed_utc IS NOT NULL THEN 'gone'
              WHEN NOT coalesce(e.axs_ticketed, false) THEN 'not_axs_sold'
              WHEN NOT public.axs_watch_rule_ok(e.major_category, coalesce(e.event_title, t.name)) THEN 'not_kept'
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
          OR NOT public.axs_watch_rule_ok(e.major_category, coalesce(e.event_title, t.name))
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
