-- ============================================================================
-- Migration 20260910080000 — N2S gets its OWN TicketsData budget: 500/day
--
-- Lane:     D0 (orders surface) over A1's TicketsData plane
-- Touches:  n2s_td_credits_today(), n2s_td_budget_ok(), n2s_td_drain() (new),
--           one cron. Does NOT alter td_budget_ok(), td_pull_drain(), or any
--           existing TicketsData cron.
-- Pre-reqs: 20260910070000
--
-- Upstream: GET https://ticketsdata.com/fetch only — a read. RULE 2 holds.
--
-- Operator direction 2026-09-09: "override td budget for this, budget for
-- separate system" / "cap this budget at 500 daily."
--
-- ── ⚠ THIS IS A DELIBERATE, OPERATOR-AUTHORISED SPEND CARVE-OUT ────────────
-- TicketsData is a PAID, credit-metered API. Until now the N2S pipeline sat
-- behind the shared td_budget_ok() guard, and its 16 on-demand pulls were
-- correctly refusing to fire because the shared daily budget was spent
-- (5,899 credits). The operator has authorised N2S to bypass that shared
-- guard AND set its own hard cap of 500/day.
--
-- ⚠ THE SHARED GUARD IS NOT WEAKENED. td_budget_ok(), td_daily_budget_ok(),
-- td_pull_drain() and every existing TicketsData cron are untouched. This adds
-- a SEPARATE, narrower lane that drains ONLY rows tagged 'n2s_ondemand'.
-- Nothing else in the system gains any additional spending power. Anyone
-- tempted to "simplify" this by relaxing td_budget_ok() itself would be
-- removing the cap on the whole platform, not just this pipeline.
--
-- ── The cap is counted in FIRES, and why ───────────────────────────────────
-- One /fetch call costs one credit: measured over today's 7,250 fired queue
-- rows, credits_used averages exactly 1.00. But credits_used is only written
-- once a pull RESOLVES, so budgeting on it would ignore everything currently
-- in flight and could overshoot under concurrency. Counting FIRES instead is
-- conservative in the right direction — an in-flight pull already counts
-- against the cap, so 500 can be approached but not blown through.
-- Day boundary is (fired_at AT TIME ZONE 'UTC')::date = CURRENT_DATE, matching
-- td_credits_today() exactly rather than inventing a second notion of "today".
--
-- ⚠ THE SHARED DRAIN ALSO FIRES n2s_ondemand ROWS, AND THOSE STILL COUNT HERE.
-- td_pull_drain() selects any unfired row regardless of tag, so when the shared
-- budget is healthy it may fire N2S rows on the shared dime. Those fires are
-- still tagged 'n2s_ondemand' and so still count against this 500. That
-- under-serves N2S slightly rather than overspending, which is the correct
-- direction for a spend guard to err, and is why it is left alone.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_td_credits_today()
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
  -- FIRES, not resolved credits: see header. Counts in-flight pulls too.
  SELECT count(*)::integer
    FROM public.td_pull_queue
   WHERE interval_tag = 'n2s_ondemand'
     AND fired_at IS NOT NULL
     AND (fired_at AT TIME ZONE 'UTC')::date = CURRENT_DATE;
$function$;

CREATE OR REPLACE FUNCTION public.n2s_td_budget_ok(p_cap integer DEFAULT 500)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
  SELECT public.n2s_td_credits_today() < p_cap;
$function$;

COMMENT ON FUNCTION public.n2s_td_budget_ok(integer) IS
  'The N2S pipeline''s OWN TicketsData daily cap (default 500 fires/UTC day), '
  'separate from and deliberately independent of td_budget_ok(). Operator-'
  'authorised 2026-09-09. Does NOT relax the shared guard, which still governs '
  'every other TicketsData caller.';

