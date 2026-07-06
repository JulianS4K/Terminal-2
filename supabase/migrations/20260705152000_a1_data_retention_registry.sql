-- ============================================================================
-- Migration 20260705152000 — data-retention registry + per-minute tick runner
--
-- ⚠ SUPERSEDED same-day by 20260705153000_a1_retention_policy_engine (PR #805,
--   a parallel operator-directed session) — consolidated by
--   20260705170000_a1_retention_consolidation, which retired every object this
--   file creates. Kept as the historical record of what ran 15:24–23:59Z
--   (drained ~14.38M rows). Renamed from 20260705153000 to resolve the
--   filename collision with PR #805's migration.
--
-- Lane:     A1 (data plane)
-- Touches:  data_retention_policy (W, new), run_data_retention_tick (new fn),
--           cron.job (W: schedule runner, tombstone 3 folded sweeps),
--           listings_snapshots (D), ticketsdata_listings_snapshots (D),
--           section_metrics (D + new idx), event_section_row_snapshots (D),
--           event_metrics (D + new idx), cron_gate_decisions (D + new idx),
--           cron.job_run_details (D)
-- Pre-reqs: cron_should_fire(), pg_cron
--
-- REDESIGN of the DELETE-based retention sweeps (operator-directed
-- 2026-07-05). The old per-table sweep crons died of mechanics, not policy:
-- single long transactions (the A1-OPS-24 74h txn pinned the vacuum horizon),
-- 120s cron timeouts, and silent `active=false` tombstones (4 giants had NO
-- retention since ~2026-06-19; listings_snapshots grew ~2GB/day unbounded).
--
-- New shape:
--   * public.data_retention_policy — one row per swept table (keep window,
--     batch size, active flag, last-run stats + last_error). The table IS the
--     health surface: a dead sweep is a visibly stale row, not a silent
--     cron tombstone.
--   * public.run_data_retention_tick() — ONE ≤20k-row batch per active
--     policy per invocation, fired EVERY MINUTE: each tick is a single short
--     transaction (seconds), so no long snapshots, no vacuum-horizon pinning,
--     ~28M rows/table/day drain capacity. (v1 tried commit-per-batch inside a
--     CALLed procedure — pg_cron and the MCP SQL path both wrap commands in a
--     transaction, so in-proc COMMIT fails; the tick design needs none.)
--     Batch discovery is `WHERE ts < cutoff ORDER BY ts ASC LIMIT n` so it
--     rides the leading-timestamp index from the oldest edge — index scan in
--     both backlog and steady state (unordered scans seq-scanned 41GB when
--     zero rows matched). current_user assert + cron_should_fire gate +
--     xact-scoped advisory lock; per-policy errors recorded on the row.
--   * method='partition_drop' reserved for the partition cutover
--     (20260619220000_partition_listings_snapshots_BLUEPRINT.sql): when a
--     table converts, flip its method and the runner skips it.
--
-- Folded + tombstoned standalone crons (same behavior, one system):
--   sweep-old-event-section-rows (30d), cron_gate_decisions_prune_daily
--   (30d, decision <> 'fire'), cron-run-details-cleanup (7d).
-- Seeded INACTIVE (deliberate): seatgeek_listings_snapshots +
--   seatgeek_sales_snapshots — SG pollers paused since 2026-06-26; an active
--   30d window would progressively erode the last data the SG chart views
--   still serve. Flip active=true when the pollers resume.
-- Keep windows: listings 30d (was 15 in the dead sweep — conservative;
--   matches the listings_snapshots_recent 30d analysis window), td 30d,
--   section_metrics 60d, esrs 30d, event_metrics 90d (was co-deleted by
--   sweep_old_listings; now explicit).
--
-- Applied to prod 2026-07-05 via MCP (as three steps: registry, v2, v3 —
-- this file is the consolidated end state); idempotent on replay. The three
-- supporting indexes were built CONCURRENTLY on prod; plain CREATE INDEX
-- IF NOT EXISTS here so branch replays inside a transaction succeed.
-- ============================================================================

create table if not exists public.data_retention_policy (
  schema_name        text        not null default 'public',
  table_name         text        not null,
  ts_column          text        not null,
  keep_interval      interval    not null,
  method             text        not null default 'delete'
                     check (method in ('delete','partition_drop')),
  batch_rows         integer     not null default 20000 check (batch_rows between 100 and 500000),
  active             boolean     not null default false,
  extra_where        text,           -- optional extra predicate (trusted: table is service-writable only)
  last_run_at        timestamptz,
  last_rows_deleted  bigint,
  last_error         text,
  total_rows_deleted bigint      not null default 0,
  notes              text,
  primary key (schema_name, table_name)
);

comment on table public.data_retention_policy is
  'Registry driving run_data_retention_tick(): one row per retention-swept table. active=false = deliberate pause (visible here, not a silent cron tombstone). A stale last_run_at on an active row means the runner is unhealthy.';

alter table public.data_retention_policy enable row level security;
revoke all on table public.data_retention_policy from anon, authenticated;

