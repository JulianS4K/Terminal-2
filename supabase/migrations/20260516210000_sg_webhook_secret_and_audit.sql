-- Migration 20260516210000 · lane:A1 (D2-authored) · writes:vault.secrets,get_app_secret(),sg_seller_webhook_notifications_seen · reads:- · pre:20260515120000 · auth:operator-permitted 2026-05-16
-- WS2 part 1/3: SG SellerDirect webhook receiver groundwork.
-- 1. Extend get_app_secret allowlist with SG_SELLER_WEBHOOK_SECRET.
-- 2. Create the audit/idempotency table tracking every notification_id
--    we receive (independent of per-type table idempotency keys).
-- 3. The vault secret value itself is set by operator post-migration
--    (random 32+ char token shared with SG support via ticket).

CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
DECLARE v_value text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'get_app_secret: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;
  IF p_name NOT IN (
    'SEATDATA_API_KEY',
    'TEVO_API_TOKEN',
    'TEVO_SECRET',
    'SEATGEEK_API_TOKEN',
    'TICKPICK_API_TOKEN',
    'VIVID_API_TOKEN',
    'APPSCRIPT_INGEST_SECRET',
    'SG_SELLER_WEBHOOK_SECRET'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name
      USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value
    FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $function$;

-- Audit/idempotency table — every webhook hit lands here first.
-- The edge function INSERTs notification_id with ON CONFLICT DO NOTHING:
-- if the row already exists, the request is a SG retry (or replay attack)
-- and the edge function returns 200 silently without re-dispatching.
CREATE TABLE IF NOT EXISTS public.sg_seller_webhook_notifications_seen (
  notification_id   uuid PRIMARY KEY,
  notification_type text NOT NULL,
  received_at       timestamptz NOT NULL DEFAULT now(),
  seller_id         bigint,
  payload_count     int,         -- length of data[] for batched notifications
  schema_version    int,
  payload_summary   jsonb
);

CREATE INDEX IF NOT EXISTS sg_seller_webhook_notifications_seen_received_at_idx
  ON public.sg_seller_webhook_notifications_seen (received_at DESC);

CREATE INDEX IF NOT EXISTS sg_seller_webhook_notifications_seen_type_idx
  ON public.sg_seller_webhook_notifications_seen (notification_type);

-- Standard RLS lockdown — only service_role (edge function caller) reads/writes.
ALTER TABLE public.sg_seller_webhook_notifications_seen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sg_seller_webhook_notifications_seen FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON public.sg_seller_webhook_notifications_seen TO service_role;

COMMENT ON TABLE public.sg_seller_webhook_notifications_seen IS
  'Idempotency log for SG SellerDirect webhook notifications. Every inbound POST inserts notification_id; ON CONFLICT DO NOTHING is the dedup signal. Retained 30 days (purge cron added in a follow-up migration if volume demands).';
