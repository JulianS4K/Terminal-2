-- ============================================================================
-- Migration 20260727160000 — AXS-specific pipeline health checks
--
-- Lane:     A1 (data plane — AXS ingest pipeline) · health-monitoring surface
-- Touches:  record_axs_health() (W, new), health_snapshot_pipeline() (W, wires
--           the new recorder into the existing */5min health_tick path)
-- Pre-reqs: health_check_history, record_source_freshness/record_cron_deadman
--           (existing monitoring), axs_probe + axs_event_snapshots, is_peak(),
--           td_budget_ok()
--
-- WHY: AXS already appears on the health site via the loose source_freshness
-- card (`axs_events`, warn 720m / fail 2160m) + the `axs-probe-drain` cron. That
-- SLA is deliberately slack because the drain only runs during the ET peak
-- window AND while the shared TD credit budget holds — so a 12h/36h freshness
-- gap is normal on a budget-gated day and can't be tightened without crying
-- wolf. The cost of that slack: a genuinely broken drain/parser can sit silent
-- for a day+ (exactly how the prior multi-week AXS outage went unnoticed).
--
-- These three checks add a tighter, gate-aware AXS signal under a new
-- `axs_pipeline` check_class. They render automatically on the health page
-- (get_health_dashboard groups every check_class <> 'web' generically) and feed
-- the overall banner. Design goal: distinguish an INTENTIONAL pause from a REAL
-- break, and stay quiet (never 'fail') during a legitimate gated pause.
--
--   axs_drain_gate  — status only, never fails. Surfaces WHY the drain is live
--                     or paused (off-peak / budget) so a budget pause is never
--                     misread as an outage. Also shows newest-snapshot age.
--   axs_drain_stall — only evaluated while eligible (peak AND budget). A probe
--                     stuck 'pending' >15m means axs_probe_step's 10-min
--                     self-heal never ran ⇒ the drain step is not executing
--                     (wedged cron / deadlock — the prior-outage failure mode).
--                     Reports 'off' when gated, so a leftover pending during a
--                     budget pause stays benign.
--   axs_ingest      — total-failure detector over AXS-ok responses in the last
--                     12h. A nonzero partial no-snapshot rate is NORMAL
--                     (sold-out/expired events legitimately yield no snapshot),
--                     so we only 'fail' when EVERY recent AXS-ok response failed
--                     to ingest ⇒ the dual-format parser regressed. 'off' when
--                     there were no AXS-ok responses to judge (idle/gated).
--
-- No cron changes: health_snapshot_pipeline() already runs inside health_tick()
-- on the health_monitor_5min job, so wiring the recorder there keeps the whole
-- change in the public schema.
-- ============================================================================

create or replace function public.record_axs_health()
 returns integer
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_n integer;
  v_peak boolean := public.is_peak();
  v_budget boolean := public.td_budget_ok();
  v_eligible boolean;
  v_gate text;
  v_newest timestamptz;
  v_stuck integer;
  v_ok_resp integer;
  v_ingested integer;
  v_no_snap integer;
  v_last_ingest timestamptz;
begin
  v_eligible := v_peak and v_budget;
  v_gate := case
              when v_eligible then 'drain live (peak window + TD budget ok)'
              when not v_peak and not v_budget then 'paused — off-peak + TD budget exhausted'
              when not v_peak then 'paused — off-peak window (ET 02:00–08:59)'
              else 'paused — TD credit budget exhausted' end;

  select max(captured_at) into v_newest from public.axs_event_snapshots;

  -- a pending older than the 10-min self-heal window ⇒ the drain step isn't running
  select count(*) into v_stuck
    from public.axs_probe
   where status = 'pending' and checked_at is null
     and fired_at < now() - interval '15 minutes';

  -- recent ingest outcomes among AXS-primary responses (snapshot_id: >0 ingested, -1 no-snapshot)
  select count(*) filter (where status = 'axs_ok'),
         count(*) filter (where status = 'axs_ok' and snapshot_id > 0),
         count(*) filter (where status = 'axs_ok' and snapshot_id = -1),
         max(checked_at) filter (where status = 'axs_ok' and snapshot_id > 0)
    into v_ok_resp, v_ingested, v_no_snap, v_last_ingest
    from public.axs_probe
   where checked_at > now() - interval '12 hours';

  insert into health_check_history (captured_at, check_class, check_name, status, metric, detail)
  values
  (now(), 'axs_pipeline', 'axs_drain_gate',
     case when v_eligible then 'ok' else 'off' end,
     null,
     v_gate || ' · newest snapshot ' || coalesce(to_char(v_newest, 'MM-DD HH24:MI'), 'never')
       || coalesce(' (' || round(extract(epoch from now() - v_newest) / 60.0)::text || 'm ago)', '')),

  (now(), 'axs_pipeline', 'axs_drain_stall',
     case when not v_eligible then 'off'
          when v_stuck = 0 then 'ok'
          when v_stuck < 3 then 'warn'
          else 'fail' end,
     v_stuck::numeric,
     case when not v_eligible then 'drain paused (gated) — stall check n/a · ' || v_gate
          else v_stuck::text
               || ' probe(s) stuck pending >15m — self-heal flips at 10m, so >0 ⇒ drain step not executing' end),

  (now(), 'axs_pipeline', 'axs_ingest',
     case when v_ok_resp = 0 then 'off'
          when v_ingested = 0 then 'fail'
          else 'ok' end,
     v_ingested::numeric,
     case when v_ok_resp = 0 then 'no AXS-primary responses in 12h to assess (idle/gated)'
          else v_ingested::text || '/' || v_ok_resp::text || ' AXS-ok responses ingested, '
               || v_no_snap::text || ' no-snapshot (partial-fail is normal: sold-out/expired)'
               || ' · last ingest ' || coalesce(to_char(v_last_ingest, 'MM-DD HH24:MI'), 'never') end);

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
  return n;
end $function$;
