-- Migration 20260928190000 · level:secondary-sales · lane:A1 (operator-routed to D7; A1 retired) · writes:sg_events_canonical,seatgeek_orders,cron.job,n2s_pull_events · reads:seatgeek_orders · pre:20260928174500
--
-- Already applied to prod · via MCP 2026-09-28 ~18:40 UTC under operator direction
-- ("yes build it, test first"), after two rolled-back dry runs (backfill 1.0 s,
-- 332 events seeded, 0 raw ids left unfilled; the majority-vote variant was
-- rejected for the unanimous one — see CHANGE 3). bot_chat #4538.
--
-- ============================================================================
-- Register SeatGeek events from our own SeatGeek orders, so their ids resolve
-- and N2S can pull SeatGeek listings for them.
--
-- FOUND (2026-09-28, order k9l9brp580m, $uicideboy$ @ Cascades, 203/D x2):
-- SeatGeek had two 203/D pairs ($311.55 / $379.88) but N2S never pulled
-- SeatGeek for the event, because TEvo 3349564 had no SeatGeek link. The link
-- was in our own data: another SeatGeek order for the same show carries
-- raw.event.seatgeek_event_id = 18155878, but seatgeek_orders.sg_event_id is
-- NULL. That column has an FK to sg_events_canonical, and the event was never
-- registered there — so seatgeek_orders_recover_event_id() (cron 659, every
-- 15 min) cannot fill it (it requires the canonical row to exist).
--
-- sg_canonical_seed_from_orders() does exactly that registration, but nothing
-- ever scheduled it: 332 SeatGeek events waiting at the time of writing; 691
-- SeatGeek orders over 7 days had the id only in raw; 33 of 859 mapped N2S
-- orders over 7 days (~4%) had no SeatGeek link at all.
--
-- CHANGE
--   1. Run the seed + recovery once now (backfill).
--   2. Cron 659 (id_spine_tick_15min) runs the seed immediately before the
--      recovery, every tick. Anchored text insert, guarded.
--   3. n2s_pull_events resolves a SeatGeek event id from seatgeek_orders as a
--      third fallback (after sg_events_canonical.tevo_event_id and
--      aq_event_map), ONLY when every SeatGeek order on that TEvo event names
--      the same SeatGeek event. Not a majority vote: 24 TEvo events have orders
--      on 2+ SeatGeek events (parking, round-1 vs round-2, and one where 3 orders
--      were mis-mapped to a different artist's show) and a majority would pick
--      the wrong event there.
--      Seeded canonical rows carry no tevo_event_id (the terminal's matchers
--      own that), so without this N2S still would not find them. md5-guarded.
-- Reads only our own tables; no upstream call.
-- ============================================================================

-- 1. backfill now
SELECT public.sg_canonical_seed_from_orders(true);
SELECT public.seatgeek_orders_recover_event_id(true);

-- 2. cron 659 seeds before it recovers
DO $mig$
DECLARE v_cmd text; v_new text;
BEGIN
  SELECT command INTO v_cmd FROM cron.job WHERE jobid = 659 AND jobname = 'id_spine_tick_15min';
  IF v_cmd IS NULL THEN RAISE EXCEPTION 'cron 659 id_spine_tick_15min not found'; END IF;
  IF v_cmd LIKE '%sg_canonical_seed_from_orders%' THEN
    RAISE NOTICE 'cron 659 already seeds; skipped';
  ELSE
    IF (SELECT count(*) FROM regexp_matches(v_cmd, 'PERFORM public\.seatgeek_orders_recover_event_id\(true\);', 'g')) <> 1 THEN
      RAISE EXCEPTION 'cron 659: recovery anchor not found exactly once';
    END IF;
    v_new := replace(v_cmd,
      'PERFORM public.seatgeek_orders_recover_event_id(true);',
      'PERFORM public.sg_canonical_seed_from_orders(true);   -- mig 20260928190000' || E'\n      '
      || 'PERFORM public.seatgeek_orders_recover_event_id(true);');
    PERFORM cron.alter_job(659, command := v_new);
  END IF;
END $mig$;

-- 3. n2s_pull_events: third SeatGeek id fallback via our SeatGeek orders
DO $mig$
DECLARE v_def text; v_new text;
BEGIN
  v_def := pg_get_functiondef('public.n2s_pull_events(bigint[], interval)'::regprocedure);
  IF md5(v_def) <> '11caad0f48204f9f107941dfd2e1ae8c' THEN
    RAISE EXCEPTION 'n2s_pull_events changed since this migration was written (md5 %)', md5(v_def);
  END IF;
  v_new := replace(v_def,
$a$                     WHERE a.tevo_event_id = w.tevo_event_id AND a.sg_event_id IS NOT NULL
                     ORDER BY a.sg_event_id LIMIT 1)) AS sg_event_id$a$,
$b$                     WHERE a.tevo_event_id = w.tevo_event_id AND a.sg_event_id IS NOT NULL
                     ORDER BY a.sg_event_id LIMIT 1),
                   -- mig 20260928190000: our own SeatGeek orders for the event,
                   -- only when they all agree on one SeatGeek event
                   (SELECT min(o.sg_event_id) FROM public.seatgeek_orders o
                     WHERE o.tevo_event_id = w.tevo_event_id AND o.sg_event_id IS NOT NULL
                    HAVING count(DISTINCT o.sg_event_id) = 1)) AS sg_event_id$b$);
  IF v_new = v_def THEN RAISE EXCEPTION 'n2s_pull_events: anchor not found'; END IF;
  EXECUTE v_new;
END $mig$;

-- rollback:
--   cron.alter_job(659, command := <command without the sg_canonical_seed_from_orders line>);
--   re-create n2s_pull_events without the third COALESCE branch (20260928153000 state);
--   seeded sg_events_canonical rows (raw_event_jsonb->>'seeded_from' = 'seatgeek_orders')
--   and the filled seatgeek_orders.sg_event_id (sg_event_id_source = 'raw_backfill')
--   are correct data and are not rolled back.
