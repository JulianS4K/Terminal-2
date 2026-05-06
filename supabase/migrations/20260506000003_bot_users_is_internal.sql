-- Distinguish internal staff from external whitelisted users (clients, partners).
-- Internal-only tools (zone exposure, S4K-owned breakdowns) check this flag.

alter table bot_users
  add column if not exists is_internal boolean not null default false;

comment on column bot_users.is_internal is
  'When true, the user can call internal-only tools (zone exposure, S4K-owned breakdowns). External users (e.g., clients) are still whitelisted but locked out of internal data.';

update bot_users set is_internal = true where phone = '+14253728504';
