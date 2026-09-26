-- ============================================================================
-- Migration 20260926070000 — Exos (Bridge / D4): price-disclosure record
--                            (what the buyer was shown vs what Stripe charged)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_price_disclosures, exos_price_disclosure_lines (new),
--              FUNCTION exos_record_price_disclosure (new, service_role — exos-checkout),
--              FUNCTION exos_record_price_charged (new, service_role — stripe-webhook),
--              FUNCTION exos_price_disclosure_export (new, authenticated; owner/manager/finance),
--              FUNCTION exos_tg_price_disclosure_frozen (new, trigger)
--           R: exos_checkout_sessions, exos_events
-- Pre-reqs: 20260702123100 (exos_checkout_sessions), 20260924211840 (all-in price + tax)
--
-- Proof for NY Arts & Cultural Affairs Law §25.07 (all-in price shown up front,
-- no increase during checkout) and the FTC junk-fee rule. For every paid
-- checkout session we keep, per line: tier / add-on, quantity, the face price,
-- the tax, buyer fees (Exos charges none, so 0), the all-in unit price shown
-- and the line total; plus the order total shown. When Stripe settles, the
-- amount it actually charged is stored next to it, and charge_mismatch flags
-- charged != shown (or a currency change).
--
--   * Written by exos-checkout right after it records the session, from the
--     same numbers it sends Stripe as line items (the price the buyer sees on
--     Stripe's page). Free lines (a $0 tier with paid add-ons) are recorded too.
--   * The shown side is frozen once written (trigger); only the charged side
--     can be set later, by exos_record_price_charged.
--   * Organizers export it per event (owner / manager / finance).
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ROLLBACK: DROP FUNCTION exos_price_disclosure_export(uuid),
--   exos_record_price_charged(text, int, text), exos_record_price_disclosure(text, text, jsonb);
--   DROP TABLE exos_price_disclosure_lines, exos_price_disclosures;
--   DROP FUNCTION exos_tg_price_disclosure_frozen().
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_price_disclosures (
  session_id        text PRIMARY KEY REFERENCES public.exos_checkout_sessions (session_id) ON DELETE CASCADE,
  event_id          uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id            uuid NOT NULL,
  currency          text NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
  total_shown_cents integer NOT NULL CHECK (total_shown_cents >= 0),
  shown_at          timestamptz NOT NULL DEFAULT now(),
  charged_cents     integer CHECK (charged_cents IS NULL OR charged_cents >= 0),
  charged_currency  text CHECK (charged_currency IS NULL OR charged_currency ~ '^[a-z]{3}$'),
  charged_at        timestamptz,
  charge_mismatch   boolean GENERATED ALWAYS AS (
    charged_cents IS NOT NULL
    AND (charged_cents <> total_shown_cents OR coalesce(charged_currency, currency) <> currency)
  ) STORED
);
COMMENT ON TABLE public.exos_price_disclosures IS
  'Per checkout session: the all-in total the buyer was shown and what Stripe charged (NY ACAL 25.07 / FTC fee rule proof).';
CREATE INDEX IF NOT EXISTS exos_price_disclosures_event_idx ON public.exos_price_disclosures (event_id, shown_at);
CREATE INDEX IF NOT EXISTS exos_price_disclosures_mismatch_idx ON public.exos_price_disclosures (event_id) WHERE charge_mismatch;

CREATE TABLE IF NOT EXISTS public.exos_price_disclosure_lines (
  session_id        text NOT NULL REFERENCES public.exos_price_disclosures (session_id) ON DELETE CASCADE,
  line_no           integer NOT NULL CHECK (line_no BETWEEN 1 AND 50),
  kind              text NOT NULL CHECK (kind IN ('ticket','addon')),
  item_id           uuid,
  item_name         text NOT NULL CHECK (length(item_name) <= 300),
  quantity          integer NOT NULL CHECK (quantity BETWEEN 1 AND 50),
  face_unit_cents   integer NOT NULL CHECK (face_unit_cents >= 0),
  tax_cents         integer NOT NULL DEFAULT 0 CHECK (tax_cents >= 0),
  tax_included      boolean NOT NULL DEFAULT false,
  fee_cents         integer NOT NULL DEFAULT 0 CHECK (fee_cents >= 0),
  unit_all_in_cents integer NOT NULL CHECK (unit_all_in_cents >= 0),
  line_total_cents  integer NOT NULL CHECK (line_total_cents = unit_all_in_cents * quantity),
  PRIMARY KEY (session_id, line_no)
);
COMMENT ON TABLE public.exos_price_disclosure_lines IS
  'Lines of exos_price_disclosures: face price, tax, buyer fee (0) and the all-in unit price shown.';

-- Service role only; organizers read through exos_price_disclosure_export.
ALTER TABLE public.exos_price_disclosures      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_price_disclosure_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_price_disclosures      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.exos_price_disclosure_lines FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_price_disclosures      TO service_role;
GRANT ALL ON public.exos_price_disclosure_lines TO service_role;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_price_disclosures','exos_price_disclosure_lines'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 2. The shown side is a record: frozen once written.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_price_disclosure_frozen()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF TG_TABLE_NAME = 'exos_price_disclosure_lines' THEN
    RAISE EXCEPTION 'exos_price_disclosure_lines are immutable' USING ERRCODE = '42501';
  END IF;
  IF NEW.session_id IS DISTINCT FROM OLD.session_id
     OR NEW.event_id IS DISTINCT FROM OLD.event_id
     OR NEW.org_id IS DISTINCT FROM OLD.org_id
     OR NEW.currency IS DISTINCT FROM OLD.currency
     OR NEW.total_shown_cents IS DISTINCT FROM OLD.total_shown_cents
     OR NEW.shown_at IS DISTINCT FROM OLD.shown_at THEN
    RAISE EXCEPTION 'exos_price_disclosures: the shown price is immutable' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_price_disclosure_frozen() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_price_disclosures_frozen ON public.exos_price_disclosures;
CREATE TRIGGER exos_price_disclosures_frozen
  BEFORE UPDATE ON public.exos_price_disclosures
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_price_disclosure_frozen();
DROP TRIGGER IF EXISTS exos_price_disclosure_lines_frozen ON public.exos_price_disclosure_lines;
CREATE TRIGGER exos_price_disclosure_lines_frozen
  BEFORE UPDATE ON public.exos_price_disclosure_lines
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_price_disclosure_frozen();

-- ---------------------------------------------------------------------------
-- 3. Write the shown side (exos-checkout, after the session row exists).
--    p_lines: [{kind, item_id, name, quantity, face_unit_cents, tax_cents,
--               tax_included, fee_cents, unit_all_in_cents}, ...]
--    First write wins; a retry returns the stored total. Returns total shown.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_price_disclosure(
  p_session_id text,
  p_currency   text,
  p_lines      jsonb
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s        public.exos_checkout_sessions%ROWTYPE;
  v_total  integer;
  v_cur    text := lower(coalesce(p_currency, ''));
  v_n      integer;
BEGIN
  IF session_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_record_price_disclosure: service role only' USING ERRCODE = '42501';
  END IF;
  SELECT total_shown_cents INTO v_total FROM public.exos_price_disclosures WHERE session_id = p_session_id;
  IF FOUND THEN
    RETURN v_total;
  END IF;
  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_record_price_disclosure: session % not found', p_session_id;
  END IF;
  IF v_cur !~ '^[a-z]{3}$' THEN
    RAISE EXCEPTION 'exos_record_price_disclosure: bad currency %', p_currency;
  END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'exos_record_price_disclosure: p_lines must be an array';
  END IF;
  v_n := jsonb_array_length(p_lines);
  IF v_n < 1 OR v_n > 50 THEN
    RAISE EXCEPTION 'exos_record_price_disclosure: 1 to 50 lines, got %', v_n;
  END IF;

  -- Total shown = sum of the lines' all-in totals, fixed before anything is written.
  SELECT sum((el->>'unit_all_in_cents')::int * (el->>'quantity')::int)::int INTO v_total
    FROM jsonb_array_elements(p_lines) el;

  INSERT INTO public.exos_price_disclosures (session_id, event_id, org_id, currency, total_shown_cents)
  VALUES (p_session_id, s.event_id, s.org_id, v_cur, v_total)
  ON CONFLICT (session_id) DO NOTHING;
  IF NOT FOUND THEN  -- a concurrent call won
    SELECT total_shown_cents INTO v_total FROM public.exos_price_disclosures WHERE session_id = p_session_id;
    RETURN v_total;
  END IF;

  INSERT INTO public.exos_price_disclosure_lines (session_id, line_no, kind, item_id, item_name, quantity,
    face_unit_cents, tax_cents, tax_included, fee_cents, unit_all_in_cents, line_total_cents)
  SELECT p_session_id, l.ord::int,
         coalesce(l.el->>'kind', 'ticket'),
         CASE WHEN (l.el->>'item_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              THEN (l.el->>'item_id')::uuid END,
         left(coalesce(nullif(l.el->>'name', ''), 'Item'), 300),
         (l.el->>'quantity')::int,
         (l.el->>'face_unit_cents')::int,
         coalesce((l.el->>'tax_cents')::int, 0),
         coalesce((l.el->>'tax_included')::boolean, false),
         coalesce((l.el->>'fee_cents')::int, 0),
         (l.el->>'unit_all_in_cents')::int,
         (l.el->>'unit_all_in_cents')::int * (l.el->>'quantity')::int
    FROM jsonb_array_elements(p_lines) WITH ORDINALITY AS l(el, ord);

  RETURN v_total;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_price_disclosure(text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_price_disclosure(text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Write the charged side (stripe-webhook on completion). Idempotent: the
--    latest Stripe amount wins, charged_at keeps the first settle time.
--    Returns charge_mismatch, or NULL when no disclosure exists for the session
--    (sessions created before this migration).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_price_charged(
  p_session_id   text,
  p_amount_cents integer,
  p_currency     text DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_mm boolean;
BEGIN
  IF session_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_record_price_charged: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_amount_cents IS NULL OR p_amount_cents < 0 THEN
    RAISE EXCEPTION 'exos_record_price_charged: bad amount %', p_amount_cents;
  END IF;
  UPDATE public.exos_price_disclosures
     SET charged_cents    = p_amount_cents,
         charged_currency = coalesce(nullif(lower(p_currency), ''), currency),
         charged_at       = coalesce(charged_at, now())
   WHERE session_id = p_session_id
  RETURNING charge_mismatch INTO v_mm;
  IF v_mm THEN
    RAISE WARNING 'exos_record_price_charged: session % charged % but showed a different total', p_session_id, p_amount_cents;
  END IF;
  RETURN v_mm;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_price_charged(text, integer, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_record_price_charged(text, integer, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Organizer export: one row per line, per session, for an event.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_price_disclosure_export(p_event_id uuid)
RETURNS TABLE (
  session_id text, session_status text, shown_at timestamptz, currency text,
  line_no integer, kind text, item_name text, quantity integer,
  face_unit_cents integer, tax_cents integer, tax_included boolean, fee_cents integer,
  unit_all_in_cents integer, line_total_cents integer, total_shown_cents integer,
  charged_cents integer, charged_at timestamptz, charge_mismatch boolean
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_org uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_price_disclosure_export: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT e.org_id INTO v_org FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_price_disclosure_export: event not found';
  END IF;
  IF NOT (public.exos_is_admin() OR public.exos_has_org_role(v_org, ARRAY['owner','manager','finance'])) THEN
    RAISE EXCEPTION 'exos_price_disclosure_export: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT d.session_id, s.status, d.shown_at, d.currency,
         l.line_no, l.kind, l.item_name, l.quantity,
         l.face_unit_cents, l.tax_cents, l.tax_included, l.fee_cents,
         l.unit_all_in_cents, l.line_total_cents, d.total_shown_cents,
         d.charged_cents, d.charged_at, d.charge_mismatch
    FROM public.exos_price_disclosures d
    JOIN public.exos_price_disclosure_lines l ON l.session_id = d.session_id
    LEFT JOIN public.exos_checkout_sessions s ON s.session_id = d.session_id
   WHERE d.event_id = p_event_id
   ORDER BY d.shown_at, d.session_id, l.line_no;
END $$;
REVOKE ALL ON FUNCTION public.exos_price_disclosure_export(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_price_disclosure_export(uuid) TO authenticated, service_role;
