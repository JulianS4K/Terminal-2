-- Migration 20260819213700 · level:data-collection · lane:D0 · writes:gt_deals_retire_tick(int)[new],gotickets_deals_feed(gone_at),cron.schedule(gt_ingest_cascade_1min)[replace] · reads:gotickets_listings_snapshots · pre:20260811280000 (cascade body replaced), 20260811264000 (<14d rule folded in), 20260811240000 (gotickets_deals_feed.gt_event_id) · auth:OPERATOR-APPROVAL REQUIRED before apply (cron.schedule + SECDEF fn)
-- fix (2026-08-19) — GoTickets deal feed reads as frozen/paused.
--
-- Lane:     D0 (terminal — GoTickets deal feed)
-- Touches:  gotickets_deals_feed (W), gotickets_listings_snapshots (R),
--           cron.job `gt_ingest_cascade_1min` (W), gt_deals_retire_tick() (new fn)
-- Pre-reqs: 20260811280000 (cascade + scanner incident fix — supplies the cron body this replaces),
--           20260811264000 (<14d retire rule, folded into the new fn),
--           20260811240000 (gotickets_deals_feed.gt_event_id)
--
-- SYMPTOM. The DEALS page reads as paused: for long stretches the only rows are 4 Toronto Blue
-- Jays deals frozen at 2026-08-11 20:35, while genuinely-live deals blink out and back in. The
-- pipeline itself is healthy (poll 2min + cascade 1min both active, snapshots landing every minute).
--
-- ROOT CAUSE. The cascade's "gone" rule (mig 20260811280000 cron body) keys off poll FIRE time
-- rather than captured evidence:
--     EXISTS  (gt_listings_poll_state.last_polled_listings_at > now()-12min)
--     AND NOT EXISTS (snapshot of that listing captured in the last 12min)
--   1. FLAPPING — a poll that fires but whose response never lands (GT timeout, lost inflight)
--      satisfies clause 1 with no capture behind it, so every live deal on that event is retired
--      even though nothing was observed to be gone. Observed: gt_event 1188809 captured 20:34 then
--      21:26 (a 52-min gap) with listing 6654784588 present at $84.55 in every capture either side
--      — retired 20:47, re-added 21:27. That is the feed emptying out and refilling.
--   2. FROZEN — the inverse. An event that stops being polled entirely never satisfies clause 1,
--      so its deals can never be retired. mig 20260811270000/274000 narrowed the poller to US
--      `venue_state`; Rogers Centre is 'ON', so gt_events 1187955/1187967/1188007 were last polled
--      2026-08-11 19:54 and their 4 deals have been immortal since — the only rows that never move.
--
-- FIX. `gt_deals_retire_tick()` retires on captured evidence only, with no wall-clock poll window:
--   * GONE  — the newest capture of the event postdates the capture the deal was priced from and
--             does not contain the listing. A lost poll response can no longer retire anything.
--   * STALE — the event produced no capture at all inside p_stale_hours (default 12h: poll-scope
--             change, deactivation, indefinite quarantine, or a feed row with no gt_event_id).
--             The deal can no longer be verified, so it stops presenting as live. 12h is ~72x the
--             10-min curated-deal cadence (mig 20260811274000), so a healthy event never trips it.
--   * <14d  — unchanged, folded in verbatim from mig 20260811264000.
--   The scanner's own "no longer qualifies" retire (scan_gotickets_deals, mig 20260811280000)
--   is untouched — it answers a different question (still a deal?) than this one (still there?).
--
-- NOT IN SCOPE (deliberate): the poller stays US-only — widening `gt_listings_poll_tick` to
--   Canadian venues is a credit-budget/scope call for the operator, not a bug fix. Under this
--   migration those events' deals simply retire as STALE instead of living forever.
--
-- VERIFY (real rows, run pre-apply as SELECT): flags exactly the 4 orphaned Blue Jays deals
--   (gt_events 1187955/1187967/1188007, last_cap NULL) and zero of the 11 genuinely-live deals,
--   including gt_event 1191956 whose listing was still present in a capture newer than the one it
--   was priced from.
--
-- ROLLBACK:
--   SELECT cron.schedule('gt_ingest_cascade_1min','* * * * *', <the mig 20260811280000 body>);
--   DROP FUNCTION public.gt_deals_retire_tick(integer);

