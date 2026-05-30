-- ============================================================
-- Daily self-heal cron for the Knicks-Finals split-aq mapping.
-- A1 2026-05-30. Prevents SH/VD cross-source drift: if the aq-curated process
-- re-creates orphan "Home Game N" rows (sg/tevo NULL) for the Knicks Finals home
-- games, the terminal RPC (tevo -> sg_events_canonical -> aq_event_map.sg_event_id
-- -> xref) would stop reaching the StubHub/Vivid xref again. This re-runs the
-- idempotent reconcile (mig 20260530140000) every morning to keep the curated rows
-- consolidated onto / promoted to the tevo+SG-anchored records.
--
-- Slot 09:05 UTC — after td_watchlist_refresh (09:00), before the GT/TP/TM
-- discover-drains (09:15-09:50) so those match the consolidated aq rows.
-- No-op once reconciled (and after the Finals pass). Unschedule after the Finals
-- if desired: SELECT cron.unschedule('td-reconcile-knicks-finals-daily');
-- ============================================================
DO $$ BEGIN
  PERFORM cron.unschedule('td-reconcile-knicks-finals-daily');
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT cron.schedule('td-reconcile-knicks-finals-daily', '5 9 * * *',
  $cron$SELECT public.td_reconcile_knicks_finals_aq();$cron$);
