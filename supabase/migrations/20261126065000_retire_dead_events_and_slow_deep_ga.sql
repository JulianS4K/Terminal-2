-- Migration 20261126065000 · level:data-collection · lane:a1 (AXS watch) · writes:axs_watch_config(+no_tickets_retire_days,+ga_slow_every,+ga_slow_min_tickets),primary_poll_event(+ga_slow),axs_watch_event_dead()(new),axs_watch_cadence_every(bool overload)(new),axs_watch_settle_one()(patched),axs_watch_fill()(patched),axs_catalogue_fill()(patched),axs_watch_cadence_demand()(replaced),axs_watch_pace_apply()(patched) · reads:axs_watch_poll,primary_poll_listing
--
-- ============================================================================
-- Migration 20261126065000 — stop reading events that are over, and slow deep GA
--
-- Lane:     a1 (AXS watch)
-- pre:      20261126060000 (the watch/catalogue split), 20261126062000 (the gauge).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes which events we
-- read and how often.
--
-- ── WHAT THE OPERATOR ASKED FOR ───────────────────────────────────────────
-- Operator 2026-11-26, two messages:
--   "exclude cancelled events and anything that's 7 days away or sooner that show
--    No tickets are currently available."
--   "if event is GA only and over 100 GA [tickets] we can reduce polling cadence to
--    every 2 hours"   (corrected from "100 listings" to "100 tickets" by the operator)
--
-- ── RULE 1 + 2: THE EVENT IS OVER, STOP PAYING FOR IT ─────────────────────
-- axs_watch_event_dead(event_id, event_date) reads the event's last error and says true
-- when either holds:
--   · the read says cancelled                       — whatever the date
--   · the read says no tickets are currently available AND the event is within
--     no_tickets_retire_days (7)                    — near-term only
--
-- The 7-day qualifier is the whole point of the second rule and is why it is not simply
-- "no tickets available". Measured on the live list right now, three events carry that
-- error and NONE of them is within 7 days:
--     Matt Rife - Saturday        2026-12-05    9 days out
--     Sienna Spiro                2027-09-09  287 days out
--     Sienna Spiro 2nd Show       2027-09-10  288 days out
-- A far-out event answering "no tickets available" has usually not released inventory
-- yet — the BNP Paribas Open qualifier sessions behave the same way — so retiring on
-- that string alone would throw away events that are going to sell. Seven days out it
-- means something different: the event is not going to put inventory up.
--
-- Rule 1 matches exactly one event today: "Tierra Cali y Banda Machos" at Peacock
-- Theater, TOMORROW, whose read returns "This event has been cancelled." It is on the
-- 30-minute band, so it was due to cost ~48 reads before its date passed.
--
-- The check is applied in FOUR places, and all four are needed:
--   axs_watch_fill   retire arm   takes it off the watch
--   axs_watch_fill   _aw_cand     stops the same fill putting it straight back
--   axs_catalogue_fill  insert    stops it reappearing as a catalogue row
--   axs_catalogue_fill  delete    takes it out of the API feed too
-- A cancelled event should not be published either, so this removes it from the feed
-- rather than demoting it to catalogue-only.
--
-- axs_watch_settle_one also drops a dead event to not_on_sale_every (6h) the moment the
-- read lands, so the waste between that read and the next fill is 4 reads rather than 48.
-- The fill is what removes it; this just bounds the bleeding.
--
-- ── RULE 3: DEEP GA DOES NOT NEED A FAST BAND ─────────────────────────────
-- "GA only" has to mean "no listing that is neither GA nor ADA", not "no non-GA listing",
-- and the reason is in the data. The three Red Rocks GA events are stored as TWO listings
-- each: one GA block and one ADA block. The feed splits the GA block into hundreds of
-- pieces (1,405 for Nora En Pure's 5,617 tickets) and withholds the ADA one, so the feed
-- shows them as GA-only while the table shows a non-GA listing. Table-wide only 27 of
-- 86,227 stored AXS listings are GA.
--
-- An accessible listing alongside GA does not make an event reserved-seating, and the
-- feed already takes that view: send_ada is false and the feed carries 0 ADA rows against
-- 1,016 stored (operator 2026-11-26: "our AXS feed out should be excluding ADA" —
-- verified true, nothing changed for it here).
--
-- So: no listing that is neither GA nor ADA, and more than ga_slow_min_tickets (100) GA
-- tickets, means the band is replaced by greatest(band, ga_slow_every). greatest() so the
-- rule can only ever SLOW an event down; all three bands (30/60/90 min) are faster than
-- 2 hours, so in practice it always does.
--
-- Six events qualify today, and the ticket threshold matters: at >100 LISTINGS only five
-- would (CupcakKe has 111 feed listings but the T-Mobile event has 80), while at
-- >100 TICKETS all six do, the smallest being 441.
--     Nora En Pure (Red Rocks)   5,617 GA tickets   90 min -> 2h
--     SIDEPIECE (Red Rocks)      3,213             90 min -> 2h
--     A Boogie (Orlando Amph)    1,973             60 min -> 2h
--     The Escapement (T-Mobile)    631             60 min -> 2h
--     Cloonee (Red Rocks)          595             90 min -> 2h
--     CupcakKe (Terminal 5)        441             60 min -> 2h
-- Saving 2.0 reads/hour, 48/day. Small today; 16 further events carry GA alongside
-- reserved seating and correctly do not qualify, and the rule scales as more GA shows land.
--
-- The decision is STORED on primary_poll_event.ga_slow at settle time rather than
-- recomputed, because axs_watch_cadence_demand() and axs_watch_pace_apply() both have to
-- agree with it across all 310 events and an aggregate over 86k listings per event would
-- not survive the monitor's 8s statement timeout. The gauge and the brake pass the stored
-- flag to the same function the settle uses, so none of the three can disagree — the
-- failure 20261126062000 was about.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- UPDATE public.axs_watch_config SET no_tickets_retire_days = 0;   -- rule 2 off
-- UPDATE public.axs_watch_config SET ga_slow_min_tickets = 2147483647;  -- rule 3 off
-- Rule 1 has no off switch short of reverting axs_watch_event_dead to return false.
-- ============================================================================

BEGIN;

-- ── 1. the knobs ──────────────────────────────────────────────────────────
ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS no_tickets_retire_days integer NOT NULL DEFAULT 7
    CHECK (no_tickets_retire_days >= 0 AND no_tickets_retire_days <= 365),
  ADD COLUMN IF NOT EXISTS ga_slow_every interval NOT NULL DEFAULT interval '2 hours'
    CHECK (ga_slow_every >= interval '5 minutes' AND ga_slow_every <= interval '24 hours'),
  ADD COLUMN IF NOT EXISTS ga_slow_min_tickets integer NOT NULL DEFAULT 100
    CHECK (ga_slow_min_tickets >= 0);
COMMENT ON COLUMN public.axs_watch_config.no_tickets_retire_days IS
  'An event whose last read says "no tickets are currently available" is retired when it is this many days away or sooner (mig 20261126065000). 0 disables the rule. A far-out event answering that way has usually not released inventory yet.';
COMMENT ON COLUMN public.axs_watch_config.ga_slow_every IS
  'The cadence for a GA-only event holding more than ga_slow_min_tickets GA tickets (mig 20261126065000). Applied as greatest(band, this), so it can only slow an event down.';
COMMENT ON COLUMN public.axs_watch_config.ga_slow_min_tickets IS
  'GA TICKETS (not listings) above which a GA-only event moves to ga_slow_every (mig 20261126065000). Operator set 100.';

ALTER TABLE public.primary_poll_event
  ADD COLUMN IF NOT EXISTS ga_slow boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.primary_poll_event.ga_slow IS
  'true = this event holds only GA (and ADA) listings with more than ga_slow_min_tickets GA tickets, so its cadence is ga_slow_every (mig 20261126065000). Recomputed on every settled read. Stored rather than derived so the settle, the demand gauge and the pacer cannot disagree.';

-- ── 2. is the event over? ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.axs_watch_event_dead(p_event_id text, p_event_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(bool_or(
           s.err ~* '\mcancel(l?)ed\M'
           OR (s.err ~* 'no tickets are currently available'
               AND p_event_date IS NOT NULL
               AND (SELECT c.no_tickets_retire_days FROM public.axs_watch_config c) > 0
               AND p_event_date <= current_date
                   + (SELECT c.no_tickets_retire_days FROM public.axs_watch_config c))), false)
    FROM (
      -- TWO sources, and both are needed.
      --
      -- The event's own last error. primary_poll_ingest writes it on EVERY read path — the
      -- worker's axs_watch_record AND the queue's axs_queue_ack -> axs_watch_settle_one —
      -- and sets it back to NULL on a successful read, so it cannot go stale. Live check:
      -- 308 ok events carry 0 stale errors, and both failed events carry one.
      SELECT e.poll_error AS err
        FROM public.primary_poll_event e
       WHERE e.source = 'axs' AND e.source_event_id = p_event_id
         AND e.poll_error IS NOT NULL
      UNION ALL
      -- And the read ledger, which outlives the event being taken OFF the list. Without
      -- it the retire arm and the candidate arm would disagree: the fill would remove a
      -- cancelled event and the same fill's backfill would hand it a place straight back,
      -- because primary_poll_event no longer has a row to carry the error.
      --
      -- Only axs_watch_record and axs_watch_tick write axs_watch_poll; axs_queue_ack does
      -- not. That is why the event row is consulted FIRST and this is only a fallback — a
      -- check resting on the ledger alone would go blind the day the queue is switched on.
      SELECT w.error
        FROM public.axs_watch_poll w
       WHERE w.axs_event_id = p_event_id AND w.error IS NOT NULL
         AND w.checked_at = (SELECT max(w2.checked_at) FROM public.axs_watch_poll w2
                              WHERE w2.axs_event_id = p_event_id AND w2.checked_at IS NOT NULL)
    ) s
$function$;

REVOKE ALL ON FUNCTION public.axs_watch_event_dead(text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_event_dead(text, date) TO service_role;

-- ── 3. the cadence, with the deep-GA override ─────────────────────────────
-- A NEW overload. The 2-arg form keeps its exact meaning for every existing caller.
CREATE OR REPLACE FUNCTION public.axs_watch_cadence_every(p_start timestamp with time zone,
                                                          p_event_date date,
                                                          p_ga_slow boolean)
 RETURNS interval
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN coalesce(p_ga_slow, false)
              -- greatest(): the rule may only ever slow an event down
              THEN greatest(public.axs_watch_cadence_every(p_start, p_event_date),
                            (SELECT c.ga_slow_every FROM public.axs_watch_config c))
              ELSE public.axs_watch_cadence_every(p_start, p_event_date)
         END
$function$;

REVOKE ALL ON FUNCTION public.axs_watch_cadence_every(timestamptz, date, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_cadence_every(timestamptz, date, boolean) TO service_role;

-- ── 4. the settle computes ga_slow and honours both rules ─────────────────
-- primary_poll_ingest has already written this read's listings by the time the cadence
-- block runs, so the GA profile is computable from the fresh rows.
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_settle_one not found'; END IF;
  v_new := v_src;

  -- (a) a local for the flag
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'v_every interval; v_sec bigint; v_phase bigint; v_next numeric; v_slack numeric; v_base numeric;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle DECLARE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'v_every interval; v_sec bigint; v_phase bigint; v_next numeric; v_slack numeric; v_base numeric;',
    E'v_every interval; v_sec bigint; v_phase bigint; v_next numeric; v_slack numeric; v_base numeric;\n  v_ga_slow boolean := false;');

  -- (b) compute the GA profile from the rows just written, then use the 3-arg cadence
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'v_every := coalesce\(public\.axs_watch_cadence_every\(t\.start_utc, t\.event_date\), interval ''1 hour''\);', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle cadence call: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'v_every := coalesce(public.axs_watch_cadence_every(t.start_utc, t.event_date), interval ''1 hour'');',
    E'-- deep GA: no listing that is neither GA nor ADA, and more than ga_slow_min_tickets GA\n'
    || E'    -- tickets. An ADA listing beside GA does not make the event reserved-seating, and the\n'
    || E'    -- feed withholds ADA anyway (mig 20261126065000).\n'
    || E'    SELECT count(*) FILTER (WHERE NOT coalesce(l.general_admission, false)\n'
    || E'                              AND NOT coalesce(l.ada, false)) = 0\n'
    || E'           AND coalesce(sum(l.quantity) FILTER (WHERE coalesce(l.general_admission, false)), 0)\n'
    || E'               > v_cfg.ga_slow_min_tickets\n'
    || E'      INTO v_ga_slow\n'
    || E'      FROM public.primary_poll_listing l\n'
    || E'     WHERE l.source = ''axs'' AND l.source_event_id = p_event_id;\n'
    || E'    v_ga_slow := coalesce(v_ga_slow, false);\n'
    || E'    v_every := coalesce(public.axs_watch_cadence_every(t.start_utc, t.event_date, v_ga_slow), interval ''1 hour'');');

  -- (c) store the flag alongside the interval
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'       SET poll_interval = v_every,\\n           next_poll_at  = to_timestamp\\(v_next\\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle cadence UPDATE: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'       SET poll_interval = v_every,\n           next_poll_at  = to_timestamp(v_next)',
    E'       SET poll_interval = v_every,\n           ga_slow       = v_ga_slow,\n           next_poll_at  = to_timestamp(v_next)');

  -- (d) a dead event drops to the slow rule at once, so the waste before the next fill
  --     removes it is a handful of reads rather than a day of them
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'IF v_outcome = ''unparsed'' AND v_error ~\* ''not \(currently \|yet \)\?on sale\|not on sale yet\|no tickets are currently available\|coming soon'' THEN', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'settle slow branch: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'IF v_outcome = ''unparsed'' AND v_error ~* ''not (currently |yet )?on sale|not on sale yet|no tickets are currently available|coming soon'' THEN',
    'IF v_outcome = ''unparsed'' AND v_error ~* ''not (currently |yet )?on sale|not on sale yet|no tickets are currently available|coming soon|\mcancel(l?)ed\M'' THEN');

  IF v_new = v_src THEN RAISE EXCEPTION 'settle unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_settle_one';
  IF v_src !~ 'v_ga_slow' OR v_src !~ 'ga_slow       = v_ga_slow'
     OR v_src !~ 'ga_slow_min_tickets' OR v_src !~ 'cancel\(l\?\)ed' THEN
    RAISE EXCEPTION 'settle did not come back with all four changes';
  END IF;
