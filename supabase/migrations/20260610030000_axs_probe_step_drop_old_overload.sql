-- Fix: drop the stale 1-arg axs_probe_step overload.
--
-- 20260610000000 added axs_probe_step(p_max_attempts, p_refresh_hours) via
-- CREATE OR REPLACE, but that creates a NEW overload rather than replacing the
-- original 1-arg axs_probe_step(p_max_attempts) — so the cron's no-arg call
-- `select public.axs_probe_step();` became ambiguous ("function ... is not
-- unique") and every drain run errored. Drop the old 1-arg form; the 2-arg
-- (all-default) version then resolves uniquely for the no-arg call.
-- (PROJECT_BIBLE §7: drop old overloads explicitly on a signature change.)
drop function if exists public.axs_probe_step(integer);
