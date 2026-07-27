-- ============================================================================
-- Migration 20260630230000 — Phase-A TD cadence boost (use the 300k headroom until 7/9)
--
-- Lane:     A1
-- Touches:  collector_band(text,text,numeric) + collector_band(text,text,numeric,boolean) (CREATE OR REPLACE).
-- Pre-reqs: 20260630170000 (is_peak refactor of collector_band); collector_cadence.
--
-- WHY (operator directive 2026-06-30): "run the 300k headroom now, then on 7/9 run the ~5,700/day."
-- The standard ladder bills ~5,700 real/day for owned+AXS, leaving most of the 300k-plan allowance
-- (~9.7k/day) unused this cycle — and unused quota expires at the 7/9 reset. So tighten the TD cadence to
-- ~1.67x (interval x0.6) through 7/9 to lift demand toward the 300k pace (~9.5-10k/day real, well under the
-- 40k/day phase-A gate), then auto-revert to the standard ladder (~5,700/day, under the 8k cap) on 7/9.
--
-- TD-ONLY + date-gated: the x0.6 factor applies only when p_source='TD' AND now() < 2026-07-09, so EVO
-- (free firehose) and the SG broker token (429-throttled — must NOT be polled harder) are untouched, and
-- the boost self-reverts at the cycle reset with no manual edit. enqueues_today<=4/day still caps near-term;
-- far-out bands (where the volume gain is) tighten from ~0.35/day toward ~0.59/day per source.
--
-- Idempotent (CREATE OR REPLACE) -> apply-before-PR; re-apply is a no-op. is_peak() logic preserved verbatim.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.collector_band(p_source text, p_scope text, p_hours numeric)
 RETURNS TABLE(band text, required_min integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT c.band,
         ((CASE WHEN public.is_peak() THEN c.peak_interval_min ELSE c.offpeak_interval_min END)
          * CASE WHEN p_source='TD' AND now() < timestamptz '2026-07-09' THEN 0.6 ELSE 1.0 END)::int
  FROM public.collector_cadence c
  WHERE c.source=p_source AND c.scope=p_scope AND c.enabled
    AND p_hours >= c.min_hours AND (c.max_hours IS NULL OR p_hours < c.max_hours)
  ORDER BY c.sort_order LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.collector_band(p_source text, p_scope text, p_hours numeric, p_owned boolean)
 RETURNS TABLE(band text, required_min integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT c.band,
         ((CASE WHEN public.is_peak() THEN c.peak_interval_min ELSE c.offpeak_interval_min END)
          * CASE WHEN p_source='TD' AND now() < timestamptz '2026-07-09' THEN 0.6 ELSE 1.0 END)::int
  FROM public.collector_cadence c
  WHERE c.source=p_source AND c.scope=p_scope AND c.enabled
    AND p_hours >= c.min_hours AND (c.max_hours IS NULL OR p_hours < c.max_hours)
    AND c.owned_kind IN (CASE WHEN p_owned THEN 'owned' ELSE 'non' END, 'any')
  ORDER BY (c.owned_kind <> 'any') DESC, c.sort_order LIMIT 1;
$function$;
