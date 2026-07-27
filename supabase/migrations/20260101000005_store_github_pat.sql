-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-04-25 18:28 UTC.
--
-- Stores Julian's fine-grained GitHub PAT in settings (RLS on, no policies →
-- service_role only). Scope: Contents R/W on JulianS4K/Terminal-2.
--
-- SECURITY: the actual PAT value is REDACTED in this committed file. The real
-- token is already applied in prod. To re-apply this migration in a fresh
-- environment, manually replace 'REDACTED_SET_FROM_VAULT' with the active
-- GitHub PAT before running.
--
-- Rotate via:
--   update settings set value = 'NEW_TOKEN', updated_at = now() where key = 'github_pat';

insert into settings (key, value) values
  ('github_pat',           'REDACTED_SET_FROM_VAULT'),
  ('github_pat_owner',     'JulianS4K'),
  ('github_pat_expires_at','2026-05-25')
on conflict (key) do update set value = excluded.value, updated_at = now();
