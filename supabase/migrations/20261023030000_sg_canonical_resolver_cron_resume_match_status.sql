-- Migration 20261023030000 · level:ops · lane:A1 (data plane — SG→TEvo event mapping) · writes:cron.job(246 via cron.alter_job),sg_events_canonical.match_status(backfill),trg_sgec_match_status_sync()(new) · reads:sg_events_canonical,event_mapper_switch,cron_policy · pre:20260911210000
--
-- ============================================================================
-- Migration 20261023030000 — SG canonical → TEvo: resume the unified resolver
--   cron (246), and make `match_status` mean something again
--
-- Lane:     A1 (data plane). Filed as KANBAN A1-DB-20 from the 2026-10-23
--           mapper investigation (operator: "dig into why the SG pending
--           backlog is skipped").
-- Touches:  cron.job 246 `auto_match_sg_canonical_v3_hourly`
--                                   (W via cron.alter_job: command → single
--                                    statement, schedule :07 → :21, active → true)
--           sg_events_canonical.match_status (W: one-off backfill, 10,999 +
--                                    2 rows; trigger keeps it in step after)
--           trg_sgec_match_status_sync()  (W: new trigger fn + BEFORE trigger)
-- Reads:    event_mapper_switch (sg_events_canonical is `live`, fallback on,
--           cap 400), cron_policy (row for the jobname exists, enabled, has a
--           work_check_sql + daily_max_fires 24 — so cron_should_fire gates it).
-- Pre-reqs: 20260911210000 (event_mapper_run / event_mapper_switch).
--
-- WHY (facts verified read-only on prod 2026-10-23):
--   1. The SG-side mapper is NOT the overnight loop. `sg_canonical_link_overnight`
--      (141) walks from the TEvo side: the 100 soonest TEvo events in 90 d with
--      no SG link, 14 runs/night ≈ 1,400 of 58,841 candidates, re-testing the
--      same soonest rows every night. It never iterates an SG row at all.
--   2. The SG-side path exists and works: `event_mapper_run('sg_events_canonical')`
--      (the unified resolver, mig 20260911210000, `live` for this surface since
--      2026-09-11 18:55 UTC) — but the ONLY cron that calls it, job 246, has been
--      inactive since 2026-06-19 (mig 20260619180000: "redundant: cross_source_
--      match_tick already calls auto_match_sg_canonical_v3()"). The switchover
--      migration rewired 246's command to the resolver yet left it inactive, so
--      the resolver has NEVER run for this surface on a schedule. The
--      "don't re-enable" note (mig 20260620120000) refers to the legacy v3
--      function being redundant with job 152; it does not apply to the resolver.
--   3. What still runs is the legacy `auto_match_sg_canonical_v3()` inside
--      `cross_source_match_tick` (152, :09/:39, daily_max_fires 6): random-order
--      sweep with a 90 s budget, yielding ~1 match/day (`matcher_v3_pm24h`).
--   4. Dry run of the resolver on prod (`event_mapper_map_surface(
--      'sg_events_canonical', false, 150)`): 58 of 150 rows resolve — including
--      every high-sales miss found by hand (South Carolina at Oklahoma 12,999
--      sales/30 d via identity_hub; Geese via catalog_venue; Billy Strings,
--      Baylor at Kansas, Boise State at Washington State via name_day_exact;
--      Rush / Foreigner via id_venue_day). Live upcoming unmapped = 831 rows,
--      124 with sales in 30 d (2.1% of the sales feed; 83,188 rows).
--   5. `match_status` is dead weight: only `aq_hub_n2s` ever writes 'matched';
--      10,999 rows carry tevo_event_id AND 'pending'. Anyone reading the column
--      (the KANBAN investigation did) sees a 4,515-row "backlog" that is 83%
--      already mapped. The CHECK allows pending|matched|ignored_historic|
--      unmatchable; the trigger below only ever moves pending↔matched and
--      leaves the two manual states alone.
--
-- Single-statement cron command (A1-DB-5 rule): the old command was
-- `BEGIN; DO …; COMMIT; BEGIN; SET LOCAL …; SELECT shadow_tick; COMMIT;`
-- — exactly the multi-statement shape that stalls the launcher with
-- use_background_workers=off. The shadow replay was the pre-switch
-- comparison; the surface is live, so it is dropped here (gt/s4kcs keep theirs
-- on their own jobs). `event_mapper_run` sets its own 170 s statement_timeout.
-- Schedule :21 — no other hourly job fires on that minute (checked 2026-10-23).
--
-- Already applied to prod · via MCP 2026-10-23 03:02 UTC (operator-approved; the
-- DROP TRIGGER IF EXISTS line was omitted on apply — the trigger did not exist —
-- because the MCP tool holds any statement containing DROP). Verified: 246
-- active '21 * * * *' single statement; trigger enabled; status table now
-- ignored_historic 185 (no tevo) · matched 11,090 (all with tevo) · pending
-- 2,896 (none with tevo). First resolver run lands 03:21 UTC.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A. Job 246: single statement, off the :07 slot, active again
-- ---------------------------------------------------------------------------
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'auto_match_sg_canonical_v3_hourly'),
  schedule := '21 * * * *',
  command  := $c$DO $b$ BEGIN
  IF NOT public.cron_should_fire('auto_match_sg_canonical_v3_hourly') THEN RETURN; END IF;
  PERFORM public.event_mapper_run('sg_events_canonical');
END $b$;$c$,
  active   := true);