END $surgery$;

-- ── 5. the fill retires a dead event and does not re-add it ───────────────
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_fill'
     AND pg_get_function_identity_arguments(p.oid) = 'p_apply boolean';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_fill(boolean) not found'; END IF;
  v_new := v_src;

  -- (a) a named retire reason, ahead of the on-sale arm
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'              WHEN public\\.axs_watch_not_on_sale\\(lr\\.outcome, lr\\.error, e\\.status\\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'retire CASE on-sale arm: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'              WHEN public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status)',
    E'              WHEN public.axs_watch_event_dead(t.source_event_id, t.event_date) THEN ''over_or_cancelled''\n'
    || E'              WHEN public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status)');

  -- (b) the WHERE arm
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'          OR public\\.axs_watch_not_on_sale\\(lr\\.outcome, lr\\.error, e\\.status\\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'retire WHERE on-sale arm: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'          OR public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status)',
    E'          OR public.axs_watch_event_dead(t.source_event_id, t.event_date)\n'
    || E'          OR public.axs_watch_not_on_sale(lr.outcome, lr.error, e.status)');

  -- (c) and the candidate set must not put it straight back
  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    'AND \(SELECT count\(\*\) FROM public\.axs_watch_poll w WHERE w\.axs_event_id = e\.axs_event_id::text AND w\.outcome IN \(''not_axs'', ''expired''\)\) < 3;', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'candidate three-strikes: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    'AND (SELECT count(*) FROM public.axs_watch_poll w WHERE w.axs_event_id = e.axs_event_id::text AND w.outcome IN (''not_axs'', ''expired'')) < 3;',
    E'AND (SELECT count(*) FROM public.axs_watch_poll w WHERE w.axs_event_id = e.axs_event_id::text AND w.outcome IN (''not_axs'', ''expired'')) < 3\n'
    || E'     -- cancelled, or near-term with no tickets: do not hand back a place to an event\n'
    || E'     -- the retire arm above has just taken off the list (mig 20261126065000)\n'
    || E'     AND NOT public.axs_watch_event_dead(e.axs_event_id::text, left(e.event_date_local, 10)::date);');

  IF v_new = v_src THEN RAISE EXCEPTION 'fill unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_fill'
     AND pg_get_function_identity_arguments(p.oid) = 'p_apply boolean';
  IF v_src !~ 'over_or_cancelled'
     OR v_src !~ 'NOT public\.axs_watch_event_dead\(e\.axs_event_id::text'
     OR (SELECT count(*) FROM regexp_matches(v_src, 'axs_watch_event_dead', 'g')) <> 3 THEN
    RAISE EXCEPTION 'fill did not come back with all three dead-event checks';
  END IF;
