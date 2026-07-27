-- ============================================================================
-- Migration 20260523190000 — Exos (Bridge / D4): inventory distribution scaffold
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_distribution_listings (W, new), exos_request_distribution() (W, new)
-- Pre-reqs: 20260520120000 (exos_events.distribution_networks/automatiq_listing_id/
--           sync_status, exos_org_secrets.distribution), bridge_event_xref
--
-- "Toast for tickets" distribution layer (SCAFFOLD — Automatiq/Lysted creds wired
-- later). Insight: D1's storefront reads TEvo/EVO "owned" inventory, and Automatiq
-- distributes INTO EVO — so ONE path (Exos primary → Automatiq → EVO) surfaces an
-- organizer's inventory in the D1 storefront AND the wider secondary ecosystem.
-- bridge_event_xref.tevo_event_id is the canonical key that links the resulting
-- EVO listing back to the Exos primary (so D1 can route a buy to the in-house
-- checkout and we never double-count the same event).
--
-- ⚠ The live push is an UPSTREAM WRITE (creating listings on EVO/SeatGeek via
--   Automatiq/Lysted) — forbidden without explicit operator authorization +
--   provider creds (CLAUDE.md Hard Rule #2). This migration owns the intent/state
--   model only; the `exos-distribute` edge fn holds the (inert) push, gated on
--   AUTOMATIQ_API_KEY like the Stripe scaffold.
--
-- D4 authors; A1 applies. Live distribution stays gated until operator sign-off.
-- ============================================================================

-- Per-event-per-channel distribution state. distribution_networks on the event
-- selects WHICH channels; this table tracks the listing lifecycle per channel.
CREATE TABLE IF NOT EXISTS public.exos_distribution_listings (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id            uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  channel             text NOT NULL CHECK (channel IN ('automatiq','evo','seatgeek','stubhub','vivid','tickpick')),
  status              text NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','listing','listed','failed','delisting','delisted')),
  external_listing_id text,            -- Automatiq/exchange listing id once created
  requested_qty       integer CHECK (requested_qty IS NULL OR requested_qty >= 0),
  unit_price          numeric CHECK (unit_price IS NULL OR unit_price >= 0),
  last_synced_at      timestamptz,
  error               text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, channel)
);
CREATE INDEX IF NOT EXISTS exos_distribution_listings_event_idx  ON public.exos_distribution_listings (event_id);
CREATE INDEX IF NOT EXISTS exos_distribution_listings_status_idx ON public.exos_distribution_listings (status);

ALTER TABLE public.exos_distribution_listings ENABLE ROW LEVEL SECURITY;
-- Org staff read their org's distribution state; no client writes (RPC + edge fn).
CREATE POLICY exos_distribution_sel ON public.exos_distribution_listings FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager','finance']));
REVOKE ALL ON public.exos_distribution_listings FROM anon, authenticated;
GRANT  SELECT ON public.exos_distribution_listings TO authenticated;

-- Org owner/manager requests distribution of a published event to one or more
-- channels. Records intent (status='pending') for the exos-distribute edge fn to
-- pick up; does NOT call any upstream itself.
CREATE OR REPLACE FUNCTION public.exos_request_distribution(
  p_event_id  uuid,
  p_channels  text[],
  p_qty       int     DEFAULT NULL,
  p_unit_price numeric DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_status text;
  v_chan   text;
  v_n      int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_request_distribution: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status INTO v_org, v_status FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_request_distribution: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_request_distribution: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_request_distribution: event must be published (is %)', v_status;
  END IF;
  IF p_channels IS NULL OR array_length(p_channels, 1) IS NULL THEN
    RAISE EXCEPTION 'exos_request_distribution: no channels specified';
  END IF;

  FOREACH v_chan IN ARRAY p_channels LOOP
    INSERT INTO public.exos_distribution_listings (event_id, org_id, channel, status, requested_qty, unit_price)
    VALUES (p_event_id, v_org, v_chan, 'pending', p_qty, p_unit_price)
    ON CONFLICT (event_id, channel) DO UPDATE
      SET status = 'pending', requested_qty = EXCLUDED.requested_qty,
          unit_price = EXCLUDED.unit_price, error = NULL, updated_at = now();
    v_n := v_n + 1;
  END LOOP;

  UPDATE public.exos_events
     SET distribution_networks = p_channels, sync_status = 'pending', updated_at = now()
   WHERE id = p_event_id;

  RETURN v_n;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_request_distribution(uuid, text[], int, numeric) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_request_distribution(uuid, text[], int, numeric) TO authenticated;
