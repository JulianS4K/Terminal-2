-- The pacer measures the READ, not the queue wait.
-- Operator 2026-11-26: "apply fixes".
--
-- Self-inflicted, found by the 16:21Z monitor run. axs_watch_pace derives capacity from
--   s_per_read   = greatest(settle_p50 + 1.0, spacing_s)
--   usable/hour  = floor(3600 / s_per_read * pace_target_pct / 100)
-- where settle_p50 is the median of checked_at - fired_at.
--
-- Until today fired_at was the moment the read was SENT, so settle was the read's own
-- duration. mig 20261126124500 (the queue ack's ledger row) set it to
-- least(coalesce(release_at, claimed_at, now()), now()); at ack time now() is already past
-- release_at, so fired_at IS release_at — the pacer's permission slot. axs_queue_claim hands
-- those slots out read_spacing_ms apart (3 s) as if the reads ran in parallel, but
-- core/axs_watch_reader.run_queue reads its claimed batch SERIALLY at ~6.4 s each, so with
-- queue_lanes 6 the later items in a batch sit waiting and settle absorbs that wait.
--
-- Measured at 16:2xZ: settle_p50 9.4 s, settle_p90 19.4 s, response_p50 6.4 s. The 3.0 s gap
-- is queue wait. It cost 126 usable reads an hour:
--   current  s_per_read 10.4 -> 347/h -> usable 260  <  demand 333  -> brake engages
--   honest   s_per_read  7.4 -> 486/h -> usable 365  >  demand 333  -> no brake
-- so the hourly pacer set cadence_scale 1.0 -> 1.68 and the operator's 30/60/90-minute bands
-- began running at roughly 50/101/151 minutes: demand_per_day 4,779 against the 7,992 the
-- bands specify, events read about 40% less often than asked. Completed throughput never
-- changed (352 reads/hour measured, reads_per_hour 347) — only the measure moved. And it could
-- not self-restore, because the hysteresis only unwinds when usable >= demand and usable
-- cannot recover while fired_at carries the wait.
--
-- The fix is to measure the thing that actually costs time. response_s is TicketsData's own
-- elapsed_seconds for that read: the true per-read cost, and already selected in this
-- function as response_p50. A read that timed out upstream reports its real ~20 s, so slow
-- reads still show up; only a 'lost' read (no response at all) has response_s NULL, which is
-- what the coalesce chain to settle_p50 and then 9.0 is for. The spacing floor is unchanged,
-- so the pacer can never claim to go faster than TicketsData's 3-second rule allows.
--
-- IT IS READER-AWARE, and that is not caution for its own sake. On the worker path the wait
-- is scheduling slack we chose, so response_s is the honest cost. On the db-fires path
-- (axs_watch_tick, reader <> 'worker') fired_at is set when net.http_get is CALLED and the
-- request can then sit in pg_net's own queue, which has a fixed worker budget: there the wait
-- is real capacity and must keep counting, and response_s — the browser run time TicketsData
-- reports — would not show it. So the worker path measures the read and the db path keeps
-- measuring the settle. s04 section C caught this: it simulates a slow reader by stretching
-- checked_at alone and leaving response_s at 6.4, which is precisely the queue artifact's
-- shape, so under a reader-blind fix it stopped testing anything. Its fixture now raises
-- response_s too, which is what a genuinely slow reader looks like.
--
-- One expression, in one function. axs_watch_pace_apply consumes s_per_read and
-- usable_per_hour from here (it reads settle_p50_s only for its note), and
-- axs_watch_cadence_demand calls axs_watch_pace(), so both follow without being touched.
-- settle_p50_s and settle_p90_s stay in the output: the gap between settle and response is
-- how this was diagnosed and is worth keeping visible.

BEGIN;

DO $surgery$
DECLARE v_src text; v_new text; v_hits integer;
  v_old text := 'greatest(coalesce(m.settle_p50, 9.0) + 1.0, CASE WHEN cfg.reader = ''worker'' THEN cfg.read_spacing_ms / 1000.0 ELSE 15.0 END) AS s_per_read';
  v_rep text := 'greatest(coalesce(CASE WHEN cfg.reader = ''worker'' THEN m.response_p50 END, m.settle_p50, 9.0) + 1.0, CASE WHEN cfg.reader = ''worker'' THEN cfg.read_spacing_ms / 1000.0 ELSE 15.0 END) AS s_per_read';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_pace';
  IF v_src IS NULL THEN RAISE EXCEPTION 'axs_watch_pace not found'; END IF;

  SELECT count(*) INTO v_hits FROM regexp_matches(v_src, regexp_replace(v_old, '([.()*+?\[\]^$\\|{}])', '\\\1', 'g'), 'g');
  IF v_hits <> 1 THEN RAISE EXCEPTION 'axs_watch_pace s_per_read: expected 1 site, found %', v_hits; END IF;

  v_new := replace(v_src, v_old, v_rep);
  IF v_new = v_src THEN RAISE EXCEPTION 'axs_watch_pace unchanged — surgery did nothing'; END IF;
  EXECUTE v_new;

  SELECT pg_get_functiondef(p.oid) INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='axs_watch_pace';
  IF v_src !~ 'coalesce\(CASE WHEN cfg\.reader = ''worker'' THEN m\.response_p50 END, m\.settle_p50, 9\.0\) \+ 1\.0' THEN
    RAISE EXCEPTION 'axs_watch_pace did not come back measuring response_p50 on the worker path';
  END IF;
  -- the spacing floor must survive: the pacer may never claim to beat the 3-second rule
  IF v_src !~ 'cfg\.read_spacing_ms / 1000\.0 ELSE 15\.0 END\) AS s_per_read' THEN
    RAISE EXCEPTION 'axs_watch_pace lost its spacing floor';
  END IF;
END $surgery$;

COMMIT;
