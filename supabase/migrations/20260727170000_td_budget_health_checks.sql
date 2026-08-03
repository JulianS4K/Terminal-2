-- ============================================================================
-- Migration 20260727170000 — TicketsData credit-budget ("token usage") health
--
-- Lane:     A1 (data plane) · health-monitoring surface
-- Touches:  record_td_budget_health() (W, new), health_snapshot_pipeline() (W,
--           wire the recorder into the existing */5min health_tick path)
-- Pre-reqs: ticketsdata_credit_usage, td_credits_today()/td_credits_this_cycle(),
--           td_daily_budget_ok()/td_monthly_budget_ok(), health_check_history
--
-- WHY: every TicketsData-backed source (VD / SH / GT / TM / AXS / SG) draws on
-- one shared credit ("token") budget — a daily cap and a monthly billing-cycle
-- cap (cycle starts day 9). Hitting the daily cap is exactly what pauses AXS
-- polling (td_budget_ok() → false), which the new axs_pipeline checks report as
-- an intentional pause — but nothing on the health site showed HOW MUCH of the
-- budget is spent or which source is spending it. These two checks surface that
-- so an operator can see the pause's cause at a glance and catch a runaway
-- consumer before the monthly cap (a multi-day outage of ALL TD sources) is hit.
--
--   td_credits_daily   — est credits today vs the daily cap, + the top spenders.
--                        A daily cap-hit is BY DESIGN (throttle resets 00:00
--                        UTC), so it is a 'warn', never a 'fail' — benign, and
--                        the same pause the AXS gate check already explains.
--   td_credits_monthly — est credits this billing cycle vs the monthly cap.
--                        Exhausting the cycle pauses every TD source until the
--                        day-9 reset (potentially days), so this one 'fail's
--                        when the cycle budget is gone.
--
-- Estimates use the same ×1.276 logged→billed factor and the same caps as
-- td_daily_budget_ok()/td_monthly_budget_ok(); the exhaustion boundary is read
-- straight off those gate functions so status can't drift from the real gate.
-- Rendered automatically by get_health_dashboard (check_class <> 'web'); no cron
-- change (wired through the existing health_snapshot_pipeline path).
-- ============================================================================

create or replace function public.record_td_budget_health()
 returns integer
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_n integer;
  c_daily_cap   constant numeric := 7500;    -- display cap; must match td_daily_budget_ok()
  c_monthly_cap constant numeric := 225000;  -- display cap; must match td_monthly_budget_ok()
  c_factor      constant numeric := 1.276;    -- logged→billed credit factor (matches td_*_budget_ok)
  v_raw_today   integer := public.td_credits_today();
  v_raw_cycle   bigint  := public.td_credits_this_cycle();
  v_est_today   numeric := round(v_raw_today * c_factor);
  v_est_cycle   numeric := round(v_raw_cycle * c_factor);
  v_daily_ok    boolean := public.td_daily_budget_ok();
  v_monthly_ok  boolean := public.td_monthly_budget_ok();
  v_daily_pct   numeric := round(v_est_today / c_daily_cap * 100, 1);
  v_monthly_pct numeric := round(v_est_cycle / c_monthly_cap * 100, 1);
  v_top text;
begin
  -- top-3 spenders today (share of today's raw credits) for the daily detail
  select string_agg(platform || ' ' || pct::text || '%', ', ' order by raw desc)
    into v_top
  from (
    select platform, sum(credits) as raw,
           round(100.0 * sum(credits) / nullif(
             (select sum(credits) from public.ticketsdata_credit_usage
               where (called_at at time zone 'UTC')::date = current_date), 0)) as pct
    from public.ticketsdata_credit_usage
    where (called_at at time zone 'UTC')::date = current_date
    group by platform
    order by sum(credits) desc
    limit 3
  ) t;

  insert into health_check_history (captured_at, check_class, check_name, status, metric, detail)
  values
  (now(), 'td_budget', 'td_credits_daily',
     case when v_daily_ok and v_daily_pct < 85 then 'ok' else 'warn' end,
     v_daily_pct,
     'est ' || v_est_today::text || ' / ' || c_daily_cap::text || ' (' || v_daily_pct::text
       || '%) · raw ' || v_raw_today::text || ' · resets 00:00 UTC'
       || case when not v_daily_ok then ' · CAP HIT — TD sources throttled (incl. AXS) until reset' else '' end
       || coalesce(' · top: ' || v_top, '')),

  (now(), 'td_budget', 'td_credits_monthly',
     case when not v_monthly_ok then 'fail' when v_monthly_pct >= 80 then 'warn' else 'ok' end,
     v_monthly_pct,
     'est ' || v_est_cycle::text || ' / ' || c_monthly_cap::text || ' (' || v_monthly_pct::text
       || '%) · raw ' || v_raw_cycle::text || ' · cycle resets day 9'
       || case when not v_monthly_ok then ' · CYCLE EXHAUSTED — all TD sources paused until day-9 reset' else '' end);

  get diagnostics v_n = row_count;
  return v_n;
end $function$;

-- Wire the recorder into the existing */5min health snapshot path (no cron edit).
create or replace function public.health_snapshot_pipeline()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare n int;
begin
  insert into public.health_check_history (check_class, check_name, status, metric, detail)
  select check_class, check_name, status, metric, detail from public.release_health_check();
  get diagnostics n = row_count;
  perform public.record_axs_health();
  perform public.record_td_budget_health();
  return n;
end $function$;
