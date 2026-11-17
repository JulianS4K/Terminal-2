-- Migration 20260928153000 · level:secondary-sales · lane:D7 · writes:n2s_sg_expired,n2s_mkt_drain,n2s_pull_events · reads:n2s_mkt_pull,net._http_response · pre:20260927160500
--
-- Already applied to prod · via MCP 2026-09-28 ~15:40 UTC under operator direction
-- ("skip SeatGeek events that already started" → chose skip-after-expired), after a
-- rolled-back dry run (421006 reply marked the event; a different 400 did not;
-- both function patches present; prod unchanged afterwards).
--
-- ============================================================================
-- Stop re-polling SeatGeek events that SeatGeek has expired.
--
-- Once an event is over, brokerdata.seatgeek.com/listings answers
-- 400 {"error":{"code":421006,"message":"The event with the given event_id has
-- expired"}}. n2s_pull_events kept re-firing those every 2 minutes for as long
-- as an order on the event stayed inside its window (12 of 45 SeatGeek pulls
-- on 2026-09-27 18:37–19:34 UTC).
--
-- WHY NOT SKIP AT START TIME (operator asked, then chose this after the data):
-- SeatGeek keeps selling after the scheduled start. Over the 14 days to
-- 2026-09-28, 60–90 events per half-hour still returned listings 0–4 h after
-- sg_datetime_utc, and the three events that expired on 2026-09-27 did so
-- 1 h 40 m – 4 h after start. A start-time cut would drop real in-game covers.
-- SeatGeek's own "expired" answer is the only reliable signal.
--
-- CHANGE
--   * n2s_sg_expired(sg_event_id) — events SeatGeek has told us are expired.
--   * n2s_mkt_drain: a SeatGeek 400 whose body carries code 421006 records the
--     event there; rows older than 7 days are purged (the event is over).
--   * n2s_pull_events: never fires SeatGeek for an event in n2s_sg_expired.
-- Cost: exactly one wasted call per expired event. EVO / GoTickets unchanged.
-- Both function edits are anchored text replacements, md5-guarded.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.n2s_sg_expired (
  sg_event_id bigint PRIMARY KEY,
  expired_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.n2s_sg_expired ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_sg_expired FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.n2s_sg_expired TO service_role;
COMMENT ON TABLE public.n2s_sg_expired IS
  'SeatGeek events whose listings endpoint answered 421006 "event has expired"; n2s_pull_events skips them. Written by n2s_mkt_drain, purged after 7 days (20260928153000).';

DO $mig$
DECLARE
  v_def text; v_new text;
BEGIN
  -- ── n2s_mkt_drain: record SeatGeek "expired" answers ─────────────────────
  SELECT pg_get_functiondef('public.n2s_mkt_drain()'::regprocedure) INTO v_def;
  IF md5(v_def) <> 'c70d28e7c7932c321a96abf990daa047' THEN
    RAISE EXCEPTION 'n2s_mkt_drain changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  v_new := replace(v_def,
$a$          GET DIAGNOSTICS v_n = ROW_COUNT;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN$a$,
$b$          GET DIAGNOSTICS v_n = ROW_COUNT;
        ELSIF r.status_code = 400 AND r.content LIKE '%421006%' THEN
          -- SeatGeek: "The event with the given event_id has expired" -> stop polling it
          INSERT INTO public.n2s_sg_expired(sg_event_id) VALUES (r.mkt_event_id)
          ON CONFLICT (sg_event_id) DO NOTHING;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN$b$);
  v_new := replace(v_new,
$a$  DELETE FROM public.n2s_sg_current  WHERE pulled_at < now() - interval '1 hour';
$a$,
$b$  DELETE FROM public.n2s_sg_current  WHERE pulled_at < now() - interval '1 hour';
  DELETE FROM public.n2s_sg_expired  WHERE expired_at < now() - interval '7 days';
$b$);
  IF v_new = v_def OR v_new NOT LIKE '%421006%' OR v_new NOT LIKE '%n2s_sg_expired  WHERE expired_at%' THEN
    RAISE EXCEPTION 'n2s_mkt_drain: anchors not found';
  END IF;
  EXECUTE v_new;

  -- ── n2s_pull_events: skip expired SeatGeek events ─────────────────────────
  SELECT pg_get_functiondef('public.n2s_pull_events(bigint[], interval)'::regprocedure) INTO v_def;
  IF md5(v_def) <> 'f264bfd5197d20e48e452057eb2f89b5' THEN
    RAISE EXCEPTION 'n2s_pull_events changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  v_new := replace(v_def,
$a$         WHERE rs.sg_event_id IS NOT NULL
$a$,
$b$         WHERE rs.sg_event_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM public.n2s_sg_expired x WHERE x.sg_event_id = rs.sg_event_id)
$b$);
  IF v_new = v_def THEN
    RAISE EXCEPTION 'n2s_pull_events: anchor not found';
  END IF;
  EXECUTE v_new;
END $mig$;

-- rollback:
--   re-create n2s_mkt_drain and n2s_pull_events from 20260927041700 /
--   20260927042100 (drop the 421006 ELSIF, the 7-day purge and the NOT EXISTS),
--   then DROP TABLE public.n2s_sg_expired;
