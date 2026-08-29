-- Migration 20260829190000 · level:data-collection · lane:A1 · writes:evenuedesk_raw_pulls,evenuedesk_queue_feed_pull()[new],evenuedesk_process_feed_pull()[new],v_evenuedesk_pull_health[new],cron.evenuedesk_feed_queue[new],cron.evenuedesk_feed_process[new] · reads:vault.decrypted_secrets(EVENUEDESK_API_KEY),net._http_response · pre:vault.EVENUEDESK_API_KEY must be seeded BEFORE apply (see §0) · auth:OPERATOR-APPROVAL REQUIRED before apply (new cron schedules + vault read + new SECDEF fns)
--
-- eVenue Desk marketplace feed poller — 10-minute cadence.
--
-- §0 PRE-REQ (operator, out-of-band — do NOT put the key in git):
--     select vault.create_secret('<the s4k_… key>', 'EVENUEDESK_API_KEY',
--                                'eVenue Desk marketplace API key (crm.s4kcs.com)');
--   The key is never written to a migration, a comment, or a log. If it has
--   ever been pasted into a chat, a ticket, or a shared doc, ROTATE IT FIRST.
--
-- §1 SEPARATE SOURCE. This is NOT the Paciolan pipeline. The desk
--   (crm.s4kcs.com) is its own host with its own auth, its own event-ID scheme
--   and its own tables. It shares nothing with paciolan_event_snapshots /
--   paciolan_ingest / paciolan_raw_captures, which stay browser-extension
--   sourced against <tenant>.evenue.net. Nothing here reads or writes a
--   paciolan_* object, and nothing there should read an evenuedesk_* one.
--
-- §2 RULE 2. Read-only: net.http_get only. There is no POST/PUT/PATCH/DELETE
--   to crm.s4kcs.com anywhere in this migration and none may be added — the
--   desk fronts live primary box-office inventory.
--
-- §3 WHY RAW-FIRST. As of authoring, only GET /api/v1/ping is confirmed
--   against this host; the feed response shape is transcribed from the API
--   reference PDF and unverified (the issued key carries an `s4k_` prefix
--   where that reference documents `evd_`). So this lands the WHOLE response
--   as jsonb rather than shredding it into typed columns built on a guess —
--   same format-drift philosophy as paciolan_raw_captures. The typed
--   projection lands in a follow-up migration once a real response is
--   captured and diffed against docs/evenuedesk_feed_mapping.md §2.
--
-- §4 WHY /feed/changes, NOT /feed/full. /feed/full is a BASELINE RESET: it
--   rewrites the key's feed_seen rows server-side, so polling it would make
--   every subsequent delta meaningless. /feed/changes is the poll, and it
--   advances the baseline exactly once per call — which is also why there is
--   exactly ONE scheduled caller on this key. Ad-hoc inspection must pass
--   dry_run=true or it will eat the poller's deltas.

-- ---- 1) raw landing: one row per poll --------------------------------------
create table if not exists public.evenuedesk_raw_pulls (
  id                bigint generated always as identity primary key,
  queued_at         timestamptz not null default now(),
  landed_at         timestamptz,
  endpoint          text not null,
  request_id        bigint,               -- net.http_get request id
  http_status       int,
  payload           jsonb,                -- the WHOLE response body, unshredded
  payload_bytes     int,
  added_count       int,                  -- best-effort counts, null until shape confirmed
  changed_count     int,
  removed_count     int,
  error             text                  -- transport/parse failure; never carries the key
);
create index if not exists idx_evd_raw_queued   on public.evenuedesk_raw_pulls (queued_at desc);
create index if not exists idx_evd_raw_request  on public.evenuedesk_raw_pulls (request_id);
create index if not exists idx_evd_raw_pending  on public.evenuedesk_raw_pulls (request_id)
  where landed_at is null;
alter table public.evenuedesk_raw_pulls enable row level security;  -- service-role only
comment on table public.evenuedesk_raw_pulls is
  'Raw eVenue Desk (crm.s4kcs.com) feed responses, one row per 10-minute poll. Landed whole as jsonb so a desk-side format change never silently loses data — re-parse from here. SEPARATE SOURCE from paciolan_* (different host, auth, ID scheme). Pruned to 30d by the process fn.';
grant select on public.evenuedesk_raw_pulls to service_role;

-- ---- 2) queue: fire the GET (async, via pg_net) -----------------------------
create or replace function public.evenuedesk_queue_feed_pull()
returns bigint
language plpgsql security definer set search_path = public, net, vault as $$
declare
  v_key text;
  v_req bigint;
  v_path text := '/api/v1/feed/changes';
