-- Migration 20261126060000 · level:data-collection · lane:a1 (AXS watch + feed) · writes:primary_poll_event(+watch),axs_watch_config(+catalogue_until_days,target_events),axs_watch_venue(18 venues keep_all,quota 0),primary_poll_due()(replaced),axs_watch_next()(replaced in place),axs_queue_fill()(replaced in place),axs_watch_fill()(replaced in place),axs_catalogue_fill()(new) · reads:axs_export_event
--
-- ============================================================================
-- Migration 20261126060000 — the API lists every event; we only READ 310 of them
--
-- Lane:     a1 (AXS watch + the primary-poll feed)
-- Touches:  primary_poll_event (+watch), axs_watch_config (+catalogue_until_days,
--           target_events 230 -> 310), axs_watch_venue (18 more venues keep_all, all
--           quotas 0), primary_poll_due() (REPLACED), axs_watch_next() /
--           axs_queue_fill() / axs_watch_fill() (patched in place),
--           axs_catalogue_fill() (NEW).
-- pre:      20261126044500 (keep_all, trust_axs_sold), 20261126053000 (the pacer).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes which events we
-- read and which we merely publish. No price, hold or order path is touched.
--
-- ── WHAT THE OPERATOR ASKED FOR ───────────────────────────────────────────
-- Operator 2026-11-26: "send listings for up to 310 upcoming events from the venues i
-- listed, but send the api all events from those venues".
--
-- Two different sets, which the schema had conflated into one. primary_poll_event has
-- been both "the events we read" and "the events the API knows about", because
-- v_primary_poll_events_feed is built from it. So an event we chose not to read was
-- invisible to consumers rather than visible-without-listings.
--
-- The feed already had the vocabulary for this. Its listings_withheld column returns
-- 'not_polled' when poll_status = 'pending', alongside 'poll_failed', 'poll_stale' and
-- 'event_started'. Nothing had ever put a row in that state on purpose. So this does not
-- invent a feed concept; it starts using one that was already defined and already
-- rendered by every consumer.
--
-- ── THE SPLIT ─────────────────────────────────────────────────────────────
-- primary_poll_event.watch  true  -> read on its cadence, listings published  (310)
--                           false -> published with listings_withheld='not_polled',
--                                    never read, costs no credit               (~390)
--
-- Four selectors decide what gets read, and all four now honour the flag:
--   primary_poll_due()   the shared due-list (all sources; defaults true so the other
--                        three sources are unaffected)
--   axs_watch_next()     the worker's batch
--   axs_queue_fill()     the paced queue's enqueuer
--   axs_watch_fill()     membership and promotion
--
-- Without ALL FOUR the flag is decorative: primary_poll_due() treats a NULL next_poll_at
-- as due, and a catalogue row has no next_poll_at, so every catalogue event would have
-- been read immediately — the opposite of the intent, and ~390 extra reads an hour.
--
-- ── HOW THE 310 ARE CHOSEN: SOONEST FIRST ─────────────────────────────────
-- Every keep_all venue's quota goes to 0, so the fill's per-venue refill does nothing and
-- the backfill arm — which orders by event_date_utc — picks the whole set. That is
-- literally "the 310 soonest upcoming events", which is what was asked for, and it needs
-- no new selection code.
--
-- The consequence is worth saying out loud: a dense venue takes slots in proportion to its
-- density. Ryman Auditorium has 94 of its 155 events in December alone, so it will hold a
-- large share of the 310. If that is wrong, the lever is Ryman's quota or its keep_all
-- flag, not this migration.
--
-- Convergence: the fill keeps events already on the list, so on the first run the 310 are
-- "the 208 already watched plus the 102 soonest new ones", not strictly the soonest 310.
-- As events pass and the give-back arm demotes the furthest-out, it converges within days.
--
-- ── DEMOTION REPLACES DELETION ────────────────────────────────────────────
-- The fill's step-3 give-back used to DELETE events past the list's size. It now sets
-- watch = false instead: the event stops costing a credit but stays in the feed. Deleting
-- it would have removed it from the API, which is exactly what the operator asked us to
-- stop doing.
--
-- ── WHY A SEPARATE axs_catalogue_fill() ───────────────────────────────────
-- The watch set needs the 180-day horizon and the on-sale rules, because reading an event
-- that is not on sale wastes a credit. The catalogue set needs neither: publishing an
-- event costs nothing, so it uses its own wider catalogue_until_days (400) and no on-sale
-- gate. Two different rule sets, so two functions rather than one with a mode flag.
--
-- It is called from INSIDE axs_watch_fill, immediately before primary_poll_run_done, and
-- that ordering is load-bearing, not tidiness: the feed joins primary_poll_source on
-- current_run = last_run, and run_done is what stamps last_run. A catalogue row inserted
-- after run_done would sit in the table invisible to the API until the next fill.
--
-- ── SIZE (measured on prod 2026-11-26 04:5xZ) ─────────────────────────────
-- 28 venues the operator listed. Events AXS sells there, future, past exclude_regex: 697
--   of which inside the 180-day horizon and on sale:  605
--   published to the API (catalogue_until_days 400):  ~697
--   READ for listings (target_events):                 310
-- Credit cost: NOT the blended 22.5 reads/event/day the current list averages. The 310 are
-- the SOONEST events, so they sit in the faster bands: the same set measured as an 85-day
-- horizon costs 8,016 reads/day against the ~8,060 sustainable from the 250,000-credit
-- cycle — 99%. The other ~390 events cost zero.
--
-- 99% is deliberately tight and the operator chose 310 knowing the ceiling. The safety net
-- is 20261126053000: as these events march into faster bands the pacer widens cadence_scale
-- from live throughput rather than letting the list outrun the reader. If sustained reading
-- less often is not wanted, the lever is target_events ~280 (a 75-day horizon, ~15% headroom).
-- exclude_regex still drops 55 events at these venues, all of them the operator's own
-- named exclusions (Lakers home games, Vegas Vanguards, Olivia Rodrigo and the rest). They
-- are absent from the feed as well as from the watch; `SET exclude_regex` is the one lever
-- that changes that, and it was left alone deliberately.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- UPDATE public.primary_poll_event SET watch = true WHERE source = 'axs';
-- DELETE FROM public.primary_poll_event WHERE source = 'axs' AND poll_status = 'pending'
--   AND poll_ok_at IS NULL;              -- the catalogue-only rows, never read
-- UPDATE public.axs_watch_config SET target_events = 230;
-- UPDATE public.axs_watch_venue SET keep_all = false WHERE axs_venue_id IN (
--   100913,101196,101206,101207,101229,101260,101349,101390,101406,101499,
--   102082,124944,125102,125705,125886,128058,128382,132202);
-- ============================================================================