-- ── the N2S-only drain ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_td_drain(
  p_max integer DEFAULT 10,
  p_cap integer DEFAULT 500
)
RETURNS TABLE(fired integer, remaining_today integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  r        RECORD;
  v_user   text;
  v_pass   text;
  v_req    bigint;
  v_count  int := 0;
  v_head   int;
BEGIN
  -- N2S's OWN cap. td_budget_ok() is deliberately NOT consulted here — that is
  -- the authorised override. This lane's spend is bounded by p_cap alone.
  v_head := p_cap - public.n2s_td_credits_today();
  IF v_head <= 0 THEN
    RAISE NOTICE 'n2s_td_drain: N2S daily cap of % reached; skipping', p_cap;
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'n2s_td_drain: TICKETSDATA creds missing from vault';
  END IF;

  FOR r IN
    SELECT q.id, q.event_id, q.platform, q.event_url
      FROM public.td_pull_queue q
     WHERE q.interval_tag = 'n2s_ondemand'   -- THIS LANE ONLY
       AND q.fired_at IS NULL
       AND q.resolved_at IS NULL
     ORDER BY q.created_at ASC               -- newest subs queue last, drain FIFO
     LIMIT LEAST(p_max, v_head)              -- never exceed remaining headroom
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/fetch',
      params := jsonb_build_object(
                  'platform',  public.td_api_platform(r.platform),
                  'event_url', r.event_url,
                  'username',  v_user,
                  'password',  v_pass),
      headers := '{}'::jsonb,
      timeout_milliseconds := 35000) INTO v_req;

    UPDATE public.td_pull_queue
       SET request_id = v_req, fired_at = clock_timestamp()
     WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN QUERY SELECT v_count, GREATEST(p_cap - public.n2s_td_credits_today(), 0);
END $function$;

COMMENT ON FUNCTION public.n2s_td_drain(integer, integer) IS
  'Fires ONLY td_pull_queue rows tagged n2s_ondemand, bounded by the N2S '
  'pipeline''s own daily cap rather than td_budget_ok(). Operator-authorised '
  'override 2026-09-09, capped at 500/day. Every other TicketsData caller '
  'still goes through the untouched shared guard.';

