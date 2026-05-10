-- =============================================================
-- share_links — revocable, trackable storefront share links
-- =============================================================
-- A share link points at one event with a saved filter set (zones,
-- sections, price range, min qty). Surfaced at /s/{id} on the storefront
-- (see /api/store/share endpoints in app.py).
--
-- Auth model: server-side only. The service_role bypasses RLS, and the
-- /api/store/share/* handlers are the only writers. Reads are also
-- handler-mediated (the public /api/store/share/{id} endpoint enforces
-- revocation + expiry + view-count bump in code, not in policy).

create table if not exists share_links (
  -- Short URL-safe token. We generate ~12 chars (~72 bits of entropy)
  -- via secrets.token_urlsafe(9) on the server.
  id              text         primary key,
  event_id        bigint       not null references events(id) on delete cascade,

  -- Filter payload, same shape the /api/store/events/{id} endpoint accepts:
  --   { "zones": [...], "section": [...], "min_price": n, "max_price": n, "min_qty": n }
  -- Stored as jsonb so we can add filter dimensions later without a migration.
  filters         jsonb        not null default '{}'::jsonb,

  -- Optional human note ("Hey John, here are the seats I mentioned").
  -- Shown to the recipient in the shared-view banner.
  note            text,

  created_at      timestamptz  not null default now(),
  -- created_by is opt-in: when the storefront eventually adds auth-gated
  -- creation, we'll fill this with the Supabase user_id. NULL today.
  created_by      uuid,

  expires_at      timestamptz,            -- null = never expires
  revoked_at      timestamptz,            -- null = active

  view_count      integer      not null default 0,
  last_viewed_at  timestamptz
);

create index if not exists idx_share_links_event
  on share_links (event_id);

create index if not exists idx_share_links_active
  on share_links (event_id, created_at desc)
  where revoked_at is null;

alter table share_links enable row level security;
-- No policies — service_role (server) bypasses RLS, all other access goes
-- through API handlers. If you ever need to expose direct PostgREST reads
-- to the anon role, add a policy that filters out revoked/expired rows.

comment on table share_links is
  'Revocable storefront share links — /s/{id} resolves to one event with saved filters.';
comment on column share_links.filters is
  'Same filter shape /api/store/events/{id} accepts. JSONB so filter dimensions can grow.';
comment on column share_links.expires_at is
  'NULL = never expires. Server-side enforced in /api/store/share/{id}.';
comment on column share_links.revoked_at is
  'NULL = active. Set by DELETE /api/store/share/{id}; rows are NEVER deleted so view history stays intact.';

-- Atomic view-count bump. The handler calls this after enforcing
-- revocation/expiry so a 410 response never increments the count.
create or replace function bump_share_view(p_id text)
returns void
language sql
as $func$
  update share_links
     set view_count = view_count + 1,
         last_viewed_at = now()
   where id = p_id;
$func$;
revoke all on function bump_share_view(text) from public;
grant execute on function bump_share_view(text) to service_role;
