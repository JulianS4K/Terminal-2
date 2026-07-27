-- Migration 20260727210000 · level:data-collection · lane:D6 (author) → A1 (apply) · writes:paciolan_extension_release,paciolan_extension_latest(),paciolan_extension_publish(text,text,text) · reads:paciolan_ingest_config · pre:20260727190000 (paciolan_ingest_config) · auth:OPERATOR-APPROVAL REQUIRED before apply
--
-- Self-hosted (NOT Web Store) update channel for the Chrome extension. The
-- extension is installed unpacked from this repo, so an update is `git pull` +
-- Reload at chrome://extensions — Chrome does not auto-update unpacked
-- extensions. To tell the operator WHEN a newer version exists, CI publishes
-- the manifest version to Supabase on push to main (paciolan_extension_publish,
-- secret-gated) and the popup reads it (paciolan_extension_latest, public).
-- Version strings are not sensitive, so the read is anon/open.

create table if not exists public.paciolan_extension_release (
  id         int  primary key default 1,
  version    text not null,
  notes      text,
  updated_at timestamptz not null default now(),
  constraint paciolan_extension_release_singleton check (id = 1)
);
alter table public.paciolan_extension_release enable row level security;  -- deny-all direct
comment on table public.paciolan_extension_release is
  'Latest published version of paciolan_extension (self-hosted, no Web Store). Set by CI on push to main via paciolan_extension_publish; read by the popup via paciolan_extension_latest.';

-- seed with the current shipped version
insert into public.paciolan_extension_release (id, version, notes)
values (1, '0.2.0', 'export-health verdict + git-pull update check')
on conflict (id) do nothing;

-- public read (version numbers aren't secret) — the popup polls this
create or replace function public.paciolan_extension_latest()
returns text
language sql stable security definer set search_path = public as $$
  select version from public.paciolan_extension_release where id = 1;
$$;
revoke all on function public.paciolan_extension_latest() from public;
grant execute on function public.paciolan_extension_latest() to anon, authenticated;
comment on function public.paciolan_extension_latest() is
  'Latest published paciolan_extension version. Public (anon) — version strings are not sensitive. The popup compares it to chrome.runtime.getManifest().version.';

-- secret-gated publish — CI calls this with the anon key + the shared ingest
-- secret (reuses paciolan_ingest_config, so no service_role key in CI).
create or replace function public.paciolan_extension_publish(
  p_secret text, p_version text, p_notes text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_expected text;
begin
  select secret into v_expected from public.paciolan_ingest_config where id = 1;
  if v_expected is null then raise exception 'paciolan ingest not configured'; end if;
  if p_secret is null or length(p_secret) <> length(v_expected) or not (p_secret = v_expected) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  if coalesce(btrim(p_version), '') = '' then raise exception 'version required'; end if;
  insert into public.paciolan_extension_release (id, version, notes, updated_at)
  values (1, p_version, p_notes, now())
  on conflict (id) do update
    set version = excluded.version, notes = excluded.notes, updated_at = now();
end;
$$;
revoke all on function public.paciolan_extension_publish(text, text, text) from public;
grant execute on function public.paciolan_extension_publish(text, text, text) to anon, authenticated;
comment on function public.paciolan_extension_publish(text, text, text) is
  'CI publishes the extension version here on push to main (secret-gated by paciolan_ingest_config). Reused shared secret → no service_role key in CI.';
