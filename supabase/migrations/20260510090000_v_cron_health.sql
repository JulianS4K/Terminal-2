-- ============================================================================
-- Migration 20260510090000 — v_cron_health (last-24h cron health rollup)
--
-- Closes the last gap in the original DATA_QUALITY_DASHBOARD spec.
-- Section 3 ("Cron health (24h)") has been showing
-- "v_cron_health not yet available" since the dashboard launched —
-- the proto's fetchCronLive() reads this view and falls back to a
-- "not available" message when the table doesn't exist.
--
-- The view runs SECURITY DEFINER so anon can read aggregates without
-- needing direct grants on the cron schema (which Supabase doesn't
-- expose to anon by default).
--
-- Surfaces 4 real issues on first run that were previously invisible:
--   evo_orders_process_30min     75% (4/16 fails)  ON CONFLICT missing
--   sg_listings_process_5min     82% (18/100 fails) ON CONFLICT missing
--   sg_seller_process_30min      94% (1/16)         dedup race condition
--   zone-backfill-isolated-10min 99% (2/144)        match_performer_zone timeout
--
-- All four worth fixing in phase 2 but the dashboard will now show them
-- yellow/red automatically without anyone having to spot-query the
-- cron.job_run_details table.
-- ============================================================================

CREATE OR REPLACE VIEW v_cron_health
WITH (security_invoker = false) AS
SELECT
  j.jobname,
  count(d.runid)                                                    AS runs_24h,
  count(d.runid) FILTER (WHERE d.status = 'succeeded')              AS ok_24h,
  count(d.runid) FILTER (WHERE d.status = 'failed')                 AS fail_24h,
  CASE WHEN count(d.runid) > 0
    THEN round(100.0 * count(d.runid) FILTER (WHERE d.status = 'succeeded')
                     / count(d.runid), 1)
    ELSE NULL END                                                   AS pct_ok,
  max(d.start_time)                                                 AS latest_run,
  (SELECT d2.return_message
     FROM cron.job_run_details d2
    WHERE d2.jobid = j.jobid
      AND d2.status = 'failed'
      AND d2.start_time > now() - interval '24 hours'
    ORDER BY d2.start_time DESC
    LIMIT 1)                                                        AS latest_error
FROM cron.job j
LEFT JOIN cron.job_run_details d
  ON d.jobid = j.jobid
 AND d.start_time > now() - interval '24 hours'
WHERE j.active = true
GROUP BY j.jobid, j.jobname;

GRANT SELECT ON v_cron_health TO anon;

COMMENT ON VIEW v_cron_health IS
  'Last-24h health rollup per active cron job. SECURITY DEFINER so anon '
  'can read aggregates without needing direct grants on the cron schema. '
  'Dashboard fetchCronLive() consumes this. Failing jobs sort to the top '
  'in the UI by lowest pct_ok.';
