-- Migration 20261121060000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_enqueue_trg,n2s_autobuy_job_json,n2s_autobuy_config · reads:n2s_autobuy_exec · pre:20261117013000
--
-- One $5,000 cap per calendar month (ET) for EVO and GoTickets buys together; a new month
-- lifts the stop it made. Per-order and daily caps stay separate per market.
--
-- Operator 2026-11-21, after the first live EVO buy (exec 10, EVO 19464447, $146.52): "change to
-- $1000 spend max daily for Evo", then, asked about the lifetime cap: "5000 a month" and
-- "1000 or less per order, auto resets monthly, no buy limit just total limit"; "retain
-- gotickets buy limit for now". Later the same day: "Add go tickets to the $5000 month limiter
-- but separate daily and per order limiters now". The config values were set that day
-- (05:41 UTC): per_order_cap_usd 1000, daily_cap_usd 1000, project_cap_usd 5000,
-- live_runs_allowed and max_buys_per_day 1000000 (no limit); then (06:10 UTC, "Change go
-- tickets per order and day amounts to 1000$") gt_per_order_cap_usd and gt_daily_cap_usd 1000.
-- GoTickets keeps those two caps of its own and its one live run (still in testing). Until this
-- migration each market had a lifetime project cap of its own (EVO $5000, GoTickets $666).
--
-- 1. n2s_autobuy_enqueue_trg() (md5-guarded anchor patch on the prod text, three anchors):
--    a. the project cap for both markets is project_cap_usd (gt_project_cap_usd is no longer read);
--    b. project spend (v_proj, also stored as the exec row's project_spent_before, which the live
--       worker re-checks) is every committed EVO and GoTickets buy created this calendar month in
--       America/New_York, whichever market the new cover is on;
--    c. a stop the cap set in an earlier ET month is cleared by the first would-buy of a new month:
--       project_stopped (with stop_emailed_at, as n2s_autobuy_resume() does) when its reason is one
--       of the EVO cap texts, gt_project_stopped when its reason is one of the GoTickets cap texts.
--       Any other stop stays until the operator clears it. kill_switch is never touched.
--    Each market still sets only its own stop flag; the other market's next would-buy sees the same
--    combined spend and is blocked over_project_cap (and stops) in turn.
-- 2. n2s_autobuy_job_json() (md5-guarded, one anchor): the worker's project_cap_usd is
--    project_cap_usd for both markets, matching the trigger.
-- The stop reason texts are unchanged; "project spend" in them is now this month's combined spend.
--
-- VERIFY: SELECT md5(pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure)),
--                md5(pg_get_functiondef('public.n2s_autobuy_job_json(bigint, text)'::regprocedure));
--         -- = the new md5s in the PR body
--         SELECT project_cap_usd, project_stopped, gt_project_stopped FROM n2s_autobuy_config;
--         SELECT exec_id, sub_source, created_at, project_spent_before FROM n2s_autobuy_exec
--          WHERE mode = 'live' ORDER BY exec_id DESC LIMIT 5;  -- the next row shows this month's combined spend
-- ROLLBACK: re-apply n2s_autobuy_enqueue_trg() and n2s_autobuy_job_json() as 20261117013000 left
--           them (md5 83d1d69b24bd3c5e6188383f79751c45 and 5376a0f8ca2751037518061a884a7425).

BEGIN;
SET LOCAL lock_timeout = '10s';

