-- ============================================================================
-- Migration 20260914220030 — a rescheduled game was graded against its OLD date
--
-- Lane:     D0 (deals surface)
-- Touches:  deal_event_datetime(timestamptz,timestamptz,text) (new) ·
--           scan_listing_deals(…) (CREATE OR REPLACE — event date + weekend flag) ·
--           gotickets_deals_feed (repair stored event_date on affected rows) ·
--           gotickets_deal_outcome (delete grades produced from the wrong date)
-- Pre-reqs: 20260911162500
--
-- Operator 2026-09-14, after asking whether the predictions had been accurate.
--
-- ── WHAT WENT WRONG ────────────────────────────────────────────────────────
-- Of 148 graded deals only 15 carried a price prediction, and all 15 were ONE match:
-- "Vancouver Whitecaps FC at Chicago Fire FC (Rescheduled from 7/16)", tevo_event_id 3253199.
-- Measured price error on them was a median 143% with the bias EQUAL to the absolute error —
-- every row wrong in the same direction, which is a systematic fault, not model drift.
--
-- The three date sources disagreed:
--   events.occurs_at_local            2026-10-06  (TEvo, state='rescheduled', name says so)
--   sg_events_canonical.sg_datetime_utc  2026-07-16  (SeatGeek, stale pre-reschedule)
--   gotickets_deals_feed.event_date      2026-07-16  (what the scanner stored)
--
-- scan_listing_deals picks CANDIDATES off e.occurs_at_local, so it correctly saw a game 22
-- days out and flagged it. It then DENORMALISED the stored date through
--   coalesce(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local::timestamptz)
-- which prefers SeatGeek — still holding July. Two different date sources inside one function.
-- grade_deal_outcomes() reads only the stored feed event_date, so it treated an October game
-- as long played and scored it against July sales. dte_at_flag came out at -58.
--
-- Consequence: 15 of 148 label rows (~10%) are garbage, and they are ALL of the graded rows
-- carrying a prediction — so the price model's out-of-sample accuracy is currently UNTESTED,
-- not poor. The earliest genuine read is the 2026-09-21 events.
--
-- Blast radius at authoring time: 111 events whose SeatGeek date disagrees with TEvo by more
-- than a day, 23 explicitly 'rescheduled', and 8 where SeatGeek says the event is already past
-- while TEvo says it is still upcoming — those 8 would have repeated this exactly.
--
-- ── THE RULE ───────────────────────────────────────────────────────────────
-- SeatGeek's sg_datetime_utc stays preferred, because it is a clean UTC timestamptz whereas
-- occurs_at_local is text. But TEvo is the reschedule-aware catalogue: when a cross-source
-- date disagrees with TEvo by MORE THAN A DAY, the other source is stale and TEvo wins.
-- A sub-day difference is timezone/rounding noise and keeps the existing preference.
--
-- deal_event_datetime() is STABLE, not IMMUTABLE: text -> timestamptz is a stable cast.
--
-- ROLLBACK: re-apply scan_listing_deals from 20260911162500; DROP FUNCTION deal_event_datetime.
-- The data repairs below are not reversed by that (the grades were wrong).
-- ============================================================================

-- ── 1. One place decides an event's datetime ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.deal_event_datetime(
  p_sg timestamptz, p_gt timestamptz, p_tevo_local text)
RETURNS timestamptz
LANGUAGE sql STABLE
AS $fn$
  SELECT CASE
    WHEN p_tevo_local IS NULL                THEN coalesce(p_sg, p_gt)
    WHEN coalesce(p_sg, p_gt) IS NULL        THEN p_tevo_local::timestamptz
    -- TEvo tracks reschedules; a cross-source date more than a day adrift is stale.
    WHEN abs(extract(epoch FROM (coalesce(p_sg, p_gt) - p_tevo_local::timestamptz))) > 86400
                                             THEN p_tevo_local::timestamptz
    ELSE coalesce(p_sg, p_gt)
  END
