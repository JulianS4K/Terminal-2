-- ============================================================================
-- Migration 20260926020000 — Exos (Bridge / D4): promoter commissions
--                            (terms, accrual ledger, payouts)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_promoters (+commission_bps, +commission_flat_cents),
--              TABLE exos_promoter_event_terms, exos_promoter_payouts,
--              exos_promoter_commissions (new),
--              FUNCTION exos_pc_commission_cents, exos_pc_accrue_ticket,
--              exos_set_promoter_terms, exos_record_promoter_payout,
--              exos_org_promoter_commissions, exos_promoter_earnings (new),
--              TRIGGER exos_tickets_pc_accrue, exos_tickets_pc_status,
--              exos_promoters_pc_backfill (new)
--           R: exos_tickets, exos_checkout_sessions, exos_events, exos_orgs,
--              exos_org_memberships
-- Pre-reqs: 20260924233000 (exos_promoters), 20260924223000 (paid tickets
--           carry promoter_id), 20260924205115 (refund voids tickets)
--
-- Promoters could see their sales but not what they'd earned, and organizers
-- tracked payouts in a spreadsheet. (Posh's "Kickback" pays a cut per sale.)
-- Neither hi.events nor pretix has promoter commissions, so this is our own
-- design:
--
--   * Terms. exos_promoters.commission_bps (basis points of the base) and
--     commission_flat_cents (per ticket) are the promoter's default; a row in
--     exos_promoter_event_terms overrides BOTH for one event. Owner / manager
--     set them (exos_set_promoter_terms). New terms apply to new sales; pass
--     p_reprice_accrued to re-price rows that are accrued and not yet paid.
--
--   * Accrual. One exos_promoter_commissions row per attributed ticket
--     (UNIQUE ticket_id, so replaying fulfillment or the backfill can never
--     double-accrue). Written by an AFTER INSERT trigger on exos_tickets, and
--     by a backfill when a promoter record is created for a code that already
--     has sales. The base is what the org earns from the ticket:
--       Stripe order: (amount_cents - add-on net - tax_cents) / quantity,
--                     floored to the cent (add-ons and all tax come out; the
--                     platform fee is NOT taken off, it's the org's cost).
--       No session:   price_paid in cents (staff-minted paid tickets).
--     Comps (channel_source 'comp') and free tickets have base 0: no row.
--     commission = min(base, floor(base * bps / 10000) + flat). Integer cents,
--     floor to the cent; the cap means a flat fee never exceeds the ticket.
--     Same math as EXP src/lib/commissions.ts (commissionCents).
--     Rows accrue whatever the promoter's status; pausing only closes the kit.
--
--   * Reversal. The commission follows the ticket: when a ticket leaves the
--     valid states (voided by a refund, a full-order refund, a staff void), its
--     row is reversed IN FULL. A partial refund that leaves the ticket valid
--     does not change the commission (operator can void the refunded tickets).
--     A row reversed after it was paid is a clawback: it's netted out of the
--     promoter's next payout.
--
--   * Payouts. exos_record_promoter_payout records money the organizer paid
--     outside Exos (method is free text: "Venmo", "cash"), covering selected
--     accrued rows of one currency, less any outstanding clawbacks. The amount
--     must equal that net (guards against a stale screen). Rows flip to
--     'paid'. No money moves; Stripe Connect transfers are a follow-up.
--
--   * Reads. exos_org_promoter_commissions (owner / manager / finance) per
--     promoter and currency; exos_promoter_earnings(token) for the promoter's
--     portal: their own totals, per-event breakdown and payouts, no buyer
--     data. Staff may also SELECT the three tables through RLS.
--
-- Idempotent. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Terms.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_promoters
  ADD COLUMN IF NOT EXISTS commission_bps integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS commission_flat_cents integer NOT NULL DEFAULT 0;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'exos_promoters_commission_chk') THEN
    ALTER TABLE public.exos_promoters ADD CONSTRAINT exos_promoters_commission_chk
      CHECK (commission_bps BETWEEN 0 AND 10000 AND commission_flat_cents BETWEEN 0 AND 100000);
  END IF;
