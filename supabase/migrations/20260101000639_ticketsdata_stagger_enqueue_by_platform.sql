-- 20260527170000_ticketsdata_stagger_enqueue_by_platform.sql
--
-- Reschedule per-platform enqueue crons so platforms are staggered 15 min apart
-- within each 3-hour peak slot. Previously SH (:00) and VD (:45) fired too close
-- together, piling 74 requests into the drain queue simultaneously.
--
-- NEW SCHEDULE (all within pull_drain window 16-04 UTC):
--   SH: '0 16,19,22,1 * * *'   — noon/3pm/6pm/9pm ET exactly
--   GT: '15 16,19,22,1 * * *'  — 12:15/3:15/6:15/9:15pm ET  (phase 2 stub)
--   VD: '30 16,19,22,1 * * *'  — 12:30/3:30/6:30/9:30pm ET
--
-- STAGGER BENEFIT:
--   SH's 37 requests take ~7-8 min to drain (5/min × 37 = ~7 min + normalize lag).
--   15-min gap before VD fires means SH batch is fully resolved before VD rows land.
--   No mixed-platform interleaving in the drain queue. Each source gets a clean window.
--
-- BUDGET: unchanged — 37 events × 2 platforms × 4 fires = 296 credits/day ≤ 300.

DO $sched$ BEGIN

  -- SH: noon / 3pm / 6pm / 9pm ET  (16/19/22/01 UTC)
  PERFORM cron.schedule(
    'td_enqueue_peak_sh',
    '0 16,19,22,1 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('SH',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 16 THEN 'noon_ET'  WHEN 19 THEN '3pm_ET'
          WHEN 22 THEN '6pm_ET'   WHEN  1 THEN '9pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  -- GT: 12:15pm / 3:15pm / 6:15pm / 9:15pm ET  — phase 2 stub (active=false rows, no-ops cleanly)
  PERFORM cron.schedule(
    'td_enqueue_peak_gt',
    '15 16,19,22,1 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('GT',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 16 THEN 'noon_ET'  WHEN 19 THEN '3pm_ET'
          WHEN 22 THEN '6pm_ET'   WHEN  1 THEN '9pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  -- VD: 12:30pm / 3:30pm / 6:30pm / 9:30pm ET  (30 min after SH)
  PERFORM cron.schedule(
    'td_enqueue_peak_vd',
    '30 16,19,22,1 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('VD',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 16 THEN 'noon_ET'  WHEN 19 THEN '3pm_ET'
          WHEN 22 THEN '6pm_ET'   WHEN  1 THEN '9pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

END $sched$;

-- Update cron_policy to reflect new schedules and stagger notes
UPDATE public.cron_policy SET
  notes      = 'TD enqueue SH — noon/3pm/6pm/9pm ET (0 16,19,22,1 UTC). '
                'SH fires first; VD fires 30 min later so each platform drains cleanly. '
                '37 events/fire × 4 fires = 148 SH credits/day.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_sh';

UPDATE public.cron_policy SET
  notes      = 'TD enqueue VD — 12:30pm/3:30pm/6:30pm/9:30pm ET (30 16,19,22,1 UTC). '
                '30 min after SH so VD drain queue is separate from SH drain queue. '
                '37 events/fire × 4 fires = 148 VD credits/day.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_vd';

UPDATE public.cron_policy SET
  notes      = 'TD enqueue GT — 12:15pm/3:15pm/6:15pm/9:15pm ET (15 16,19,22,1 UTC). '
                'Phase 2 stub — no-ops until td_gt_discover_drain populates active xref rows. '
                '37 events/fire × 4 fires = 148 GT credits/day when active.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_gt';
