-- AXS primary-vs-not classifier + serial drainer + URL/search macros.
--
-- Why: axs.com hosts BOTH AXS-primary box-office events (veritix engine) and
-- resale/no-inventory pages. The workbook col-D set (public.axs_events) mixes
-- them. The only reliable discriminator is the /fetch?platform=axs payload:
--   200 + body.meta.api='veritix'  -> AXS-primary  (is_axs_primary = true)
--   200 + body.meta.status='no_data' (reason page_never_loaded) -> not AXS
--   502/503/504 "AXS dedicated worker unavailable" / timeout -> transient retry
-- The TicketsData AXS worker is single-threaded + slow (~60s) + in development,
-- so probing must be SERIAL with bounded retries. no_data is retried up to the
-- cap before being finalized (a single page_never_loaded can be a transient
-- load miss); exhausted-transient cases land 'inconclusive', never a false
-- 'not_axs'. Read-only upstream: GET /fetch only (CLAUDE.md §2).

-- ---- registry flag columns (authoritative verdict mirror) -------------------
alter table public.axs_events add column if not exists is_axs_primary boolean;   -- null = unknown
alter table public.axs_events add column if not exists probe_status   text;       -- axs_ok|not_axs|inconclusive|retry|pending
alter table public.axs_events add column if not exists probed_at       timestamptz;

-- ---- probe working log ------------------------------------------------------
create table if not exists public.axs_probe (
  axs_event_id   text primary key references public.axs_events(axs_event_id) on delete cascade,
  request_id     bigint,
  fired_at       timestamptz,
  status_code    int,
  is_axs_primary boolean,
  note           text,
  checked_at     timestamptz,
  attempts       int not null default 0,
  status         text,        -- axs_ok | not_axs | inconclusive | retry | pending
  last_reason    text
);
alter table public.axs_probe enable row level security;

-- ---- normalization + URL/search macros (automation surface) -----------------
-- callable mirror of axs_venues.axs_name_norm generated column
create or replace function public.venue_norm(p_name text)
returns text language sql immutable as $$
  select coalesce(
    nullif(regexp_replace(regexp_replace(lower(coalesce(p_name,'')),'^the ',''),'[^a-z0-9]+','','g'), ''),
    'cjk:' || lower(btrim(coalesce(p_name,'')))
  );
$$;

-- slugify a title the way AXS event URLs are formed
create or replace function public.axs_slugify(p_text text)
returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(
           regexp_replace(lower(coalesce(p_text,'')), '[^a-z0-9]+', '-', 'g'),
           '(^-+|-+$)', '', 'g'), '-'), '');
$$;

-- canonical https://www.axs.com/events/<id>/<slug>-tickets builder
create or replace function public.axs_build_event_url(p_event_id text, p_slug_or_title text)
returns text language sql immutable as $$
  select 'https://www.axs.com/events/' || p_event_id || '/'
       || coalesce(public.axs_slugify(p_slug_or_title), 'event') || '-tickets';
$$;

-- search/peg helper: fuzzy find registry events + their axs_venues peg
create or replace function public.axs_search_events(p_q text)
returns table(axs_event_id text, event_url text, source_sheets text,
              is_axs_primary boolean, probe_status text,
              venue_guess text, venue_is_axs boolean)
language sql stable as $$
  with q as (select lower(btrim(p_q)) as t)
  select e.axs_event_id, e.event_url, e.source_sheets, e.is_axs_primary, e.probe_status,
         e.source_sheets as venue_guess,
         exists(select 1 from public.axs_venues v
                where v.axs_name_norm = public.venue_norm(e.source_sheets)) as venue_is_axs
  from public.axs_events e, q
  where q.t = '' or e.event_url ilike '%'||q.t||'%' or e.source_sheets ilike '%'||q.t||'%'
  order by e.axs_event_id;
$$;

-- ---- serial drainer: classify prior + fire exactly one next ------------------
create or replace function public.axs_probe_step(p_max_attempts int default 4)
returns table(action text, ev text, detail text)
language plpgsql security definer set search_path = public, net, extensions as $$
declare
  v_ev text; v_url text; v_rid bigint;
begin
  -- PHASE 1: classify any landed in-flight response.
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
        when r.status_code in (400,404,410,422) then false
        when r.status_code=200 then case when p.attempts >= p_max_attempts then false else null end
        else null end,
      status = case
        when r.status_code=200 and (r.content::jsonb->'body'->'meta'->>'api')='veritix' then 'axs_ok'
        when r.status_code in (400,404,410,422) then 'not_axs'
        when r.status_code=200 then case when p.attempts >= p_max_attempts then 'not_axs' else 'retry' end
        else case when p.attempts >= p_max_attempts then 'inconclusive' else 'retry' end
      end
  from net._http_response r
  where r.id = p.request_id and p.checked_at is null;

  -- mirror terminal verdicts onto the registry
  update public.axs_events e
  set is_axs_primary = p.is_axs_primary, probe_status = p.status, probed_at = p.checked_at
  from public.axs_probe p
  where p.axs_event_id = e.axs_event_id
    and p.status in ('axs_ok','not_axs','inconclusive')
    and (e.probe_status is distinct from p.status or e.probed_at is distinct from p.checked_at);

  -- serial: never fire while a prior request is still outstanding
  if exists (select 1 from public.axs_probe where request_id is not null and checked_at is null) then
    return query select 'in_flight'::text, null::text, 'awaiting prior response'::text; return;
  end if;

  -- PHASE 2: next eligible = never-probed, or retryable under cap
  select e.axs_event_id, e.event_url into v_ev, v_url
  from public.axs_events e
  left join public.axs_probe p on p.axs_event_id = e.axs_event_id
  where e.active
    and (p.axs_event_id is null or (p.status='retry' and p.attempts < p_max_attempts))
  order by (p.axs_event_id is not null), coalesce(p.attempts,0), e.axs_event_id
  limit 1;

  if v_ev is null then
    return query select 'done'::text, null::text, 'all events terminal'::text; return;
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
        checked_at=null, status_code=null, is_axs_primary=null;

  return query select 'fired'::text, v_ev, ('rid='||v_rid)::text;
end $$;

-- ---- progress rollup --------------------------------------------------------
create or replace view public.v_axs_events_classified as
select coalesce(probe_status,'unprobed') as probe_status,
       count(*) as n,
       count(*) filter (where is_axs_primary) as axs_primary,
       count(*) filter (where is_axs_primary = false) as not_axs
from public.axs_events group by 1 order by 2 desc;

-- ---- background drain: one event / 2 min (serial, ~60s load, retries) -------
-- select cron.schedule('axs-probe-drain', '*/2 * * * *', $$select public.axs_probe_step();$$);
-- select cron.unschedule('axs-probe-drain');  -- to stop
