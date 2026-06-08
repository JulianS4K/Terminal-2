-- Migration 20260607170000 · level:admin · lane:D0 (authored) → A1 (apply)
--   writes: public.ticketsdata_event_xref (+col manual_opt_in),
--           public.td_enqueue_peak(text,text) [TP opt-in gate],
--           public.td_tp_set_opt_in(bigint,boolean) [new operator toggle]
--   reads:  sg_events_canonical, aq_event_map
--   pre:    20260529180000 (td_tickpick_platform), 20260529200000 (td_ticketmaster_platform)
--
-- ⚠️  NOT YET APPLIED TO PROD — D0 authored, A1 to review + apply (D0 cannot run migrations).
--
-- ============================================================
-- DEMOTE TICKPICK → OPT-IN; TICKETMASTER TAKES OVER ITS EVENT SET
-- ============================================================
-- Operator directive (2026-06-07): "demote tickpick, replace with ticketmaster
-- everywhere tickpick was." Resolved via AskUserQuestion to:
--   1. TP collected ONLY when explicitly turned on for an event (opt-in).
--   2. Map TM onto the existing TP event set.
--   3. Author full migration; no FE changes in this PR.
--
-- WHY THIS IS SMALL: TM is ALREADY a structural peer of TP —
--   • same enqueue cadence  : td_enqueue_peak_tm '6-59/10' vs td_enqueue_peak_tp '8-59/10' (both 'metronome')
--   • same performers       : Yankees + Knicks (td_tm_performers == td_tp_performers by team)
--   • same event set        : 21 of 22 active TP events already have an active TM xref;
--                             the lone gap (Boston @ Yankees 2026-06-07 13:35Z) is a PAST game.
-- So "TM everywhere TP was" needs no new TM wiring — it only needs TP to step down.
--
-- WHAT CHANGES:
--   A. New column ticketsdata_event_xref.manual_opt_in (DEFAULT false). On apply, ALL
--      existing TP rows become false → TP enqueue stops immediately. TM continues untouched.
--   B. td_enqueue_peak() gains a single guard: TP rows enqueue ONLY when manual_opt_in=true.
--      (Every other platform is unaffected — same behavior whether called per-platform or all.)
--   C. td_tp_set_opt_in(tevo_event_id, on) — clean operator toggle to turn TP on/off per event.
--
-- WHAT INTENTIONALLY DOES NOT CHANGE:
--   • TP discovery (td_tp_discover/_drain) keeps the TP↔event MAPPING fresh so an operator can
--     opt an event back in at any time. Mapping ≠ collection.
--   • TM stays the metronome — td_enqueue_peak_tm ('6-59/10') is unchanged and remains the
--     primary listings cron for this event set.
--   • td_enqueue_peak_tp is DEMOTED from the metronome ('8-59/10') to hourly ('12 * * * *') — see
--     section D. It now only serves opted-in events; hourly is responsive enough for a manual toggle
--     while reclaiming the every-10-min slot TM occupies.
--   • td_tp_* snapshot columns + td_combined_median: compute_event_listing_snapshot only counts
--     TP listings captured in the last 25h, so once TP goes quiet td_tp_* self-heals to NULL and
--     drops out of the LEAST(...) combined median automatically — no column surgery needed.
--   • FE (event.js TP listings tab + TP order-book tab): deferred per directive. Note for the FE
--     pass — the TP *order-book* tab has no TM analogue (we don't sell on TM primary); only the
--     TP *listings* tab maps to TM.
--
-- ROLLBACK:
--   -- restore prior enqueue (drop the TP guard line), then:
--   ALTER TABLE public.ticketsdata_event_xref DROP COLUMN IF EXISTS manual_opt_in;
--   DROP FUNCTION IF EXISTS public.td_tp_set_opt_in(bigint, boolean);

-- ── A) Per-event opt-in flag ────────────────────────────────────────────────
ALTER TABLE public.ticketsdata_event_xref
  ADD COLUMN IF NOT EXISTS manual_opt_in boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.ticketsdata_event_xref.manual_opt_in IS
  'TP opt-in gate (2026-06-07): TickPick is collected ONLY for rows where this is true. '
  'Other platforms ignore it. Toggle via td_tp_set_opt_in(tevo_event_id, on).';