$fn$;
COMMENT ON FUNCTION public.deal_event_datetime(timestamptz,timestamptz,text) IS
  'THE event datetime for the deals surface. Prefers the SeatGeek canonical UTC timestamp (occurs_at_local is text), EXCEPT when it disagrees with TEvo by more than a day — TEvo is reschedule-aware, so the other source is stale and TEvo wins. Sub-day gaps are timezone noise. STABLE, not IMMUTABLE: text->timestamptz is a stable cast. D0 mig 20260914220030.';

-- ── 2. Scanner stores the same date it selected on ───────────────────────────
DO $do$
DECLARE
  v_def  text;
  v_args text;
  v_cnt  int;
  i      int;
  v_pairs text[][] := ARRAY[
    ARRAY[
      $a$coalesce(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local::timestamptz)::date AS dt$a$,
      $b$public.deal_event_datetime(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local)::date AS dt$b$
    ],
    ARRAY[
      $a$EXTRACT(dow FROM coalesce(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local::timestamptz))::int$a$,
      $b$EXTRACT(dow FROM public.deal_event_datetime(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local))::int$b$
    ]
  ];
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid) INTO v_def, v_args
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname='public' AND p.proname='scan_listing_deals';
  IF v_def IS NULL THEN RAISE EXCEPTION 'scan_listing_deals not found'; END IF;

  FOR i IN 1 .. array_length(v_pairs,1) LOOP
    v_cnt := (length(v_def) - length(replace(v_def, v_pairs[i][1], ''))) / length(v_pairs[i][1]);
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION 'date patch % matched % times (expected exactly 1) — refusing to replace scanner', i, v_cnt;
    END IF;
    v_def := replace(v_def, v_pairs[i][1], v_pairs[i][2]);
  END LOOP;

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.scan_listing_deals(%s) RETURNS jsonb LANGUAGE plpgsql '
    || 'SECURITY DEFINER SET search_path TO ''public'', ''extensions'', ''pg_temp'' AS %L',
    v_args, v_def);
END
$do$;

-- ── 3. Repair rows already stamped with a stale date ─────────────────────────
-- The GT lookup MUST mirror the scanner's own lateral (ORDER BY event_time_utc LIMIT 1).
-- A plain LEFT JOIN hits the documented `UPDATE … FROM` one-source-row-per-target trap:
-- 4 events carry TWO gotickets_event rows a day apart, so a plain join picks arbitrarily and
-- leaves rows one day off from what the scanner will write next tick. Seen live: the first
-- pass of this repair left 29 rows stale for exactly that reason.
UPDATE public.gotickets_deals_feed f
   SET event_date = src.want
  FROM (
    SELECT e.id AS ev,
           public.deal_event_datetime(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local)::date AS want
    FROM public.events e
    LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id
    LEFT JOIN LATERAL (
      SELECT g2.event_time_utc FROM public.gotickets_event g2
      WHERE g2.tevo_event_id = e.id ORDER BY g2.event_time_utc LIMIT 1) ge ON true
  ) src
 WHERE src.ev = f.tevo_event_id
   AND f.event_date IS DISTINCT FROM src.want;

-- ── 4. Drop grades that were produced from the wrong date ────────────────────
-- These are not corrections, they are removals: the event has not played yet, so there is
-- nothing to grade. grade_deal_outcomes() will pick it up normally after it does.
DELETE FROM public.gotickets_deal_outcome o
 USING public.events e
 WHERE e.id = o.tevo_event_id
   AND public.deal_event_datetime(
         (SELECT sgc.sg_datetime_utc FROM public.sg_events_canonical sgc WHERE sgc.tevo_event_id = e.id),
         (SELECT ge.event_time_utc  FROM public.gotickets_event ge      WHERE ge.tevo_event_id = e.id),
         e.occurs_at_local)::date >= current_date;
