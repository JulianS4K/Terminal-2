-- 20260526050000_security_revoke_confirmed_anon_policies.sql
--
-- Close anon-read exposure on tables/views confirmed safe by D0 + D1
-- (bot_chat #537 → #553 → #556).
--
-- ## WHO CONFIRMED WHAT
-- D1 (#553, 2026-05-26): "D1 needs anon-read on NONE of the flagged surfaces."
--   All /api/store/* routes use service_role; store.js has zero direct anon calls.
-- D0 (B1 code-audit #556): terminal/*.js has 0 .from() direct reads — RPC-only.
--   The 3 'anon_select_dashboard' policies point at a former D0 dashboard consumer
--   that D0 confirmed is no longer active.
--
-- ## WHAT'S IN THIS MIGRATION
-- Part 1 — DROP 4 base-table anon policies (D0 + D1 confirmed, no D3 dependency)
-- Part 2 — REVOKE anon on 4 Tier-2 views (D1 confirmed; no /api/store/* refs)
--
-- ## WHAT'S HELD (pending D3 confirm on thread #537)
-- espn_athletes (espn_athletes_anon_read)
-- espn_teams_canonical (espn_teams_canonical_anon_read)
-- espn_event_snapshots (anon_select_dashboard)
-- D3 / Broadway may surface these publicly — A1 will revoke once D3 confirms.
--
-- ## ROLLBACK
-- Restore policies:
--   CREATE POLICY events_anon_read ON events FOR SELECT TO anon USING (true);
--   CREATE POLICY anon_select_dashboard ON event_xref FOR SELECT TO anon USING (true);
--   CREATE POLICY venue_assets_anon_read ON venue_assets FOR SELECT TO anon USING (true);
--   CREATE POLICY anon_select_dashboard ON listings_snapshots FOR SELECT TO anon USING (true);
-- Restore view grants:
--   GRANT SELECT ON espn_injury_snapshot_latest TO anon, authenticated;
--   etc.
--
-- NOTE (HIGH PRIORITY): listings_snapshots had USING(true) anon-read — the 8M-row
-- owned-inventory firehose (broker-competitive pricing/qty) was readable by the
-- publishable anon key. This is the most sensitive closure in this migration.
-- ─────────────────────────────────────────────────────────────────────────────

-- PART 1 — Base-table anon policy drops

-- events: confirmed no anon consumer (D0 terminal = SECDEF RPCs, D1 = service_role)
DROP POLICY IF EXISTS events_anon_read ON public.events;

-- event_xref: anon_select_dashboard policy — D0 dashboard defunct, D1 unused
DROP POLICY IF EXISTS anon_select_dashboard ON public.event_xref;

-- venue_assets: D1 storefront confirmed no anon read; D0 terminal confirmed clean
DROP POLICY IF EXISTS venue_assets_anon_read ON public.venue_assets;

-- listings_snapshots: HIGH PRIORITY — 8M-row broker firehose (prices/qty exposed to anon)
-- Policy named anon_select_dashboard — D0 confirmed defunct; D1 confirmed unused
DROP POLICY IF EXISTS anon_select_dashboard ON public.listings_snapshots;


-- PART 2 — Tier-2 view anon REVOKE (B1-NEXT-59 partial close; D1 confirmed safe)
-- These views were left commented in mig 20260525170000 pending lane confirms.

REVOKE SELECT ON public.espn_injury_snapshot_latest FROM anon, authenticated;
REVOKE SELECT ON public.seatgeek_event_latest        FROM anon, authenticated;
REVOKE SELECT ON public.v_event_full_sports          FROM anon, authenticated;
REVOKE SELECT ON public.v_event_full_v2              FROM anon, authenticated;
