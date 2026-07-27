-- ============================================================================
-- Migration 20260709222500 — TM: poll ALL events (every DTE tier) but cap to once/day
--
-- Lane:     A1 (data plane — TicketsData TM coverage)
-- Touches:  td_poll_policy rows for platform 'TM' (upsert hot/warm/cool/cold/frozen).
-- Reads on run: (none — config only). Consumed by td_tier_enqueue('TM').
-- Pre-reqs: 20260709221500 (TM enrolled across all DTE via /match), td_event_tier(), td_tier_enqueue().
-- Auth:     operator directive 2026-07-09 (julian@s4kent.com — "expand tm to all events but cap to poll
--           tm once daily if findings exceed budget cap").
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- td_tier_enqueue('TM') only enqueues an enrolled event if there's an ACTIVE td_poll_policy row for its
-- DTE tier (td_event_tier: hot≤7d, warm≤30d, cool≤90d, cold≤180d, frozen>180d). TM had rows for only
-- hot+warm — so TM events more than 30 days out were enrolled (mig 20260709221500) but NEVER polled.
--
-- Two changes, both here:
--   1. EXPAND TO ALL EVENTS: add TM policy rows for cool/cold/frozen (max_dte NULL = no horizon cap), so
--      every enrolled TM event is polled regardless of how far out it is.
--   2. CAP TO ONCE/DAY: set every TM tier's peak_min AND offpeak_min to 1,440 (24h). Broadening TM to the
--      full event set at the old 15-min cadence would blow the budget; a 1-poll/day/event cap keeps the
--      expanded footprint affordable. (This is the cost governor the directive asks for — "cap ... once
--      daily if findings exceed budget cap".) The global td_budget_ok() gate that td_tier_enqueue already
--      checks remains the hard backstop: if collective spend still reaches the 225k/cycle cap, TM enqueue
--      stops with everything else.
--
-- Cost: TM /fetch ≈ (# active TM events) per day. At today's 363 that's ~363/day (~463 real ×1.276) ≈ 6%
-- of the ~7,500 real/day even-spread; scales linearly as TM enrollment grows, staying well under budget.
-- Tradeoff (intentional): near-term (hot) TM events also drop from 15-min to daily — breadth over intraday
-- frequency. Reversible: restore hot/warm to 15 and drop cool/cold/frozen to narrow TM back.
--
-- Idempotent (INSERT ... ON CONFLICT) -> apply-before-PR under operator direction; re-apply is a no-op.
-- ============================================================================

INSERT INTO public.td_poll_policy (platform, tier, peak_min, offpeak_min, max_dte, active, updated_at)
VALUES
  ('TM', 'hot',    1440, 1440, NULL, true, now()),
  ('TM', 'warm',   1440, 1440, NULL, true, now()),
  ('TM', 'cool',   1440, 1440, NULL, true, now()),
  ('TM', 'cold',   1440, 1440, NULL, true, now()),
  ('TM', 'frozen', 1440, 1440, NULL, true, now())
ON CONFLICT (platform, tier) DO UPDATE
  SET peak_min    = EXCLUDED.peak_min,
      offpeak_min = EXCLUDED.offpeak_min,
      max_dte     = EXCLUDED.max_dte,
      active      = true,
      updated_at  = now();
