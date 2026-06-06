-- ============================================================
-- SECURITY P0 — close public read/write/TRUNCATE on 6 RLS-disabled tables (2026-06-01).
-- Source: Supabase Security Advisor (lint 0013_rls_disabled_in_public), 6 ERROR rows.
--
-- Exposure confirmed via catalog: these 6 public tables have RLS DISABLED *and* the
-- `anon` role holds full SELECT/INSERT/UPDATE/DELETE/TRUNCATE (anon ships in client JS).
-- The house model is "anon has blanket DML, RLS is the gate" — 140/146 grant-bearing
-- tables already have RLS on (deny-by-default). These 6 are stragglers that missed it,
-- so they are presently readable, writable AND truncatable by any unauthenticated client.
--
-- Fix matches the established convention (see 20260531200000_cutover_p0_fixes.sql §3):
-- ENABLE RLS + REVOKE ALL from anon/authenticated. service_role BYPASSES RLS, so
-- cron jobs and edge/backend (service_role) are unaffected. No policies are added —
-- deny-by-default, identical to the other ~136 internal tables.
--
-- NOTE for reviewer: if any FRONTEND surface reads these via the anon/authenticated key
-- (e.g. an "event movers" UI panel reading public.event_movers_index), that read will
-- now return zero rows and a narrow SELECT policy must be added. Backend writes are safe.
-- ============================================================

ALTER TABLE public.td_tp_performers          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.td_tm_performers          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aq_tevo_search_attempts   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_movers_index        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_movers_index_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.discovery_gap_alerts      ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.td_tp_performers           FROM anon, authenticated;
REVOKE ALL ON public.td_tm_performers           FROM anon, authenticated;
REVOKE ALL ON public.aq_tevo_search_attempts    FROM anon, authenticated;
REVOKE ALL ON public.event_movers_index         FROM anon, authenticated;
REVOKE ALL ON public.event_movers_index_history FROM anon, authenticated;
REVOKE ALL ON public.discovery_gap_alerts       FROM anon, authenticated;