-- 1. Evidence-based retire.
CREATE OR REPLACE FUNCTION public.gt_deals_retire_tick(p_stale_hours integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_gone int := 0; v_stale int := 0; v_orphan int := 0; v_soon int := 0;
  v_hours int := GREATEST(coalesce(p_stale_hours, 12), 1);
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '15000', true);

  -- Newest capture per event carrying a live deal. Small set (tens of events); each max() is a
  -- backwards scan of gotickets_listings_snapshots_pkey (gt_event_id, captured_at, gt_listing_id)
  -- bounded to the staleness window, so this never seq-scans the 330M-row firehose.
  CREATE TEMP TABLE _cap ON COMMIT DROP AS
    SELECT e.gt_event_id,
           (SELECT max(s.captured_at)
              FROM public.gotickets_listings_snapshots s
             WHERE s.gt_event_id = e.gt_event_id
               AND s.captured_at > now() - make_interval(hours => v_hours)) AS last_cap
      FROM (SELECT DISTINCT gt_event_id
              FROM public.gotickets_deals_feed
             WHERE gone_at IS NULL AND gt_event_id IS NOT NULL) e;

  -- GONE: a capture newer than the one this deal was priced from does not contain the listing.
  UPDATE public.gotickets_deals_feed f
     SET gone_at = now()
    FROM _cap c
   WHERE c.gt_event_id = f.gt_event_id
     AND f.gone_at IS NULL
     AND c.last_cap IS NOT NULL
     AND c.last_cap > coalesce(f.gt_captured_at, f.last_seen_at)
     AND NOT EXISTS (SELECT 1 FROM public.gotickets_listings_snapshots s2
                      WHERE s2.gt_event_id  = f.gt_event_id
                        AND s2.captured_at  = c.last_cap
                        AND s2.gt_listing_id = f.gt_listing_id);
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  -- STALE: no capture for the event inside the window — unverifiable, so not "live".
  UPDATE public.gotickets_deals_feed f
     SET gone_at = now()
    FROM _cap c
   WHERE c.gt_event_id = f.gt_event_id
     AND f.gone_at IS NULL
     AND c.last_cap IS NULL;
  GET DIAGNOSTICS v_stale = ROW_COUNT;

  -- STALE (orphan): pre-mig-20260811240000 rows with no gt_event_id can never be matched to a
  -- capture at all, so they would otherwise be immortal for the same reason.
  UPDATE public.gotickets_deals_feed
     SET gone_at = now()
   WHERE gone_at IS NULL
     AND gt_event_id IS NULL
     AND last_seen_at < now() - make_interval(hours => v_hours);
  GET DIAGNOSTICS v_orphan = ROW_COUNT;

  -- <14d: unchanged from mig 20260811264000.
  UPDATE public.gotickets_deals_feed
     SET gone_at = now()
   WHERE gone_at IS NULL
     AND event_date IS NOT NULL
     AND event_date < (now() + interval '14 days')::date;
  GET DIAGNOSTICS v_soon = ROW_COUNT;

  RETURN jsonb_build_object('gone', v_gone, 'stale', v_stale + v_orphan,
                            'under_14d', v_soon, 'stale_hours', v_hours, 'at', now());
END;
$function$;

REVOKE ALL ON FUNCTION public.gt_deals_retire_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gt_deals_retire_tick(integer) TO service_role;

-- 2. Cascade: same drain -> median -> retire -> scan sequence and schedule as mig 20260811280000;
--    only the two inline retire UPDATEs are replaced by the call above.
SELECT cron.schedule('gt_ingest_cascade_1min', '* * * * *', $cron$
  SELECT public.gt_listings_drain(3000);
  UPDATE public.gt_listings_poll_state ps SET event_median_price = m.med
    FROM (SELECT gt_event_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY all_in_price)::numeric AS med
          FROM public.gotickets_listings_snapshots
          WHERE captured_at > now()-interval '12 min' AND all_in_price > 0
          GROUP BY gt_event_id) m
    WHERE ps.gt_event_id = m.gt_event_id;
  DO $b$ BEGIN PERFORM public.gt_deals_retire_tick(); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt retire skipped: %', SQLERRM; END $b$;
  DO $b$ BEGIN PERFORM public.scan_gotickets_deals(30); EXCEPTION WHEN OTHERS THEN RAISE WARNING 'gt scan skipped: %', SQLERRM; END $b$;
$cron$);

-- 3. Clear the standing backlog immediately (the 4 orphaned Blue Jays deals) instead of waiting
--    for the next cascade tick.
SELECT public.gt_deals_retire_tick();