END $surgery$;

-- ── 6. the catalogue does not publish a dead event either ─────────────────
DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_catalogue_fill';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_catalogue_fill not found'; END IF;
  v_new := v_src;

  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'       AND NOT EXISTS \\(SELECT 1 FROM public\\.primary_poll_event t\\n', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'catalogue insert guard: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'       AND NOT EXISTS (SELECT 1 FROM public.primary_poll_event t\n',
    E'       -- a cancelled event is not published either (mig 20261126065000)\n'
    || E'       AND NOT public.axs_watch_event_dead(e.axs_event_id::text, left(e.event_date_local, 10)::date)\n'
    || E'       AND NOT EXISTS (SELECT 1 FROM public.primary_poll_event t\n');

  SELECT count(*) INTO v_hits FROM regexp_matches(v_new,
    E'            OR coalesce\\(t\\.event_date, \\(e\\.event_date_utc\\)::date\\) < current_date\\n', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'catalogue delete arm: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_new,
    E'            OR coalesce(t.event_date, (e.event_date_utc)::date) < current_date\n',
    E'            OR public.axs_watch_event_dead(t.source_event_id, t.event_date)\n'
    || E'            OR coalesce(t.event_date, (e.event_date_utc)::date) < current_date\n');

  IF v_new = v_src THEN RAISE EXCEPTION 'catalogue fill unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_catalogue_fill';
  IF (SELECT count(*) FROM regexp_matches(v_src, 'axs_watch_event_dead', 'g')) <> 2 THEN
    RAISE EXCEPTION 'catalogue fill did not come back with both dead-event checks';
  END IF;
