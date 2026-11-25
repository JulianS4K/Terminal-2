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
-- ── It fits, but with little room ──────────────────────────────────────────
-- 305 watched events at one read an hour is 305 reads/h, against usable_per_hour
-- 314 (reads_per_hour 419 at pace_target_pct 75). That is 97% of the usable rate,
-- so the ladder has about 9 reads/h of slack: each event that comes inside 36 h
-- adds one read an hour, so from about the 9th near event the reads begin to slip
-- past their slot. Today 0 of the 305 are inside 36 h, so there is no 30-minute
-- tier yet; it appears as the list ages. pace_target_pct (75) is the lever if the
-- slack runs out — raising it to 90 gives 377/h — and that is a reader-headroom
-- decision, not a credit one.
--
-- Credits: 305 x 24 = 7,320 reads a day plus about 52 for the catalogue feed,
-- against a daily_cap of 10,310 derived from the 250,000-credit cycle. Fits with
-- 29% to spare, and the spend becomes predictable rather than ladder-dependent.
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
  ADD COLUMN IF NOT EXISTS base_every  interval NOT NULL DEFAULT interval '1 hour',
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
  v_every interval;
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
    UPDATE public.primary_poll_event e
       SET poll_interval = v_every,
           next_poll_at  = public.primary_poll_next(v_every, e.next_poll_at)
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
