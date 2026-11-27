-- target_events 310 -> 341.
-- Operator 2026-11-26: "assuming we do 8300 daily cap, how many events can we pull with current
-- cadances?" -> 341, then "Add more events to hit 341".
--
-- THE ARITHMETIC, computed against the real bands the next catalogue events would get rather
-- than an average. The next 31 reach out to 61 days, so every one lands on the 60-minute band:
-- one read an hour, about 24 credits a day each.
--     now          310 events   313.0 reads/hour   7,535 credits/day
--     at 341       341 events   344.0 reads/hour   8,281 credits/day
--     342 breaks it             345.0              8,305
--
-- A SECOND WORKER IS NOT NEEDED AND WOULD NOT HELP. 344 reads/hour sits under the measured
-- usable throughput of 377/hour with 33/hour spare, so at this cap CREDITS bind and throughput
-- does not. The queue is demand-bounded — axs_queue_fill enqueues an event only when its
-- next_poll_at has arrived — so two workers would read the same 344/hour that one reads. The
-- second reader only becomes worth building if the monthly pool goes past about 315k/month,
-- which would put ~374 events inside the credit line and make 377/hour the binding ceiling.
-- Tested in s24; not built.
--
-- TWO THINGS THE OPERATOR SHOULD WEIGH, recorded here because they are not visible from the
-- target number alone:
--
-- 1. 8,281/day FITS 8,300 BUT EXCEEDS THE SYSTEM'S OWN CAP NEXT CYCLE. axs_watch_budget()
--    computes daily_cap = floor((pool_remaining - reserve_credits) / days_left). From a full
--    pool over a 30-day cycle that is (250,000 - 5,000)/30 = 8,167, and over a 31-day cycle
--    8,065. The operator's 8,300 is 250,000/30 with the 5,000 reserve treated as usable slack.
--    So from 2026-12-18 the budget gate would begin refusing reads late in each Eastern day
--    unless daily_cap_override is set at 8,300 or above, or the list is trimmed. The numbers
--    that fit the system's own formula are 336 events (8,160/day) for a 30-day cycle and 332
--    (8,064/day) for a 31-day one. THIS CYCLE is unaffected: the cap is 10,419 because the
--    first eight days spent only 15,690, so 8,281 is 79% of it.
--
-- 2. THE MARGIN AT 341 IS 19 CREDITS A DAY against the 8,300 line — about half an hour of one
--    event. A TicketsData timeout returns HTTP 200 after 20 seconds and IS billed, so a bad
--    AXS hour eats that margin. 330 events (8,016/day) would keep ~280 credits/day of slack.
--
-- The mix also drifts upward on its own: an event crossing from the 60-minute band to 30
-- minutes doubles its own cost, so the 341 figure is a ceiling that erodes as December arrives.
-- The pacer's brake would absorb that by slowing every band — the behaviour migs 20261126053000
-- and 20261126163000 exist to keep honest — so the operator should expect to revisit the target
-- rather than treat 341 as settled.
--
-- No new code: the fill's backfill arm picks the extra 31 soonest-first across the 28 keep_all
-- venues, exactly as it did for the 46 the tour exclusion freed.

BEGIN;

DO $guard$
DECLARE v_old integer; v_new integer := 341; v_usable integer; v_demand numeric;
BEGIN
  SELECT target_events INTO v_old FROM public.axs_watch_config;
  IF v_old IS NULL THEN RAISE EXCEPTION 'target_events is NULL'; END IF;
  IF v_old = v_new THEN
    RAISE NOTICE 'target_events already %, nothing to change', v_new;
    RETURN;
  END IF;

  UPDATE public.axs_watch_config SET target_events = v_new, updated_at = now() WHERE id;

  -- the new target must still fit measured throughput, or the pacer's brake engages and every
  -- band slows — which is the failure migs 20261126053000 / 20261126163000 exist to prevent
  SELECT (public.axs_watch_pace()->>'usable_per_hour')::integer INTO v_usable;
  IF v_usable IS NOT NULL AND v_usable < 344 THEN
    RAISE WARNING 'measured usable_per_hour is % against a demand of ~344 at % events — the brake may engage',
                  v_usable, v_new;
  END IF;
  RAISE NOTICE 'target_events % -> %; usable_per_hour %', v_old, v_new, v_usable;
END $guard$;

COMMIT;