END $surgery$;

-- ── 7. the gauge and the brake use the same cadence the settle does ───────
-- 20261126062000's lesson: if the settle, the gauge and the pacer compute the interval
-- differently, the pacer acts on a number that is not what the reader is doing. All three
-- now call the 3-arg form with the stored flag.
CREATE OR REPLACE FUNCTION public.axs_watch_cadence_demand()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH e AS (
    SELECT public.axs_watch_cadence_every(t.start_utc, t.event_date, t.ga_slow) AS every
      FROM public.primary_poll_event t
     WHERE t.source = 'axs' AND t.watch AND t.ticket_url IS NOT NULL
  ), d AS (
    SELECT count(*) AS events,
           sum(3600.0 / nullif(extract(epoch FROM every), 0)) AS per_hour,
           sum(86400.0 / nullif(extract(epoch FROM every), 0)) AS per_day
      FROM e
  ), cap AS (
    SELECT (public.axs_watch_pace()->>'usable_per_hour')::numeric AS usable_per_hour,
           (public.axs_watch_budget()->>'daily_cap')::numeric     AS daily_cap
  )
  SELECT jsonb_build_object(
           'events', d.events,
           'catalogue_only', (SELECT count(*) FROM public.primary_poll_event t
                               WHERE t.source = 'axs' AND NOT t.watch),
           'ga_slow', (SELECT count(*) FROM public.primary_poll_event t
                        WHERE t.source = 'axs' AND t.watch AND t.ga_slow),
           'demand_per_hour', round(d.per_hour, 1),
           'demand_per_day', round(d.per_day),
           'usable_per_hour', cap.usable_per_hour,
           'daily_cap', cap.daily_cap,
           'pct_of_throughput', round(100 * d.per_hour / nullif(cap.usable_per_hour, 0), 1),
           'pct_of_daily_cap', round(100 * d.per_day / nullif(cap.daily_cap, 0), 1),
           'fits', d.per_hour <= coalesce(cap.usable_per_hour, 0)
                   AND d.per_day <= coalesce(cap.daily_cap, 0),
           'cadence_scale', (SELECT cfg.cadence_scale FROM public.axs_watch_config cfg))
    FROM d, cap;