-- ── B) Enqueue gate — TP requires opt-in (live body reproduced + one guard) ──
CREATE OR REPLACE FUNCTION public.td_enqueue_peak(
  p_platform text DEFAULT NULL::text, p_interval_tag text DEFAULT 'manual'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_count int := 0; v_now timestamptz := clock_timestamp(); v_jobname text;
BEGIN
  v_jobname := CASE WHEN p_platform IS NOT NULL THEN 'td_enqueue_peak_'||lower(p_platform) ELSE 'td_enqueue_peak' END;
  IF NOT public.cron_should_fire(v_jobname) THEN RETURN 0; END IF;
  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_enqueue_peak(%): budget exhausted, skipping', COALESCE(p_platform,'all');
    RETURN 0;
  END IF;

  FOR r IN
    SELECT x.event_id, x.platform, x.event_url, c.required_min
    FROM public.ticketsdata_event_xref x
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = (
      SELECT aem.sg_event_id FROM public.aq_event_map aem
      WHERE aem.aq_short_event_id = x.aq_short_event_id LIMIT 1)
    CROSS JOIN LATERAL public.collector_band('TD','listings',
                 greatest(EXTRACT(epoch FROM (sgc.sg_datetime_utc - v_now))/3600.0, 0)) c
    WHERE x.active = true
      AND x.event_url IS NOT NULL
      AND sgc.sg_datetime_utc > v_now - interval '6 hours'
      AND (p_platform IS NULL OR x.platform = p_platform)
      -- TP DEMOTION (2026-06-07): TickPick enqueues ONLY for opted-in events.
      AND (x.platform <> 'TP' OR x.manual_opt_in = true)
      AND ( x.last_enqueued_at IS NULL
            OR x.last_enqueued_at < v_now - make_interval(mins => c.required_min) )
      AND NOT EXISTS (
        SELECT 1 FROM public.td_pull_queue q
        WHERE q.event_id = x.event_id AND q.platform = x.platform AND q.resolved_at IS NULL)
    ORDER BY c.required_min ASC, x.owned_tickets DESC NULLS LAST,
             x.median_retail_price DESC NULLS LAST, x.last_enqueued_at NULLS FIRST
    LIMIT 40
  LOOP
    INSERT INTO public.td_pull_queue (event_id, platform, event_url, interval_tag, created_at)
    VALUES (r.event_id, r.platform, r.event_url, p_interval_tag, v_now);
    UPDATE public.ticketsdata_event_xref
      SET last_enqueued_at = v_now, enqueues_today = enqueues_today + 1, updated_at = v_now
      WHERE (event_id, platform) = (r.event_id, r.platform);
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;

-- ── C) Operator toggle: turn TP on/off for one canonical (tevo) event ────────
CREATE OR REPLACE FUNCTION public.td_tp_set_opt_in(
  p_tevo_event_id bigint, p_on boolean DEFAULT true)
 RETURNS integer  -- # of TP xref rows updated (0 if no TP mapping for this event)
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_email text; v_aq text; v_n int;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: td_tp_set_opt_in is @s4kent.com only';
  END IF;
  SELECT aem.aq_short_event_id INTO v_aq
  FROM public.sg_events_canonical sgc
  JOIN public.aq_event_map aem ON aem.sg_event_id = sgc.sg_event_id
  WHERE sgc.tevo_event_id = p_tevo_event_id
  LIMIT 1;
  IF v_aq IS NULL THEN RETURN 0; END IF;
  UPDATE public.ticketsdata_event_xref
    SET manual_opt_in = p_on, updated_at = now()
    WHERE platform = 'TP' AND aq_short_event_id = v_aq;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.td_tp_set_opt_in(bigint, boolean) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.td_tp_set_opt_in(bigint, boolean) TO authenticated;

-- ── D) Cron: TM keeps the metronome; demote the TP enqueue to hourly ─────────
-- TM (td_enqueue_peak_tm '6-59/10') is intentionally left as-is — it is now the sole
-- every-10-min listings driver for this set. TP drops to hourly: it fires only for
-- opted-in events (section B gate), so the dense cadence is wasted on it.
SELECT cron.unschedule('td_enqueue_peak_tp')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='td_enqueue_peak_tp');
SELECT cron.schedule('td_enqueue_peak_tp', '12 * * * *',
  $cb$ DO $b$ BEGIN PERFORM public.td_enqueue_peak('TP','opt_in_hourly'); END $b$; $cb$);

-- ── Post-apply smoke (A1, run manually) ─────────────────────────────────────
--   -- TP should now enqueue nothing (no opt-ins yet); TM unaffected:
--   SELECT public.td_enqueue_peak('TP','smoke');   -- expect 0
--   SELECT public.td_enqueue_peak('TM','smoke');   -- expect >0 (TM still active)
--   -- Turn TP on for one event, confirm it enqueues next tick:
--   SELECT public.td_tp_set_opt_in(<tevo_event_id>, true);   -- expect 1
--   SELECT count(*) FROM ticketsdata_event_xref WHERE platform='TP' AND manual_opt_in;  -- expect 1
--   -- Coverage check: every active TP event has an active TM peer (ignoring past games):
--   SELECT count(*) FROM ticketsdata_event_xref tp
--   JOIN sg_events_canonical sgc ON sgc.tevo_event_id IS NOT NULL
--   WHERE tp.platform='TP' AND tp.active
--     AND NOT EXISTS (SELECT 1 FROM ticketsdata_event_xref tm
--                     WHERE tm.platform='TM' AND tm.active AND tm.aq_short_event_id=tp.aq_short_event_id);
