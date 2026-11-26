-- Migration 20261125214500 · level:data-collection · lane:a1 (AXS watch cadence) · writes:axs_watch_cadence(new),axs_watch_config(+cadence_scale),axs_watch_cadence_every()(new),axs_watch_cadence_demand()(new),axs_watch_settle_one()(replaced) · reads:primary_poll_event,axs_watch_config,axs_watch_poll
--
-- ============================================================================
-- Migration 20261125214500 — ONE cadence for the AXS watch: proximity bands,
--   a stable per-event phase, sized from measured throughput
--
-- Lane:     a1 (AXS watch cadence)
-- Touches:  axs_watch_cadence (new table), axs_watch_config (+cadence_scale),
--           axs_watch_cadence_every() (new), axs_watch_cadence_demand() (new),
--           axs_watch_settle_one() (REPLACED, 7-arg form).
-- pre:      none hard. It creates the 7-argument axs_watch_settle_one itself, so it
--           applies whether or not 20261125210000 (the extension reader) is in place,
--           and its higher number means a from-zero replay lands it last either way.
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes only how often
-- the existing reader is told to read.
--
-- ── WHY THIS MIGRATION EXISTS: TWO CADENCES WERE IN FLIGHT ────────────────
-- Operator 2026-11-25: "take control of the cadence versions and consolidate into one
-- version that takes into account median process times and allows for all 305 events to
-- be collected within the daily budget and CPU/processing budget, need freshest listings
-- for all events without breaking the system or restarting. Closer events can be polled
-- more often".
--
-- Two sessions were editing the same path:
--   * 20261125204500 (this session, PR 1215, never applied — REMOVED by this change):
--     one flat interval for every watched event, 75 minutes, 30 inside 36 hours. Sized
--     from TicketsData: 339 reads/h on an average hour, 10.6 s a read, sequential
--     because TicketsData refuses a second AXS request inside three seconds.
--   * 20261125210000 (another session, PR 1216): reader = 'extension', a Firefox
--     extension reading ext_lanes events at once, unmetered (daily_cap 1,000,000), with
--     20/30/45-minute rungs offered to the pace picker. It KEEPS the far_out_every floor.
-- Both replace axs_watch_settle_one, so whichever applied second silently discarded the
-- other. Worse, each hardcodes numbers that are only right for its own reader.
--
-- Two things settled it, both measured rather than assumed:
--   1. THE FLAT INTERVAL WAS WRONG FOR THE ACTUAL LIST. The nearest of the 305 events is
--      6.2 days out; nothing is inside 36 hours, so the 30-minute tier of 204500 would
--      have sat empty for days while every event, 6 days out or 180, read alike.
--   2. CLOSENESS IS WHERE FRESHNESS IS WORTH PAYING FOR, and the list is heavily far-out:
--      2 events inside 7 days, 16 at 7-14, 36 at 14-30, 44 at 30-60, 102 at 60-120,
--      75 at 120-180. Spending the same rate on all of them buys staleness where it
--      matters and waste where it does not.
--
-- ── THE BANDS, AND WHAT THEY COST (measured, 2026-11-25 21:4xZ) ───────────
--   days out   events   every     reads/h   reads/day
--   <= 2            0   15 min          -           -
--   2 - 7           2   20 min        6.0         144
--   7 - 14         16   30 min       32.0         768
--   14 - 30        36   45 min       48.0       1,152
--   30 - 60        44   90 min       29.3         704
--   60 - 120      102    3 h         34.0         816
--   120 - 180      75    6 h         12.5         300
--   TOTAL         275              162 /h       3,884 /day
--
-- Against the budgets this had to fit:
--   CPU / processing: 162 reads/h is 48% of an average hour's measured 339, and 78% of
--     the worst hour observed today (207, a restart hour). So it holds THROUGH a restart
--     hour, which neither 60 nor 75 minutes flat did (90% and 72% of average, 147% and
--     118% of the worst). settle_p50 is 7.6-8.2 s and s_per_read 8.6-10.6 s; the bands
--     were chosen against those numbers, not against the credit cap.
--   Daily budget: 3,884 reads/day against daily_cap 10,297 — 38%. Over the cycle
--     89,332 of the 236,835 credits available after the reserve, so the 250,000 ceiling
--     stops being a constraint at all.
--   Freshness: the imminent events move from today's flat 60-90 minutes to 20-30, about
--     three times fresher, while TOTAL LOAD HALVES (162/h against the ~339/h the watch
--     actually ran today). That is the whole point: fresher where it matters, cheaper
--     overall, and real headroom so a restart does not strand the list.
--
-- ── READER-AGNOSTIC BY DESIGN ─────────────────────────────────────────────
-- The band table holds the intervals; axs_watch_config.cadence_scale multiplies all of
-- them. The absolute rate therefore follows whichever reader is live: on the TicketsData
-- worker the figures above hold at scale 1.0; the extension reads ext_lanes at once, so
-- a read costs about (settle + 1)/lanes and the same table can be tightened by lowering
-- the scale. Nothing here hardcodes a reader's speed, which is what let the two earlier
-- versions contradict each other.
-- axs_watch_cadence_demand() reports demand against measured throughput and the day's
-- cap so the hourly monitor can assert the fit instead of trusting this comment.
-- SCALING IS MANUAL FOR NOW: at 48% of capacity nothing needs to move, and having
-- axs_watch_pace_apply() drive the scale is a separate, testable change.
--
-- ── EVEN PHASE, SO THE WHOLE INTERVAL IS USED ─────────────────────────────
-- primary_poll_next() puts an event on the next interval boundary plus a RANDOM multiple
-- of primary_poll_config.slot (10 min) — six marks an hour. Measured on prod: 304 of the
-- 305 were due at exactly second 0 of a ten-minute mark, loaded 30/36/41/55/68/75 across
-- the six, so the :50 mark carried 2.5x the :00 mark. The reads came out smooth only
-- because the sequential reader cannot burst: a permanent backlog was flattening the
-- spikes, and every read was served however deep the queue was at its turn. That is the
-- 48-minute median gap with an 87-minute p90 and a 146-minute maximum.
-- Each event now has a stable phase from its own id (hashtext & 2147483647, modulo the
-- interval in seconds); next_poll_at is the next instant congruent to it. A late read
-- RESYNCS to its own slot rather than drifting, so after a restart the list returns to
-- its spacing instead of bunching at now + interval.
--
-- ── THE STOP RULES ARE UNTOUCHED ──────────────────────────────────────────
-- This governs how often a WATCHED event is read, nothing about which events are watched:
-- stop_before_start (6 h before the start), watch_until_days (the 180-day ceiling),
-- not_on_sale_every (that branch runs after this one and still wins), upcoming-sale
-- exclusion and onsale_delay all stand. Events leave and enter at the 03:20Z fill.
--
-- far_out_every / far_out_days stay on the config and axs_watch_pace() still reports
-- them, but NOTHING READS THEM FOR CADENCE ANY MORE, so the 01:00/01:30 rung flapping
-- logged as a known non-issue for days ends here.
--
-- ⚠ hot_every AND THE OVER-CAP BRANCH. axs_watch_next() hands out only events with
-- poll_interval <= hot_every once the day's cap is spent. hot_every is 30 minutes, so
-- with these bands "hot" means an event inside 14 days — which is the right triage, but
-- it is emergent from the two values, not stated in axs_watch_next. Widen the 30-minute
-- band and more events qualify as hot; raise every band above 30 minutes and the
-- over-cap branch hands out nothing.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.axs_watch_cadence (
  band        text PRIMARY KEY,
  max_days    numeric NOT NULL,
  every       interval NOT NULL CHECK (every >= interval '5 minutes'),
  sort_order  integer NOT NULL,
  enabled     boolean NOT NULL DEFAULT true,
  note        text,
  set_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.axs_watch_cadence IS
  'AXS watch read cadence by how close the event is (mig 20261125214500). An event takes the interval of the first enabled band, by sort_order, whose max_days it is within; axs_watch_config.cadence_scale multiplies it.';

INSERT INTO public.axs_watch_cadence (band, max_days, every, sort_order, note) VALUES
  ('d0_2',     2,  interval '15 minutes', 1, 'event day and the day before'),
  ('d2_7',     7,  interval '20 minutes', 2, 'inside a week'),
  ('d7_14',   14,  interval '30 minutes', 3, 'inside a fortnight; also the hot_every bound'),
  ('d14_30',  30,  interval '45 minutes', 4, NULL),
  ('d30_60',  60,  interval '90 minutes', 5, NULL),
  ('d60_120',120,  interval '3 hours',    6, NULL),
  ('d120_up',1e9,  interval '6 hours',    7, 'to the watch_until_days ceiling')
ON CONFLICT (band) DO NOTHING;

ALTER TABLE public.axs_watch_config
  ADD COLUMN IF NOT EXISTS cadence_scale numeric NOT NULL DEFAULT 1.0
    CHECK (cadence_scale >= 0.25 AND cadence_scale <= 8.0);
COMMENT ON COLUMN public.axs_watch_config.cadence_scale IS
  'Multiplies every axs_watch_cadence band. 1.0 = the table as written; raise it to slow the whole ladder when throughput drops (mig 20261125214500).';

ALTER TABLE public.axs_watch_cadence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.axs_watch_cadence FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.axs_watch_cadence TO service_role;

-- The interval for one event: its band, scaled. STABLE so the planner can batch it.
CREATE OR REPLACE FUNCTION public.axs_watch_cadence_every(p_start timestamptz, p_event_date date)
 RETURNS interval
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT c.every * (SELECT cfg.cadence_scale FROM public.axs_watch_config cfg)
    FROM public.axs_watch_cadence c
   WHERE c.enabled
     AND extract(epoch FROM coalesce(p_start, (p_event_date + 1)::timestamptz) - now()) / 86400.0
         <= c.max_days
   ORDER BY c.sort_order
   LIMIT 1;
$function$;

-- What the ladder asks of the reader, against what the reader can do. Read-only; the
-- hourly monitor asserts the fit with this rather than trusting the header's arithmetic.
CREATE OR REPLACE FUNCTION public.axs_watch_cadence_demand()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH e AS (
    SELECT public.axs_watch_cadence_every(t.start_utc, t.event_date) AS every
      FROM public.primary_poll_event t
     WHERE t.source = 'axs' AND t.ticket_url IS NOT NULL
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

-- The 7-argument form, created here whether or not 20261125210000 applied. p_charge and
-- p_via keep that migration's meaning: the extension's reads pass false and name
-- themselves, so no TicketsData credit is spent for them.
DROP FUNCTION IF EXISTS public.axs_watch_settle_one(text, integer, jsonb, boolean, text);

CREATE OR REPLACE FUNCTION public.axs_watch_settle_one(
         p_event_id text, p_status_code integer, p_content jsonb,
         p_timed_out boolean DEFAULT false, p_error_msg text DEFAULT NULL,
         p_charge boolean DEFAULT true, p_via text DEFAULT 'TicketsData')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.axs_watch_config%ROWTYPE;
  t record; body jsonb; parsed jsonb; v_ok boolean; v_outcome text; v_error text; v_tevo bigint;
  v_via text := coalesce(nullif(p_via, ''), 'TicketsData');
  v_every interval; v_sec bigint; v_phase bigint; v_next numeric;
BEGIN
  SELECT * INTO v_cfg FROM public.axs_watch_config;
  body := p_content->'body';
  parsed := NULL; v_error := NULL;
  IF coalesce(p_timed_out, false) OR p_error_msg IS NOT NULL THEN
    v_ok := false; v_outcome := 'timeout'; v_error := left(coalesce(p_error_msg, 'timed out'), 200);
  ELSIF p_status_code IN (400, 404, 410, 422) THEN
    v_ok := false; v_outcome := 'not_axs'; v_error := 'HTTP ' || p_status_code || ': AXS does not sell this event through ' || v_via;
  ELSIF p_status_code IS DISTINCT FROM 200 THEN
    v_ok := false; v_outcome := 'upstream_error'; v_error := 'HTTP ' || coalesce(p_status_code::text, '?') || ' from ' || v_via;
  ELSIF body->>'status' = 'expired' THEN
    v_ok := false; v_outcome := 'expired'; v_error := 'expired: the event is over on AXS';
  ELSIF jsonb_typeof(body->'event') = 'object' AND coalesce(body->>'status', '') IN ('ok', 'success') AND coalesce(body->>'exit_code', '0') = '0' THEN
    parsed := public.axs_watch_parse(body);
    v_ok := true; v_outcome := CASE WHEN jsonb_array_length(parsed->'listings') = 0 THEN 'empty' ELSE 'ok' END;
  ELSE
    v_ok := false; v_outcome := 'unparsed';
    v_error := left(coalesce(body->>'error', body->>'message', p_content->>'error', v_via || ' answered without an event'), 200);
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

    -- The cadence: the event's proximity band, scaled, SET rather than floored — the
    -- ingest above has just written the shared ladder's interval from date / price /
    -- quantity, and this replaces it. next_poll_at is always recomputed, on this event's
    -- own stable phase, so the due times spread across the whole interval instead of
    -- landing on six marks an hour. far_out_every / far_out_days are not consulted.
    v_every := coalesce(public.axs_watch_cadence_every(t.start_utc, t.event_date), interval '1 hour');
    v_sec   := greatest(extract(epoch FROM v_every)::bigint, 1);
    v_phase := (hashtext(p_event_id)::bigint & 2147483647) % v_sec;
    v_next  := floor((extract(epoch FROM now()) - v_phase) / v_sec) * v_sec + v_phase;
    IF v_next <= extract(epoch FROM now()) THEN v_next := v_next + v_sec; END IF;
    UPDATE public.primary_poll_event e
       SET poll_interval = v_every,
           next_poll_at  = to_timestamp(v_next)
     WHERE e.source = 'axs' AND e.source_event_id = p_event_id;

    -- An event that says it is not on sale keeps its own, slower rule, and so wins over
    -- the band above: this branch runs after it, as it did before the consolidation.
    IF v_outcome = 'unparsed' AND v_error ~* 'not (currently |yet )?on sale|not on sale yet|no tickets are currently available|coming soon' THEN
      UPDATE public.primary_poll_event e
         SET poll_interval = v_cfg.not_on_sale_every, next_poll_at = now() + v_cfg.not_on_sale_every * (0.75 + random() * 0.5)
       WHERE e.source = 'axs' AND e.source_event_id = p_event_id;
    END IF;
  END IF;
  IF p_status_code = 200 AND coalesce(p_charge, true) THEN
    PERFORM public.td_charge_credit(1, v_tevo, 'AXS', '/fetch', p_status_code, nullif(p_content->>'quota_remaining', '')::integer);
  END IF;
  RETURN jsonb_build_object(
           'outcome', v_outcome, 'error', v_error,
           'response_s', nullif(coalesce(body->>'elapsed_seconds', p_content->>'response_s'), '')::numeric,
           'listings', CASE WHEN parsed IS NOT NULL THEN jsonb_array_length(parsed->'listings') END,
           'quota_remaining', nullif(p_content->>'quota_remaining', '')::bigint);
END $function$;

REVOKE ALL ON FUNCTION public.axs_watch_settle_one(text, integer, jsonb, boolean, text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_settle_one(text, integer, jsonb, boolean, text, boolean, text) TO service_role;
REVOKE ALL ON FUNCTION public.axs_watch_cadence_every(timestamptz, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_cadence_every(timestamptz, date) TO service_role;
REVOKE ALL ON FUNCTION public.axs_watch_cadence_demand() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_watch_cadence_demand() TO service_role;

COMMIT;