END $$;
COMMENT ON COLUMN public.exos_promoters.commission_bps IS
  'Default commission, basis points of the ticket base (paid price net of tax). mig 20260926020000.';
COMMENT ON COLUMN public.exos_promoters.commission_flat_cents IS
  'Default flat commission per paid ticket, cents. mig 20260926020000.';

CREATE TABLE IF NOT EXISTS public.exos_promoter_event_terms (
  promoter_id uuid NOT NULL REFERENCES public.exos_promoters (id) ON DELETE CASCADE,
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  rate_bps    integer NOT NULL DEFAULT 0 CHECK (rate_bps BETWEEN 0 AND 10000),
  flat_cents  integer NOT NULL DEFAULT 0 CHECK (flat_cents BETWEEN 0 AND 100000),
  updated_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (promoter_id, event_id)
);
CREATE INDEX IF NOT EXISTS exos_promoter_event_terms_org_idx ON public.exos_promoter_event_terms (org_id);
CREATE INDEX IF NOT EXISTS exos_promoter_event_terms_event_idx ON public.exos_promoter_event_terms (event_id);

-- ---------------------------------------------------------------------------
-- 2. Payouts + ledger.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_promoter_payouts (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  promoter_id      uuid NOT NULL REFERENCES public.exos_promoters (id) ON DELETE CASCADE,
  currency         text NOT NULL,
  amount_cents     integer NOT NULL CHECK (amount_cents >= 0),
  commission_cents integer NOT NULL CHECK (commission_cents >= 0),
  clawback_cents   integer NOT NULL DEFAULT 0 CHECK (clawback_cents >= 0),
  row_count        integer NOT NULL CHECK (row_count >= 1),
  method           text NOT NULL CHECK (length(btrim(method)) BETWEEN 1 AND 60),
  note             text CHECK (note IS NULL OR length(note) <= 500),
  paid_on          date NOT NULL DEFAULT current_date,
  created_by       uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  CHECK (amount_cents = commission_cents - clawback_cents)
);
CREATE INDEX IF NOT EXISTS exos_promoter_payouts_promoter_idx ON public.exos_promoter_payouts (promoter_id);
CREATE INDEX IF NOT EXISTS exos_promoter_payouts_org_idx ON public.exos_promoter_payouts (org_id);

CREATE TABLE IF NOT EXISTS public.exos_promoter_commissions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  promoter_id         uuid NOT NULL REFERENCES public.exos_promoters (id) ON DELETE CASCADE,
  event_id            uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  ticket_id           uuid UNIQUE REFERENCES public.exos_tickets (id) ON DELETE SET NULL,
  currency            text NOT NULL DEFAULT 'usd',
  gross_cents         integer NOT NULL CHECK (gross_cents >= 0),
  base_cents          integer NOT NULL CHECK (base_cents > 0),
  rate_bps            integer NOT NULL CHECK (rate_bps BETWEEN 0 AND 10000),
  flat_cents          integer NOT NULL CHECK (flat_cents BETWEEN 0 AND 100000),
  terms_source        text NOT NULL CHECK (terms_source IN ('promoter', 'event')),
  commission_cents    integer NOT NULL CHECK (commission_cents >= 0 AND commission_cents <= base_cents),
  status              text NOT NULL DEFAULT 'accrued' CHECK (status IN ('accrued', 'reversed', 'paid')),
  accrued_at          timestamptz NOT NULL DEFAULT now(),
  reversed_at         timestamptz,
  reversed_reason     text,
  payout_id           uuid REFERENCES public.exos_promoter_payouts (id) ON DELETE SET NULL,
  paid_at             timestamptz,
  -- Set on a row reversed after it was paid, once a later payout nets it out.
  recovered_payout_id uuid REFERENCES public.exos_promoter_payouts (id) ON DELETE SET NULL,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'paid' OR payout_id IS NOT NULL),
  CHECK (status <> 'reversed' OR reversed_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS exos_promoter_commissions_promoter_idx ON public.exos_promoter_commissions (promoter_id, status);
CREATE INDEX IF NOT EXISTS exos_promoter_commissions_org_idx ON public.exos_promoter_commissions (org_id);
CREATE INDEX IF NOT EXISTS exos_promoter_commissions_event_idx ON public.exos_promoter_commissions (event_id);
CREATE INDEX IF NOT EXISTS exos_promoter_commissions_payout_idx ON public.exos_promoter_commissions (payout_id) WHERE payout_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_promoter_commissions_recovered_idx ON public.exos_promoter_commissions (recovered_payout_id) WHERE recovered_payout_id IS NOT NULL;

-- RLS: staff who see promoter sales (owner / manager / finance) read; every
-- write goes through the SECURITY DEFINER functions below.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_promoter_event_terms','exos_promoter_payouts','exos_promoter_commissions'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    EXECUTE format('GRANT ALL ON public.%I TO service_role', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_staff_read', t);
    EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT TO authenticated
                    USING (public.exos_has_org_role(org_id, ARRAY[''owner'', ''manager'', ''finance'']))',
                   t || '_staff_read', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Math + accrual.
