-- ============================================================================
-- Migration 20260705153030 — suppress no-op order-row rewrites (vivid/tickpick)
--
-- Lane:     A1 (data plane / order ingest)
-- Touches:  vivid_orders (W trigger), tickpick_orders (W trigger)
-- Pre-reqs: none (pattern precedent: espn_athletes_suppress_redundant,
--           mig 20260702000500)
--
-- vivid_orders_process() / the tickpick upsert do ON CONFLICT ... DO UPDATE
-- SET ..., last_seen_at=now(), raw=EXCLUDED.raw UNCONDITIONALLY — every order
-- row (with its ~1.5KB raw payload) rewritten every poll cycle, forever:
-- 1.10M updates over 2,138 vivid rows lifetime, 98% table bloat before the
-- 2026-07-05 VACUUM FULL. This BEFORE UPDATE guard discards writes where
-- nothing but the bookkeeping timestamps changed, while still letting a
-- last_seen_at heartbeat through once per 24h (so freshness monitoring keeps
-- working). Real content changes (status/price/etc.) always pass.
--
-- Applied to prod 2026-07-05 via MCP; idempotent on replay.
-- ============================================================================

create or replace function public.orders_suppress_noop_update()
returns trigger
language plpgsql
as $fn$
begin
  if (to_jsonb(new) - 'last_seen_at' - 'pulled_at') = (to_jsonb(old) - 'last_seen_at' - 'pulled_at')
     and old.last_seen_at is not null
     and old.last_seen_at > now() - interval '24 hours' then
    return null;  -- content-identical + heartbeat fresh → skip the write
  end if;
  return new;
end $fn$;

drop trigger if exists vivid_orders_noop_guard on public.vivid_orders;
create trigger vivid_orders_noop_guard
  before update on public.vivid_orders
  for each row execute function public.orders_suppress_noop_update();

drop trigger if exists tickpick_orders_noop_guard on public.tickpick_orders;
create trigger tickpick_orders_noop_guard
  before update on public.tickpick_orders
  for each row execute function public.orders_suppress_noop_update();
