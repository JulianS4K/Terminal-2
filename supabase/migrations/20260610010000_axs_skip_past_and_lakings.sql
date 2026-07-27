-- Skip past events + LA Kings from the AXS drain (operator directive 2026-06-10).
--
-- Two parts:
--  (1) one-time deactivation of the events we can identify as out-of-scope now:
--      - LA Kings (source_sheets 'LA Kings') — no AXS box office, all no_data;
--      - any event whose URL slug carries a past year (2024/2025) — genuinely past.
--  (2) a date gate in axs_probe_step(): once an event is pulled and its
--      meta.event_date is in the past, retire it (active=false) so it is never
--      refreshed. Most past events without a slug date have no pre-pull date
--      source (only ~1/351 is AQ-mapped), so this catches them on first pull;
--      dead AXS pages already exit rotation via the no_data retry cap.

-- (1) one-time deactivations -------------------------------------------------
update public.axs_events
set active = false
where active and (
      source_sheets ilike '%LA Kings%'
   or regexp_replace(event_url, '^https://www\.axs\.com/events/[0-9]+/', '') ~ '20(24|25)'
);

-- (2) drainer with past-event retire gate ------------------------------------
create or replace function public.axs_probe_step(p_max_attempts int default 4, p_refresh_hours int default 12)
returns table(action text, ev text, detail text)
language plpgsql security definer set search_path = public, net, extensions as $$
declare
  v_ev text; v_url text; v_rid bigint; v_snap bigint;
begin
  update public.axs_probe p
  set status_code = r.status_code,
      checked_at  = now(),
      last_reason = coalesce(r.content::jsonb->'body'->'meta'->>'reason',
                             case when r.error_msg is not null then 'timeout'
                                  when r.status_code in (502,503,504) then 'worker_unavailable'
                                  when r.status_code=200 and (r.content::jsonb->'body'->'meta'->>'api')='veritix' then 'veritix'
                                  else null end),
      is_axs_primary = case
        when r.status_code=200 and (r.content::jsonb->'body'->'meta'->>'api')='veritix' then true
        when p.is_axs_primary then true
        when r.status_code in (400,404,410,422) then false
        when r.status_code=200 then case when p.attempts >= p_max_attempts then false else null end
        else null end,
      status = case
        when r.status_code=200 and (r.content::jsonb->'body'->'meta'->>'api')='veritix' then 'axs_ok'
        when p.is_axs_primary then 'axs_ok'
        when r.status_code in (400,404,410,422) then 'not_axs'
        when r.status_code=200 then case when p.attempts >= p_max_attempts then 'not_axs' else 'retry' end
        else case when p.attempts >= p_max_attempts then 'inconclusive' else 'retry' end
      end
  from net._http_response r
  where r.id = p.request_id and p.checked_at is null;

  -- persist a full snapshot for any freshly-landed veritix pull; retire the
  -- event if its date is already in the past (no refresh).
  for v_ev, v_rid in
    select p.axs_event_id, p.request_id
    from public.axs_probe p
    join net._http_response r on r.id = p.request_id
    where p.status='axs_ok' and p.snapshot_id is null
      and (r.content::jsonb->'body'->'meta'->>'api')='veritix'
  loop
    v_snap := public.axs_ingest_snapshot(v_rid, v_ev);
    if v_snap is not null then
      update public.axs_probe set snapshot_id = v_snap where axs_event_id = v_ev;
      update public.axs_events e
        set last_snapshot_id = v_snap, last_pulled_at = now(), api = 'veritix',
            active = case when s.occurs_at_local is not null
                           and s.occurs_at_local::timestamptz < now()
                          then false else e.active end
        from public.axs_event_snapshots s
        where e.axs_event_id = v_ev and s.id = v_snap;
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
  order by
    case when p.axs_event_id is null or p.status='retry' then 0 else 1 end,
    coalesce(p.attempts,0), coalesce(e.last_pulled_at, 'epoch'::timestamptz), e.axs_event_id
  limit 1;

  if v_ev is null then
    return query select 'done'::text, null::text, 'all events terminal / fresh'::text; return;
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
end $$;
