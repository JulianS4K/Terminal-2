-- Migration 20260926212000 · level:secondary-sales · lane:A1 (operator-routed to D7; A1 retired) · writes:cron.job · reads:none · pre:20260926170000
--
-- Already applied to prod · via MCP 2026-09-26 21:20 UTC under operator direction
-- ("A1 is retired, you'll have to fix"), after a rolled-back dry run.
--
-- ============================================================================
-- Six terminal jobs lose their leading `SET statement_timeout …;`, the same
-- change that stopped cron 640 from stalling the scheduler (20260926170000).
-- 639 also gains the overlap guard the others already had.
--
-- RESULT (21:20–21:50 vs 20:49–21:19 UTC): no scheduler gain (startup timeouts
-- 16 → 18) and 629/639/638 then ran past their old limits (138/134/530 s vs
-- 55/100/480 s). 628, 629, 630 and 639 were then PAUSED on 2026-09-27
-- (20260927043400); 583 and 638 still run in this form.
-- 636 (tevo_blindspot_mv_refresh) deliberately untouched: its refresh needs the
-- 20-minute cap and runs ~0.1 s most of the time.
-- ============================================================================

SELECT cron.alter_job(583, command := 'SELECT public.aq_link_tevo_from_sibling_rows();');
SELECT cron.alter_job(628, command := $c$DO $guard$ BEGIN IF NOT public.cron_try_lock('gt_listings_poll_tick') THEN RETURN; END IF; PERFORM public.gt_listings_poll_tick(300, 75); END $guard$;$c$);
SELECT cron.alter_job(629, command := $c$DO $guard$ BEGIN
  IF NOT public.cron_try_lock('gt_listings_drain') THEN RETURN; END IF;
  PERFORM public.gt_listings_drain(3000);
  BEGIN
    PERFORM public.gt_deals_retire_tick();
  EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt retire skipped: %', SQLERRM;
  END;
END $guard$;$c$);
SELECT cron.alter_job(630, command := $c$DO $b$ BEGIN
  IF NOT public.cron_try_lock('deal_scan_tick') THEN RETURN; END IF;
  BEGIN PERFORM public.scan_listing_deals('gotickets', 25); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt deal scan skipped: %', SQLERRM; END;
  BEGIN PERFORM public.scan_listing_deals('evo', 25);       EXCEPTION WHEN OTHERS THEN RAISE WARNING 'evo deal scan skipped: %', SQLERRM; END;
END $b$;$c$);
SELECT cron.alter_job(638, command := $c$DO $body$ BEGIN
  IF NOT public.cron_should_fire('sg_classify_events_5min') THEN RETURN; END IF;
  PERFORM public.sg_classify_events();
END $body$;$c$);
SELECT cron.alter_job(639, command := $c$DO $guard$ BEGIN IF NOT public.cron_try_lock('sg_broker_listings_process') THEN RETURN; END IF; PERFORM public.sg_broker_listings_process(50); END $guard$;$c$);

-- rollback (the pre-change commands):
-- 583: SET statement_timeout='120s'; SELECT public.aq_link_tevo_from_sibling_rows();
-- 628: SET statement_timeout='110s'; DO $guard$ … gt_listings_poll_tick(300, 75) … $guard$;
-- 629: SET statement_timeout='55s';  DO $guard$ … gt_listings_drain(3000) … $guard$;
-- 630: SET statement_timeout='120s'; DO $b$ … scan_listing_deals … $b$;
-- 638: SET statement_timeout='8min'; DO $body$ … sg_classify_events() … $body$;
-- 639: SET statement_timeout='100s'; SELECT public.sg_broker_listings_process(50);
