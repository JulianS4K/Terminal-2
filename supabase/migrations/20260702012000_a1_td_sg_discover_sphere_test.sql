-- ============================================================================
-- Migration 20260702012000 — td_sg_discover test: Wizard of Oz at Sphere enrolled
--
-- Lane:     A1
-- Touches:  td_sg_performers (one allowlist row, performer 123021).
-- Pre-reqs: td_sg_discover()/td_sg_discover_drain() (mig 20260606170000).
--
-- WHY (operator 2026-07-02 "use the td discovery tool to map, but test on evo performer with
-- most events first"): performer 123021 'The Wizard of Oz at Sphere' had 453 unmapped future
-- EVO events — the largest single gap in SG mapping. Enrolled + fired live:
--   * slug 'wizard-of-oz-at-sphere' -> 200/0 events (wrong; SG keeps the 'the-' prefix here);
--   * slug 'the-wizard-of-oz-at-sphere' -> 448 events (SG performer 1963905), drained into
--     sg_events_canonical; 395/448 auto-matched to TEvo immediately (88%). Cost: 2 TD credits.
--   * Net effect: SG-mapped EVO universe 2,118 -> ~2,513 (+19%); Sphere shows now flow into the
--     sales-eligibility universe via the re-enabled classifier.
-- The row keeps the 7-day discover cooldown from the fn; future re-discovery is automatic
-- whenever td_sg_discover() is invoked (manual, td_budget_ok()-gated by design).
--
-- Idempotent: INSERT ... ON CONFLICT DO NOTHING + guarded UPDATE of the URL.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

INSERT INTO td_sg_performers (tevo_performer_id, performer_name, performer_url, active)
VALUES (123021, 'The Wizard of Oz at Sphere', 'https://seatgeek.com/the-wizard-of-oz-at-sphere-tickets', true)
ON CONFLICT DO NOTHING;

UPDATE td_sg_performers
SET performer_url = 'https://seatgeek.com/the-wizard-of-oz-at-sphere-tickets'
WHERE tevo_performer_id = 123021
  AND performer_url <> 'https://seatgeek.com/the-wizard-of-oz-at-sphere-tickets';
