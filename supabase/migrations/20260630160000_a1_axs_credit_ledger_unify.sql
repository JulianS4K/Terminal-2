-- ============================================================================
-- Migration 20260630160000 — Unify AXS credit consumption into the TD ledger
--
-- Lane:     A1
-- Touches:  axs_probe_step (W, fn), ticketsdata_credit_usage (W, via td_charge_credit + backfill),
--           v_td_credit_usage_by_platform (W, view), v_td_credit_usage_mtd (W, view),
--           v_td_credit_cost_per_call (W, view); reads axs_event_snapshots, axs_probe.
-- Pre-reqs: 20260527050000 (td_charge_credit + ticketsdata_credit_usage),
--           20260610050000 / live axs_probe_step (this CREATE OR REPLACE is authored from the LIVE
--           pg_get_functiondef so the 30-min failure-backoff clause is preserved — NOT from the file).
--
-- WHY: AXS routes through ticketsdata.com/fetch?platform=axs (it IS TD credits) but never called
-- td_charge_credit, so AXS spend was invisible in the credit ledger and the shared quota_remaining
-- counter is contended (3 groups: {SH},{VD,GT,TM},{AXS}) → AXS true cost was unmeasurable. This lands
-- AXS into the same ledger at ingest (mirroring td_normalize_drain's post-200 charge) and adds
-- per-platform + counter-group-aware accounting views. "Log everything so we can track."
--
-- Idempotent (CREATE OR REPLACE + guarded backfill) → apply-before-PR; re-apply is a no-op.
-- ============================================================================

-- 1a. axs_probe_step — verbatim live body + ONE td_charge_credit at the ingest-success branch.
CREATE OR REPLACE FUNCTION public.axs_probe_step(p_max_attempts integer DEFAULT 4, p_refresh_hours integer DEFAULT 12, p_ingest_limit integer DEFAULT 5)
 RETURNS TABLE(action text, ev text, detail text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions', 'pg_temp'
AS $function$
declare
  v_ev text; v_url text; v_rid bigint; v_snap bigint;
begin
  update public.axs_probe p
  set status_code = r.status_code,
      checked_at  = now(),
      last_reason = coalesce(public.safe_jsonb(r.content)->'body'->'meta'->>'reason',
                             case when r.error_msg is not null then 'timeout'
                                  when r.status_code in (502,503,504) then 'worker_unavailable'
                                  when r.status_code=200 and (public.safe_jsonb(r.content)->'body'->'meta'->>'api')='veritix' then 'veritix'
                                  when r.status_code=200 then 'non_json'
                                  else null end),
      is_axs_primary = case
        when r.status_code=200 and (public.safe_jsonb(r.content)->'body'->'meta'->>'api')='veritix' then true
        when p.is_axs_primary then true
        when r.status_code in (400,404,410,422) then false
        when r.status_code=200 then case when p.attempts >= p_max_attempts then false else null end
        else null end,
      status = case
        when r.status_code=200 and (public.safe_jsonb(r.content)->'body'->'meta'->>'api')='veritix' then 'axs_ok'
        when p.is_axs_primary then 'axs_ok'
        when r.status_code in (400,404,410,422) then 'not_axs'
        when r.status_code=200 then case when p.attempts >= p_max_attempts then 'not_axs' else 'retry' end
        else case when p.attempts >= p_max_attempts then 'inconclusive' else 'retry' end
      end
  from net._http_response r
  where r.id = p.request_id and p.checked_at is null;

  for v_ev, v_rid in
    select p.axs_event_id, p.request_id
    from public.axs_probe p
    where p.status='axs_ok' and p.snapshot_id is null and p.request_id is not null
    order by p.checked_at nulls last
    limit greatest(p_ingest_limit, 1)
  loop
    v_snap := public.axs_ingest_snapshot(v_rid, v_ev);
    if v_snap is not null then
      update public.axs_probe set snapshot_id = v_snap where axs_event_id = v_ev;
      update public.axs_events e
        set last_snapshot_id = v_snap, last_pulled_at = now(),
            active = case when s.occurs_at_local is not null
                           and s.occurs_at_local::timestamptz < now()
                          then false else e.active end
        from public.axs_event_snapshots s
        where e.axs_event_id = v_ev and s.id = v_snap;

      -- NEW (mig 20260630160000): log AXS credit consumption into the unified TD ledger,
      -- mirroring td_normalize_drain's post-200 charge. quota_remaining is read from the snapshot
      -- we just ingested (axs_ingest_snapshot parsed it from the body) — the AXS-counter value at
      -- ingest, not fire time. p_n=1 = call-count; true per-call cost is derived from quota deltas
      -- (v_td_credit_cost_per_call), never this column.
      perform public.td_charge_credit(
                1,
                s.tevo_event_id,
                'AXS',
                '/fetch',
                coalesce(pr.status_code, 200),
                s.quota_remaining::int)
      from public.axs_event_snapshots s
      left join public.axs_probe pr on pr.axs_event_id = v_ev
      where s.id = v_snap;
    else
      update public.axs_probe set snapshot_id = -1 where axs_event_id = v_ev and request_id = v_rid;
    end if;
  end loop;

  update public.axs_events e
  set is_axs_primary = p.is_axs_primary, probe_status = p.status, probed_at = p.checked_at
  from public.axs_probe p
  where p.axs_event_id = e.axs_event_id
    and p.status in ('axs_ok','not_axs','inconclusive')
    and (e.probe_status is distinct from p.status or e.probed_at is distinct from p.checked_at);

  if exists (select 1 from public.axs_probe where request_id is not null and checked_at is null) then
    return query select 'in_flight'::text, null::text, 'awaiting prior response'::text; return;
  end if;

  select e.axs_event_id, e.event_url into v_ev, v_url
  from public.axs_events e
  left join public.axs_probe p on p.axs_event_id = e.axs_event_id
  where e.active
    and (
      p.axs_event_id is null
      or (p.status='retry' and p.attempts < p_max_attempts)
      or (p.status='axs_ok' and (e.last_pulled_at is null
                                 or e.last_pulled_at < now() - make_interval(hours => p_refresh_hours)))
    )
    -- FAILURE BACKOFF: a fire that did not capture (last_reason <> 'veritix') waits ~30 min
    -- before retry, instead of being re-fired every minute. Rechecks well within the hour;
    -- naturally throttles the whole probe during an upstream outage and resumes fast on recovery.
    and (
      p.axs_event_id is null
      or p.last_reason = 'veritix'
      or p.fired_at is null
      or p.fired_at < now() - interval '30 minutes'
    )
  order by
    case when p.axs_event_id is null or p.status='retry' then 0 else 1 end,
    coalesce(p.attempts,0), coalesce(e.last_pulled_at, 'epoch'::timestamptz), e.axs_event_id
  limit 1;

  if v_ev is null then
    return query select 'done'::text, null::text, 'all events terminal / fresh / backed-off'::text; return;
  end if;

  select net.http_get(
    url := 'https://ticketsdata.com/fetch',
    params := jsonb_build_object(
      'username',  public.get_app_secret(p_name => 'TICKETSDATA_USERNAME'),
      'password',  public.get_app_secret(p_name => 'TICKETSDATA_PASSWORD'),
      'event_url', v_url, 'platform', 'axs'),
    timeout_milliseconds := 100000
  ) into v_rid;

  insert into public.axs_probe (axs_event_id, request_id, fired_at, attempts, status)
  values (v_ev, v_rid, now(), 1, 'pending')
  on conflict (axs_event_id) do update
    set request_id=excluded.request_id, fired_at=now(),
        attempts=public.axs_probe.attempts+1, status='pending',
        checked_at=null, status_code=null, snapshot_id=null;

  return query select 'fired'::text, v_ev, ('rid='||v_rid)::text;
end $function$;

REVOKE EXECUTE ON FUNCTION public.axs_probe_step(integer,integer,integer) FROM public, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.axs_probe_step(integer,integer,integer) TO service_role;

-- 1c. Per-platform daily accounting (credits == call-count; all rows log 1).
CREATE OR REPLACE VIEW public.v_td_credit_usage_by_platform AS
SELECT (called_at AT TIME ZONE 'UTC')::date          AS day,
       coalesce(platform,'(none)')                   AS platform,
       count(*)                                       AS calls,
       sum(credits)                                   AS credits,
       min(quota_remaining) FILTER (WHERE quota_remaining IS NOT NULL) AS quota_min,
       max(quota_remaining) FILTER (WHERE quota_remaining IS NOT NULL) AS quota_max
FROM public.ticketsdata_credit_usage
GROUP BY 1,2;

-- Month-to-date rollup (operator dashboard read).
CREATE OR REPLACE VIEW public.v_td_credit_usage_mtd AS
SELECT coalesce(platform,'(none)') AS platform,
       count(*)                                                                    AS calls_mtd,
       count(*) FILTER (WHERE (called_at AT TIME ZONE 'UTC')::date = (now() AT TIME ZONE 'UTC')::date) AS calls_today,
       sum(credits)                                                                AS credits_mtd
FROM public.ticketsdata_credit_usage
WHERE date_trunc('month', called_at AT TIME ZONE 'UTC') = date_trunc('month', now() AT TIME ZONE 'UTC')
GROUP BY 1
ORDER BY calls_mtd DESC;

-- True per-call cost via quota deltas — partitioned by COUNTER GROUP (not platform), robust to
-- co-tenant contention: median of deltas on dense (<=120s apart) adjacent pairs. The shared quota
-- groups were verified live: {SH}, {VD,GT,TM}, {AXS}. AXS is its own counter → cleanest read.
CREATE OR REPLACE VIEW public.v_td_credit_cost_per_call AS
WITH grp AS (
  SELECT id, called_at, platform, quota_remaining,
         CASE WHEN platform='SH' THEN 'SH'
              WHEN platform='AXS' THEN 'AXS'
              WHEN platform IN ('VD','GT','TM') THEN 'VDGTTM'
              ELSE coalesce(platform,'OTHER') END AS counter_group
  FROM public.ticketsdata_credit_usage
  WHERE quota_remaining IS NOT NULL
),
d AS (
  SELECT counter_group, called_at,
         lag(quota_remaining) OVER (PARTITION BY counter_group ORDER BY called_at, id) AS prev_q,
         quota_remaining AS cur_q,
         lag(called_at)    OVER (PARTITION BY counter_group ORDER BY called_at, id) AS prev_at
  FROM grp
)
SELECT counter_group,
       count(*) FILTER (WHERE prev_q IS NOT NULL) AS adjacent_pairs,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY (prev_q - cur_q))
         FILTER (WHERE prev_q IS NOT NULL
                   AND extract(epoch FROM (called_at - prev_at)) <= 120
                   AND (prev_q - cur_q) BETWEEN 0 AND 50)            AS cost_per_call_median_dense,
       avg(prev_q - cur_q)
         FILTER (WHERE prev_q IS NOT NULL AND (prev_q - cur_q) BETWEEN 0 AND 50) AS cost_per_call_mean_capped,
       max(prev_q - cur_q) FILTER (WHERE prev_q IS NOT NULL)         AS max_observed_delta
FROM d
GROUP BY counter_group;

REVOKE ALL ON public.v_td_credit_usage_by_platform, public.v_td_credit_usage_mtd, public.v_td_credit_cost_per_call FROM anon, authenticated;
GRANT SELECT ON public.v_td_credit_usage_by_platform, public.v_td_credit_usage_mtd, public.v_td_credit_cost_per_call TO service_role;

-- 1b. OPTIONAL backfill (separable, idempotent). Nudges td_credits_today/this_month up by the AXS
-- call-count (~240/day, ≪ 50k/600k gates). Skip this statement to leave the budget gate untouched.
INSERT INTO public.ticketsdata_credit_usage (called_at, event_id, platform, endpoint, credits, status_code, quota_remaining)
SELECT s.captured_at, s.tevo_event_id, 'AXS', '/fetch', 1, 200, s.quota_remaining::int
FROM public.axs_event_snapshots s
WHERE s.quota_remaining IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.ticketsdata_credit_usage u
                  WHERE u.platform='AXS' AND u.called_at = s.captured_at);
