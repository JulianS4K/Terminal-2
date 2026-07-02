-- ============================================================================
-- Migration 20260702014500 — exclude 'The Wizard of Oz at Sphere' everywhere (not a real event)
--
-- Lane:     A1
-- Touches:  events.state (performer 123021 future rows -> 'ignored');
--           sg_event_priority_state (448 SKIP rows seeded); td_sg_performers (row deactivated).
-- Pre-reqs: 20260702012000 (the discovery test that mapped it).
--
-- WHY (operator 2026-07-02): the Sphere Wizard-of-Oz showtimes are venue-experience slots, not
-- resale events — exclude from all polling. Three layers:
--   1) 453 future events (primary_performer_id=123021) -> state='ignored' (the EVO poller's
--      eligibility filter `coalesce(state,'shown') <> 'ignored'` drops them next tick);
--   2) 448 sg_event_priority_state rows pre-seeded/forced tier='SKIP' (they had not yet entered
--      the state table; seeding closes the door on the classifier tiering them into the SG sales
--      universe — VERIFY the classifier does not flip these back on its next passes);
--   3) td_sg_performers row for 123021 deactivated (no future re-discovery).
-- The 448 sg_events_canonical rows + 395 TEvo mappings are retained (harmless identity data).
--
-- Idempotent: guarded UPDATEs + ON CONFLICT upsert. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

UPDATE events SET state='ignored'
WHERE primary_performer_id=123021
  AND occurs_at_local IS NOT NULL AND occurs_at_local::timestamptz > now()
  AND coalesce(state,'shown') <> 'ignored';

INSERT INTO sg_event_priority_state
  (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, tevo_event_id,
   owned_count_last_7d, active_listings_last_7d, tier,
   sales_polls_today, listings_polls_today, budget_day, computed_at)
SELECT c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_datetime_utc, c.tevo_event_id,
       0, 0, 'SKIP', 0, 0, current_date, now()
FROM sg_events_canonical c
WHERE c.sg_event_name ILIKE '%wizard of oz%'
ON CONFLICT (sg_event_id) DO UPDATE SET tier='SKIP';

UPDATE td_sg_performers SET active=false, updated_at=now()
WHERE tevo_performer_id=123021 AND active;
