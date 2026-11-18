-- Migration 20260705152027 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "a1_data_retention_runner_v2_ordered_scan" (version 20260705152027) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

-- Runner v2: inner select now ORDER BY ts ASC so batch discovery rides the
-- timestamp index from the oldest edge — index scan in both backlog and
-- steady state (unordered version seq-scanned 41GB when zero rows matched).
create or replace procedure public.run_data_retention(p_ignore_gate boolean default false)
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $proc$
declare
  r          record;
  v_deadline timestamptz;
  v_cutoff   timestamptz;
  v_deleted  bigint;
  v_batch    bigint;
  v_err      text;
  v_sql      text;
begin
  if current_user not in ('postgres', 'service_role', 'supabase_admin') then
    raise exception 'run_data_retention: forbidden for %', current_user;
  end if;
  if not p_ignore_gate and not public.cron_should_fire('data-retention-runner') then
    return;
  end if;
  if not pg_try_advisory_lock(hashtext('data-retention-runner')) then
    return;
  end if;

  v_deadline := clock_timestamp() + interval '50 seconds';

  for r in
    select * from public.data_retention_policy
    where active and method = 'delete'
    order by last_run_at asc nulls first
  loop
    exit when clock_timestamp() >= v_deadline;
    v_cutoff  := now() - r.keep_interval;
    v_deleted := 0;
    v_err     := null;
    v_sql := format(
      'delete from only %I.%I t where t.ctid = any(array(select ctid from %I.%I where %I < $1 %s order by %I asc limit %s))',
      r.schema_name, r.table_name, r.schema_name, r.table_name, r.ts_column,
      case when r.extra_where is not null then 'and (' || r.extra_where || ')' else '' end,
      r.ts_column, r.batch_rows);

    loop
      begin
        execute v_sql using v_cutoff;
        get diagnostics v_batch = row_count;
      exception when others then
        v_err := left(sqlerrm, 300);
        v_batch := 0;
      end;
      exit when v_err is not null;
      v_deleted := v_deleted + v_batch;
      commit;
      exit when v_batch < r.batch_rows or clock_timestamp() >= v_deadline;
    end loop;

    update public.data_retention_policy
       set last_run_at        = now(),
           last_rows_deleted  = v_deleted,
           total_rows_deleted = total_rows_deleted + v_deleted,
           last_error         = v_err
     where schema_name = r.schema_name and table_name = r.table_name;
    commit;
  end loop;

  perform pg_advisory_unlock(hashtext('data-retention-runner'));
end $proc$;
;
