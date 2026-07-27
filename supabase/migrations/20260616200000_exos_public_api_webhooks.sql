-- ============================================================================
-- Migration 20260616200000 — Exos (Bridge / D4): public API keys + webhooks
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_api_keys (W,new), exos_webhooks (W,new),
--           exos_webhook_deliveries (W,new), exos_enqueue_webhook (W,new) +
--           AFTER triggers on exos_tickets / exos_event_checkins /
--           exos_checkout_sessions / exos_events; exos_create_api_key /
--           exos_revoke_api_key / exos_list_api_keys (W,new RPCs)
-- Pre-reqs: 20260520120000 (orgs/events/has_org_role), 20260520130000
--           (tickets/checkins), 20260523170000 (checkout sessions), pgcrypto
--           (extensions.digest / extensions.gen_random_bytes — confirmed installed)
--
-- Feature parity with Hi.Events' developer surface: an outbound REST API
-- (read-only, org-scoped, API-key auth) + outbound webhooks so a venue can
-- integrate Exos with its own systems.
--   * exos_api_keys — only a SHA-256 HASH + a display prefix are stored; the
--     plaintext is shown ONCE at creation (exos_create_api_key). The edge fn
--     exos-api authenticates by hashing the presented key.
--   * exos_webhooks — org-registered HTTPS endpoints + per-hook signing secret
--     + subscribed event types.
--   * AFTER triggers enqueue exos_webhook_deliveries on the real lifecycle
--     events (ticket.created / ticket.checked_in / order.fulfilled /
--     order.refunded / event.published) — at the TABLE layer, so comp, free,
--     and paid paths all emit uniformly without re-touching the SECDEF mint
--     functions. The exos-webhook-drain edge fn POSTs them HMAC-signed, with an
--     SSRF guard + retry/backoff (delivery-time concerns live in the edge fn).
-- Security mirrors phase-1: deny-by-default RLS; API-key rows are NEVER client-
-- readable (managed only through SECDEF RPCs); delivery ledger is trigger/
-- service_role write.
-- ⚠ B1 review: new auth surface (API keys) + outbound HTTP (SSRF). The edge fn
--   enforces https-only + private-IP block at send time; keys are hash-at-rest.
-- D4 authors; A1 applies to prod. The drainer needs a cron (operator schedules).
-- ============================================================================

