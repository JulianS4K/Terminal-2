-- Migration 20261126062000 · level:data-collection · lane:a1 (AXS watch pacing) · writes:axs_watch_cadence_demand()(replaced),axs_watch_pace_apply()(patched in place) · reads:primary_poll_event
--
-- ============================================================================
-- Migration 20261126062000 — the demand gauge counts events we READ, not ones we list
--
-- Lane:     a1 (AXS watch pacing)
-- Touches:  axs_watch_cadence_demand() (REPLACED), axs_watch_pace_apply() (patched).
-- pre:      20261126060000 (primary_poll_event.watch), 20261126053000 (the pacer).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- ── THE BUG, INTRODUCED 20 MINUTES EARLIER BY 20261126060000 ──────────────
-- Both the gauge and the brake measure demand with
--
--   SELECT sum(3600 / every) FROM primary_poll_event WHERE source='axs' AND ticket_url IS NOT NULL
--
-- which was exact while every row on the list was read. 20261126060000 split the list:
-- 310 rows are read and 380 are published to the API only. The predicate did not change,
-- so both functions started counting the catalogue:
--
--   axs_watch_cadence_demand() -> {"events": 690, "demand_per_hour": 662.3,
--                                  "usable_per_hour": 330, "pct_of_throughput": 200.7,
--                                  "fits": false}
--
-- The truth for the same moment is 310 events and 334.0 reads/hour — 101% of throughput,
-- not 201%. The 380 catalogue rows have next_poll_at NULL and are skipped by all four
-- selectors; they generate no read and cost no credit.
--
-- Left alone this was not a cosmetic reporting error. axs_watch_pace_apply() computes
-- cadence_scale as cadence_scale * band_demand / usable_per_hour, so at the next :07 it
-- would have read 662/330, set cadence_scale to about 2.0, and HALVED the real cadence of
-- all 310 watched events to relieve pressure that does not exist. The monitor would then
-- have reported a correctly-working brake applying a correct formula to a wrong input.
--
-- Caught by reading the gauge straight after applying 20261126060000 rather than trusting
-- that a split which passed 19 scenarios had not moved anything downstream. The scenarios
-- did not catch it: none asserts the demand figure against a list holding both kinds of
-- row, which is the gap s19 closes.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────
-- One predicate in each: AND t.watch. The gauge and the brake must count the same set the
-- selectors read, and the way to keep them honest is for all of them to name the flag.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.axs_watch_cadence_demand()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH e AS (
    SELECT public.axs_watch_cadence_every(t.start_utc, t.event_date) AS every
      FROM public.primary_poll_event t
     -- t.watch: a catalogue-only row is published, never read, and so is not demand
     -- (mig 20261126062000)
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
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_pace_apply';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_pace_apply not found'; END IF;

  SELECT count(*) INTO v_hits FROM regexp_matches(v_src,
    'WHERE t\.source = ''axs'' AND t\.ticket_url IS NOT NULL', 'g');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'pace_apply band-demand predicate: expected 1 site, found %', v_hits;
  END IF;
  v_new := replace(v_src,
    'WHERE t.source = ''axs'' AND t.ticket_url IS NOT NULL',
    'WHERE t.source = ''axs'' AND t.watch AND t.ticket_url IS NOT NULL');
  IF v_new = v_src THEN RAISE EXCEPTION 'pace_apply unchanged'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'axs_watch_pace_apply';
  IF v_src !~ 'AND t\.watch AND t\.ticket_url IS NOT NULL' THEN
    RAISE EXCEPTION 'pace_apply did not take the watch predicate';
  END IF;
END $surgery$;

-- bring the brake's own record into line now, so the 06:07 run diffs against the truth
SELECT public.axs_watch_pace_apply();

COMMIT;