-- ---------------------------------------------------------------------------
-- min(base, floor(base * bps / 10000) + flat); 0 for a non-positive base.
-- Mirrors EXP src/lib/commissions.ts commissionCents.
CREATE OR REPLACE FUNCTION public.exos_pc_commission_cents(p_base_cents integer, p_rate_bps integer, p_flat_cents integer)
RETURNS integer
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN coalesce(p_base_cents, 0) <= 0 THEN 0
    ELSE least(p_base_cents::bigint,
               (p_base_cents::bigint * greatest(coalesce(p_rate_bps, 0), 0)) / 10000
               + greatest(coalesce(p_flat_cents, 0), 0))::integer
  END
$$;
REVOKE ALL ON FUNCTION public.exos_pc_commission_cents(integer, integer, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_pc_commission_cents(integer, integer, integer) TO authenticated, service_role;

-- Accrue one ticket (no-op when it isn't a valid, paid, attributed ticket of a
-- registered promoter, or already has a row). Internal: triggers only.
CREATE OR REPLACE FUNCTION public.exos_pc_accrue_ticket(p_ticket_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t       public.exos_tickets%ROWTYPE;
  p       public.exos_promoters%ROWTYPE;
  s       public.exos_checkout_sessions%ROWTYPE;
  v_gross integer;
  v_base  integer;
  v_addon integer;
  v_bps   integer;
  v_flat  integer;
  v_src   text := 'promoter';
  v_cur   text;
  v_id    uuid;
BEGIN
  SELECT * INTO t FROM public.exos_tickets WHERE id = p_ticket_id;
  IF NOT FOUND OR t.promoter_id IS NULL
     OR t.status NOT IN ('active', 'used', 'transferred')
     OR t.channel_source = 'comp'
     OR coalesce(t.price_paid, 0) <= 0 THEN
    RETURN false;
  END IF;
  SELECT * INTO p FROM public.exos_promoters WHERE org_id = t.org_id AND code = t.promoter_id;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_gross := round(t.price_paid * 100)::integer;
  IF t.order_ref IS NOT NULL THEN
    SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = t.order_ref;
  END IF;
  IF s.session_id IS NOT NULL AND s.quantity > 0 THEN
    SELECT coalesce(sum(coalesce((a->>'quantity')::int, 0) * coalesce((a->>'unit_price_cents')::int, 0)), 0)
      INTO v_addon
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.addons) = 'array' THEN s.addons ELSE '[]'::jsonb END) a;
    -- Integer division floors (the numerator is clamped to >= 0).
    v_base := least(greatest(s.amount_cents - v_addon - coalesce(s.tax_cents, 0), 0) / s.quantity, v_gross);
    v_cur  := lower(coalesce(s.currency, 'usd'));
  ELSE
    v_base := v_gross;
    SELECT lower(coalesce(e.currency, 'usd')) INTO v_cur FROM public.exos_events e WHERE e.id = t.event_id;
  END IF;
  IF coalesce(v_base, 0) <= 0 THEN
    RETURN false;
  END IF;

  SELECT o.rate_bps, o.flat_cents INTO v_bps, v_flat
    FROM public.exos_promoter_event_terms o
   WHERE o.promoter_id = p.id AND o.event_id = t.event_id;
  IF FOUND THEN
    v_src := 'event';
  ELSE
    v_bps := p.commission_bps; v_flat := p.commission_flat_cents;
  END IF;

  INSERT INTO public.exos_promoter_commissions (
    org_id, promoter_id, event_id, ticket_id, currency, gross_cents, base_cents,
    rate_bps, flat_cents, terms_source, commission_cents
  ) VALUES (
    t.org_id, p.id, t.event_id, t.id, coalesce(v_cur, 'usd'), greatest(v_gross, 0), v_base,
    v_bps, v_flat, v_src, public.exos_pc_commission_cents(v_base, v_bps, v_flat)
  )
  ON CONFLICT (ticket_id) DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id IS NOT NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_pc_accrue_ticket(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_pc_accrue_ticket(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.exos_tg_pc_ticket_accrue()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.exos_pc_accrue_ticket(NEW.id);
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_pc_ticket_accrue() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.exos_tg_pc_ticket_status()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.status NOT IN ('active', 'used', 'transferred') AND OLD.status IN ('active', 'used', 'transferred') THEN
    UPDATE public.exos_promoter_commissions
       SET status = 'reversed', reversed_at = now(),
           reversed_reason = left(coalesce(NEW.voided_reason, NEW.status), 200),
           updated_at = now()
     WHERE ticket_id = NEW.id AND status IN ('accrued', 'paid');
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_pc_ticket_status() FROM PUBLIC, anon, authenticated;

-- A promoter record created for a code that's already on sales picks them up.
CREATE OR REPLACE FUNCTION public.exos_tg_pc_promoter_backfill()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT t.id FROM public.exos_tickets t
            WHERE t.org_id = NEW.org_id AND t.promoter_id = NEW.code
              AND t.status IN ('active', 'used', 'transferred') AND t.price_paid > 0
  LOOP
    PERFORM public.exos_pc_accrue_ticket(r.id);
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_pc_promoter_backfill() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_tickets_pc_accrue ON public.exos_tickets;
CREATE TRIGGER exos_tickets_pc_accrue
  AFTER INSERT ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.promoter_id IS NOT NULL)
  EXECUTE FUNCTION public.exos_tg_pc_ticket_accrue();

DROP TRIGGER IF EXISTS exos_tickets_pc_status ON public.exos_tickets;
CREATE TRIGGER exos_tickets_pc_status
  AFTER UPDATE OF status ON public.exos_tickets
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status AND NEW.promoter_id IS NOT NULL)
  EXECUTE FUNCTION public.exos_tg_pc_ticket_status();