REVOKE ALL ON FUNCTION public.n2s_td_credits_today() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.n2s_td_budget_ok(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.n2s_td_drain(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_td_credits_today() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.n2s_td_budget_ok(integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.n2s_td_drain(integer, integer) TO service_role;

-- Every 2 minutes, in step with the enqueue (cron 599). At 10 per run that is
-- a ceiling of 300/hour, so the 500/day cap — not the cadence — is the binding
-- constraint, which is the intended shape.
SELECT cron.schedule(
  'n2s_td_drain_2min', '*/2 * * * *',
  $cron$ SELECT public.n2s_td_drain(); $cron$
);

-- ── ⚠ CIRCUIT BREAKER: THE VENDOR QUOTA IS REAL, NOT JUST OUR GUARD ────────
-- Discovered by firing this lane for the first time: all 10 pulls returned
-- HTTP 403 {"detail":"Quota exhausted"} — from TicketsData's SERVER. The
-- shared td_budget_ok() was not merely a local policy knob; it mirrors an
-- actual account quota, and it is well calibrated (it flipped false at 5,899
-- credits, which is where the vendor also started refusing).
--
-- So OVERRIDING OUR GUARD DOES NOT CREATE QUOTA. The operator-authorised
-- 500/day cap is real and enforced, but it can only be SPENT on days where the
-- account still has vendor quota left. Without the breaker below, the 2-minute
-- cron would burn the whole 500-slot allowance on 403s in under a day and the
-- lane would be dead when quota actually returned.
--
-- Good news, measured: a 403 quota rejection charges NOTHING —
-- ticketsdata_credit_usage recorded no new row for those 10 calls. The cost of
-- the discovery was slots, not money.
--
-- The breaker skips firing while a recent n2s_ondemand pull came back quota-
-- exhausted, and the reset below returns wasted slots so the cap measures real
-- spend rather than rejected attempts.
CREATE OR REPLACE FUNCTION public.n2s_td_drain(
  p_max integer DEFAULT 10,
  p_cap integer DEFAULT 500,
  p_backoff interval DEFAULT interval '30 minutes'
)
RETURNS TABLE(fired integer, remaining_today integer, quota_blocked boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  r        RECORD;
  v_user   text;  v_pass text;  v_req bigint;
  v_count  int := 0;
  v_head   int;
  v_quota  boolean;
BEGIN
  -- Don't hammer a wall: if the vendor said "Quota exhausted" recently, stop.
  SELECT EXISTS (
    SELECT 1 FROM public.td_pull_queue q
     WHERE q.interval_tag = 'n2s_ondemand'
       AND q.resolved_at > now() - p_backoff
       AND q.error_msg = 'quota_exhausted'
  ) INTO v_quota;

  IF v_quota THEN
    RAISE NOTICE 'n2s_td_drain: vendor quota exhausted recently; backing off';
    RETURN QUERY SELECT 0, GREATEST(p_cap - public.n2s_td_credits_today(), 0), true;
    RETURN;
  END IF;

  v_head := p_cap - public.n2s_td_credits_today();
  IF v_head <= 0 THEN
    RAISE NOTICE 'n2s_td_drain: N2S daily cap of % reached; skipping', p_cap;
    RETURN QUERY SELECT 0, 0, false; RETURN;
  END IF;

  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'n2s_td_drain: TICKETSDATA creds missing from vault';
  END IF;

  FOR r IN
    SELECT q.id, q.event_id, q.platform, q.event_url
      FROM public.td_pull_queue q
     WHERE q.interval_tag = 'n2s_ondemand'
       AND q.fired_at IS NULL AND q.resolved_at IS NULL
     ORDER BY q.created_at ASC
     LIMIT LEAST(p_max, v_head)
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/fetch',
      params := jsonb_build_object(
                  'platform',  public.td_api_platform(r.platform),
                  'event_url', r.event_url,
                  'username',  v_user,
                  'password',  v_pass),
      headers := '{}'::jsonb,
      timeout_milliseconds := 35000) INTO v_req;
    UPDATE public.td_pull_queue
       SET request_id = v_req, fired_at = clock_timestamp() WHERE id = r.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN QUERY SELECT v_count,
                      GREATEST(p_cap - public.n2s_td_credits_today(), 0),
                      false;
END $function$;

DROP FUNCTION IF EXISTS public.n2s_td_drain(integer, integer);

REVOKE ALL ON FUNCTION public.n2s_td_drain(integer, integer, interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_td_drain(integer, integer, interval) TO service_role;

-- ⚠ THE BREAKER NEEDS A DURABLE SIGNAL, AND THE OBVIOUS FIX DESTROYS IT.
-- The first attempt at reclaiming wasted slots set fired_at = NULL on the
-- rejected rows. That looks right -- no data was fetched, so the slot should
-- not count -- but it erases exactly what the breaker reads (a recent fire
-- whose response was a quota 403), so the very next cron tick fires straight
-- back into the wall. Reclaiming the slot and remembering the rejection are
-- the same fact stored two ways, and one must not delete the other.
--
-- So rejected pulls stay FIRED and are marked RESOLVED with status_code 403.
-- The breaker reads those. The cap excludes them, because a refused call
-- fetched nothing and (measured) was charged nothing.
CREATE OR REPLACE FUNCTION public.n2s_td_sweep()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  -- Scoped by request_id to a handful of rows: joining net._http_response
  -- unscoped is slow enough to blow the statement budget on this project.
  UPDATE public.td_pull_queue q
     SET resolved_at = now(),
         status_code = x.status_code,
         error_msg   = CASE WHEN x.status_code = 403 AND x.content ILIKE '%quota%'
                            THEN 'quota_exhausted' ELSE q.error_msg END
    FROM net._http_response x
   WHERE x.id = q.request_id
     AND q.interval_tag = 'n2s_ondemand'
     AND q.resolved_at IS NULL
     AND q.request_id IS NOT NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_td_sweep() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_td_sweep() TO service_role;

-- Cap counts only pulls that actually reached the vendor: a quota refusal
-- fetched nothing and charged nothing, so it must not consume the allowance.
CREATE OR REPLACE FUNCTION public.n2s_td_credits_today()
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
  SELECT count(*)::integer
    FROM public.td_pull_queue
   WHERE interval_tag = 'n2s_ondemand'
     AND fired_at IS NOT NULL
     AND (fired_at AT TIME ZONE 'UTC')::date = CURRENT_DATE
     AND COALESCE(error_msg, '') <> 'quota_exhausted';
$function$;

-- Sweep then drain, in that order, every 2 minutes: the sweep turns responses
-- into the durable quota marker the drain's breaker reads.
SELECT cron.unschedule('n2s_td_drain_2min');
SELECT cron.schedule(
  'n2s_td_drain_2min', '*/2 * * * *',
  $cron$
    SELECT public.n2s_td_sweep();
    SELECT public.n2s_td_drain();
  $cron$
);
