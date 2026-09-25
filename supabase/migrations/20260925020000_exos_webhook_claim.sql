-- ============================================================================
-- Migration 20260925020000 — Exos (Bridge / D4): edge-function audit fixes —
--                            webhook row claim, API rate limit, reconcile
--                            sweep progress, disputes recorded (not refunds)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_webhook_deliveries (+claimed_at, +claim_token,
--              status 'sending'); FUNCTION exos_webhook_claim_batch (new)
--           W: TABLE exos_api_rate_windows (new); FUNCTION exos_api_rate_hit (new)
--           W: TABLE exos_checkout_sessions (+reconcile_*, +dispute_*);
--              FUNCTION exos_reconcile_mark (new), exos_record_dispute (new)
-- Pre-reqs: 20260616200000 (webhooks + API keys), 20260702123100 (payment ledger)
--
-- From the 2026-09-24 audit (EXP KANBAN "open findings"):
--   * exos-webhook-drain read due rows with a plain SELECT, so two overlapping
--     runs could POST the same delivery twice. exos_webhook_claim_batch claims
--     rows with FOR UPDATE SKIP LOCKED and a lease (status 'sending',
--     claimed_at, attempts+1, a fresh claim_token), like exos_mail_claim_batch.
--     A lease that outlives its run is reclaimed after p_lease_minutes; one
--     that expired on its last attempt goes 'dead'.
--   * exos-api had no rate limit. exos_api_rate_hit(key) counts hits per key
--     per clock minute and says whether this one is within the limit.
--   * exos-reconcile-checkouts re-read the same newest 100 'failed' sessions
--     every run, so older charged-but-unfulfilled ones could starve.
--     exos_reconcile_mark stamps each session it looked at (attempts, last
--     check, next check with backoff, done when nothing is left to do); the
--     sweep reads never-checked / due sessions oldest first.
--   * stripe-webhook treated an opened dispute as a refund (voided tickets,
--     session 'refunded'). exos_record_dispute records the dispute on the
--     session (dispute_* columns) and the payment row's meta instead; only a
--     LOST dispute is then refunded by the function via exos_refund_checkout.
--
-- Grants: every new function is service_role only; the rate table has RLS on
-- and no client grants. Re-run safe. D4 authors; applying to prod is
-- operator-gated.
--
-- APPLIED to prod 2026-09-25 (operator-approved). Every function it creates or
-- patches was verified by md5 against a copy of prod's schema with it applied.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Webhook delivery claim
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_webhook_deliveries
  ADD COLUMN IF NOT EXISTS claimed_at  timestamptz,
  ADD COLUMN IF NOT EXISTS claim_token uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.exos_webhook_deliveries'::regclass
       AND conname = 'exos_webhook_deliveries_status_check'
       AND pg_get_constraintdef(oid) LIKE '%sending%'
  ) THEN
    ALTER TABLE public.exos_webhook_deliveries DROP CONSTRAINT IF EXISTS exos_webhook_deliveries_status_check;
    ALTER TABLE public.exos_webhook_deliveries ADD CONSTRAINT exos_webhook_deliveries_status_check
      CHECK (status IN ('pending','sending','delivered','failed','dead'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS exos_webhook_deliveries_lease_idx
  ON public.exos_webhook_deliveries (claimed_at) WHERE status = 'sending';

CREATE OR REPLACE FUNCTION public.exos_webhook_claim_batch(
  p_limit         integer DEFAULT 20,
  p_max_attempts  integer DEFAULT 8,
  p_lease_minutes integer DEFAULT 15
)
RETURNS TABLE(id uuid, webhook_id uuid, event_type text, payload jsonb, attempts integer,
              claim_token uuid, url text, secret text, enabled boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
#variable_conflict use_column
BEGIN
  -- A lease that ran out on the final attempt: the run died mid-send; give up.
  UPDATE public.exos_webhook_deliveries d
     SET status = 'dead', claim_token = NULL,
         last_error = left(coalesce(d.last_error || '; ', '') || 'lease expired on final attempt', 500)
   WHERE d.status = 'sending'
     AND d.claimed_at < now() - make_interval(mins => p_lease_minutes)
     AND d.attempts >= p_max_attempts;

  RETURN QUERY
  WITH claimable AS (
    SELECT d.id
      FROM public.exos_webhook_deliveries d
     WHERE ( (d.status = 'pending' AND d.next_attempt_at <= now())
          OR (d.status = 'sending' AND d.claimed_at < now() - make_interval(mins => p_lease_minutes)) )
       AND d.attempts < p_max_attempts
     ORDER BY d.next_attempt_at
     LIMIT GREATEST(LEAST(p_limit, 200), 1)
     FOR UPDATE OF d SKIP LOCKED
  )
  UPDATE public.exos_webhook_deliveries d
     SET status      = 'sending',
         attempts    = d.attempts + 1,
         claimed_at  = now(),
         claim_token = gen_random_uuid()
    FROM claimable c, public.exos_webhooks w
   WHERE d.id = c.id AND w.id = d.webhook_id
  RETURNING d.id, d.webhook_id, d.event_type, d.payload, d.attempts, d.claim_token,
            w.url, w.secret, w.enabled;
END $function$;

REVOKE ALL ON FUNCTION public.exos_webhook_claim_batch(integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_webhook_claim_batch(integer, integer, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Public API rate limit (fixed one-minute window per key)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_api_rate_windows (
  key_id       uuid        NOT NULL REFERENCES public.exos_api_keys(id) ON DELETE CASCADE,
  window_start timestamptz NOT NULL,
  hits         integer     NOT NULL DEFAULT 0,
  PRIMARY KEY (key_id, window_start)
);
ALTER TABLE public.exos_api_rate_windows ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.exos_api_rate_windows FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.exos_api_rate_windows TO service_role;

CREATE OR REPLACE FUNCTION public.exos_api_rate_hit(p_key_id uuid, p_limit integer DEFAULT 120)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_win  timestamptz := date_trunc('minute', now());
  v_hits integer;
BEGIN
  IF p_key_id IS NULL THEN RETURN false; END IF;
  INSERT INTO public.exos_api_rate_windows AS w (key_id, window_start, hits)
  VALUES (p_key_id, v_win, 1)
  ON CONFLICT (key_id, window_start) DO UPDATE SET hits = w.hits + 1
  RETURNING w.hits INTO v_hits;
  -- First hit of a new window: drop this key's old windows (PK-bounded).
  IF v_hits = 1 THEN
    DELETE FROM public.exos_api_rate_windows
     WHERE key_id = p_key_id AND window_start < v_win - interval '5 minutes';
  END IF;
  RETURN v_hits <= GREATEST(p_limit, 1);
END $function$;

REVOKE ALL ON FUNCTION public.exos_api_rate_hit(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_api_rate_hit(uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Reconcile sweep bookkeeping
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS reconcile_attempts   integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reconcile_checked_at timestamptz,
  ADD COLUMN IF NOT EXISTS reconcile_next_at    timestamptz,
  ADD COLUMN IF NOT EXISTS reconcile_done_at    timestamptz,
  ADD COLUMN IF NOT EXISTS reconcile_note       text;

CREATE INDEX IF NOT EXISTS exos_checkout_sessions_failed_sweep_idx
  ON public.exos_checkout_sessions (reconcile_next_at NULLS FIRST, created_at)
  WHERE status = 'failed' AND reconcile_done_at IS NULL;

-- Stamp a session the failed-sweep looked at. p_done = nothing left to do
-- (refunded, or it can never be charged). Otherwise the next check backs off:
-- 2^attempts minutes, capped at a day, so a stuck row never hogs the batch.
CREATE OR REPLACE FUNCTION public.exos_reconcile_mark(p_session_id text, p_done boolean, p_note text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE v_attempts integer;
BEGIN
  UPDATE public.exos_checkout_sessions s
     SET reconcile_attempts   = s.reconcile_attempts + 1,
         reconcile_checked_at = now(),
         reconcile_next_at    = now() + LEAST(make_interval(mins => (2 ^ LEAST(s.reconcile_attempts + 1, 11))::int),
                                              interval '24 hours'),
         reconcile_done_at    = CASE WHEN p_done THEN coalesce(s.reconcile_done_at, now()) ELSE s.reconcile_done_at END,
         reconcile_note       = left(coalesce(p_note, s.reconcile_note), 500)
   WHERE s.session_id = p_session_id
  RETURNING s.reconcile_attempts INTO v_attempts;
  RETURN v_attempts;
END $function$;

REVOKE ALL ON FUNCTION public.exos_reconcile_mark(text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_reconcile_mark(text, boolean, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Disputes are recorded, not treated as refunds
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_checkout_sessions
  ADD COLUMN IF NOT EXISTS dispute_id        text,
  ADD COLUMN IF NOT EXISTS dispute_status    text,
  ADD COLUMN IF NOT EXISTS disputed_at       timestamptz,
  ADD COLUMN IF NOT EXISTS dispute_closed_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.exos_checkout_sessions'::regclass
                    AND conname = 'exos_checkout_sessions_dispute_status_chk') THEN
    ALTER TABLE public.exos_checkout_sessions ADD CONSTRAINT exos_checkout_sessions_dispute_status_chk
      CHECK (dispute_status IS NULL OR dispute_status ~ '^[a-z_]{1,40}$');
  END IF;
END $$;

-- Record a Stripe dispute's state on its session + payment row. Stripe status
-- values: warning_needs_response, warning_under_review, warning_closed,
-- needs_response, under_review, won, lost. A closed state (won / lost /
-- warning_closed) is final: a late or replayed earlier event can't reopen it.
-- Returns the stored status. Does NOT void tickets — the caller refunds a
-- lost dispute through exos_refund_checkout.
CREATE OR REPLACE FUNCTION public.exos_record_dispute(
  p_session_id        text,
  p_dispute_id        text,
  p_status            text,
  p_reason            text    DEFAULT NULL,
  p_amount_cents      integer DEFAULT NULL,
  p_provider_event_id text    DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  s       public.exos_checkout_sessions%ROWTYPE;
  v_final constant text[] := ARRAY['won','lost','warning_closed'];
  v_new   text := lower(btrim(p_status));
BEGIN
  IF p_dispute_id IS NULL OR btrim(p_dispute_id) = '' THEN
    RAISE EXCEPTION 'exos_record_dispute: dispute id is required';
  END IF;
  IF v_new IS NULL OR v_new !~ '^[a-z_]{1,40}$' THEN
    RAISE EXCEPTION 'exos_record_dispute: invalid status %', p_status;
  END IF;

  SELECT * INTO s FROM public.exos_checkout_sessions WHERE session_id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_record_dispute: unknown session %', p_session_id;
  END IF;

  -- Same dispute already closed: keep the final state.
  IF s.dispute_id = p_dispute_id AND s.dispute_status = ANY (v_final) AND NOT (v_new = ANY (v_final)) THEN
    RETURN s.dispute_status;
  END IF;

  UPDATE public.exos_checkout_sessions
     SET dispute_id        = p_dispute_id,
         dispute_status    = v_new,
         disputed_at       = coalesce(disputed_at, now()),
         dispute_closed_at = CASE WHEN v_new = ANY (v_final) THEN coalesce(dispute_closed_at, now()) ELSE NULL END
   WHERE session_id = p_session_id;

  UPDATE public.exos_order_payments
     SET meta = coalesce(meta, '{}'::jsonb) || jsonb_build_object('dispute', jsonb_build_object(
                  'id', p_dispute_id, 'status', v_new, 'reason', left(p_reason, 200),
                  'amount_cents', p_amount_cents, 'event_id', p_provider_event_id, 'updated_at', now())),
         updated_at = now()
   WHERE session_id = p_session_id AND provider = 'stripe';

  RETURN v_new;
END $function$;

REVOKE ALL ON FUNCTION public.exos_record_dispute(text, text, text, text, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.exos_record_dispute(text, text, text, text, integer, text) TO service_role;
