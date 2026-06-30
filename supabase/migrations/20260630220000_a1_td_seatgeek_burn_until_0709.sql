-- ============================================================================
-- Migration 20260630220000 — TEMPORARY: TD-SeatGeek surplus-burn until 7/9 (auto-reverts)
--
-- Lane:     A1
-- Touches:  integration_policy (W, kill-switch flag), ticketsdata_event_xref + td_pull_queue
--           (ALTER platform CHECK to allow 'SG'; seed SG rows), cron jobs 'td_enqueue_peak_sg' (NEW)
--           + 'td_sg_burn_teardown' (NEW, self-destructing).
-- Pre-reqs: td_api_platform/td_seatgeek_allowed kill-switch (20260606120000); td_enqueue_peak;
--           aq_event_map (sg_event_id); cron_should_fire (returns true for unknown jobname).
--
-- WHY (operator directive 2026-06-30): the billing cycle (Jun 9→Jul 9) has ~224k of REAL quota expiring
-- unused at the 7/9 reset (only 26,349/250,000 used) and the SG broker token is 429-throttled (#1
-- bottleneck). So temporarily override the deliberate TD-SeatGeek kill-switch, enroll all ~1,956 mapped
-- upcoming events on platform 'SG', and poll SG listings via TD through 7/9 to burn the otherwise-wasted
-- surplus + relieve the token. AUTO-REVERTS: the enqueue cron is date-gated (< 7/9), and a self-destructing
-- teardown cron re-arms the kill-switch, deactivates the SG xref rows, and unschedules both crons on/after
-- 7/9 — at which point the 8k/day cap (mig 20260630210000) takes over. SG URL templated from sg_event_id
-- (same format as the axs-sg-url-anchor-backfill cron). The 'SG' CHECK widening is left in place after
-- teardown (harmless; no active SG rows remain).
--
-- Idempotent: UPDATE/guarded-INSERT for the flag, DROP IF EXISTS + ADD for the CHECKs, ON CONFLICT DO
-- NOTHING for the seed, cron.schedule upsert-by-name. Re-apply is a no-op.
-- ============================================================================

-- 1. Override the SG kill-switch (re-armed by td_sg_burn_teardown on/after 7/9).
UPDATE public.integration_policy
   SET enabled = true, updated_by = 'a1', updated_at = now(),
       reason = 'surplus-burn until 2026-07-09 (operator 2026-06-30); auto-reverts via td_sg_burn_teardown'
 WHERE key = 'td_seatgeek_emergency_override';
INSERT INTO public.integration_policy (key, enabled, reason, updated_by, updated_at)
SELECT 'td_seatgeek_emergency_override', true,
       'surplus-burn until 2026-07-09 (operator 2026-06-30); auto-reverts via td_sg_burn_teardown', 'a1', now()
WHERE NOT EXISTS (SELECT 1 FROM public.integration_policy WHERE key='td_seatgeek_emergency_override');

-- 2. Allow platform 'SG' on the xref + queue.
ALTER TABLE public.ticketsdata_event_xref DROP CONSTRAINT IF EXISTS ticketsdata_event_xref_platform_check;
ALTER TABLE public.ticketsdata_event_xref ADD  CONSTRAINT ticketsdata_event_xref_platform_check
  CHECK (platform IN ('SH','VD','GT','TM','TP','SG'));
ALTER TABLE public.td_pull_queue DROP CONSTRAINT IF EXISTS td_pull_queue_platform_check;
ALTER TABLE public.td_pull_queue ADD  CONSTRAINT td_pull_queue_platform_check
  CHECK (platform IN ('SH','VD','GT','TM','TP','SG'));

-- 3. Seed SG xref for all mapped upcoming events (owned-first; URL templated from sg_event_id).
INSERT INTO public.ticketsdata_event_xref
  (event_id, platform, aq_short_event_id, event_url, owned_tickets, active, match_method, meta)
SELECT DISTINCT ON (a.sg_event_id)
       a.sg_event_id, 'SG', a.aq_short_event_id,
       'http://www.seatgeek.com/e/events/' || a.sg_event_id,
       coalesce(m.owned_tickets_count, 0), true, 'seed',
       jsonb_build_object('seed','sg_burn','seeded_at', now())
FROM public.aq_event_map a
LEFT JOIN LATERAL (SELECT owned_tickets_count FROM public.event_metrics em
                   WHERE em.event_id = a.tevo_event_id ORDER BY captured_at DESC LIMIT 1) m ON true
WHERE a.tevo_event_id IS NOT NULL AND a.event_date >= now() AND a.sg_event_id IS NOT NULL
ORDER BY a.sg_event_id, coalesce(m.owned_tickets_count, 0) DESC
ON CONFLICT (event_id, platform) DO NOTHING;

-- 4. SG enqueue cron — fires through 7/9 only (date-gated), staggered at :05 off the even leapfrog.
SELECT cron.schedule('td_enqueue_peak_sg', '5-59/10 * * * *',
$cmd$do $b$ begin
  if now() < timestamptz '2026-07-09' then
    perform public.td_enqueue_peak('SG','sg_burn');
  end if;
end $b$;$cmd$);

-- 5. Self-destructing teardown — on/after 7/9: re-arm kill-switch, deactivate SG xref, unschedule both.
SELECT cron.schedule('td_sg_burn_teardown', '20 12 * * *',
$cmd$do $b$ begin
  if now() >= timestamptz '2026-07-09' then
    update public.integration_policy
       set enabled=false, updated_by='td_sg_burn_teardown', updated_at=now()
     where key='td_seatgeek_emergency_override';
    update public.ticketsdata_event_xref
       set active=false, updated_at=now()
     where platform='SG' and meta->>'seed'='sg_burn';
    perform cron.unschedule('td_enqueue_peak_sg');
    perform cron.unschedule('td_sg_burn_teardown');
  end if;
end $b$;$cmd$);
