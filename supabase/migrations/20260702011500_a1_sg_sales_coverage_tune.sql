-- ============================================================================
-- Migration 20260702011500 — SG sales coverage tune (classifier back on + 5/tick)
--
-- Lane:     A1
-- Touches:  cron sg_classify_events_5min (active=true); cron sg_sales_poll_5min (p_max 4->5).
-- Pre-reqs: 20260702004500 (sales path re-lit).
--
-- WHY (operator 2026-07-02 "are we getting all sg sales for all evo events polled?" — audit):
--   Sales universe = sg_event_priority_state non-SKIP <=180d at 24h/event (+ post-event flush).
--   Audit found: EVO polls 6,308 future events; only 2,118 are SG-mapped at all (the hard ceiling
--   — SG has no search API; mapping grows via the matchers); 1,622 are sales-eligible now and
--   1,135 in-horizon are tier=SKIP by classification.
--   Fix 1: sg_classify_events_5min RE-ENABLED — it maintains the tier (incl. SKIP) that gates the
--   sales poller; it was paused this session under the frozen-corpus assumption, which stopped
--   being true the moment sales were re-lit. Without it, new events never get classified.
--   Fix 2: p_max 4->5 per tick. Capacity was 4 x 15 ticks/hr x 24 = 1,440/day < 1,622 eligible at
--   24h cadence (slow starvation of the far tail). 5/tick = 1,800/day (~11% headroom); 5-per-burst
--   matches the historical SG tick sizing against the shared ~10-req/8s token window.
--
-- Idempotent: alter_job by name. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

DO $do$
BEGIN
  PERFORM cron.alter_job((SELECT jobid FROM cron.job WHERE jobname='sg_classify_events_5min'), active:=true);
  PERFORM cron.alter_job(
    (SELECT jobid FROM cron.job WHERE jobname='sg_sales_poll_5min'),
    command := $cmd$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_sales_poll_5min') THEN RETURN; END IF; PERFORM public.sg_sales_poll_tick(5, 180); END $b$;$cmd$);
END $do$;
