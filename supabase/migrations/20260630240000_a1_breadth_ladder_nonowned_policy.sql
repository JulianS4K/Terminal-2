-- ============================================================================
-- Migration 20260630240000 — Breadth ladder + non-owned policy + enqueue consolidation
--
-- Lane:     A1
-- Touches:  td_should_poll (NEW), td_enqueue_peak (CREATE OR REPLACE — breadth + non-owned cap +
--           date-robust source), cron: disable td_tier_enqueue_{sh,vd,gt,tm,axs}, re-enable
--           td_enqueue_peak_tp.
-- Pre-reqs: collector_band (is_peak + phase-A boost), ticketsdata_event_xref, aq_event_map, events,
--           sg_events_canonical.
--
-- WHY (operator 2026-06-30 "do it + turn on crons"): encode the agreed sourcing policy in the live
-- enqueue path and consolidate the two duplicate enqueue systems onto it.
--   BREADTH LADDER (td_should_poll): SH all bands · VD all bands (owned) · GT ≤30d · TP ≤3d ·
--     TM/SG pass-through. NON-OWNED policy: VD only ≤30d (SH-only beyond 30d) and a 1-poll/day-max cap
--     (interval floored to 1440 min) for every non-owned secondary fetch — SG exempt (temporary burn).
--   CONSOLIDATION: td_tier_enqueue_* read the SAME ticketsdata_event_xref as td_enqueue_peak, so they
--     are redundant; disable them and drive everything through td_enqueue_peak. BUT td_enqueue_peak used
--     to INNER JOIN sg_events_canonical for the date (dropping ~421 SH-mapped-but-no-SG events the tier
--     path covered) — so this makes its date source robust (COALESCE sgc → events.occurs_at_local →
--     aq.event_date) FIRST, then the tier crons are safe to retire.
--   TP re-enabled (was fully off) but scoped to ≤3d by td_should_poll.
--
-- Net effect REDUCES polling (breadth caps + non-owned 1/day + de-dup) — safe for budget; coverage is
-- preserved because td_enqueue_peak now covers the full active xref.
--
-- Idempotent (CREATE OR REPLACE + cron alter by name). Re-apply is a no-op.
-- ============================================================================

-- 1. Breadth ladder + non-owned SH-only-beyond-30d, as a pure policy function.
CREATE OR REPLACE FUNCTION public.td_should_poll(p_platform text, p_hours numeric, p_owned boolean)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_platform
    WHEN 'SH' THEN true                              -- StubHub: all bands, owned + non-owned
    WHEN 'VD' THEN (p_owned OR p_hours < 720)        -- Vivid: owned all; non-owned only ≤30d (SH-only >30d)
    WHEN 'GT' THEN (p_hours < 720)                   -- GameTime: ≤30d
    WHEN 'TP' THEN (p_hours < 72)                    -- TickPick: ≤3d only
    WHEN 'TM' THEN true                              -- Ticketmaster track (MSG-scoping is a separate step)
    WHEN 'SG' THEN true                              -- SeatGeek temporary burn (own scope/teardown)
    ELSE false
  END;
$function$;

-- 2. td_enqueue_peak: date-robust source + breadth filter + non-owned 1/day cap. Owned-first ORDER kept.
CREATE OR REPLACE FUNCTION public.td_enqueue_peak(p_platform text DEFAULT NULL::text, p_interval_tag text DEFAULT 'manual'::text)
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
    LEFT JOIN public.aq_event_map a   ON a.aq_short_event_id = x.aq_short_event_id
    LEFT JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = a.sg_event_id
    LEFT JOIN public.events e         ON e.id = a.tevo_event_id
    CROSS JOIN LATERAL (SELECT COALESCE(
        sgc.sg_datetime_utc,
        CASE WHEN e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}' THEN e.occurs_at_local::timestamptz END,
        a.event_date::timestamptz
      ) AS event_dt) dt
    CROSS JOIN LATERAL public.collector_band('TD','listings',
                 greatest(EXTRACT(epoch FROM (dt.event_dt - v_now))/3600.0, 0)) c
    WHERE x.active = true
      AND x.event_url IS NOT NULL
      AND dt.event_dt IS NOT NULL
      AND dt.event_dt > v_now - interval '6 hours'
      AND (p_platform IS NULL OR x.platform = p_platform)
      AND public.td_should_poll(x.platform,
            EXTRACT(epoch FROM (dt.event_dt - v_now))/3600.0,
            (coalesce(x.owned_tickets,0) > 0))
      AND ( x.last_enqueued_at IS NULL
            OR x.last_enqueued_at < v_now - make_interval(mins =>
                 CASE WHEN coalesce(x.owned_tickets,0) > 0 OR x.platform = 'SG'
                      THEN c.required_min                       -- owned / SG burn: full ladder cadence
                      ELSE greatest(c.required_min, 1440) END)) -- non-owned: 1 poll/day max
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

-- 3. Consolidate: retire the duplicate tier enqueues; re-enable TP (scoped to ≤3d by td_should_poll).
DO $do$
DECLARE j bigint;
BEGIN
  FOR j IN SELECT jobid FROM cron.job
           WHERE jobname IN ('td_tier_enqueue_sh','td_tier_enqueue_vd','td_tier_enqueue_gt',
                             'td_tier_enqueue_tm','td_tier_enqueue_axs','td_tier_enqueue_tp')
  LOOP PERFORM cron.alter_job(j, active := false); END LOOP;

  PERFORM cron.alter_job(jobid, active := true) FROM cron.job WHERE jobname = 'td_enqueue_peak_tp';
END $do$;