-- ===========================================================================
-- 1. API keys — hash-at-rest, org-scoped, revocable.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_api_keys (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  name        text,
  key_prefix  text NOT NULL,                 -- e.g. 'sk_live_1a2b3c' (display/identify only)
  key_hash    text NOT NULL UNIQUE,          -- sha256 hex of the full key (auth compares this)
  scopes      text[] NOT NULL DEFAULT ARRAY['read'],
  last_used_at timestamptz,
  revoked_at  timestamptz,
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_api_keys_org_idx  ON public.exos_api_keys (org_id);
CREATE INDEX IF NOT EXISTS exos_api_keys_hash_idx ON public.exos_api_keys (key_hash) WHERE revoked_at IS NULL;

-- ===========================================================================
-- 2. Webhooks — org endpoints + signing secret + subscribed event types.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_webhooks (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  url         text NOT NULL CHECK (url ~ '^https://'),   -- https only (SSRF guard at send time)
  -- Strong default so a client INSERT can't ship a weak/empty signing secret.
  secret      text NOT NULL DEFAULT encode(extensions.gen_random_bytes(24), 'hex'),
  -- '*' = all event types; else a subset of the known names.
  event_types text[] NOT NULL DEFAULT ARRAY['*'],
  enabled     boolean NOT NULL DEFAULT true,
  description text,
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_webhooks_org_idx ON public.exos_webhooks (org_id);

-- ===========================================================================
-- 3. Delivery queue + ledger. One row per (event, subscribed webhook).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_webhook_deliveries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  webhook_id      uuid NOT NULL REFERENCES public.exos_webhooks (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL,
  event_type      text NOT NULL,
  payload         jsonb NOT NULL,
  status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','delivered','failed','dead')),
  attempts        int NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_status_code int,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  delivered_at    timestamptz
);
-- Drainer claims due rows oldest-first.
CREATE INDEX IF NOT EXISTS exos_webhook_deliveries_due_idx
  ON public.exos_webhook_deliveries (next_attempt_at) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS exos_webhook_deliveries_org_idx ON public.exos_webhook_deliveries (org_id);

-- updated_at touches.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['exos_api_keys','exos_webhooks'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON public.%I
                      FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
  END LOOP;
END $$;

-- ===========================================================================
-- 4. RLS.
-- ===========================================================================
ALTER TABLE public.exos_api_keys           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_webhooks           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_webhook_deliveries ENABLE ROW LEVEL SECURITY;

-- API keys: NO client policy at all → no direct read/write. Managed only via the
-- SECDEF RPCs below (so the hash is never selectable by a client). service_role
-- (the exos-api edge fn) bypasses RLS to authenticate.
REVOKE ALL ON public.exos_api_keys FROM anon, authenticated;

-- Webhooks: org owner/manager manage directly (they need the secret to verify
-- signatures on their endpoint).
CREATE POLICY exos_webhooks_all ON public.exos_webhooks FOR ALL TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager']))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_webhooks FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON public.exos_webhooks TO authenticated;

-- Deliveries: org staff read their log; writes are trigger/service_role only.
CREATE POLICY exos_webhook_deliveries_sel ON public.exos_webhook_deliveries FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager']));
REVOKE ALL ON public.exos_webhook_deliveries FROM anon, authenticated;
GRANT  SELECT ON public.exos_webhook_deliveries TO authenticated;

-- ===========================================================================
-- 5. Emission: fan an event out to every enabled, subscribed webhook of an org.
--    SECURITY DEFINER (called from AFTER triggers running as the acting user).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_enqueue_webhook(
  p_org_id uuid, p_event_type text, p_payload jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_org_id IS NULL THEN RETURN; END IF;
  INSERT INTO public.exos_webhook_deliveries (webhook_id, org_id, event_type, payload)
  SELECT w.id, w.org_id, p_event_type,
         jsonb_build_object(
           'type', p_event_type,
           'org_id', w.org_id,
           'created_at', now(),
           'data', p_payload)
  FROM public.exos_webhooks w
  WHERE w.org_id = p_org_id
    AND w.enabled
    AND ('*' = ANY (w.event_types) OR p_event_type = ANY (w.event_types));
END $$;
REVOKE ALL ON FUNCTION public.exos_enqueue_webhook(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_enqueue_webhook(uuid, text, jsonb) TO service_role;

-- ---- trigger fns (one per source table) -----------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_ticket_created()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public.exos_enqueue_webhook(NEW.org_id, 'ticket.created', jsonb_build_object(
    'ticket_id', NEW.id, 'event_id', NEW.event_id, 'tier_name', NEW.tier_name,
    'owner_email', NEW.buyer_email, 'price_paid', NEW.price_paid,
    'channel_source', NEW.channel_source, 'order_ref', NEW.order_ref));
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.exos_tg_ticket_checked_in()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM public.exos_enqueue_webhook(NEW.org_id, 'ticket.checked_in', jsonb_build_object(
    'ticket_id', NEW.ticket_id, 'event_id', NEW.event_id,
    'verification', NEW.verification, 'scanned_at', NEW.scanned_at));
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.exos_tg_checkout_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status = 'fulfilled' AND OLD.status IS DISTINCT FROM 'fulfilled' THEN
    PERFORM public.exos_enqueue_webhook(NEW.org_id, 'order.fulfilled', jsonb_build_object(
      'session_id', NEW.session_id, 'event_id', NEW.event_id, 'quantity', NEW.quantity,
      'amount_cents', NEW.amount_cents, 'currency', NEW.currency, 'buyer_email', NEW.buyer_email));
  ELSIF NEW.status = 'refunded' AND OLD.status IS DISTINCT FROM 'refunded' THEN
    PERFORM public.exos_enqueue_webhook(NEW.org_id, 'order.refunded', jsonb_build_object(
      'session_id', NEW.session_id, 'event_id', NEW.event_id, 'amount_cents', NEW.amount_cents));
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public.exos_tg_event_published()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF NEW.status = 'published' AND OLD.status IS DISTINCT FROM 'published' THEN
    PERFORM public.exos_enqueue_webhook(NEW.org_id, 'event.published', jsonb_build_object(
      'event_id', NEW.id, 'name', NEW.name, 'slug', NEW.slug, 'starts_at', NEW.starts_at));
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS exos_tickets_webhook ON public.exos_tickets;
CREATE TRIGGER exos_tickets_webhook AFTER INSERT ON public.exos_tickets
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_created();

DROP TRIGGER IF EXISTS exos_checkins_webhook ON public.exos_event_checkins;
CREATE TRIGGER exos_checkins_webhook AFTER INSERT ON public.exos_event_checkins
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_ticket_checked_in();

DROP TRIGGER IF EXISTS exos_checkout_webhook ON public.exos_checkout_sessions;
CREATE TRIGGER exos_checkout_webhook AFTER UPDATE ON public.exos_checkout_sessions
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_checkout_status();

DROP TRIGGER IF EXISTS exos_events_webhook ON public.exos_events;
CREATE TRIGGER exos_events_webhook AFTER UPDATE ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_event_published();

-- ===========================================================================
-- 6. API-key management RPCs (SECDEF; the only path that touches exos_api_keys).
-- ===========================================================================
-- Create: generates the key, stores ONLY its hash + prefix, returns the
-- plaintext ONCE. Caller must be org owner/manager.
CREATE OR REPLACE FUNCTION public.exos_create_api_key(p_org_id uuid, p_name text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_key text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_api_key: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT exos_has_org_role(p_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_create_api_key: not authorized' USING ERRCODE = '42501';
  END IF;
  v_key := 'sk_live_' || encode(extensions.gen_random_bytes(24), 'hex');
  INSERT INTO public.exos_api_keys (org_id, name, key_prefix, key_hash, created_by)
  VALUES (p_org_id, nullif(btrim(p_name), ''), left(v_key, 16),
          encode(extensions.digest(v_key, 'sha256'), 'hex'), v_uid);
  RETURN v_key;   -- shown to the user ONCE; never recoverable
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_create_api_key(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_api_key(uuid, text) TO authenticated;

-- Revoke.
CREATE OR REPLACE FUNCTION public.exos_revoke_api_key(p_key_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid; v_rows int;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_api_keys WHERE id = p_key_id;
  IF v_org IS NULL THEN RETURN false; END IF;
  IF NOT exos_has_org_role(v_org, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_revoke_api_key: not authorized' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_api_keys SET revoked_at = now() WHERE id = p_key_id AND revoked_at IS NULL;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_revoke_api_key(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_revoke_api_key(uuid) TO authenticated;

-- List (safe columns only — NEVER the hash). Staff read.
CREATE OR REPLACE FUNCTION public.exos_list_api_keys(p_org_id uuid)
RETURNS TABLE (id uuid, name text, key_prefix text, scopes text[],
               last_used_at timestamptz, revoked_at timestamptz, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT exos_has_org_role(p_org_id, ARRAY['owner','manager','finance']) THEN
    RAISE EXCEPTION 'exos_list_api_keys: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT k.id, k.name, k.key_prefix, k.scopes, k.last_used_at, k.revoked_at, k.created_at
  FROM public.exos_api_keys k
  WHERE k.org_id = p_org_id
  ORDER BY k.created_at DESC;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_list_api_keys(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_list_api_keys(uuid) TO authenticated;

COMMENT ON TABLE public.exos_api_keys IS
  'D4 mig 20260616200000: org API keys (hash-at-rest). Managed ONLY via
   exos_create_api_key / exos_revoke_api_key / exos_list_api_keys (no client
   RLS). The exos-api edge fn authenticates by SHA-256 of the presented key.';
COMMENT ON TABLE public.exos_webhooks IS
  'D4 mig 20260616200000: org outbound webhooks. AFTER triggers enqueue
   exos_webhook_deliveries; the exos-webhook-drain edge fn POSTs them HMAC-signed
   (X-Exos-Signature) with an SSRF guard + retry/backoff.';
