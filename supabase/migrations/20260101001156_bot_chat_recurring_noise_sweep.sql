-- ============================================================================
-- Migration 20260702140200 — recurring bot_chat auto-noise sweep + one-time backlog clear
--
-- Lane:     A1 (cron topology) · operator-authorized (2026-07-02)
-- Touches:  public.sweep_bot_chat_auto_noise() (new fn), cron.job (new job),
--           public.cron_policy (new row), public.bot_chat (one-time UPDATE).
-- Reads:    cron.job, public.bot_chat.
--
-- WHY:
--   The unresolved bot_chat monitor (v_bot_chat_unresolved) had re-accumulated
--   ~1,850 rows, ~1,666 of them auto-`status` noise, because the auto-resolve is
--   only a VIEW predicate + a ONE-TIME sweep (mig 20260608032000) — nothing
--   RECURRING maintains it. The daily job named `sweep-bot-messages` (jobid 195)
--   cleans an unrelated 16-row `bot_messages` table, not `bot_chat` at all.
--
--   This ships an actual recurring sweep:
--     * sweep_bot_chat_auto_noise() resolves ONLY auto-noise:
--         - status              older than 24h
--         - change_log/broadcast older than 48h
--         - SG_BROKER_429 flags older than 24h (auto-generated; poster paused in
--           20260702140030, established noise class per mig 20260608032000)
--       It NEVER resolves real flag/question/collision/p0_security — those need
--       their owners (docs/bot_chat_conventions.md "Sweep protocol").
--     * cron job `sweep-bot-chat-noise-daily` (03:43 UTC, cron_should_fire-gated,
--       cron_policy row present so both control planes agree — audit AUD-15).
--       min_interval 720 < daily cadence avoids the AUD-22 epsilon-skip.
--     * one-time bulk clear of the CURRENT backlog (same proven predicate as
--       20260608032000): resolves all status + SG_BROKER_429 + stale
--       change_log/sync/broadcast, so the ~163 genuinely-aged flag/question items
--       (which bot_chat_aging_7d, mig 20260702140100, now surfaces) stop being
--       buried.
--
-- ## Already applied to prod
-- Applied via mcp apply_migration on 2026-07-02 under the operator directive.
-- Idempotent: CREATE OR REPLACE fn; DELETE+INSERT policy row; unschedule-then-
-- schedule cron; the one-time UPDATE re-runs as a near-no-op (only newly-arrived
-- noise, of which there is none once the posters are paused).
-- ============================================================================

-- 1) Recurring sweep function (SECURITY INVOKER; runs as the postgres cron owner).
CREATE OR REPLACE FUNCTION public.sweep_bot_chat_auto_noise()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  UPDATE public.bot_chat
     SET resolved_at = now(),
         resolved_by = 'cron/sweep-bot-chat-noise',
         meta = COALESCE(meta,'{}'::jsonb)
                || jsonb_build_object('resolve_note','recurring auto-noise sweep (sweep_bot_chat_auto_noise)')
   WHERE resolved_at IS NULL
     AND (
           (event_type = 'status'                    AND created_at < now() - interval '24 hours')
        OR (event_type IN ('change_log','broadcast') AND created_at < now() - interval '48 hours')
        OR (event_type = 'flag' AND message LIKE 'SG_BROKER_429%' AND created_at < now() - interval '24 hours')
     );
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

-- 2) cron_policy row (DELETE+INSERT = idempotent without relying on a unique constraint).
DELETE FROM public.cron_policy WHERE jobname = 'sweep-bot-chat-noise-daily';
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES
  ('sweep-bot-chat-noise-daily', ARRAY[]::int[], 720, 720,
   NULL, 1, true,
   'Daily bot_chat auto-noise sweep: resolves status>24h, change_log/broadcast>48h, SG_BROKER_429 flags>24h. Never touches real flag/question/collision/p0_security.',
   now());

-- 3) Schedule the cron (unschedule-then-schedule for idempotency).
DO $sched$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'sweep-bot-chat-noise-daily') THEN
    PERFORM cron.unschedule('sweep-bot-chat-noise-daily');
  END IF;
END $sched$;

SELECT cron.schedule(
  'sweep-bot-chat-noise-daily',
  '43 3 * * *',
  $cron$DO $body$ BEGIN IF NOT public.cron_should_fire('sweep-bot-chat-noise-daily') THEN RETURN; END IF; PERFORM public.sweep_bot_chat_auto_noise(); END $body$;$cron$
);

-- 4) One-time bulk clear of the accumulated backlog (proven predicate from 20260608032000).
UPDATE public.bot_chat
   SET resolved_at = now(),
       resolved_by = 'admin/A1',
       meta = COALESCE(meta,'{}'::jsonb)
              || jsonb_build_object('resolve_note','bulk auto-noise sweep mig 20260702140200')
 WHERE resolved_at IS NULL
   AND (
         event_type = 'status'
      OR message LIKE 'SG_BROKER_429%'
      OR (event_type IN ('change_log','sync','broadcast') AND created_at < now() - interval '3 days')
   );