DROP TRIGGER IF EXISTS exos_promoters_pc_backfill ON public.exos_promoters;
CREATE TRIGGER exos_promoters_pc_backfill
  AFTER INSERT ON public.exos_promoters
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_pc_promoter_backfill();

-- Backfill existing sales of registered promoters (at their current terms,
-- which are 0 until set; re-price with exos_set_promoter_terms). Re-run safe.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT t.id FROM public.exos_tickets t
             JOIN public.exos_promoters p ON p.org_id = t.org_id AND p.code = t.promoter_id
            WHERE t.status IN ('active', 'used', 'transferred') AND t.price_paid > 0
              AND NOT EXISTS (SELECT 1 FROM public.exos_promoter_commissions c WHERE c.ticket_id = t.id)
  LOOP
    PERFORM public.exos_pc_accrue_ticket(r.id);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 4. Set terms (owner / manager).
--    p_event_id NULL: the promoter's default (NULLs mean 0).
--    p_event_id set:  that event's override; both NULL removes the override.
--    p_reprice_accrued: re-price this promoter's accrued (unpaid) rows in
--    scope at the terms now in effect. Returns the rows re-priced.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_set_promoter_terms(
  p_promoter_id     uuid,
  p_rate_bps        integer,
  p_flat_cents      integer,
  p_event_id        uuid    DEFAULT NULL,
  p_reprice_accrued boolean DEFAULT false
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_n   integer := 0;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_promoter_terms: not allowed' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_rate_bps, 0) NOT BETWEEN 0 AND 10000 THEN
    RAISE EXCEPTION 'Commission percent must be between 0 and 100.' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_flat_cents, 0) NOT BETWEEN 0 AND 100000 THEN
    RAISE EXCEPTION 'Flat commission must be between 0 and 1,000 per ticket.' USING ERRCODE = '22023';
  END IF;

  IF p_event_id IS NULL THEN
    UPDATE public.exos_promoters
       SET commission_bps = coalesce(p_rate_bps, 0),
           commission_flat_cents = coalesce(p_flat_cents, 0),
           updated_at = now()
     WHERE id = p_promoter_id;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.exos_events WHERE id = p_event_id AND org_id = v_org) THEN
      RAISE EXCEPTION 'exos_set_promoter_terms: event is not this organizer''s' USING ERRCODE = '22023';
    END IF;
    IF p_rate_bps IS NULL AND p_flat_cents IS NULL THEN
      DELETE FROM public.exos_promoter_event_terms WHERE promoter_id = p_promoter_id AND event_id = p_event_id;
    ELSE
      INSERT INTO public.exos_promoter_event_terms AS o (promoter_id, event_id, org_id, rate_bps, flat_cents, updated_by)
      VALUES (p_promoter_id, p_event_id, v_org, coalesce(p_rate_bps, 0), coalesce(p_flat_cents, 0), auth.uid())
      ON CONFLICT (promoter_id, event_id) DO UPDATE SET
        rate_bps = EXCLUDED.rate_bps, flat_cents = EXCLUDED.flat_cents,
        updated_by = EXCLUDED.updated_by, updated_at = now();
    END IF;
  END IF;

  IF p_reprice_accrued THEN
    UPDATE public.exos_promoter_commissions c
       SET rate_bps = x.bps, flat_cents = x.flat, terms_source = x.src,
           commission_cents = public.exos_pc_commission_cents(c.base_cents, x.bps, x.flat),
           updated_at = now()
      FROM (
        SELECT c2.id,
               coalesce(o.rate_bps, p.commission_bps) AS bps,
               coalesce(o.flat_cents, p.commission_flat_cents) AS flat,
               CASE WHEN o.promoter_id IS NULL THEN 'promoter' ELSE 'event' END AS src
          FROM public.exos_promoter_commissions c2
          JOIN public.exos_promoters p ON p.id = c2.promoter_id
          LEFT JOIN public.exos_promoter_event_terms o ON o.promoter_id = c2.promoter_id AND o.event_id = c2.event_id
         WHERE c2.promoter_id = p_promoter_id AND c2.status = 'accrued'
           AND (p_event_id IS NULL OR c2.event_id = p_event_id)
      ) x
     WHERE c.id = x.id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_promoter_terms(uuid, integer, integer, uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_promoter_terms(uuid, integer, integer, uuid, boolean) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Record a payout (owner / manager). The selected rows must all be this
--    promoter's, accrued (not reversed or already paid) and in one currency.
--    Outstanding clawbacks in that currency are netted out; p_amount_cents
--    must equal the net. Returns the payout id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_record_promoter_payout(
  p_promoter_id    uuid,
  p_commission_ids uuid[],
  p_amount_cents   integer,
  p_method         text,
  p_note           text DEFAULT NULL,
  p_paid_on        date DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org      uuid;
  v_ids      uuid[];
  v_found    integer;
  v_cur      text;
  v_ncur     integer;
  v_sum      bigint;
  v_claw     bigint;
  v_id       uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id FOR UPDATE;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_record_promoter_payout: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_method IS NULL OR length(btrim(p_method)) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'Say how you paid (e.g. Venmo), up to 60 characters.' USING ERRCODE = '22023';
  END IF;
  IF p_note IS NOT NULL AND length(p_note) > 500 THEN
    RAISE EXCEPTION 'Note is too long (500 characters max).' USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_commission_ids) x WHERE x IS NOT NULL;
  IF coalesce(cardinality(v_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Pick at least one sale to pay out.' USING ERRCODE = '22023';
  END IF;

  PERFORM 1 FROM public.exos_promoter_commissions
    WHERE id = ANY (v_ids) FOR UPDATE;
  SELECT count(*), min(currency), count(DISTINCT currency), coalesce(sum(commission_cents), 0)
    INTO v_found, v_cur, v_ncur, v_sum
    FROM public.exos_promoter_commissions
   WHERE id = ANY (v_ids) AND promoter_id = p_promoter_id AND status = 'accrued';
  IF v_found <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'Some of the selected sales can''t be paid (reversed, already paid, or not this promoter''s). Reload and try again.'
      USING ERRCODE = '22023';
  END IF;
  IF v_ncur <> 1 THEN
    RAISE EXCEPTION 'Pay out one currency at a time.' USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(sum(commission_cents), 0) INTO v_claw
    FROM public.exos_promoter_commissions
   WHERE promoter_id = p_promoter_id AND currency = v_cur AND status = 'reversed'
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL;
  IF v_sum - v_claw < 0 THEN
    RAISE EXCEPTION 'Refunds on already-paid sales (%) are more than this payout. Nothing is owed yet.', v_claw
      USING ERRCODE = '22023';
  END IF;
  IF p_amount_cents IS DISTINCT FROM (v_sum - v_claw)::integer THEN
    RAISE EXCEPTION 'Amount doesn''t match the selected sales (expected % cents). Reload and try again.', v_sum - v_claw
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.exos_promoter_payouts (
    org_id, promoter_id, currency, amount_cents, commission_cents, clawback_cents,
    row_count, method, note, paid_on, created_by
  ) VALUES (
    v_org, p_promoter_id, v_cur, p_amount_cents, v_sum, v_claw,
    cardinality(v_ids), btrim(p_method), NULLIF(btrim(coalesce(p_note, '')), ''),
    coalesce(p_paid_on, current_date), auth.uid()
  ) RETURNING id INTO v_id;

  UPDATE public.exos_promoter_commissions
     SET status = 'paid', payout_id = v_id, paid_at = now(), updated_at = now()
   WHERE id = ANY (v_ids);
  UPDATE public.exos_promoter_commissions
     SET recovered_payout_id = v_id, updated_at = now()
   WHERE promoter_id = p_promoter_id AND currency = v_cur AND status = 'reversed'
     AND payout_id IS NOT NULL AND recovered_payout_id IS NULL;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_record_promoter_payout(uuid, uuid[], integer, text, text, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_record_promoter_payout(uuid, uuid[], integer, text, text, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Organizer view (owner / manager / finance): one row per promoter and
--    currency (a promoter with no sales yet: one row, currency NULL).
--    tickets / gross / base count rows that aren't reversed. paid = rows paid
--    out; clawback = reversed after payment, not yet netted; owed = accrued -
--    clawback (negative: the promoter was overpaid).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_org_promoter_commissions(p_org_id uuid, p_event_id uuid DEFAULT NULL)
RETURNS TABLE (
  promoter_id uuid, code text, name text, status text, rate_bps integer, flat_cents integer,
  currency text, tickets bigint, gross_cents bigint, base_cents bigint,
  accrued_cents bigint, reversed_cents bigint, paid_cents bigint, clawback_cents bigint, owed_cents bigint
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_org_promoter_commissions: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT p.id, p.code, p.name, p.status, p.commission_bps, p.commission_flat_cents,
           c.currency,
           count(c.id) FILTER (WHERE c.status <> 'reversed'),
           coalesce(sum(c.gross_cents) FILTER (WHERE c.status <> 'reversed'), 0)::bigint,
           coalesce(sum(c.base_cents) FILTER (WHERE c.status <> 'reversed'), 0)::bigint,
           coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0)::bigint,
           coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed'), 0)::bigint,
           coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'paid'), 0)::bigint,
           coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed' AND c.payout_id IS NOT NULL
                                                      AND c.recovered_payout_id IS NULL), 0)::bigint,
           (coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0)
            - coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed' AND c.payout_id IS NOT NULL
                                                        AND c.recovered_payout_id IS NULL), 0))::bigint
      FROM public.exos_promoters p
      LEFT JOIN public.exos_promoter_commissions c
             ON c.promoter_id = p.id AND (p_event_id IS NULL OR c.event_id = p_event_id)
     WHERE p.org_id = p_org_id
     GROUP BY p.id, p.code, p.name, p.status, p.commission_bps, p.commission_flat_cents, c.currency
     ORDER BY 15 DESC, p.name;
