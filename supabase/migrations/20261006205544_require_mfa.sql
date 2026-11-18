-- Migration 20261006205544 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "require_mfa" (version 20261006205544) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

create or replace function ledger.is_app_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with claims as (
    select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) as c
  )
  select exists (
    select 1 from ledger_private.app_owner o where o.user_id = (select auth.uid())
  )
  and (
    coalesce((select c ->> 'aal' from claims) = 'aal2', false)
    or exists (
      select 1 from claims, jsonb_array_elements(case when jsonb_typeof(c -> 'amr') = 'array' then c -> 'amr' else '[]'::jsonb end) m
      where m ->> 'method' = 'oauth'
    )
  );
$$;
;
