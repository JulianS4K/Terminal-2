-- ============================================================================
-- Migration 20260523130000 — Exos (Bridge / D4): exos_mail drainer support
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_mail (W: status CHECK + attempts/claimed_at/last_attempt_at),
--           exos_mail_claim_batch() RPC (W, new), exos_mail_mark() RPC (W, new)
-- Pre-reqs: 20260520160000 (exos_mail + exos_queue_mail)
--
-- D4-OPS-8 — the drainer. The edge function `exos-mail-drain` (cron-gated,
-- service_role) claims pending rows, sends them via the email provider, and
-- flips status. This migration adds the concurrency-safe claim primitives the
-- drainer needs:
--   * a 'sending' interim status so concurrent invocations don't double-send,
--   * attempts / claimed_at / last_attempt_at for retry + stuck-row recovery,
--   * exos_mail_claim_batch(): atomic FOR UPDATE SKIP LOCKED batch claim,
--   * exos_mail_mark(): outcome state machine — sent / failed(terminal) /
--     pending(retry-under-cap).
-- Both RPCs are service_role-only (the drainer); clients still queue via
-- exos_queue_mail() and never touch this table (RLS REVOKE from 20260520160000).
--
-- D4 authors; A1 applies to prod. Cron scheduling is a separate operator step
-- (see exos-mail-drain function header).
-- ============================================================================

-- 1. Allow the interim 'sending' claim state. (Original CHECK: pending/sent/failed.)
ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_status_check;
ALTER TABLE public.exos_mail ADD  CONSTRAINT exos_mail_status_check
  CHECK (status IN ('pending','sending','sent','failed'));

-- 2. Retry + claim bookkeeping.
ALTER TABLE public.exos_mail ADD COLUMN IF NOT EXISTS attempts        int NOT NULL DEFAULT 0;
ALTER TABLE public.exos_mail ADD COLUMN IF NOT EXISTS claimed_at      timestamptz;
ALTER TABLE public.exos_mail ADD COLUMN IF NOT EXISTS last_attempt_at timestamptz;

-- Claim scan covers pending + (stuck) sending, oldest first.
CREATE INDEX IF NOT EXISTS exos_mail_claimable_idx
  ON public.exos_mail (created_at) WHERE status IN ('pending','sending');

-- 3. Atomic batch claim. FOR UPDATE SKIP LOCKED lets multiple concurrent drainer
--    invocations each grab a disjoint batch without blocking or double-sending.
--    Re-claims rows stuck in 'sending' (a crashed drainer) after p_stuck_minutes.
CREATE OR REPLACE FUNCTION public.exos_mail_claim_batch(
  p_limit         int DEFAULT 20,
  p_max_attempts  int DEFAULT 5,
  p_stuck_minutes int DEFAULT 10
) RETURNS TABLE (id uuid, to_email text, subject text, html text, attempts int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  WITH claimable AS (
    SELECT m.id
    FROM public.exos_mail m
    WHERE (
            m.status = 'pending'
            OR (m.status = 'sending'
                AND m.claimed_at < now() - make_interval(mins => p_stuck_minutes))
          )
      AND m.attempts < p_max_attempts
    ORDER BY m.created_at
    LIMIT GREATEST(p_limit, 1)
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.exos_mail m
     SET status          = 'sending',
         attempts        = m.attempts + 1,
         claimed_at      = now(),
         last_attempt_at = now()
    FROM claimable c
   WHERE m.id = c.id
  RETURNING m.id, m.to_email, m.subject, m.html, m.attempts;
END $$;
REVOKE ALL ON FUNCTION public.exos_mail_claim_batch(int,int,int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_mail_claim_batch(int,int,int) TO service_role;

-- 4. Record the send outcome for a claimed row.
--    ok=true -> sent. ok=false -> 'failed' once attempts hit the cap, else back
--    to 'pending' so the next run retries.
CREATE OR REPLACE FUNCTION public.exos_mail_mark(
  p_id           uuid,
  p_ok           boolean,
  p_error        text DEFAULT NULL,
  p_max_attempts int  DEFAULT 5
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_ok THEN
    UPDATE public.exos_mail
       SET status = 'sent', sent_at = now(), error = NULL, claimed_at = NULL
     WHERE id = p_id;
  ELSE
    UPDATE public.exos_mail
       SET status     = CASE WHEN attempts >= p_max_attempts THEN 'failed' ELSE 'pending' END,
           error      = left(coalesce(p_error, ''), 2000),
           claimed_at = NULL
     WHERE id = p_id;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.exos_mail_mark(uuid,boolean,text,int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_mail_mark(uuid,boolean,text,int) TO service_role;
