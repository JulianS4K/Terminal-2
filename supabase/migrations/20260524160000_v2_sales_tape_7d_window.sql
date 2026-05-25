-- 20260524160000_v2_sales_tape_7d_window.sql
--
-- ## Already applied to prod — applied live via MCP execute_sql 2026-05-24
--   (operator-directed hotfix for an ACTIVE user-facing timeout: "issue with
--   terminal, canceling statement due to statement timeout"). This file captures
--   the live change so repo↔prod stay in sync.
--   Post-apply verified: v2 contains 0× `interval '30 days'` and exactly 1×
--   `sale_at_utc > now() - interval '7 days'`; warm get_broker_event_page_v3(3091419,168)
--   = 544 ms (EXPLAIN ANALYZE), down from >8s cold-cache timeout.
--   A1: please push this file to main (sole-pusher) so repo↔prod stay in sync.
--
-- D0 (operator-directed; crosses into A1's migration domain via the bot_chat
-- override path — "fix and test" / live-timeout report, 2026-05-24).
--
-- PROBLEM (audit 2026-05-24): get_broker_event_page_v2()'s `sales_tape` block
--   builds a recent-sales tape by deduping public.seatgeek_sales_snapshots with
--   DISTINCT ON (sg_sale_id) ... ORDER BY sg_sale_id, pulled_at DESC, windowed at
--   `sale_at_utc > now() - interval '30 days'`. For a HOT event the firehose is
--   pathologically duplicated: tevo 3091419 has 315,284 snapshot rows for just
--   862 distinct sales (~366× re-snapshot), 300,138 of them pulled in the last 7d.
--   The 30-day DISTINCT ON sort over that firehose blows past PostgREST's 8s
--   statement_timeout on a cold cache, so opening a hot event in the terminal
--   intermittently renders "canceling statement due to statement timeout"
--   (first open cold = timeout; refresh warm = fine). v3 calls v2, so v3 inherits it.
--
-- FIX: window the sales_tape dedup to 7 days, mirroring the sg_broker_sales 7d
--   window already shipped in 20260524140000_v3_sg_broker_sales_7d_window.sql.
--   Cuts the dedup input from 315,284 -> 53,175 rows (289 distinct) for this
--   event (~6× less heap to sort) while preserving the LIMIT 20 most-recent tape
--   (a 7-day lookback is ample for "recent sales"). The change is the single
--   FROM-window literal; the rest of the v2 body is byte-identical.
--
-- WHY A DO-BLOCK (not CREATE OR REPLACE): get_broker_event_page_v2 is a ~13KB
--   canonical SECDEF RPC (PROJECT_BIBLE §canonical-RPCs). Hand-reproducing the
--   full body risks transcription drift. This patch reads the live definition,
--   asserts the target window appears exactly once, and rewrites just that
--   literal — surgical and self-verifying. Idempotent: if the def already carries
--   the 7d window (prod, post-live-apply) it logs and skips.
--
-- RESIDUAL (NOT fixed here — checkpoint item): the firehose itself is still
--   scanned live per request; cold-cache first-hits on the very hottest events
--   remain a tail risk. The durable fix is a deduped sales-rollup matview (the
--   PROJECT_BIBLE §3 "use the matview, don't scan the firehose" pattern, cf.
--   mv_sg_blindspot_movers). That crosses the canonical base get_broker_event_page
--   and is deferred to a checkpoint migration, not hand-hacked here.
--
-- ROLLBACK: re-run this block with the 7<->30 day literals swapped (or restore
--   get_broker_event_page_v2 from the prior definition migration).

DO $patch$
DECLARE
  v_def  text;
  v_new  text;
  v_hits int;
  v_old_window CONSTANT text := 'sale_at_utc > now() - interval ''30 days''';
  v_new_window CONSTANT text := 'sale_at_utc > now() - interval ''7 days''';
BEGIN
  v_def := pg_get_functiondef('public.get_broker_event_page_v2(integer,integer)'::regprocedure);

  -- count occurrences of the 30-day sales_tape window
  v_hits := (length(v_def) - length(replace(v_def, v_old_window, ''))) / length(v_old_window);

  IF v_hits = 0 THEN
    -- already windowed to 7d (prod, post-live-apply) — nothing to do
    IF position(v_new_window IN v_def) > 0 THEN
      RAISE NOTICE 'get_broker_event_page_v2 sales_tape already on 7d window — skipping (idempotent).';
      RETURN;
    END IF;
    RAISE EXCEPTION 'get_broker_event_page_v2: neither 30d nor 7d sales_tape window found — definition drifted; aborting to avoid a blind rewrite.';
  ELSIF v_hits > 1 THEN
    RAISE EXCEPTION 'get_broker_event_page_v2: expected exactly one "%s" occurrence, found % — aborting.', v_old_window, v_hits;
  END IF;

  -- exactly one occurrence: rewrite just that literal and re-create
  v_new := replace(v_def, v_old_window, v_new_window);
  EXECUTE v_new;
  RAISE NOTICE 'get_broker_event_page_v2 sales_tape window rewritten 30d -> 7d.';
END
$patch$;
