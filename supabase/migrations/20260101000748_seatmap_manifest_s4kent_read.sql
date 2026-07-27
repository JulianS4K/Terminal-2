-- Migration 20260603170000 · lane:D0 (author) → operator-authorized apply 2026-06-03 · writes:seatmap_manifest RLS policy · reads:—
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-06-03 (operator-authorized).
--
-- Lets the @s4kent terminal (authenticated, email-gated) read public.seatmap_manifest
-- so the FE can hide the Seat Map tab on events whose venue/config has no map
-- (has_map=false). Section names are non-sensitive; the email gate keeps it to the
-- broker terminal, not any authenticated user. service_role (the sync edge fn) is
-- unaffected (bypasses RLS).

grant select on public.seatmap_manifest to authenticated;
drop policy if exists seatmap_manifest_s4kent_read on public.seatmap_manifest;
create policy seatmap_manifest_s4kent_read on public.seatmap_manifest
  for select to authenticated
  using ((auth.jwt() ->> 'email') like '%@s4kent.com');