$function$;

DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_pace_apply';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_pace_apply not found'; END IF;

  SELECT count(*) INTO v_hits FROM regexp_matches(v_src,
    'public\.axs_watch_cadence_every\(t\.start_utc, t\.event_date\)', 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'pace_apply cadence call: expected 1 site, found %', v_hits; END IF;
  v_new := replace(v_src,
    'public.axs_watch_cadence_every(t.start_utc, t.event_date)',
    'public.axs_watch_cadence_every(t.start_utc, t.event_date, t.ga_slow)');
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_pace_apply';
  IF v_src !~ 't\.event_date, t\.ga_slow' THEN
    RAISE EXCEPTION 'pace_apply did not take the ga_slow flag';
  END IF;
END $surgery$;

-- ── 8. set ga_slow from the captures we already hold ──────────────────────
-- Without this the flag only appears as each event is next read, and the gauge would
-- under-report the saving for an hour. poll_interval converges on the next read; the
-- gauge computes from the flag, so it is right immediately.
UPDATE public.primary_poll_event t
   SET ga_slow = g.flag
  FROM (SELECT l.source_event_id,
               (count(*) FILTER (WHERE NOT coalesce(l.general_admission, false)
                                   AND NOT coalesce(l.ada, false)) = 0
                AND coalesce(sum(l.quantity) FILTER (WHERE coalesce(l.general_admission, false)), 0)
                    > (SELECT c.ga_slow_min_tickets FROM public.axs_watch_config c)) AS flag
          FROM public.primary_poll_listing l
         WHERE l.source = 'axs'
         GROUP BY 1) g
 WHERE t.source = 'axs' AND t.source_event_id = g.source_event_id
   AND t.ga_slow IS DISTINCT FROM g.flag;

-- ── 9. apply the retires now rather than at 03:20Z ────────────────────────
SELECT public.axs_watch_fill(true);

COMMIT;
