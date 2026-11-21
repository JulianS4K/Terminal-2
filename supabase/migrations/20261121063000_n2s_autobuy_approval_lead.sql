-- Migration 20261121063000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_config,n2s_autobuy_enqueue_trg,n2s_autobuy_job_json · reads:n2s_autobuy_exec · pre:20261121060000
--
-- No approval for a cover whose event is more than 24 hours away.
--
-- Operator 2026-11-21: per-order caps raised to $2,000 ("Change per order cover to 2000$ max")
-- and daily caps to $2,500 for each market, then, told that a cover over approval_over_usd
-- ($1,000) still waits for an approval text nobody receives (notify_to is not set): "Remove
-- approval for anything over 24 hours away".
--
-- 1. n2s_autobuy_config.approval_free_lead (interval, default 24 hours): a cover whose event starts
--    at least this long after it is queued never waits for approval; per-order, daily and monthly
--    caps still apply. A cover over approval_over_usd for an event sooner than that still waits.
-- 2. n2s_autobuy_enqueue_trg() (md5-guarded, one anchor): 'awaiting_approval' only when the cost is
--    over approval_over_usd AND the event starts within approval_free_lead of now (or its start is
--    unknown, which is blocked anyway).
-- 3. n2s_autobuy_job_json() (md5-guarded, one anchor): the live worker re-checks approval itself
--    (core/n2s_autobuy_exec.buy_guards: total > approval_over_usd and state <> 'approved' → stop
--    needs_approval). For a row whose event started at least approval_free_lead after the row was
--    queued, the job's approval_over_usd is 1000000000, so the worker's check passes and no Python
--    change is needed; every other row gets approval_over_usd as before.
--
-- VERIFY: SELECT approval_over_usd, approval_free_lead FROM n2s_autobuy_config;
--         SELECT md5(pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure)),
--                md5(pg_get_functiondef('public.n2s_autobuy_job_json(bigint, text)'::regprocedure));
--         -- = the new md5s in the PR body
-- ROLLBACK: UPDATE n2s_autobuy_config SET approval_free_lead = interval '100 years' (approval for
--           every cover over approval_over_usd again), or re-apply both functions as 20261121060000
--           left them (md5 e8875a12eee0503dd1a5b95cd0205a60 and 37b2180b9dde396795f4ad0057942a71).

BEGIN;
SET LOCAL lock_timeout = '10s';

ALTER TABLE public.n2s_autobuy_config
  ADD COLUMN IF NOT EXISTS approval_free_lead interval NOT NULL DEFAULT '24 hours';
COMMENT ON COLUMN public.n2s_autobuy_config.approval_free_lead IS
  'A cover whose event starts at least this long after it is queued never waits for approval, whatever its cost (caps still apply). Operator 2026-11-21: "Remove approval for anything over 24 hours away". 20261121063000.';

DO $do$
DECLARE d text; n int;
  v_trg_old text := $r$WHEN v_cost > c.approval_over_usd THEN 'awaiting_approval'$r$;
  v_trg_new text := $r$WHEN v_cost > c.approval_over_usd
                         -- 20261121063000: no approval when the event is at least approval_free_lead away
                         AND (v_start IS NULL OR v_start < now() + c.approval_free_lead) THEN 'awaiting_approval'$r$;
  v_job_old text := $r$      'approval_over_usd', c.approval_over_usd,$r$;
  v_job_new text := $r$      -- 20261121063000: no approval when the event started at least approval_free_lead after queueing
      'approval_over_usd', CASE WHEN e.event_start_utc >= e.created_at + c.approval_free_lead
                                THEN 1000000000 ELSE c.approval_over_usd END,$r$;
BEGIN
  d := pg_get_functiondef('public.n2s_autobuy_enqueue_trg()'::regprocedure);
  IF md5(d) <> 'e8875a12eee0503dd1a5b95cd0205a60' THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg drifted from 20261121060000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, v_trg_old, ''))) / length(v_trg_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_enqueue_trg: % approval anchors (want 1) — re-derive this migration', n;
  END IF;
  EXECUTE replace(d, v_trg_old, v_trg_new);

  d := pg_get_functiondef('public.n2s_autobuy_job_json(bigint, text)'::regprocedure);
  IF md5(d) <> '37b2180b9dde396795f4ad0057942a71' THEN
    RAISE EXCEPTION 'n2s_autobuy_job_json drifted from 20261121060000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, v_job_old, ''))) / length(v_job_old);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_job_json: % approval anchors (want 1) — re-derive this migration', n;
  END IF;
  EXECUTE replace(d, v_job_old, v_job_new);
END $do$;

COMMIT;
