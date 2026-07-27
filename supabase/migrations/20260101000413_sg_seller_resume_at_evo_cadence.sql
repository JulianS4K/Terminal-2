-- Migration 20260515350000 · admin · cron-resume (D2-requested, operator-permitted 2026-05-15) · pre:20260515200000
-- Resume 3 sg_seller crons paused 2026-05-14. Match Evo cadence: orders queue @30min,
-- process @30min, listings queue @10min (was 30min, bumped to match collect-listings-0-24h).
-- Listings slot uses 3-59/10 (NOT */10) to avoid Kong-gateway herd with espn-gameday-10min
-- at :00 (bot_chat 130 silent-success class). +10min rule does not fire (10 > 5).

SELECT cron.alter_job(job_id := 63, active := true);                              -- sg_seller_orders_queue_30min
SELECT cron.alter_job(job_id := 65, active := true);                              -- sg_seller_process_30min
SELECT cron.alter_job(job_id := 64, schedule := '3-59/10 * * * *', active := true); -- sg_seller_listings_queue_30min