-- ---------------------------------------------------------------------------
-- B. match_status follows tevo_event_id from now on
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_sgec_match_status_sync()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  -- pending ↔ matched only; ignored_historic / unmatchable are manual states.
  IF NEW.tevo_event_id IS NOT NULL THEN
    IF NEW.match_status IS DISTINCT FROM 'matched' THEN NEW.match_status := 'matched'; END IF;
  ELSIF NEW.match_status = 'matched' THEN
    NEW.match_status := 'pending';
  END IF;
  RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION public.trg_sgec_match_status_sync() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS sg_events_canonical_match_status_sync ON public.sg_events_canonical;
CREATE TRIGGER sg_events_canonical_match_status_sync
  BEFORE INSERT OR UPDATE OF tevo_event_id, match_status ON public.sg_events_canonical
  FOR EACH ROW EXECUTE FUNCTION public.trg_sgec_match_status_sync();

-- ---------------------------------------------------------------------------
-- C. One-off backfill (14,171-row table; 2026-10-23 counts: 10,999 + 2)
--    Touches match_status only, so the existing AFTER … UPDATE OF tevo_event_id
--    xref trigger does not fire.
-- ---------------------------------------------------------------------------
UPDATE public.sg_events_canonical
   SET match_status = 'matched'
 WHERE tevo_event_id IS NOT NULL AND match_status IS DISTINCT FROM 'matched';

UPDATE public.sg_events_canonical
   SET match_status = 'pending'
 WHERE tevo_event_id IS NULL AND match_status = 'matched';

-- ============================================================================
-- VERIFY (after apply):
--   SELECT jobid, schedule, active, command FROM cron.job WHERE jobid = 246;
--   SELECT match_status, (tevo_event_id IS NOT NULL) has_tevo, count(*)
--     FROM public.sg_events_canonical GROUP BY 1, 2 ORDER BY 1, 2;
--       -- expect: no ('pending', true) and no ('matched', false) rows
--   -- first run (next :21): resolver output lands as match_method IN
--   -- ('identity_hub','catalog_venue','catalog_identity','name_day_exact',
--   --  'venue_day_name','id_venue_day','venue_24h_performer','unique_same_day')
--   SELECT match_method, count(*) FROM public.sg_events_canonical
--    WHERE matched_at > now() - interval '2 hours' GROUP BY 1;
--   -- unmapped-with-sales should fall from 124 toward ~40 over the first day:
--   SELECT count(DISTINCT s.sg_event_id) FROM public.seatgeek_sales_snapshots s
--     JOIN public.sg_events_canonical c USING (sg_event_id)
--    WHERE c.tevo_event_id IS NULL AND s.pulled_at > now() - interval '30 days';
--
-- ROLLBACK:
--   SELECT cron.alter_job(246, schedule := '7 * * * *', active := false,
--     command := $c$BEGIN; DO $body$ BEGIN IF NOT public.cron_should_fire('auto_match_sg_canonical_v3_hourly') THEN RETURN; END IF; PERFORM public.event_mapper_run('sg_events_canonical'); END $body$; COMMIT; BEGIN; SET LOCAL statement_timeout='120s'; SELECT public.event_mapper_shadow_tick('sg_events_canonical'); COMMIT;$c$);
--   DROP TRIGGER IF EXISTS sg_events_canonical_match_status_sync ON public.sg_events_canonical;
--   DROP FUNCTION IF EXISTS public.trg_sgec_match_status_sync();
--   (match_status backfill is informational; no data rollback needed)
-- ============================================================================
