-- ============================================================================
-- Migration 20260630170000 — Data-derived peak/off-peak window (from SG sales)
--
-- Lane:     A1
-- Touches:  is_peak (NEW fn), collector_band(text,text,numeric) (CREATE OR REPLACE),
--           collector_band(text,text,numeric,boolean) (CREATE OR REPLACE),
--           cron job 'axs-probe-drain' (jobid 402, command change — schedule unchanged).
-- Pre-reqs: collector_cadence + collector_band (20260606191854 trading-hours cadence),
--           axs_probe_step (live; charged into TD ledger by 20260630160000).
--
-- WHY: The peak window was hardcoded inline in BOTH collector_band overloads as ET hours
--   [9..23,0] (= ET 09:00-00:59). Analysis of 135,658 deduped realized SG sales
--   (seatgeek_sales_snapshots.sale_at_utc = true SG transaction time, ET clock, 120d) shows the
--   active block runs ET 09:00-01:59 (~93.4% of sales) with a clean overnight trough ET 02:00-08:59
--   (~6.6%; deep dead zone ET 03:00-06:59 ~2.0%). The curve is robust: two sample seeds agree,
--   weekday/weekend share the same dead zone, and the <=7d cohort (which burns the SG token) sells
--   slightly LATER into the night -> ET01 (2.09%, above the 2.08% half-mean) belongs in PEAK.
--   A listing-reprice cross-check (seatgeek_listings_snapshots change-rate per snapshot) is flat/noisy
--   with no morning spike, so realized-sale velocity (value-of-freshness) is the correct scheduling
--   signal. This migration (1) extracts the window into ONE canonical public.is_peak() helper
--   (DRY + DST-safe via America/New_York), (2) re-points both collector_band overloads at it — the
--   ONLY behavioural delta is adding ET01 to peak (strictly widens peak by 1h; never reduces
--   freshness), and (3) applies the same window to the AXS probe (jobid 402), which today fires
--   '* * * * *' flat 24/7 with no peak gating — the single largest unrealized credit saving. Off-peak
--   the probe drops to ~1 fire / 10 min, which is far below its 12h refresh target, so overnight AXS
--   freshness is unaffected.
--
-- NOT in scope (deliberately): per-band interval VALUES, SG discovery-first (Phase 2f),
--   td_tier_enqueue retirement / breadth ladder (Phase 2d), per-platform budget split (Phase 3).
--   Those remain gated on ~3-7 days of the Phase-1 TD ledger. This migration only encodes the
--   data-decided WINDOW (which is gated on sales data — already abundant — not the new ledger).
--
-- Idempotent (CREATE OR REPLACE + cron.schedule upsert by name) -> apply-before-PR; re-apply is a no-op.
-- ============================================================================

-- 1. Canonical ET-aware peak-window helper (single source of truth, DST-safe).
--    PEAK = ET 09:00-01:59  ->  hours [9..23, 0, 1].  OFF-PEAK = ET 02:00-08:59.
CREATE OR REPLACE FUNCTION public.is_peak(p_at timestamptz DEFAULT now())
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT EXTRACT(hour FROM p_at AT TIME ZONE 'America/New_York')::int
         = ANY (ARRAY[9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,0,1]);
$function$;

REVOKE ALL ON FUNCTION public.is_peak(timestamptz) FROM anon;
GRANT  EXECUTE ON FUNCTION public.is_peak(timestamptz) TO service_role, authenticated;

-- 2a. collector_band(source,scope,hours) — swap the inline CASE for is_peak() (verbatim otherwise).
CREATE OR REPLACE FUNCTION public.collector_band(p_source text, p_scope text, p_hours numeric)
 RETURNS TABLE(band text, required_min integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT c.band,
         CASE WHEN public.is_peak()
              THEN c.peak_interval_min ELSE c.offpeak_interval_min END
  FROM public.collector_cadence c
  WHERE c.source=p_source AND c.scope=p_scope AND c.enabled
    AND p_hours >= c.min_hours AND (c.max_hours IS NULL OR p_hours < c.max_hours)
  ORDER BY c.sort_order LIMIT 1;
$function$;

-- 2b. collector_band(source,scope,hours,owned) — same swap; owned_kind logic preserved verbatim.
CREATE OR REPLACE FUNCTION public.collector_band(p_source text, p_scope text, p_hours numeric, p_owned boolean)
 RETURNS TABLE(band text, required_min integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT c.band,
         CASE WHEN public.is_peak()
              THEN c.peak_interval_min ELSE c.offpeak_interval_min END
  FROM public.collector_cadence c
  WHERE c.source=p_source AND c.scope=p_scope AND c.enabled
    AND p_hours >= c.min_hours AND (c.max_hours IS NULL OR p_hours < c.max_hours)
    AND c.owned_kind IN (CASE WHEN p_owned THEN 'owned' ELSE 'non' END, 'any')
  ORDER BY (c.owned_kind <> 'any') DESC, c.sort_order LIMIT 1;
$function$;

-- 3. AXS probe (jobid 402, name 'axs-probe-drain'): keep the 1-min schedule, but gate the call so it
--    fires every minute during PEAK and ~every 10 min during OFF-PEAK. Minute-of-hour is timezone-
--    invariant (ET is a whole-hour UTC offset), so EXTRACT(minute FROM now()) is DST-safe here.
--    EVENLY-SPACED LEAPFROG (operator 2026-06-30): the per-source TD secondary enqueues are already on
--    2-min offsets — SH :00 / VD :02 / GT :04 / TM :06 (jobids 269/270/271/316, UNCHANGED here) — leaving
--    an idle :06->:10 gap. Landing the AXS off-peak fire on minute %10 == 8 (:08,:18,..,:58) drops it into
--    that gap, so the combined off-peak cadence is a uniform 2-min leapfrog across the whole cycle:
--    SH:0 -> VD:2 -> GT:4 -> TM:6 -> AXS:8 -> repeat. No source fires on the same minute as another;
--    TD draw stays evenly spread, never spiked. cron.schedule() upserts by name -> idempotent.
SELECT cron.schedule(
  'axs-probe-drain',
  '* * * * *',
  $cmd$do $b$ begin
    if public.is_peak() or (extract(minute from now())::int % 10 = 8) then
      perform public.axs_probe_step();
    end if;
  end $b$;$cmd$
);

-- ----------------------------------------------------------------------------
-- Recommended follow-up cadence tunes (NOT applied here — separate UPDATEs, operator's call):
--   * Hold SG listings <=7d at peak 24/7 (Phase 2f, token is off the TD budget):
--       UPDATE public.collector_cadence SET offpeak_interval_min = peak_interval_min
--       WHERE source='SG' AND scope='listings' AND band IN ('le3d','d4_7');
--   * Off-peak interval is now governed by the corrected window; the deep dead zone ET03:00-06:59
--     (~2% of sales) is the only stretch safe for ultra-sparse polling if a 3rd tier is ever added.
-- ----------------------------------------------------------------------------