END $$;
REVOKE ALL ON FUNCTION public.exos_org_promoter_commissions(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_org_promoter_commissions(uuid, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Promoter portal (/p/:token): their own earnings. Same gate as
--    exos_promoter_kit (active promoter, exact token). No ticket ids, order
--    refs, buyer data or payout notes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_promoter_earnings(p_token uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'promoter', jsonb_build_object('name', p.name, 'code', p.code),
    'terms', jsonb_build_object('rate_bps', p.commission_bps, 'flat_cents', p.commission_flat_cents),
    'totals', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'currency', x.currency, 'tickets', x.tickets, 'accrued_cents', x.accrued,
               'paid_cents', x.paid, 'reversed_cents', x.reversed, 'clawback_cents', x.claw,
               'owed_cents', x.accrued - x.claw) ORDER BY x.currency)
        FROM (
          SELECT c.currency,
                 count(*) FILTER (WHERE c.status <> 'reversed') AS tickets,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0) AS accrued,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'paid'), 0) AS paid,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed'), 0) AS reversed,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed' AND c.payout_id IS NOT NULL
                                                            AND c.recovered_payout_id IS NULL), 0) AS claw
            FROM public.exos_promoter_commissions c
           WHERE c.promoter_id = p.id
           GROUP BY c.currency
        ) x
    ), '[]'::jsonb),
    'events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'event_id', e.id, 'name', e.name, 'starts_at', e.starts_at, 'currency', y.currency,
               'rate_bps', coalesce(o.rate_bps, p.commission_bps),
               'flat_cents', coalesce(o.flat_cents, p.commission_flat_cents),
               'tickets', y.tickets, 'base_cents', y.base, 'accrued_cents', y.accrued,
               'paid_cents', y.paid, 'reversed_cents', y.reversed)
             ORDER BY e.starts_at DESC NULLS LAST)
        FROM (
          SELECT c.event_id, c.currency,
                 count(*) FILTER (WHERE c.status <> 'reversed') AS tickets,
                 coalesce(sum(c.base_cents) FILTER (WHERE c.status <> 'reversed'), 0) AS base,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'accrued'), 0) AS accrued,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'paid'), 0) AS paid,
                 coalesce(sum(c.commission_cents) FILTER (WHERE c.status = 'reversed'), 0) AS reversed
            FROM public.exos_promoter_commissions c
           WHERE c.promoter_id = p.id
           GROUP BY c.event_id, c.currency
        ) y
        JOIN public.exos_events e ON e.id = y.event_id
        LEFT JOIN public.exos_promoter_event_terms o ON o.promoter_id = p.id AND o.event_id = e.id
    ), '[]'::jsonb),
    'payouts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'paid_on', po.paid_on, 'amount_cents', po.amount_cents, 'currency', po.currency,
               'method', po.method, 'sales', po.row_count)
             ORDER BY po.paid_on DESC, po.created_at DESC)
        FROM public.exos_promoter_payouts po
       WHERE po.promoter_id = p.id
    ), '[]'::jsonb)
  )
  FROM public.exos_promoters p
  WHERE p.kit_token = p_token AND p.status = 'active';
$$;
REVOKE ALL ON FUNCTION public.exos_promoter_earnings(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_earnings(uuid) TO anon, authenticated, service_role;
