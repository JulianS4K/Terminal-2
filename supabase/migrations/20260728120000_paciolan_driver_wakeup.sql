-- Migration 20260728120000 · level:data-collection · lane:D6 (author) → A1 (apply) · writes:paciolan_driver_endpoints,paciolan_ping_drivers(text,int),paciolan_register_driver_endpoint(text,text,text),paciolan_wake_drivers(),paciolan_enqueue_due(int)[replace] · reads:paciolan_pull_queue · pre:20260727220000 (enqueue_due/pull_queue) · auth:OPERATOR-APPROVAL REQUIRED before apply (adds an outbound net.http_post to operator-registered driver URLs)
--
-- Optional "wake ping": SQL-crons-trigger-the-program (TicketsData-style push)
-- layered on top of the existing pull queue. After paciolan_enqueue_due inserts
-- due rows, it fire-and-forget net.http_post's a tiny secret-gated kick to each
-- registered driver endpoint. A REACHABLE runner (a hosted fetcher, or a local
-- runner exposed via a tunnel) gets triggered immediately and responds by
-- calling paciolan_next_pull; the plain unpacked extension keeps POLLING and is
-- unaffected — the queue stays the source of truth, the ping is just a nudge.
--
-- The endpoint URL is OPERATOR-REGISTERED (their own tunnel/server), never an
-- evenue.net host — RULE 2 is untouched (nothing here fetches eVenue; the ping
-- only wakes the runner, which does the read in its own browser/proxy).

-- ---- registry of driver endpoints to nudge ---------------------------------
create table if not exists public.paciolan_driver_endpoints (
  id               bigint generated always as identity primary key,
  url              text not null unique,     -- operator's runner (tunnel/server), NOT evenue.net
  secret           text,                     -- sent as Authorization: Bearer so the runner can verify the kick
  active           boolean not null default true,
  note             text,
  created_at       timestamptz not null default now(),
  last_pinged_at   timestamptz,
  last_ping_status text
);
alter table public.paciolan_driver_endpoints enable row level security;  -- service-role only
comment on table public.paciolan_driver_endpoints is
  'Runner endpoints the enqueue cron nudges (wake ping) after queuing work. url is the operator''s own reachable runner (hosted, or local-via-tunnel) — never an evenue.net host. secret is echoed as a Bearer token so the runner can verify the kick. The runner responds by calling paciolan_next_pull. Additive to the pull model.';
grant select on public.paciolan_driver_endpoints to service_role;

-- ---- the ping itself (fire-and-forget; never breaks enqueue) ---------------
create or replace function public.paciolan_ping_drivers(
  p_reason text default 'enqueue', p_enqueued integer default null)
returns integer
language plpgsql security definer set search_path to 'public', 'extensions', 'pg_temp' as $$
declare
  r       record;
  v_count int := 0;
  v_body  jsonb;
begin
  -- No pg_net (e.g. a bare/test DB) → nothing to ping. Prod has it (TicketsData).
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return 0;
  end if;
  v_body := jsonb_build_object('source', 'paciolan', 'reason', p_reason,
                               'enqueued', p_enqueued, 'at', now());
  for r in
    select id, url, secret from public.paciolan_driver_endpoints where active
  loop
    begin
      perform net.http_post(
        url     := r.url,
        body    := v_body,
        headers := jsonb_build_object('Content-Type', 'application/json')
                   || case when coalesce(r.secret, '') <> ''
                           then jsonb_build_object('Authorization', 'Bearer ' || r.secret)
                           else '{}'::jsonb end,
        timeout_milliseconds := 5000
      );
      update public.paciolan_driver_endpoints
         set last_pinged_at = clock_timestamp(), last_ping_status = 'sent'
       where id = r.id;
      v_count := v_count + 1;
    exception when others then
      -- a bad endpoint must never block enqueuing — record + move on
      update public.paciolan_driver_endpoints
         set last_pinged_at = clock_timestamp(),
             last_ping_status = 'error: ' || left(sqlerrm, 200)
       where id = r.id;
    end;
  end loop;
  return v_count;
end $$;
revoke all on function public.paciolan_ping_drivers(text, integer) from public;
grant execute on function public.paciolan_ping_drivers(text, integer) to service_role;
comment on function public.paciolan_ping_drivers(text, integer) is
  'Fire-and-forget net.http_post nudge to every active paciolan_driver_endpoints row (secret echoed as Bearer). Exception-safe per endpoint. No-op without pg_net. Called by paciolan_enqueue_due when work was queued.';

-- ---- register/upsert an endpoint (operator convenience) --------------------
create or replace function public.paciolan_register_driver_endpoint(
  p_url text, p_secret text default null, p_note text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  insert into public.paciolan_driver_endpoints (url, secret, note)
  values (p_url, p_secret, p_note)
  on conflict (url) do update
    set secret = excluded.secret, note = excluded.note, active = true
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.paciolan_register_driver_endpoint(text, text, text) from public;
grant execute on function public.paciolan_register_driver_endpoint(text, text, text) to service_role;
comment on function public.paciolan_register_driver_endpoint(text, text, text) is
  'Upsert a runner endpoint to nudge. url = your reachable runner (hosted or local-via-tunnel), secret echoed as Bearer. service_role only.';

-- ---- manual kick (testing / on-demand) -------------------------------------
create or replace function public.paciolan_wake_drivers()
returns integer
language sql security definer set search_path = public as $$
  select public.paciolan_ping_drivers('manual', null);
$$;
revoke all on function public.paciolan_wake_drivers() from public;
grant execute on function public.paciolan_wake_drivers() to service_role;
comment on function public.paciolan_wake_drivers() is
  'Manually nudge all active driver endpoints now (wraps paciolan_ping_drivers). service_role only.';

-- ---- enqueue_due: nudge registered runners after queuing work --------------
-- CREATE OR REPLACE of paciolan_enqueue_due (mig 20260727220000) — identical
-- body plus a single fire-and-forget ping when v_count > 0.
create or replace function public.paciolan_enqueue_due(p_max integer default 100)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  r       record;
  v_count int := 0;
  v_now   timestamptz := clock_timestamp();
  v_gate  boolean := true;
begin
  if to_regprocedure('public.cron_should_fire(text)') is not null then
    v_gate := public.cron_should_fire('paciolan_enqueue_due');
  end if;
  if not v_gate then return 0; end if;

  perform public.paciolan_seed_targets();

  for r in
    select t.tenant, t.event_code,
           public.paciolan_target_url(t.tenant, t.event_code, t.url) as url
    from public.paciolan_pull_targets t
    where t.active
      and (t.last_enqueued_at is null
           or t.last_enqueued_at < v_now - make_interval(mins => t.pull_interval_min))
      and not exists (
        select 1 from public.paciolan_pull_queue q
        where q.tenant = t.tenant and q.event_code = t.event_code
          and q.resolved_at is null
      )
    order by t.last_enqueued_at asc nulls first
    limit p_max
  loop
    insert into public.paciolan_pull_queue (tenant, event_code, url, interval_tag, created_at)
    values (r.tenant, r.event_code, r.url, 'cron', v_now);
    update public.paciolan_pull_targets
       set last_enqueued_at = v_now
     where tenant = r.tenant and event_code = r.event_code;
    v_count := v_count + 1;
  end loop;

  -- Wake any registered runner so a reachable driver pulls immediately instead
  -- of waiting for its next poll. Fire-and-forget; the queue is the fallback.
  if v_count > 0 then
    perform public.paciolan_ping_drivers('enqueue', v_count);
  end if;

  return v_count;
end $$;
