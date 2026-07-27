-- 20260606192104_cron_redesign_2_sg_token_interleave.sql
--
-- ## Already applied to prod — applied via MCP 2026-06-06 (operator-authorized)
--
-- Trading-hours cadence redesign #2 of 3 (CRON_HIERARCHY §4c).
-- The SG broker token is shared (listings + sales + an external prod program). Interleave
-- so the token sees at most one small batch per minute: listings on EVEN minutes, sales on
-- ODD minutes. Shrink the sales batch 20 -> 4 (it was a 20-wide burst every 5 min -> 429s;
-- same ~4/min throughput, now smooth). Bump the process drains to every 2 min so snapshots
-- land continuously (DB-only, no token draw). Per-event peak/off-peak cadence is handled by
-- collector_band (#1); these ticks run 24/7 and self-throttle off-hours via the band intervals.
-- Job names kept in place to preserve their cron_policy rows (the "1min"/"5min" suffixes are
-- now cosmetic).

SELECT cron.schedule('sg_listings_poll_owned_1min', '*/2 * * * *',
$$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_listings_poll_owned_1min') THEN RETURN; END IF; PERFORM public.sg_listings_poll_tick(5, 3, 'owned'); END $b$;$$);

SELECT cron.schedule('sg_sales_poll_5min', '1-59/2 * * * *',
$$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_sales_poll_5min') THEN RETURN; END IF; PERFORM public.sg_sales_poll_tick(4); END $b$;$$);

SELECT cron.schedule('sg_priority_listings_process_5min', '*/2 * * * *',
$$DO $cronbody$ BEGIN IF NOT public.cron_should_fire('sg_priority_listings_process_5min') THEN RETURN; END IF; PERFORM public.sg_broker_listings_process(100); END $cronbody$;$$);

SELECT cron.schedule('sg_priority_sales_process_5min', '1-59/2 * * * *',
$$DO $cronbody$ BEGIN IF NOT public.cron_should_fire('sg_priority_sales_process_5min') THEN RETURN; END IF; PERFORM public.sg_broker_sales_process(100); END $cronbody$;$$);
