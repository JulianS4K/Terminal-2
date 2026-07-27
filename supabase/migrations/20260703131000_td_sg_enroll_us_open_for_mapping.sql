-- Migration 20260703131000 · lane:A1 (data plane — SeatGeek event-mapping allowlist)
--   writes on run: td_sg_performers (INSERT performer 30079, ON CONFLICT reactivate)
--   reads: none
--   spends: nothing at apply. The daily td_sg_discover cron then spends ~1 TD credit
--           on its next run to /events-search this performer (GET-only, budget-gated).
--   pre: 20260606170000 (td_sg_performers / td_sg_discover / _drain)
--   auth: operator directive 2026-07-03 (julian@s4kent.com — "turn on the SeatGeek
--         API just for event mapping and run crons for that")
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible, MIGRATION_CONVENTIONS
--    §11.1). This PR is the codification; re-apply is a no-op.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- The SeatGeek event-mapping pipeline is ALREADY live: the TD-seatgeek discovery
-- path is enabled (integration_policy.td_seatgeek_emergency_override=true through
-- 2026-07-09) and its crons run daily —
--   td_sg_discover_daily        (40 9 * * *)  → /events?platform=seatgeek search
--   td_sg_discover_drain_daily  (50 9 * * *)  → sg_events_canonical + auto_match_sg_canonical_v3
--   sg-match-map-tick           (*/10 * * * *)→ fills aq_event_map.sh/vivid via TD /match
-- SeatGeek's own broker token has NO search endpoint, so TD /events is the only
-- way to DISCOVER new sg_event_ids (mig 20260606170000).
--
-- But td_sg_discover only searches performers on the td_sg_performers allowlist,
-- and the ~85 upcoming US Open Tennis sessions (TEvo performer 30079, "US Open
-- Tennis Championship") were NOT enrolled — so they never got a SeatGeek anchor,
-- and the SG-anchored mapper (sg_match_map_tick) had nothing to map. This enrolls
-- them. Once discovery gives them sg_event_ids → auto_match links to TEvo →
-- sg_match_map_tick fills their StubHub/Vivid ids automatically. No new cron, no
-- policy change (override already on) — this is purely the missing allowlist row.
--
-- performer_url uses the same seatgeek.com slug construction as the existing seed
-- (mig 20260606170000). Read-only vs upstream: only an INSERT into our allowlist.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO public.td_sg_performers (tevo_performer_id, performer_name, performer_url, active)
VALUES (30079, 'US Open Tennis Championship',
        'https://seatgeek.com/us-open-tennis-tickets', true)
ON CONFLICT (tevo_performer_id) DO UPDATE
  SET active = true,
      performer_url = EXCLUDED.performer_url,
      updated_at = now();

-- ROLLBACK: UPDATE public.td_sg_performers SET active=false WHERE tevo_performer_id=30079;
--           (or DELETE the row — no dependent rows; discovery just stops searching it.)