-- Leading-timestamp indexes for oldest-first batch discovery (built
-- CONCURRENTLY on prod 2026-07-05; section_metrics one is ~68M rows).
-- Also fixes the "min(captured_at) times out at 25s" class of freshness
-- queries on section_metrics (A1-OPS-16..21).
create index if not exists idx_event_metrics_captured_at on public.event_metrics (captured_at);
create index if not exists idx_cron_gate_decisions_decided_at on public.cron_gate_decisions (decided_at);
create index if not exists idx_section_metrics_captured_at on public.section_metrics (captured_at);

create or replace function public.run_data_retention_tick(p_ignore_gate boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  r          record;
  v_deadline timestamptz;
  v_batch    bigint;
  v_err      text;
  v_sql      text;
  v_summary  jsonb := '[]'::jsonb;
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    raise exception 'run_data_retention_tick: forbidden for %', current_user;
  end if;
  if not p_ignore_gate and not public.cron_should_fire('data-retention-runner') then
    return jsonb_build_object('skipped', 'gate');
  end if;
  if not pg_try_advisory_xact_lock(hashtext('data-retention-runner')) then
    return jsonb_build_object('skipped', 'lock');
  end if;

  v_deadline := clock_timestamp() + interval '45 seconds';

  for r in
    select * from public.data_retention_policy
    where active and method = 'delete'
    order by last_run_at asc nulls first
  loop
    exit when clock_timestamp() >= v_deadline;
    v_err := null;
    v_sql := format(
      'delete from only %I.%I t where t.ctid = any(array(select ctid from %I.%I where %I < $1 %s order by %I asc limit %s))',
      r.schema_name, r.table_name, r.schema_name, r.table_name, r.ts_column,
      case when r.extra_where is not null then 'and (' || r.extra_where || ')' else '' end,
      r.ts_column, r.batch_rows);
    begin
      execute v_sql using now() - r.keep_interval;
      get diagnostics v_batch = row_count;
    exception when others then
      v_err := left(sqlerrm, 300);
      v_batch := 0;
    end;
    update public.data_retention_policy
       set last_run_at        = now(),
           last_rows_deleted  = v_batch,
           total_rows_deleted = total_rows_deleted + v_batch,
           last_error         = v_err
     where schema_name = r.schema_name and table_name = r.table_name;
    v_summary := v_summary || jsonb_build_object(
      't', r.schema_name || '.' || r.table_name, 'deleted', v_batch, 'err', v_err);
  end loop;

  return v_summary;
end $fn$;

revoke execute on function public.run_data_retention_tick(boolean) from public, anon, authenticated;
grant execute on function public.run_data_retention_tick(boolean) to service_role;

-- Seed policies (idempotent)
insert into public.data_retention_policy
  (schema_name, table_name, ts_column, keep_interval, batch_rows, active, extra_where, notes)
values
  ('public', 'listings_snapshots',             'captured_at', interval '30 days', 20000, true,  null,
   'redesign of sweep_old_listings(15d, tombstoned ~06-19); 30d matches listings_snapshots_recent analysis window'),
  ('public', 'ticketsdata_listings_snapshots', 'captured_at', interval '30 days', 20000, true,  null,
   'redesign of sweep_old_td_listings(30d, tombstoned); feed ACTIVE (td burn until 07-20)'),
  ('public', 'section_metrics',                'captured_at', interval '60 days', 20000, true,  null,
   'redesign of sweep_old_section_metrics(60d, tombstoned) [captured_at idx built 2026-07-05]'),
  ('public', 'event_section_row_snapshots',    'captured_at', interval '30 days', 20000, true,  null,
   'folded from cron sweep-old-event-section-rows (30d), tombstoned this migration'),
  ('public', 'event_metrics',                  'captured_at', interval '90 days', 20000, true,  null,
   'was co-deleted by sweep_old_listings; explicit generous window for long charts'),
  ('public', 'cron_gate_decisions',            'decided_at',  interval '30 days', 20000, true,  'decision <> ''fire''',
   'folded from cron_gate_decisions_prune_daily, tombstoned this migration'),
  ('cron',   'job_run_details',                'start_time',  interval '7 days',  20000, true,  null,
   'folded from cron-run-details-cleanup, tombstoned this migration'),
  ('public', 'seatgeek_listings_snapshots',    'captured_at', interval '30 days', 20000, false, null,
   'INACTIVE on purpose: SG pollers paused 2026-06-26 — an active window would erode the remaining data the SG chart views serve. Enable when pollers resume.'),
  ('public', 'seatgeek_sales_snapshots',       'pulled_at',   interval '30 days', 20000, false, null,
   'INACTIVE on purpose: same as seatgeek_listings_snapshots')
on conflict (schema_name, table_name) do nothing;

-- Tombstone the three folded standalone crons (behavior now lives in the
-- registry). Via cron.alter_job(): direct UPDATE on cron.job is denied to the
-- migration role.
select cron.alter_job(jobid, active := false) from cron.job
where jobname in ('sweep-old-event-section-rows', 'cron_gate_decisions_prune_daily', 'cron-run-details-cleanup')
  and active;

-- Schedule the per-minute tick (idempotent)
select cron.schedule('data-retention-runner', '* * * * *', 'SELECT public.run_data_retention_tick();')
where not exists (select 1 from cron.job where jobname = 'data-retention-runner');
