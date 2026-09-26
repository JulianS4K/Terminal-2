-- ============================================================================
-- Migration 20260924223000 — Exos (Bridge / D4): paid checkout keeps the
--                            promoter and campaign attribution
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_checkout_sessions (+promoter_id, +attribution),
--              FUNCTION exos_fulfill_checkout (patched in place: tickets get promoter_id)
--           R: exos_tickets
-- Pre-reqs: 20260924215000 (exos_fulfill_checkout body). Apply after it.
--
-- Free claims already stamp exos_tickets.promoter_id from ?promoter=, but a
-- PAID purchase lost it: exos-checkout never received the promoter, and
-- fulfillment minted tickets with no promoter_id. So a promoter's paid sales
-- never showed up in the event's per-promoter Sales report, which is the
-- whole point of promoter links (EXP docs/gtm-nyc.md).
--   * exos_checkout_sessions.promoter_id: the sanitized ?promoter= code
--     (same charset as the Promote page's slugs).
--   * exos_checkout_sessions.attribution: UTM tags plus Meta's fbclid /
--     cart_origin, sanitized by supabase/functions/_shared/attribution.ts.
--   * fulfillment copies promoter_id onto every minted ticket.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS; the patch is skipped once applied.
-- D4 authors; applying to prod is operator-gated.
-- ============================================================================

ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS promoter_id text,
  ADD COLUMN IF NOT EXISTS attribution jsonb;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_promoter_id_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_promoter_id_chk
      CHECK (promoter_id IS NULL OR promoter_id ~ '^[A-Za-z0-9_-]{1,64}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_checkout_sessions_attribution_chk') THEN
    ALTER TABLE public.exos_checkout_sessions
      ADD CONSTRAINT exos_checkout_sessions_attribution_chk
      CHECK (attribution IS NULL OR (jsonb_typeof(attribution) = 'object' AND length(attribution::text) <= 2000));
  END IF;
END $$;

COMMENT ON COLUMN public.exos_checkout_sessions.promoter_id IS
  'Promoter / campaign code from ?promoter= at checkout; copied to exos_tickets.promoter_id on fulfillment. mig 20260924223000.';
COMMENT ON COLUMN public.exos_checkout_sessions.attribution IS
  'Sanitized utm_* / fbclid / cart_origin from the landing URL (_shared/attribution.ts). mig 20260924223000.';

DO $$
DECLARE
  v_def  text := pg_get_functiondef('public.exos_fulfill_checkout(text)'::regprocedure);
  v_col_old text := 'price_paid, order_ref, channel_source' || chr(10);
  v_col_new text := 'price_paid, order_ref, channel_source, promoter_id' || chr(10);
  v_val_old text := 'p_session_id, ''stripe''' || chr(10);
  v_val_new text := 'p_session_id, ''stripe'', s.promoter_id' || chr(10);
  v_hits int;
BEGIN
  -- Stable marker (234500 later changes the line end, so match the column).
  IF position('s.promoter_id' in v_def) > 0 THEN
    RETURN;   -- already patched
  END IF;
  IF position('SQLSTATE ''XF001''' in v_def) = 0 THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: apply 20260924215000 first';
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, v_col_old, ''))) / length(v_col_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: expected one ticket column list, found %', v_hits;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, v_val_old, ''))) / length(v_val_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: expected one ticket values tail, found %', v_hits;
  END IF;
  EXECUTE replace(replace(v_def, v_col_old, v_col_new), v_val_old, v_val_new);
END $$;