DO $do$
DECLARE d text; n int;
  v_cap_old  text := $r$  v_cap_proj := CASE WHEN v_gt THEN c.gt_project_cap_usd ELSE c.project_cap_usd END;$r$;
  v_cap_new  text := $r$  -- 20261121060000: one monthly cap for EVO and GoTickets together (operator 2026-11-21)
  v_cap_proj := c.project_cap_usd;$r$;
  v_proj_old text := $r$  -- Project spend: every buy ever committed in this mode from this sub source, any market.
  SELECT COALESCE(sum(sub_total_usd + COALESCE(est_tax_usd, 0)), 0) INTO v_proj
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND sub_source = NEW.sub_source
     AND state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL);$r$;
  v_proj_new text := $r$  -- Project spend: every buy committed in this mode, any market.
  -- 20261121060000: EVO and GoTickets subs together, created this calendar month (ET): the
  -- operator's "5000 a month", "auto resets monthly", "add go tickets to the $5000 month limiter".
  SELECT COALESCE(sum(sub_total_usd + COALESCE(est_tax_usd, 0)), 0) INTO v_proj
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND sub_source IN ('tevo', 'gotickets')
     AND state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL)
     AND (created_at AT TIME ZONE 'America/New_York')::date >= date_trunc('month', v_tz_today::timestamp)::date;$r$;
  v_stop_old text := $r$  v_stopped  := CASE WHEN v_gt THEN c.gt_project_stopped ELSE c.project_stopped END;$r$;
  v_stop_new text := $r$  -- 20261121060000: a stop the monthly cap made in an earlier ET month is lifted by the first
  -- would-buy of a new month, for EVO and for GoTickets. Any other stop stays until the operator clears it.
  IF c.project_stopped AND c.project_stopped_at IS NOT NULL
     AND (c.project_stopped_at AT TIME ZONE 'America/New_York')::date < date_trunc('month', v_tz_today::timestamp)::date
     AND (c.project_stopped_reason LIKE 'Project spend reached $% of the $% cap (dryrun %)'
          OR c.project_stopped_reason LIKE 'dryrun %: $% would take project spend from $% past the $% cap') THEN
    UPDATE public.n2s_autobuy_config
       SET project_stopped = false, project_stopped_at = NULL, project_stopped_reason = NULL,
           stop_emailed_at = NULL, updated_at = now()
     WHERE id;
    c.project_stopped := false;
  END IF;
  IF c.gt_project_stopped AND c.gt_project_stopped_at IS NOT NULL
     AND (c.gt_project_stopped_at AT TIME ZONE 'America/New_York')::date < date_trunc('month', v_tz_today::timestamp)::date
     AND (c.gt_project_stopped_reason LIKE 'GoTickets project spend reached $% of the $% cap (dryrun %)'
          OR c.gt_project_stopped_reason LIKE 'dryrun %: $% would take GoTickets project spend from $% past the $% cap') THEN
    UPDATE public.n2s_autobuy_config
       SET gt_project_stopped = false, gt_project_stopped_at = NULL, gt_project_stopped_reason = NULL,
           updated_at = now()
     WHERE id;
    c.gt_project_stopped := false;
  END IF;
  v_stopped  := CASE WHEN v_gt THEN c.gt_project_stopped ELSE c.project_stopped END;$r$;
  v_job_old  text := $r$      'project_cap_usd', CASE WHEN v_gt THEN c.gt_project_cap_usd ELSE c.project_cap_usd END,$r$;
  v_job_new  text := $r$      -- 20261121060000: one monthly cap for EVO and GoTickets together
      'project_cap_usd', c.project_cap_usd,$r$;
BEGIN
  -- the enqueue trigger
  d := pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure);
  IF md5(d) <> '83d1d69b24bd3c5e6188383f79751c45' THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg drifted from 20261117013000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, v_cap_old, ''))) / length(v_cap_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg: % project-cap anchors (want 1) — re-derive this migration', n;
  END IF;
  n := (length(d) - length(replace(d, v_proj_old, ''))) / length(v_proj_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg: % project-spend anchors (want 1) — re-derive this migration', n;
  END IF;
  n := (length(d) - length(replace(d, v_stop_old, ''))) / length(v_stop_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg: % stop-flag anchors (want 1) — re-derive this migration', n;
  END IF;
  EXECUTE replace(replace(replace(d, v_cap_old, v_cap_new), v_proj_old, v_proj_new), v_stop_old, v_stop_new);

  -- the job the live worker and the one queue get
  d := pg_get_functiondef('public.n2s_autobuy_job_json(bigint, text)'::regprocedure);
  IF md5(d) <> '5376a0f8ca2751037518061a884a7425' THEN
    RAISE EXCEPTION 'n2s_autobuy_job_json drifted from 20261117013000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, v_job_old, ''))) / length(v_job_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_job_json: % project-cap anchors (want 1) — re-derive this migration', n;
  END IF;
  EXECUTE replace(d, v_job_old, v_job_new);
END $do$;

COMMENT ON COLUMN public.n2s_autobuy_config.project_cap_usd IS
  'Spend cap per calendar month (America/New_York) for EVO and GoTickets buys together; a stop it made is lifted by the first would-buy of the next month. Operator 2026-11-21: $5000 a month, GoTickets included. 20261121060000.';
COMMENT ON COLUMN public.n2s_autobuy_config.gt_project_cap_usd IS
  'Not read since 20261121060000: GoTickets buys count against the shared monthly project_cap_usd.';

COMMIT;
