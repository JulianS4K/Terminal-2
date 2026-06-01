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
--   * We emit a tiny, DATA-FREE Broadcast carrying only {event_id, reason, at}.
--     The client re-pulls the existing email-gated RPC (get_broker_event_page_v3)
--     and re-renders, so all data access stays behind the @s4kent.com JWT gate.
--     The ping itself leaks nothing beyond "event N is dirty".
--   * Public topic ("event:<id>", private=false) → the static-site anon client
--     subscribes with just the publishable key; no RLS on realtime.messages is
--     required (private channels are out of scope for this slice).
--   * The trigger body swallows any Realtime error so a collector INSERT can
--     never fail because of a broadcast hiccup.
--
-- EFFECTS CHECK (live prod read, 2026-06-01) — this is why the trigger is gated:
--   event_alerts takes ~45.5k INSERTs/24h, but 94% are severity='info'
--   (44.5k/24h across 2.5k events — arbitrage_opportunity etc.); only warn
--   (~1k/24h) and critical (~12/24h) are page-worthy. Broadcasting every insert
--   would add ~45k mostly-subscriber-less realtime.send calls/day to a hot
--   collector path. So the trigger fires ONLY for warn/critical via a WHEN
--   clause — info rows never even call the function. Net: ~1k pings/24h.
--
--   event_movers_index was last computed 2026-05-30 (2.5d stale at authoring)
--   and, when its cron does run, upserts the whole top-N (~850 rows) in one
--   burst. A blanket trigger there is both dead-now and bursty-later, so we do
--   NOT attach one. The generic broadcast_event_dirty() helper below is instead
--   the intended one-line hook for the per-event metrics-refresh path (A1 can
--   add `PERFORM public.broadcast_event_dirty(v_event_id, 'metrics');` inside
--   the SG/EVO per-event recompute when ready) — that fires once per genuinely
--   updated event, which is the right granularity.
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

-- 2) event_alerts → ping the event, but ONLY for page-worthy severities.
--    The WHEN clause keeps the 94% info-level firehose from ever calling us.
CREATE OR REPLACE FUNCTION public.trg_event_alerts_broadcast()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $fn$
BEGIN
  PERFORM public.broadcast_event_dirty(NEW.tevo_event_id, 'alert:' || coalesce(NEW.severity, '?'));
  RETURN NULL; -- AFTER trigger; return value ignored
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS event_alerts_broadcast ON public.event_alerts;
CREATE TRIGGER event_alerts_broadcast
  AFTER INSERT ON public.event_alerts
  FOR EACH ROW
  WHEN (NEW.severity IN ('warn', 'critical') AND NEW.tevo_event_id IS NOT NULL)
  EXECUTE FUNCTION public.trg_event_alerts_broadcast();

-- ── Manual verification (run AFTER apply) ───────────────────────────────────
-- With the event page open at ?event=<ID>, fire a test ping and confirm the
-- LIVE pill flashes "updating…" and the page re-renders:
--   SELECT public.broadcast_event_dirty(<ID>, 'manual-test');
--
-- And confirm the gate works — an info alert must NOT ping, a warn alert must:
--   (observe realtime traffic on topic event:<ID> while each fires)
