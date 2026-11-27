-- Migration 20261127010000 · level:data-collection · lane:a1 (AXS read queue) · writes:axs_watch_config(stale_after) · reads:-
--
-- ============================================================================
-- Migration 20261127010000 — a failed tick must not block the queue for twelve minutes
--
-- Lane:     a1 (AXS read queue)
-- pre:      20261126030000 (the queue and its lease).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- ── THE FAULT, MEASURED ───────────────────────────────────────────────────
-- The reader is NOT slow. Over 791 reads in three hours its steady-state cycle was
--     p50 8.2s   p75 10.2s   p90 11.7s
-- of which 6.3s is TicketsData's own response. At 8.2s a read that is 439 reads an hour,
-- comfortably above the ~344 the bands ask.
--
-- It achieved 256. The whole difference is NINE STALLS:
--     736s 734s 734s 734s 728s 669s 631s 561s 531s   (and smaller ones)
-- Nine gaps over 20s took 61.6 of 175.3 elapsed minutes — 35.2% of the wall clock — while
-- the other 782 reads ran at 8.2s apiece.
--
-- The big stalls are all ~730s, and stale_after is 720s. That is the mechanism:
--   1. axs_queue_claim hands the reader a batch and sets lease_until = release_at + stale_after.
--   2. run_queue reads and acks them one at a time.
--   3. If the tick dies part-way — the ack RPC fails, the database blips, the process is
--      replaced — the REMAINING CLAIMED ITEMS ARE NEVER ACKED.
--   4. They hold their lanes until the lease expires. axs_queue_reap only returns an item
--      once lease_until < now().
--   5. Until then every claim returns 'all lanes busy' and the reader does nothing.
-- One transient error therefore costs twelve minutes of reading, not one read.
--
-- Proven, not inferred: axs_read_queue.attempts is incremented only by the reaper, and
--     106 items carry attempts > 0, 37 of them resolved in the last three hours
-- i.e. about four orphans per stall, against six lanes. At the moment of writing one item sat
-- claimed and unresolved with 682s of lease left while the oldest live claim was 56s old —
-- one lane of six dead for eleven more minutes.
--
-- ── WHAT THIS CHANGES, AND WHAT IT DOES NOT ───────────────────────────────
-- stale_after 12 minutes -> 5. An orphaned batch now clears in five minutes instead of
-- twelve, so the same nine incidents would cost ~15% of the clock rather than 35%.
--
-- It does NOT stop the orphaning. That needs the reader to ack the batch it is abandoning,
-- which is a code change and ships with the reader (core/axs_watch_reader.py). This is the
-- part that works without a deploy.
--
-- ── WHY FIVE MINUTES AND NOT THREE ────────────────────────────────────────
-- The lease must outlast the worst honest case, or an item is reaped while the worker is
-- still going to read it and we pay for the read twice. Worst case: TicketsDataClient is
-- built with timeout=120, so one hung read can take 120s, and the rest of a six-item batch
-- then needs 5 x 8.2s. That is ~161s after the batch starts, against a lease that begins at
-- the item's release slot (at most +18s) and so expires at 18 + 300 = 318s. Two hung reads
-- in one batch still finish at ~273s, inside 318. Three minutes would not clear that margin.
--
-- ── THE OTHER TWO USES OF stale_after, BOTH CHECKED ───────────────────────
-- axs_watch_budget counts in_flight as poll rows with checked_at IS NULL and fired_at inside
--   stale_after. Narrowing the window can only narrow that count, and on the queue path it is
--   always 0 — axs_queue_ack writes the row with checked_at already set. Measured 0 on every
--   reading today.
-- axs_watch_tick declares a read lost when its poll row has no checked_at and is older than
--   stale_after. That is the DB-FIRES path, which runs only while axs_watch_config.reader =
--   'db'; it is 'worker'. And with no open rows there is nothing for it to misjudge.
-- So neither use is harmed. The monitor's own "open reads older than 12 min" check reads the
--   same always-empty set.
--
-- ── WHAT IS NOT DONE HERE, DELIBERATELY: queue_lanes ──────────────────────
-- Raising queue_lanes looks like the obvious companion and is currently the WRONG move. The
-- deployed reader claims every free lane (run_queue with batch=None), so batch size tracks
-- lanes one-for-one: at 12 lanes a failed tick orphans up to 12 items and still blocks
-- everything, just with a bigger blast radius. Lanes only start to help once each loop caps
-- its own batch — which the undeployed second-reader change does (batch = lanes // workers),
-- so that an orphaned batch of six leaves six lanes for the other loop. Raise lanes WITH that
-- deploy, not before it.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- UPDATE public.axs_watch_config SET stale_after = interval '12 minutes';
-- ============================================================================

BEGIN;

DO $guard$
DECLARE v_now interval; v_lanes integer;
BEGIN
  SELECT stale_after, queue_lanes INTO v_now, v_lanes FROM public.axs_watch_config;
  IF v_now IS DISTINCT FROM interval '12 minutes' THEN
    RAISE WARNING 'stale_after is % , not the 12 minutes this migration was written against', v_now;
  END IF;
  -- the margin argument above assumes a batch no larger than the lane count; say so if that
  -- stops being true, because the safe lease length is a function of the batch
  IF v_lanes > 8 THEN
    RAISE EXCEPTION 'queue_lanes is % — recompute the lease margin before shortening it', v_lanes;
  END IF;
END $guard$;

UPDATE public.axs_watch_config SET stale_after = interval '5 minutes'
 WHERE stale_after IS DISTINCT FROM interval '5 minutes';

COMMENT ON COLUMN public.axs_watch_config.stale_after IS
  'How long a claimed queue item keeps its lane before axs_queue_reap hands it back, measured from the item''s release slot (mig 20261126030000). Cut from 12 minutes to 5 by mig 20261127010000: a tick that dies part-way never acks its remaining items, and they blocked every lane for the full lease — nine such stalls cost 35pct of one three-hour window. It must stay comfortably above one hung read (TicketsData timeout 120s) plus the rest of a batch, or an item is reaped while the worker is still going to read it and the read is paid for twice.';

COMMIT;