BEGIN;

-- ── 1. the flag ───────────────────────────────────────────────────────────
ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS watch boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.primary_poll_event.watch IS
  'true = read this event on its cadence and publish its listings. false = publish the event to v_primary_poll_events_feed with listings_withheld = ''not_polled'' and never read it, so it costs no upstream credit (mig 20261126060000). Set by axs_watch_fill for the AXS source; defaults true so every other source is unchanged.';

CREATE INDEX IF NOT EXISTS primary_poll_event_watch_idx
  ON public.primary_poll_event (source, watch) WHERE watch;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS catalogue_until_days integer NOT NULL DEFAULT 400
    CHECK (catalogue_until_days >= 1 AND catalogue_until_days <= 1000);
COMMENT ON COLUMN public.axs_watch_config.catalogue_until_days IS
  'How far ahead an event is PUBLISHED to the API as catalogue-only (mig 20261126060000). Wider than watch_until_days because publishing costs nothing; the 400-day default also drops the odd far-future artifact row the export carries.';

-- ── 2. every selector honours the flag ────────────────────────────────────
-- primary_poll_due is shared by all four sources. coalesce(..., true) and the column's
-- own DEFAULT true mean sitickets, timberwolves and the rest see no change at all.
CREATE OR REPLACE FUNCTION public.primary_poll_due(p_source text, p_event_ids jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(jsonb_agg(x.id ORDER BY x.id), '[]'::jsonb)
    FROM jsonb_array_elements_text(p_event_ids) x(id)
    LEFT JOIN public.primary_poll_event t ON t.source = p_source AND t.source_event_id = x.id
    LEFT JOIN LATERAL (SELECT public.primary_poll_interval(t.event_date, t.median_price, t.listed_quantity) AS every) live ON true
   CROSS JOIN (SELECT c.due_slack FROM public.primary_poll_config c) cfg
   WHERE t.source_event_id IS NULL
      OR (coalesce(t.watch, true)
          AND NOT public.primary_poll_ended(t.start_utc, t.event_date)
          AND (t.poll_attempt_at IS NULL OR t.next_poll_at IS NULL OR t.poll_interval IS NULL
               OR t.next_poll_at <= now() + cfg.due_slack
               OR (live.every < t.poll_interval AND t.poll_attempt_at + live.every <= now() + cfg.due_slack)))
$function$;

DO $gate$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  -- axs_watch_next: the worker's own candidate query, twice
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_next';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_next not found'; END IF;
  SELECT count(*) INTO v_hits FROM regexp_matches(v_src,
    'WHERE e\.source = ''axs'' AND e\.ticket_url IS NOT NULL', 'g');
  IF v_hits <> 2 THEN RAISE EXCEPTION 'axs_watch_next: expected 2 candidate predicates, found %', v_hits; END IF;
  v_new := replace(v_src, 'WHERE e.source = ''axs'' AND e.ticket_url IS NOT NULL',
                          'WHERE e.source = ''axs'' AND e.watch AND e.ticket_url IS NOT NULL');
  EXECUTE v_new;

  -- axs_queue_fill: the paced queue's enqueuer
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_queue_fill';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_queue_fill not found'; END IF;
  SELECT count(*) INTO v_hits FROM regexp_matches(v_src,
    'WHERE e\.source = ''axs'' AND e\.ticket_url IS NOT NULL', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'axs_queue_fill: expected 1 predicate, found %', v_hits; END IF;
  v_new := replace(v_src, 'WHERE e.source = ''axs'' AND e.ticket_url IS NOT NULL',
                          'WHERE e.source = ''axs'' AND e.watch AND e.ticket_url IS NOT NULL');
  EXECUTE v_new;

  -- prove both took
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_next';
  IF v_src !~ 'e\.watch' THEN RAISE EXCEPTION 'axs_watch_next did not take the flag'; END IF;
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_queue_fill';
  IF v_src !~ 'e\.watch' THEN RAISE EXCEPTION 'axs_queue_fill did not take the flag'; END IF;
END $gate$;

-- ── 3. the catalogue fill ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.axs_catalogue_fill()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  v_added integer := 0; v_dropped integer := 0;
BEGIN
  SELECT * INTO v_cfg FROM public.axs_watch_config;

  -- in: every event AXS sells at a keep_all venue that is not already on the list. No
  -- on-sale gate and a wider horizon than the watch, because publishing costs nothing.
  WITH ins AS (
    INSERT INTO public.primary_poll_event (source, source_event_id, name, event_date, start_local_time,
        start_utc, timezone, venue_name, venue_city, venue_state, ticket_url, tevo_event_id,
        tevo_match_method, tevo_matched_at, announced_at, watch)
    SELECT 'axs', e.axs_event_id::text, e.event_title,
           left(e.event_date_local, 10)::date,
           CASE WHEN e.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}'
                THEN substr(e.event_date_local, 12, 5)::time END,
           e.event_date_utc, e.event_timezone, e.venue_name, e.venue_city, e.venue_state,
           e.event_url, e.tevo_event_id,
           CASE WHEN e.tevo_event_id IS NOT NULL THEN 'axs_export' END,
           CASE WHEN e.tevo_event_id IS NOT NULL THEN now() END,
           now(), false
      FROM public.axs_export_event e
      JOIN public.axs_watch_venue wv ON wv.axs_venue_id = e.venue_id AND wv.enabled AND wv.keep_all
     WHERE e.gone_at IS NULL AND e.removed_utc IS NULL
       AND (coalesce(e.axs_ticketed, false) OR wv.trust_axs_sold)
       AND e.event_url IS NOT NULL
       AND e.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
       AND left(e.event_date_local, 10)::date >= current_date
       AND left(e.event_date_local, 10)::date <= current_date + v_cfg.catalogue_until_days
       AND public.axs_watch_rule_ok(e.major_category, e.event_title, e.venue_id)
       AND NOT EXISTS (SELECT 1 FROM public.primary_poll_event t
                        WHERE t.source = 'axs' AND t.source_event_id = e.axs_event_id::text)
    ON CONFLICT (source, source_event_id) DO NOTHING
    RETURNING 1)
  SELECT count(*) INTO v_added FROM ins;

  -- out: a CATALOGUE row goes when the export drops it, AXS stops selling it, the rules
  -- stop covering it, its venue stops being watched whole, it is past, or it is beyond
  -- catalogue_until_days. Rows with watch = true are never touched here — axs_watch_fill
  -- owns those, and retiring one from both places would double-count the audit.
  WITH gone AS (
    SELECT t.source_event_id
      FROM public.primary_poll_event t
      LEFT JOIN public.axs_export_event e ON e.axs_event_id::text = t.source_event_id
      LEFT JOIN public.axs_watch_venue wv ON wv.axs_venue_id = e.venue_id AND wv.enabled
     WHERE t.source = 'axs' AND NOT t.watch
       AND (e.axs_event_id IS NULL OR e.gone_at IS NOT NULL OR e.removed_utc IS NOT NULL
            OR NOT (coalesce(e.axs_ticketed, false) OR coalesce(wv.trust_axs_sold, false))
            OR NOT coalesce(wv.keep_all, false)
            OR NOT public.axs_watch_rule_ok(e.major_category, coalesce(e.event_title, t.name), e.venue_id)
            OR coalesce(t.event_date, (e.event_date_utc)::date) < current_date
            OR coalesce(t.event_date, (e.event_date_utc)::date) > current_date + v_cfg.catalogue_until_days)),
  del AS (
    DELETE FROM public.primary_poll_event t USING gone g
     WHERE t.source = 'axs' AND t.source_event_id = g.source_event_id AND NOT t.watch
    RETURNING 1)
  SELECT count(*) INTO v_dropped FROM del;

  RETURN jsonb_build_object('catalogue_added', v_added, 'catalogue_dropped', v_dropped,
           'watched', (SELECT count(*) FROM public.primary_poll_event WHERE source = 'axs' AND watch),
           'catalogue_only', (SELECT count(*) FROM public.primary_poll_event WHERE source = 'axs' AND NOT watch));
END $function$;

REVOKE ALL ON FUNCTION public.axs_catalogue_fill() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_catalogue_fill() TO service_role;

-- ── 4. the fill owns membership and the flag ──────────────────────────────
-- Five changes, each guarded by an exact site count. The function's body is otherwise
-- untouched, so the same reasoning as 20261126044500 applies: restating 13.5k characters
-- of unchanged plpgsql would let this file and prod drift apart invisibly.
--
--   _aw_retire   + t.watch     the watch-retire rules (horizon, on-sale, three-strikes)
--                              apply to WATCHED events only; axs_catalogue_fill owns the rest
--   _aw_keep     + t.watch     so v_kept counts the watch set and the catalogue cannot
--                              squeeze it out of its own target_events
--   _aw_pick     DO UPDATE     a catalogue row whose date nears is PROMOTED to watch = true
--                              rather than skipped by DO NOTHING and never read
--   give-back    UPDATE        demote past the list's size instead of DELETE, so the event
--                              stops costing a credit but stays in the API feed — but only
--                              where its venue is keep_all; elsewhere it is still deleted,
--                              because the catalogue fill would drop it anyway
--   run_done     PERFORM       the catalogue fill runs first, because run_done stamps the
--                              last_run the feed joins on
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_fill'
     AND pg_get_function_identity_arguments(p.oid) = 'p_apply boolean';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_fill(boolean) not found'; END IF;
  v_new := v_src;

  -- (1) the retire set considers watched events only
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'   WHERE t\\.source = ''axs''\\n     AND \\(e\\.axs_event_id IS NULL', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'retire WHERE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'   WHERE t.source = ''axs''\n     AND (e.axs_event_id IS NULL',
    E'   WHERE t.source = ''axs'' AND t.watch\n     AND (e.axs_event_id IS NULL');

  -- (2) the keep set counts watched events only
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'           WHERE t\\.source = ''axs''\\n             AND NOT EXISTS \\(SELECT 1 FROM _aw_retire r', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'keep WHERE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'           WHERE t.source = ''axs''\n             AND NOT EXISTS (SELECT 1 FROM _aw_retire r',
    E'           WHERE t.source = ''axs'' AND t.watch\n             AND NOT EXISTS (SELECT 1 FROM _aw_retire r');

  -- (3) a picked event is promoted, not skipped
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'ON CONFLICT \(source, source_event_id\) DO NOTHING;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'pick insert: expected 1 ON CONFLICT, found %', v_hits; END IF;
  v_new := replace(v_new,
    'ON CONFLICT (source, source_event_id) DO NOTHING;',
    'ON CONFLICT (source, source_event_id) DO UPDATE SET watch = true;');

  -- (4) demote instead of delete
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'DELETE FROM public\.primary_poll_event t USING _aw_back b WHERE t\.source = ''axs'' AND t\.source_event_id = b\.source_event_id;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'give-back: expected 1 DELETE, found %', v_hits; END IF;
  -- Demotion only KEEPS the event if its venue is watched whole, because
  -- axs_catalogue_fill drops a catalogue row whose venue is not keep_all. At a venue that
  -- is not, the row must still go, or the audit would say the event was demoted while the
  -- catalogue fill deleted it on the same call. So: demote where keep_all, delete where
  -- not. (s06 caught this — its fabricated venues are not keep_all.)
  v_new := replace(v_new,
    'DELETE FROM public.primary_poll_event t USING _aw_back b WHERE t.source = ''axs'' AND t.source_event_id = b.source_event_id;',
    E'UPDATE public.primary_poll_event t SET watch = false, next_poll_at = NULL\n'
    || E'        FROM _aw_back b, public.axs_export_event e2, public.axs_watch_venue wv2\n'
    || E'       WHERE t.source = ''axs'' AND t.source_event_id = b.source_event_id\n'
    || E'         AND e2.axs_event_id::text = t.source_event_id AND wv2.axs_venue_id = e2.venue_id\n'
    || E'         AND wv2.enabled AND wv2.keep_all;\n'
    || E'      DELETE FROM public.primary_poll_event t USING _aw_back b\n'
    || E'       WHERE t.source = ''axs'' AND t.source_event_id = b.source_event_id AND t.watch;');
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new, '''backfill_returned''', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'give-back audit note: expected 1 site, found %', v_hits; END IF;
  -- one note for both outcomes: the list was over its size. Whether the row survived as
  -- catalogue-only is visible on the row itself, so the note never claims the wrong thing.
  v_new := replace(v_new, '''backfill_returned''', '''over_target_events''');

  -- (5) the catalogue joins the run before run_done stamps last_run
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'PERFORM public\.primary_poll_run_done\(''axs''', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'run_done: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'PERFORM public.primary_poll_run_done(''axs''',
    E'PERFORM public.axs_catalogue_fill();\n    PERFORM public.primary_poll_run_done(''axs''');

  IF v_new = v_src THEN RAISE EXCEPTION 'axs_watch_fill unchanged — surgery did nothing'; END IF;
  EXECUTE v_new;

  -- read it back and prove every change is there
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_fill'
     AND pg_get_function_identity_arguments(p.oid) = 'p_apply boolean';
  IF v_src !~ 'WHERE t\.source = ''axs'' AND t\.watch'
     OR v_src !~ 'DO UPDATE SET watch = true'
     OR v_src !~ 'SET watch = false, next_poll_at = NULL'
     OR v_src !~ 'axs_catalogue_fill\(\)'
     OR v_src !~ 'AND wv2\.enabled AND wv2\.keep_all'
     OR v_src !~ 'over_target_events' THEN
    RAISE EXCEPTION 'axs_watch_fill did not come back with all five changes';
  END IF;
END $surgery$;

-- ── 5. the operator's venues, and the size of the read set ────────────────
-- The 18 venues from the 2026-11-26 survey that were not already flagged. Frost Bank
-- Center is left out: it carries 68 live rows and ZERO that AXS sells. Austin City Limits
-- is left out: no venue in the export matches it. Both were in the operator's list; saying
-- so here is cheaper than rediscovering it.
-- 12 of these 18 had NO row in axs_watch_venue at all — Ryman Auditorium, the largest of
-- them, among them. A plain UPDATE would have flagged the 6 that existed, reported success
-- and quietly skipped two thirds of what the operator asked for. Hence an upsert, with the
-- venue names from the export so a new row is readable.
INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, note, set_by, set_at)
SELECT v.id, v.nm, 0, true, true,
       'operator 2026-11-26: whole venue, listed to the API; read only if it falls inside the soonest '
       || (SELECT target_events FROM public.axs_watch_config)::text || '.',
       'operator', now()
  FROM (VALUES
     (100913::bigint, 'Delta Center'), (101196, 'Royal Oak Music Theatre'),
     (101206, 'Pechanga Arena San Diego'), (101207, 'Santa Barbara Bowl'),
     (101229, 'Ryman Auditorium'), (101260, 'Target Center'),
     (101349, 'Van Andel Arena'), (101390, 'T-Mobile Center'),
     (101406, 'Peacock Theater'), (101499, 'Amerant Bank Arena'),
     (102082, 'AT&T Stadium'), (124944, 'Forest Hills Stadium'),
     (125102, 'Pompano Beach Amphitheater'), (125705, 'Terminal 5'),
     (125886, 'Orlando Amphitheater at the Central Florida Fairgrounds'),
     (128058, 'Resorts World Theatre'), (128382, 'Yaamava'' Theater'),
     (132202, 'Crypto.com Arena Tours')) AS v(id, nm)
ON CONFLICT (axs_venue_id) DO UPDATE
   SET enabled = true, keep_all = true, note = excluded.note, set_by = 'operator', set_at = now();

DO $$
DECLARE v_n integer;
BEGIN
  SELECT count(*) INTO v_n FROM public.axs_watch_venue WHERE keep_all AND enabled;
  IF v_n <> 28 THEN
    RAISE EXCEPTION 'expected 28 whole-venue rows after this migration, found %', v_n;
  END IF;
END $$;

-- Quota 0 on every whole-venue row: the per-venue refill then does nothing and the
-- backfill arm, which orders by event_date_utc, selects the whole read set. That is
-- "the soonest N upcoming events" with no new selection code.
UPDATE public.axs_watch_venue SET quota = 0 WHERE keep_all;

UPDATE public.axs_watch_config SET target_events = 310, updated_at = now();

-- ── 6. run it once now rather than waiting for 03:20Z ─────────────────────
SELECT public.axs_watch_fill(true);

COMMIT;
