-- 20260527180000_ticketsdata_hourly_coverage_stagger.sql
--
-- Spread platforms across consecutive hours for hourly coverage noon–11pm ET.
-- Previously all 3 platforms fired within the same hour (SH:00, GT:15, VD:30).
-- Now each gets its own hour, 3 hours between same-platform fires.
--
-- NEW SCHEDULE:
--   SH: '0 16,19,22,1 * * *'   noon/3pm/6pm/9pm   ET  (UTC 16/19/22/01)
--   GT: '0 17,20,23,2 * * *'   1pm/4pm/7pm/10pm   ET  (UTC 17/20/23/02)
--   VD: '0 18,21,0,3 * * *'    2pm/5pm/8pm/11pm   ET  (UTC 18/21/00/03)
--
-- RESULT: one platform pull every hour on the hour, noon–11pm ET.
-- BUDGET: SH+VD only = 37×2×4 = 296/day ≤ 300 cap.
--         When GT activates: 37×3×4 = 444/day → raise daily cap or reduce LIMIT.

DO $sched$ BEGIN

  PERFORM cron.schedule(
    'td_enqueue_peak_sh',
    '0 16,19,22,1 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('SH',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 16 THEN 'noon_ET' WHEN 19 THEN '3pm_ET'
          WHEN 22 THEN '6pm_ET'  WHEN  1 THEN '9pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  PERFORM cron.schedule(
    'td_enqueue_peak_gt',
    '0 17,20,23,2 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('GT',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 17 THEN '1pm_ET'  WHEN 20 THEN '4pm_ET'
          WHEN 23 THEN '7pm_ET'  WHEN  2 THEN '10pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  PERFORM cron.schedule(
    'td_enqueue_peak_vd',
    '0 18,21,0,3 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('VD',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 18 THEN '2pm_ET'  WHEN 21 THEN '5pm_ET'
          WHEN  0 THEN '8pm_ET'  WHEN  3 THEN '11pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

END $sched$;

UPDATE public.cron_policy SET
  notes      = 'TD enqueue SH — noon/3pm/6pm/9pm ET (0 16,19,22,1 UTC). '
                'One platform/hour hourly coverage: SH:00, GT:+1h, VD:+2h. '
                '37 events/fire × 4 fires = 148 SH credits/day.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_sh';

UPDATE public.cron_policy SET
  notes      = 'TD enqueue GT — 1pm/4pm/7pm/10pm ET (0 17,20,23,2 UTC). '
                'Hourly offset +1h from SH. Phase 2 stub — no-ops until GT xref rows active. '
                '37 events/fire × 4 fires = 148 GT credits/day when active.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_gt';

UPDATE public.cron_policy SET
  notes      = 'TD enqueue VD — 2pm/5pm/8pm/11pm ET (0 18,21,0,3 UTC). '
                'Hourly offset +2h from SH. Each platform drains fully before next fires. '
                '37 events/fire × 4 fires = 148 VD credits/day.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_vd';
