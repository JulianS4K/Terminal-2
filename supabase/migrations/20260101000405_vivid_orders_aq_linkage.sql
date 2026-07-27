-- Migration 20260515300000 · lane:D2 · writes:vivid_orders.{aq_short_event_id,aq_match_method,aq_confidence,aq_matched_at}+FK+idx · reads:aq_event_map · pre:20260513230000,20260515210000 · auth:operator-gated (D2 author + preview only)
-- Phase B of vivid→AQ linkage plan. Schema-only; sweep wiring (Phase C) is A1.
-- Phase A audit 2026-05-15: vivid 0/842, seatgeek 0/400, tickpick 176/939 (18.7%).
-- Rationale + plan phases: docs/release-discipline.md / bot_chat handoff.

ALTER TABLE public.vivid_orders ADD COLUMN IF NOT EXISTS aq_short_event_id text;
ALTER TABLE public.vivid_orders ADD COLUMN IF NOT EXISTS aq_match_method   text;
ALTER TABLE public.vivid_orders ADD COLUMN IF NOT EXISTS aq_confidence     numeric(3,2);
ALTER TABLE public.vivid_orders ADD COLUMN IF NOT EXISTS aq_matched_at     timestamptz;

-- Partial index — small table today (842 rows) but the sweep population
-- pattern will be heavily skewed toward resolved rows. WHERE NOT NULL
-- keeps the index lean (mirrors 20260515240000 listings_aq_linkage pattern).
CREATE INDEX IF NOT EXISTS vivid_orders_aq_short_event_id_idx
  ON public.vivid_orders (aq_short_event_id)
  WHERE aq_short_event_id IS NOT NULL;

-- FK to aq_event_map (NOT VALID first — VALIDATE in a follow-up once
-- Phase C sweep has had time to populate the column on the backlog).
-- Mirrors the NOT VALID pattern from PR #99 (cross-source FK declarations)
-- and the listings_aq_linkage migration.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'vivid_orders_aq_short_event_id_fkey'
  ) THEN
    ALTER TABLE public.vivid_orders
      ADD CONSTRAINT vivid_orders_aq_short_event_id_fkey
      FOREIGN KEY (aq_short_event_id)
      REFERENCES public.aq_event_map(aq_short_event_id)
      NOT VALID;
  END IF;
END $$;

COMMENT ON COLUMN public.vivid_orders.aq_short_event_id IS
  'Canonical AQ event PK (text, 7-char operator-curated or SYS-prefixed synthetic). '
  'Populated by match_unmatched_orders_sweep via match_to_aq_event_id (mig 20260515210000). '
  'Phase B of the vivid → AQ plan; Phase C (sweep wiring) is owned by A1.';

COMMENT ON COLUMN public.vivid_orders.aq_match_method IS
  'Match tier label from match_to_aq_event_id: tier1_direct_id | tier2_exact | tier3_fuzzy | tier4_coord | sys_seed.';

COMMENT ON COLUMN public.vivid_orders.aq_confidence IS
  'Match confidence 0.50–1.00 from match_to_aq_event_id. SYS-seeded rows get 0.50.';

COMMENT ON COLUMN public.vivid_orders.aq_matched_at IS
  'When the sweep wrote this match. Lets the operator see how stale the AQ link is for a given row.';