begin
  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'EVENUEDESK_API_KEY' limit 1;

  if v_key is null or v_key = '' then
    -- Fail closed and VISIBLY: a missing key must surface as a health row, not
    -- as a silent run of zero-row polls that looks like "the desk had nothing".
    insert into public.evenuedesk_raw_pulls (endpoint, landed_at, error)
    values (v_path, now(), 'EVENUEDESK_API_KEY missing in vault.decrypted_secrets');
    return null;
  end if;

  -- RULE 2: GET only. The key travels in a header, never the URL, so it cannot
  -- land in a redirect target or an access log.
  select net.http_get(
    url := 'https://crm.s4kcs.com' || v_path,
    headers := jsonb_build_object(
      'X-API-Key', v_key,
      'Accept', 'application/json',
      'User-Agent', 'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)'
    ),
    timeout_milliseconds := 45000
  ) into v_req;

  insert into public.evenuedesk_raw_pulls (endpoint, request_id)
  values (v_path, v_req);

  return v_req;
end $$;

revoke all on function public.evenuedesk_queue_feed_pull() from public;
grant execute on function public.evenuedesk_queue_feed_pull() to service_role;
comment on function public.evenuedesk_queue_feed_pull is
  'Fire one read-only GET /api/v1/feed/changes at the eVenue Desk via pg_net. Key from vault, sent as a header, never logged. RULE 2: GET only.';

-- ---- 3) process: land the response -----------------------------------------
create or replace function public.evenuedesk_process_feed_pull()
returns int
language plpgsql security definer set search_path = public, net as $$
declare
  r record;
  v_body jsonb;
  v_count int := 0;
begin
  for r in
    select p.id, p.request_id
      from public.evenuedesk_raw_pulls p
     where p.landed_at is null and p.request_id is not null
     order by p.queued_at
     limit 50
  loop
    begin
      select
        case when rr.content is not null and rr.content <> ''
             then rr.content::jsonb else null end,
        rr.status_code
        into v_body, r.request_id
        from net._http_response rr
       where rr.id = r.request_id;
    exception when others then
      v_body := null;   -- non-JSON body; keep the row, record the failure
    end;

    update public.evenuedesk_raw_pulls p
       set landed_at     = now(),
           payload       = v_body,
           payload_bytes = length(coalesce(v_body::text, '')),
           http_status   = (select status_code from net._http_response where id = p.request_id),
           -- Best-effort delta counts. Null (not 0) when the shape is
           -- unrecognized, so "shape drifted" never masquerades as "no changes".
           added_count   = jsonb_array_length(v_body->'added'),
           changed_count = jsonb_array_length(v_body->'changed'),
           removed_count = jsonb_array_length(v_body->'removed'),
           error         = case when v_body is null
                                then 'empty or non-JSON response' else null end
     where p.id = r.id;

    v_count := v_count + 1;
  end loop;

  -- Retention: 30 days of raw. Keeps re-parse history without unbounded growth.
  delete from public.evenuedesk_raw_pulls
   where queued_at < now() - interval '30 days';

  return v_count;
end $$;

revoke all on function public.evenuedesk_process_feed_pull() from public;
grant execute on function public.evenuedesk_process_feed_pull() to service_role;
comment on function public.evenuedesk_process_feed_pull is
  'Land pg_net responses for queued eVenue Desk polls into evenuedesk_raw_pulls, then prune to 30d. Delta counts are NULL (not 0) on an unrecognized shape so drift is visible.';

-- ---- 4) health view ---------------------------------------------------------
create or replace view public.v_evenuedesk_pull_health as
select
  max(queued_at)                                          as last_queued_at,
  max(landed_at)                                          as last_landed_at,
  count(*) filter (where landed_at is null)               as pending,
  count(*) filter (where error is not null)               as errored,
  count(*) filter (where queued_at > now() - interval '1 hour') as pulls_last_hour,
  -- Shape-drift signal: landed OK but we could not read the delta arrays.
  count(*) filter (where landed_at is not null
                     and http_status = 200
                     and added_count is null)             as unrecognized_shape
from public.evenuedesk_raw_pulls;
comment on view public.v_evenuedesk_pull_health is
  'eVenue Desk poller health. unrecognized_shape > 0 means the desk returned 200 but not the added/changed/removed shape we expect — correct FEED_PATHS/parse before trusting counts.';
grant select on public.v_evenuedesk_pull_health to service_role;

-- ---- 5) cron: every 10 minutes ---------------------------------------------
-- Minute marks avoid :02 / :05 / :07 per MIGRATION_CONVENTIONS (peak-collision
-- rule). Queue at :03, land 3 minutes later at :06 — enough slack for a 45s
-- timeout plus retry, without letting a response sit unread until the next tick.
select cron.schedule('evenuedesk_feed_queue',   '3,13,23,33,43,53 * * * *',
                     $$ select public.evenuedesk_queue_feed_pull(); $$);
select cron.schedule('evenuedesk_feed_process', '6,16,26,36,46,56 * * * *',
                     $$ select public.evenuedesk_process_feed_pull(); $$);
