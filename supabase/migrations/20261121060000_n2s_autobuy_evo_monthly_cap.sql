-- Migration 20261121060000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_enqueue_trg,n2s_autobuy_config · reads:n2s_autobuy_exec · pre:20261117013000
--
-- The EVO project cap counts one calendar month (ET), and a new month lifts the stop it made.
--
-- Operator 2026-11-21, after the first live EVO buy (exec 10, EVO 19464447, $146.52): "change to
-- $1000 spend max daily for Evo", then, asked about the lifetime cap: "5000 a month" and
-- "1000 or less per order, auto resets monthly, no buy limit just total limit"; "retain
-- gotickets buy limit for now". The config values were set the same day (05:41 UTC):
-- per_order_cap_usd 1000, daily_cap_usd 1000, project_cap_usd 5000, live_runs_allowed and
-- max_buys_per_day 1000000 (no limit). Until this migration the $5000 counted every EVO buy
-- ever made; this makes it per month.
--
-- n2s_autobuy_enqueue_trg() (md5-guarded anchor patch on the prod text, two anchors):
--   1. EVO project spend (v_proj, also stored as the exec row's project_spent_before, which the
--      live worker re-checks) counts only buys created this calendar month in America/New_York.
--      GoTickets subs keep their lifetime gt_project_cap_usd, unchanged.
--   2. A project_stopped that the EVO project cap set (its two reason texts) in an earlier ET
--      month is cleared by the first would-buy of a new month, with stop_emailed_at, as
--      n2s_autobuy_resume() does. Any other stop (an operator's, a reason in another wording)
--      stays until the operator clears it. kill_switch is never touched.
-- Nothing else changes: per-order, daily, failure and event-lead guards are as they were.
--
-- VERIFY: SELECT md5(pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure));
--         -- = the new md5 in the PR body
--         SELECT project_cap_usd, project_stopped, project_stopped_reason FROM n2s_autobuy_config;
--         SELECT exec_id, sub_source, created_at, project_spent_before FROM n2s_autobuy_exec
--          WHERE mode = 'live' ORDER BY exec_id DESC LIMIT 5;  -- the next EVO row shows this month's spend
-- ROLLBACK: re-apply n2s_autobuy_enqueue_trg() as 20261117013000 left it (md5
--           83d1d69b24bd3c5e6188383f79751c45): remove the month filter and the reset block.

BEGIN;
SET LOCAL lock_timeout = '10s';

DO $do$
DECLARE d text; n int;
  v_proj_old text := $r$  -- Project spend: every buy ever committed in this mode from this sub source, any market.
  SELECT COALESCE(sum(sub_total_usd + COALESCE(est_tax_usd, 0)), 0) INTO v_proj
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND sub_source = NEW.sub_source
     AND state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL);$r$;
  v_proj_new text := $r$  -- Project spend: every buy committed in this mode from this sub source, any market.
  -- 20261121060000: for an EVO sub only this calendar month's (ET) buys count: the operator's
  -- "5000 a month", "auto resets monthly". GoTickets keeps its lifetime cap.
  SELECT COALESCE(sum(sub_total_usd + COALESCE(est_tax_usd, 0)), 0) INTO v_proj
    FROM public.n2s_autobuy_exec
   WHERE mode = c.mode AND sub_source = NEW.sub_source
     AND state IN ('shadow_buy', 'live_buy', 'awaiting_approval', 'approved') AND (phase IS DISTINCT FROM 'stopped' OR buy_order_id IS NOT NULL)
     AND (v_gt OR (created_at AT TIME ZONE 'America/New_York')::date >= date_trunc('month', v_tz_today::timestamp)::date);$r$;
  v_stop_old text := $r$  v_stopped  := CASE WHEN v_gt THEN c.gt_project_stopped ELSE c.project_stopped END;$r$;
  v_stop_new text := $r$  -- 20261121060000: a stop the monthly EVO project cap made in an earlier ET month is lifted
  -- by the first would-buy of a new month. Any other stop stays until the operator clears it.
  IF NOT v_gt AND c.project_stopped AND c.project_stopped_at IS NOT NULL
     AND (c.project_stopped_at AT TIME ZONE 'America/New_York')::date < date_trunc('month', v_tz_today::timestamp)::date
     AND (c.project_stopped_reason LIKE 'Project spend reached $% of the $% cap (dryrun %)'
          OR c.project_stopped_reason LIKE 'dryrun %: $% would take project spend from $% past the $% cap') THEN
    UPDATE public.n2s_autobuy_config
       SET project_stopped = false, project_stopped_at = NULL, project_stopped_reason = NULL,
           stop_emailed_at = NULL, updated_at = now()
     WHERE id;
    c.project_stopped := false;
  END IF;
  v_stopped  := CASE WHEN v_gt THEN c.gt_project_stopped ELSE c.project_stopped END;$r$;
BEGIN
  d := pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure);
  IF md5(d) <> '83d1d69b24bd3c5e6188383f79751c45' THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg drifted from 20261117013000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, v_proj_old, ''))) / length(v_proj_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg: % project-spend anchors (want 1) — re-derive this migration', n;
  END IF;
  n := (length(d) - length(replace(d, v_stop_old, ''))) / length(v_stop_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg: % stop-flag anchors (want 1) — re-derive this migration', n;
  END IF;
  EXECUTE replace(replace(d, v_proj_old, v_proj_new), v_stop_old, v_stop_new);
END $do$;

COMMENT ON COLUMN public.n2s_autobuy_config.project_cap_usd IS
  'EVO sub spend cap per calendar month (America/New_York); a stop it made is lifted by the first would-buy of the next month. Operator 2026-11-21: $5000 a month. 20261121060000.';

COMMIT;
