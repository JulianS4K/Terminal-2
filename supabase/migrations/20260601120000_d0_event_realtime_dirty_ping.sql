-- ============================================================
-- D0 Realtime slice #1 — per-event "dirty" Broadcast ping.
-- Authored by D0 2026-06-01. STATUS: NOT APPLIED — requires A1 apply (mutation lane).
--
-- Goal: let the open event page (static/terminal/event.js) refresh live instead
-- of only at load time, WITHOUT streaming the firehose to clients and WITHOUT
-- exposing any event data on a public channel.
--
-- Design (matches PROJECT_BIBLE landmines):
--   * We do NOT put Realtime on the high-volume snapshot tables
--     (seatgeek_*_snapshots / listings_snapshots) — Postgres-Changes CDC there
--     would flood clients and add WAL/replica-identity overhead.
--   * Instead we emit a tiny, DATA-FREE Broadcast on the already-curated,
--     bounded tables that represent "this event just changed":
--       - event_alerts      (AFTER INSERT) — a new alert fired
--       - event_movers_index (AFTER INSERT OR UPDATE) — metrics recomputed
--     The payload carries only {event_id, reason, at}. The client re-pulls the
--     existing email-gated RPC (get_broker_event_page_v3) and re-renders, so all
--     data access stays behind the @s4kent.com JWT gate. The ping itself leaks
--     nothing beyond "event N is dirty".
--   * Public topic ("event:<id>", private=false) → the static-site anon client
--     can subscribe with just the publishable key; no RLS on realtime.messages
--     is required (private channels are out of scope for this slice).
--   * Trigger bodies swallow any Realtime error so a collector INSERT/UPDATE can
--     never fail because of a broadcast hiccup.
--
-- Volume note: arbitrage_opportunity can fire ~17 alert rows per cron tick. Each
-- fires one broadcast, but the client coalesces bursts and throttles its re-fetch
-- to <= 1 / 8s (see event.js _RT_MIN_INTERVAL_MS), so same-event storms collapse
-- to a single re-render.
-- ============================================================

-- 1) Thin, reusable emitter. SECURITY DEFINER so it can reach realtime.send
--    from a trigger owned by the table writer. No-op on NULL event id.
CREATE OR REPLACE FUNCTION public.broadcast_event_dirty(p_event_id bigint, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','realtime','pg_temp'
AS $fn$
BEGIN
  IF p_event_id IS NULL THEN
    RETURN;
  END IF;
  PERFORM realtime.send(
    jsonb_build_object('event_id', p_event_id, 'reason', p_reason, 'at', now()),
    'dirty',                       -- broadcast event name
    'event:' || p_event_id::text,  -- topic (one per event)
    false                          -- public channel
  );
EXCEPTION WHEN OTHERS THEN
  -- Never let a Realtime failure break the caller's transaction.
  RETURN;
END;
$fn$;

REVOKE ALL ON FUNCTION public.broadcast_event_dirty(bigint, text) FROM anon;

-- 2) event_alerts: new alert row → ping that event.
CREATE OR REPLACE FUNCTION public.trg_event_alerts_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $fn$
BEGIN
  PERFORM public.broadcast_event_dirty(NEW.tevo_event_id, 'alert:' || coalesce(NEW.rule_key, '?'));
  RETURN NULL; -- AFTER trigger; return value ignored
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS event_alerts_broadcast ON public.event_alerts;
CREATE TRIGGER event_alerts_broadcast
  AFTER INSERT ON public.event_alerts
  FOR EACH ROW EXECUTE FUNCTION public.trg_event_alerts_broadcast();

-- 3) event_movers_index: metrics recompute (upsert / last_computed_at bump) → ping.
--    DELETE (stale-row eviction) deliberately does NOT fire — we don't want a
--    "dirty" ping when an event simply drops out of the movers slot.
CREATE OR REPLACE FUNCTION public.trg_event_movers_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $fn$
BEGIN
  PERFORM public.broadcast_event_dirty(NEW.event_id, 'movers');
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS event_movers_broadcast ON public.event_movers_index;
CREATE TRIGGER event_movers_broadcast
  AFTER INSERT OR UPDATE ON public.event_movers_index
  FOR EACH ROW EXECUTE FUNCTION public.trg_event_movers_broadcast();

-- ── Manual verification (run AFTER apply) ───────────────────────────────────
-- With the event page open at ?event=<ID>, fire a test ping and confirm the
-- LIVE pill flashes "updating…" and the page re-renders:
--   SELECT public.broadcast_event_dirty(<ID>, 'manual-test');
