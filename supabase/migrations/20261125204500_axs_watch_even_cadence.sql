-- Migration 20261125204500 · level:data-collection · lane:a1 (AXS watch cadence) · writes:axs_watch_config,axs_watch_settle_one() · reads:primary_poll_event,axs_watch_config
--
-- ============================================================================
-- Migration 20261125204500 — one cadence for every watched event: an hour, or
--   half an hour once the event is inside 36 hours
--
-- Lane:     a1 (AXS watch cadence)
-- Touches:  axs_watch_config (+base_every, +near_every, +near_within),
--           axs_watch_settle_one() (REPLACE). Reads primary_poll_event.
-- Pre-reqs: 20261125010000 (pace), 20261125150000 (stop_before_start),
--           20261125173500 (watch_until_days)
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes only how
-- often the existing reader is told to read.
--
-- Operator 2026-11-25: "event at 1 hour cadance until event is 36 hours away
-- then it drops to every 30 mins", after being shown the spread below.
--
-- ── What it replaces ───────────────────────────────────────────────────────
-- Until now an AXS event's interval came from primary_poll_interval(event_date,
-- median_price, listed_quantity) — the shared box-office ladder — and
-- axs_watch_settle_one then raised it to axs_watch_config.far_out_every for any
-- event beyond far_out_days. Two consequences, both measured on 2026-11-25:
--   * reads per event over the day ran min 2, p10 15, median 22, p90 28, max 46.
--     A 1.9x spread across the middle of the list and 23x end to end, for events
--     the watch holds precisely because they are all worth watching.
--   * far_out_every was retuned hourly by axs_watch_pace_apply() and flapped
--     between 01:00 and 01:30 because demand at the 60-minute rung (316/h) sat
--     just under usable_per_hour (314/h). The flapping was logged as a known
--     non-issue for days.
--
-- Now the interval is set, not floored, and it does not depend on price,
-- quantity or the ladder at all:
--
--   start within near_within (36 h)  ->  near_every (30 min)
--   otherwise                        ->  base_every (1 h)
--
-- The start is coalesce(start_utc, (event_date + 1)::timestamptz), the same
-- expression axs_watch_next() and the retire rule use, so an event with no
-- clock time is treated as ending its local day.
--
-- ── The stop rules are untouched ───────────────────────────────────────────
-- This governs how often a WATCHED event is read, nothing about which events are
-- watched. Still in force, all of them: stop_before_start (reads stop 6 h before
-- the start, mig 20261125150000), watch_until_days (the 180-day ceiling, mig
-- 20261125173500), the not-on-sale rule (an event answering "not on sale" is put
-- on not_on_sale_every, 6 h — that branch runs after this one and still wins),
-- upcoming-sale exclusion and onsale_delay. An event leaves the list at the
-- 03:20Z fill as before.
--
-- ── SIZED FROM MEASURED THROUGHPUT, NOT FROM THE CREDIT BUDGET ────────────
-- The reader is sequential by UPSTREAM RULE, not by choice: TicketsData refuses a
-- second AXS request inside three seconds ("Please wait at least 3 seconds between
-- AXS requests"), which is why core/axs_watch_reader.py reads one at a time. So the
-- ceiling is 3600 / (seconds per read), and nothing we configure raises it.
--
-- Twelve complete hours to 2026-11-25 20:00Z: 207 reads in the worst hour, 339 on
-- average, 409 at best; 10.6 s per read implied, settle avg 8.2 s. Against that:
--   305 events hourly   = 305/h  =  90% of an average hour, 147% of the worst
--   305 events / 75 min = 244/h  =  72% of an average hour
-- Hourly was measured and rejected for that reason: at 90% the slack is 34 reads an
-- hour, so a four-minute restart strands about 20 events and takes ~35 minutes to
-- clear, and there were 14 restarts on 2026-11-25. base_every is therefore 75
-- minutes (operator chose it over 90 after being shown both): 95 reads an hour of
-- slack, a four-minute outage clearing in about 13 minutes, 19 reads per event a day.
-- It still goes underwater in the very worst hour observed; that is the restarts,
-- and no cadence can fix them.
--
-- Credits are NOT the constraint: 244 x 24 = 5,856 reads a day against a daily_cap
-- of 10,310 from the 250,000-credit cycle. 43% spare.
--
-- ── EVEN PHASE: THE WHOLE INTERVAL IS USED, NOT SIX MARKS IN IT ────────────
-- primary_poll_next() puts an event on the next interval boundary plus a RANDOM
-- multiple of primary_poll_config.slot (10 minutes) — six marks an hour. 305 events
-- over six marks is about 51 landing together, 9 minutes of work arriving at once,
-- and random assignment clumps some marks past 65 while others sit light. That is
-- what makes a slow read hurt: it collides with a burst instead of eating slack.
--
-- Each event now has a STABLE PHASE inside the interval, from its own id:
--   phase   = hashtext(event_id) & 2147483647, modulo the interval in seconds
--   next    = the next instant t with t = phase (mod interval) and t > now()
-- 305 phases spread over 4,500 s is one read due every 14.8 s against a 10.6 s
-- service time. The queue is smooth, every event gets exactly its interval to
-- breathe, and the phase is fixed so a late read RESYNCS to its slot rather than
-- drifting: an event read 30 minutes late comes due 45 minutes later, not 75. After
-- an outage the list returns to its own spacing instead of bunching at now+interval.
--
-- ── ONE COUPLING TO KNOW ABOUT: hot_every MUST STAY EQUAL TO near_every ────
-- axs_watch_next() has a separate rule for when the day's cap is already spent:
-- it hands out only events whose poll_interval <= hot_every, and only up to
-- hot_overrun_pct. hot_every is 30 minutes and near_every is 30 minutes, so
-- under this migration "hot" and "inside 36 hours" are the SAME SET: once the
-- cap is spent the watch keeps reading exactly the imminent events and drops the
-- hourly ones. That is the triage you want, but it is emergent from the two
-- values matching, not stated anywhere in axs_watch_next. Raise near_every above
-- hot_every and the over-cap branch silently hands out nothing; lower it below
-- and far-out events start qualifying as hot. Scenario s03 section E pins the
-- behaviour: before this change it handed out event 32 (ladder, 30 min) and
-- event 33 (10 min); now only 33, because 32 is on the flat hour.
--
-- far_out_every and far_out_days stay on the config and axs_watch_pace() still
-- reports them, but NOTHING READS THEM FOR CADENCE ANY MORE. They are left in
-- place so axs_watch_pace_apply() and the monitor keep working; removing them is
-- a separate change.
-- ============================================================================

BEGIN;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS base_every  interval NOT NULL DEFAULT interval '75 minutes',
  ADD COLUMN IF NOT EXISTS near_every  interval NOT NULL DEFAULT interval '30 minutes',
  ADD COLUMN IF NOT EXISTS near_within interval NOT NULL DEFAULT interval '36 hours';

COMMENT ON COLUMN public.axs_watch_config.base_every  IS 'Read interval for every watched AXS event outside near_within (mig 20261125204500).';
COMMENT ON COLUMN public.axs_watch_config.near_every  IS 'Read interval once the event starts within near_within (mig 20261125204500).';
COMMENT ON COLUMN public.axs_watch_config.near_within IS 'How close to the start the faster near_every cadence begins (mig 20261125204500).';

CREATE OR REPLACE FUNCTION public.axs_watch_settle_one(p_event_id text, p_status_code integer,
         p_content jsonb, p_timed_out boolean DEFAULT false, p_error_msg text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  t record; body jsonb; parsed jsonb; v_ok boolean; v_outcome text; v_error text; v_tevo bigint;
  v_every interval; v_sec bigint; v_phase bigint; v_next numeric;
BEGIN
  SELECT * INTO v_cfg FROM public.axs_watch_config;
  body := p_content->'body';
  parsed := NULL; v_error := NULL;
  IF coalesce(p_timed_out, false) OR p_error_msg IS NOT NULL THEN
    v_ok := false; v_outcome := 'timeout'; v_error := left(coalesce(p_error_msg, 'timed out'), 200);
  ELSIF p_status_code IN (400, 404, 410, 422) THEN
    v_ok := false; v_outcome := 'not_axs'; v_error := 'HTTP ' || p_status_code || ': AXS does not sell this event through TicketsData';
  ELSIF p_status_code IS DISTINCT FROM 200 THEN
    v_ok := false; v_outcome := 'upstream_error'; v_error := 'HTTP ' || coalesce(p_status_code::text, '?') || ' from TicketsData';
  ELSIF body->>'status' = 'expired' THEN
    v_ok := false; v_outcome := 'expired'; v_error := 'expired: the event is over on AXS';
  ELSIF jsonb_typeof(body->'event') = 'object' AND coalesce(body->>'status', '') IN ('ok', 'success') AND coalesce(body->>'exit_code', '0') = '0' THEN
    parsed := public.axs_watch_parse(body);
    v_ok := true; v_outcome := CASE WHEN jsonb_array_length(parsed->'listings') = 0 THEN 'empty' ELSE 'ok' END;
  ELSE
    v_ok := false; v_outcome := 'unparsed';
    v_error := left(coalesce(body->>'error', body->>'message', p_content->>'error', 'TicketsData answered without an event'), 200);
  END IF;

  v_tevo := NULL;
  SELECT * INTO t FROM public.primary_poll_event e WHERE e.source = 'axs' AND e.source_event_id = p_event_id;
  IF FOUND THEN
    v_tevo := t.tevo_event_id;
    PERFORM public.primary_poll_ingest('axs', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
              'id', t.source_event_id, 'name', t.name, 'local_date', t.event_date::text,
              'local_time', to_char(t.start_local_time, 'HH24:MI'), 'start_utc', t.start_utc, 'timezone', t.timezone,
              'venue', t.venue_name, 'city', t.venue_city, 'state', t.venue_state, 'url', t.ticket_url,
              'offer_id', coalesce(parsed->>'offer_id', t.offer_id),
              'order_min', parsed->>'order_min', 'order_max', parsed->>'order_max',
              'total_available', parsed->>'total_available', 'price_min', parsed->>'price_min', 'price_max', parsed->>'price_max',
              'ok', v_ok, 'error', v_error)) || jsonb_build_object('listings', coalesce(parsed->'listings', '[]'::jsonb))));

    -- One cadence for every watched event (mig 20261125204500, operator "event at 1 hour cadance
    -- until event is 36 hours away then it drops to every 30 mins"). SET, not floored: the ingest
    -- above has just written the ladder's interval from date / price / quantity, and this replaces
    -- it, so no event is read far oftener than another. next_poll_at is always recomputed, because
    -- the ingest moved it too. far_out_every / far_out_days are no longer consulted.
    v_every := CASE
                 WHEN coalesce(t.start_utc, (t.event_date + 1)::timestamptz) <= now() + v_cfg.near_within
                 THEN v_cfg.near_every
                 ELSE v_cfg.base_every
               END;
    v_sec   := greatest(extract(epoch FROM v_every)::bigint, 1);
    v_phase := (hashtext(p_event_id)::bigint & 2147483647) % v_sec;
    -- the next instant congruent to this event's own phase, strictly after now
    v_next  := floor((extract(epoch FROM now()) - v_phase) / v_sec) * v_sec + v_phase;
    IF v_next <= extract(epoch FROM now()) THEN v_next := v_next + v_sec; END IF;
    UPDATE public.primary_poll_event e
       SET poll_interval = v_every,
           next_poll_at  = to_timestamp(v_next)
     WHERE e.source = 'axs' AND e.source_event_id = p_event_id;

    -- An event that says it is not on sale keeps its own, slower rule and so wins over the two
    -- above: it runs after them, as it did before this migration.
    IF v_outcome = 'unparsed' AND v_error ~* 'not (currently |yet )?on sale|not on sale yet|no tickets are currently available|coming soon' THEN
      UPDATE public.primary_poll_event e
         SET poll_interval = v_cfg.not_on_sale_every, next_poll_at = now() + v_cfg.not_on_sale_every * (0.75 + random() * 0.5)
       WHERE e.source = 'axs' AND e.source_event_id = p_event_id;
    END IF;
  END IF;
  IF p_status_code = 200 THEN
    PERFORM public.td_charge_credit(1, v_tevo, 'AXS', '/fetch', p_status_code, nullif(p_content->>'quota_remaining', '')::integer);
  END IF;
  RETURN jsonb_build_object(
           'outcome', v_outcome, 'error', v_error,
           'response_s', nullif(coalesce(body->>'elapsed_seconds', p_content->>'response_s'), '')::numeric,
           'listings', CASE WHEN parsed IS NOT NULL THEN jsonb_array_length(parsed->'listings') END,
           'quota_remaining', nullif(p_content->>'quota_remaining', '')::bigint);
END $function$;

COMMIT;
