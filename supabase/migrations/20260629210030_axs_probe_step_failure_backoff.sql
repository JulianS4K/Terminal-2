-- Migration 20260629210030 · lane:A1 (DB — AXS probe) · writes (DDL):axs_probe_step() [add failure backoff] · reads:axs_probe,axs_events,net._http_response · pre:20260629130000 (every-minute probe) · auth:operator-approved 2026-06-29 (julian@s4kent.com — "backoff throttle, but recheck next hour or run")
--
-- WHY: axs_probe_step re-fires an axs_ok event whenever last_pulled_at is stale, but a
-- fire that fails to capture (non_json / timeout / page_never_loaded / worker_unavailable
-- — e.g. the upstream "Scheduled maintenance" 500) does NOT advance last_pulled_at, so the
-- event stays perpetually "overdue" and gets re-fired EVERY minute (one stuck event hit 26
-- attempts). With the probe now running every minute, that hammers a dead upstream pointlessly.
--
-- FIX: add a failure backoff to the candidate selection — an event whose last fire did not
-- return 'veritix' must wait ~30 min before retry (instead of every minute). Successful
-- (veritix) events follow the normal 12h refresh; never-probed events fire immediately.
-- Rechecks well within the hour, naturally throttles the whole probe during an upstream
-- outage, and resumes full cadence within ~30 min of recovery. Only the candidate WHERE
-- changed; everything else is identical to mig 20260629130000.
-- ROLLBACK: re-CREATE OR REPLACE without the backoff clause.

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
    -- before retry instead of re-firing every minute. Throttles the probe during an upstream
    -- outage and resumes fast on recovery; rechecks well within the hour.
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