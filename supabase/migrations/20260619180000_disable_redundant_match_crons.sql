-- Migration 20260619180000 · lane:A1 (operator-directed) ·
--   writes: cron.job (active=false on 4 redundant matching crons)
--   ## Applied to prod 2026-06-19 via MCP (operator-directed). Idempotent + reversible.
--
-- Operator-directed 2026-06-19: "look at the other matching crons and disable
--   unnecessary or redundant ones."
--
-- Disabled (active=false; definitions retained for easy re-enable):
--   • td_match_fill_enqueue          — BROKEN: td_match_enqueue('fill') seeds from
--       ticketsdata_event_xref.event_url (StubHub/VividSeats/TM URLs), which /match
--       rejects (500 "could not resolve performer cluster" / "unsupported marketplace");
--       also fires 3 concurrently -> 429. Fully superseded by sg-match-map-tick, which
--       seeds SeatGeek URLs (the only form /match resolves) and fires one-at-a-time.
--   • td_match_drain                 — redundant: sg_match_map_tick() drains each cycle.
--   • td_match_apply_cron            — redundant: sg_match_map_tick() applies (conf 80,
--       superset of the cron's 90) every 10 min vs this one's 20.
--   • auto_match_sg_canonical_v3_hourly — redundant: cross_source_match_tick() already
--       calls auto_match_sg_canonical_v3() and runs twice/hr (:09,:39) vs this once/hr.
--
-- Net: sg-match-map-tick is the single owner of the TicketsData /match loop;
--      cross_source_match_tick is the single owner of the SG-canonical v3 matcher.
-- Reverse any of these with: SELECT cron.alter_job(jobid, active := true);

DO $$
DECLARE j bigint;
BEGIN
  FOR j IN
    SELECT jobid FROM cron.job
    WHERE jobname IN ('td_match_fill_enqueue','td_match_drain',
                      'td_match_apply_cron','auto_match_sg_canonical_v3_hourly')
  LOOP
    PERFORM cron.alter_job(j, active := false);
  END LOOP;
END $$;
