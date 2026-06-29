-- Migration 20260629120000 · lane:A1 (DB + ingest/cron — TicketsData watchlist) · writes (DDL):td_apply_targets() [CREATE OR REPLACE]; on run:ticketsdata_event_xref (scoped UPDATE reactivating the 5 UFC-329 xref rows) · reads:td_target_events(), ticketsdata_event_xref · pre:20260529200000 (last td_apply_targets CREATE OR REPLACE) · auth:operator-approved 2026-06-29 (julian@s4kent.com — "do it")
--
-- WHY ------------------------------------------------------------------------
-- The daily watchlist reconcile td_watchlist_refresh() (cron jobid 264, "0 9 * * *")
-- calls td_apply_targets(), whose deactivation sweep set active=false on ANY active
-- ticketsdata_event_xref row not present in td_target_events() — WITHOUT checking
-- manual_opt_in. td_target_events() only covers Yankees home games, Knicks playoff
-- games, and a fixed concert-venue allowlist. So a hand-added event outside those
-- buckets (manual_opt_in=true, hand-verified URLs) was silently switched off within
-- 24h, and the enqueue crons (td_tier_enqueue / td_enqueue_peak, which gate on
-- x.active) stopped pulling it.
--
-- Concrete victim: event 3350088 = "UFC 329 (McGregor vs Holloway)" (2026-07-11,
-- Las Vegas, aq_short_event_id 'SYS-bf1beddbe5'). All 5 platform rows (GT/SH/TM/TP/VD,
-- manual_opt_in=true) were flipped active=false at 2026-06-22 09:00 and have pulled
-- nothing since.
--
-- FIX ------------------------------------------------------------------------
-- 1. Exempt manual opt-ins from the deactivation sweep: add `x.manual_opt_in IS NOT
--    TRUE` to the WHERE clause. manual_opt_in (default false, NOT NULL) is true ONLY
--    on hand-added rows — td_apply_targets's own INSERTs never set it, so this spares
--    exactly the manual rows and zero normal-lifecycle rows. (Deliberately NOT keyed
--    on always_on: td_apply_targets sets always_on=true on its OWN auto-target rows —
--    ~200 active rows carry it — so an always_on predicate would also exempt aged-out
--    targets from deactivation, a budget/staleness leak, and would miss the UFC TM row
--    which is always_on=false.)
-- 2. Reactivate the 5 UFC-329 rows so data starts flowing immediately rather than
--    waiting for the next discovery pass.
--
-- SAFETY ---------------------------------------------------------------------
-- Budget-safe: a manual event that has passed is still deactivated by td_pending_sweep
-- (cron jobid 268, 2h post-event, SH/VD/GT/TM) and a dead URL still self-deactivates on
-- 403/404 in td_normalize_drain; the enqueue functions also gate dte>=0 /
-- sg_datetime_utc>now-6h, so a stale manual row is never pulled even if left active.
-- Plenty of TD budget exists (≈241k/250k plan pool remaining; 5,823/6,000 daily).
-- Plain CREATE OR REPLACE (signature unchanged, zero-arg) preserves the existing
-- SECDEF lockdown grants — no REVOKE/GRANT re-issue needed (matches the prior replace
-- in 20260529200000). Reactivation is scoped to 5 known rows (reversible).
--
-- ROLLBACK -------------------------------------------------------------------
-- Re-CREATE OR REPLACE td_apply_targets() with the body below minus the
-- `x.manual_opt_in IS NOT TRUE` predicate; to undo the reactivation:
--   UPDATE public.ticketsdata_event_xref SET active=false, updated_at=now()
--   WHERE aq_short_event_id='SYS-bf1beddbe5' AND manual_opt_in=true;

CREATE OR REPLACE FUNCTION public.td_apply_targets()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_count int := 0; v_now timestamptz := now();
BEGIN
  WITH t AS (SELECT * FROM public.td_target_events() WHERE sh_event_id IS NOT NULL)
  INSERT INTO public.ticketsdata_event_xref (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
  SELECT t.sh_event_id, 'SH', t.aq_short_event_id, 'https://www.stubhub.com/x/event/' || t.sh_event_id::text || '/', true, true, 'direct_id', v_now
  FROM t ON CONFLICT (event_id, platform) DO UPDATE SET active=true, always_on=true, event_url=EXCLUDED.event_url, updated_at=v_now;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  WITH t AS (SELECT * FROM public.td_target_events() WHERE vivid_event_id IS NOT NULL)
  INSERT INTO public.ticketsdata_event_xref (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
  SELECT t.vivid_event_id, 'VD', t.aq_short_event_id, 'https://www.vividseats.com/production/' || t.vivid_event_id::text, true, true, 'direct_id', v_now
  FROM t ON CONFLICT (event_id, platform) DO UPDATE SET active=true, always_on=true, event_url=EXCLUDED.event_url, updated_at=v_now;
  -- Deactivation sweep: drop anything no longer in the target set, EXCEPT manual
  -- opt-ins (manual_opt_in IS NOT TRUE) which are intentionally tracked regardless
  -- of td_target_events() membership. Post-event cleanup for manual rows is handled
  -- by td_pending_sweep / 403-404 self-deactivation, not here.
  UPDATE public.ticketsdata_event_xref x SET active=false, updated_at=v_now
  WHERE x.active=true AND x.manual_opt_in IS NOT TRUE AND NOT EXISTS (SELECT 1 FROM public.td_target_events() t
    WHERE (x.platform='SH' AND x.event_id=t.sh_event_id) OR (x.platform='VD' AND x.event_id=t.vivid_event_id)
       OR (x.platform='GT' AND x.event_id=t.sg_event_id) OR (x.platform='TP' AND x.aq_short_event_id=t.aq_short_event_id)
       OR (x.platform='TM' AND x.aq_short_event_id=t.aq_short_event_id));
  UPDATE public.ticketsdata_event_xref x SET always_on=true, updated_at=v_now
  WHERE x.platform='GT' AND x.active=true AND EXISTS (SELECT 1 FROM public.td_target_events() t WHERE t.sg_event_id=x.event_id);
  UPDATE public.ticketsdata_event_xref x SET owned_tickets=COALESCE(em_data.owned_tickets_count,0), median_retail_price=em_data.retail_median, updated_at=v_now
  FROM public.aq_event_map aem JOIN public.sg_events_canonical sgc ON sgc.sg_event_id=aem.sg_event_id
  LEFT JOIN LATERAL (SELECT em.owned_tickets_count, em.retail_median FROM public.event_metrics em
    WHERE em.event_id=sgc.tevo_event_id ORDER BY em.captured_at DESC LIMIT 1) em_data ON true
  WHERE aem.aq_short_event_id=x.aq_short_event_id AND x.active=true AND sgc.tevo_event_id IS NOT NULL;
  RETURN v_count;
END $function$;

-- Reactivate the 5 hand-added UFC-329 (event 3350088) rows that the old sweep killed.
-- Scoped to the exact aq id + manual_opt_in flag (exactly 5 rows: GT/SH/TM/TP/VD).
-- enqueues_today=0 so they enqueue on the next metronome tick instead of waiting for
-- the 09:00 watchlist refresh to zero it.
UPDATE public.ticketsdata_event_xref
SET active = true, enqueues_today = 0, updated_at = now()
WHERE aq_short_event_id = 'SYS-bf1beddbe5'
  AND manual_opt_in = true;
