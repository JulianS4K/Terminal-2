-- Migration 20260604125000 · lane:D0 (author) → A1 (apply) · writes:alert_mail + alert_mail_claim_batch + alert_mail_mark · reads:— · pre:20260603200000 · auth:operator-requested 2026-06-04
--
-- D0 — the terminal's OWN outbound mail queue, kept separate from D4/Exos.
-- Exos is a separate project; we reuse the same SENDING BACKEND pattern (Resend
-- + claim/mark/drain) but with our own queue + templates so alerts and Exos
-- transactional mail never mix. Drained by the sibling edge fn alert-mail-drain
-- (a copy of exos-mail-drain pointed at this table). Mirrors exos_mail 1:1 minus
-- the created_by column.

CREATE TABLE IF NOT EXISTS public.alert_mail (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  to_email        text NOT NULL,
  template        text NOT NULL,
  subject         text NOT NULL,
  html            text NOT NULL,
  status          text NOT NULL DEFAULT 'pending',   -- pending | sending | sent | failed
  created_at      timestamptz NOT NULL DEFAULT now(),
  sent_at         timestamptz,
  error           text,
  attempts        int NOT NULL DEFAULT 0,
  claimed_at      timestamptz,
  last_attempt_at timestamptz
);
CREATE INDEX IF NOT EXISTS alert_mail_pending_idx ON public.alert_mail(status, created_at)
  WHERE status IN ('pending', 'sending');

-- Not user-facing: service_role (the drainer) only. RLS on + no policy = locked.
ALTER TABLE public.alert_mail ENABLE ROW LEVEL SECURITY;

-- Claim a batch (FOR UPDATE SKIP LOCKED) — flips pending→sending so overlapping
-- drain runs grab disjoint rows; re-claims rows stuck in 'sending'.
CREATE OR REPLACE FUNCTION public.alert_mail_claim_batch(
  p_limit int DEFAULT 20, p_max_attempts int DEFAULT 5, p_stuck_minutes int DEFAULT 10
) RETURNS TABLE (id uuid, to_email text, subject text, html text, attempts int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  WITH claimable AS (
    SELECT m.id FROM public.alert_mail m
    WHERE (m.status = 'pending'
           OR (m.status = 'sending' AND m.claimed_at < now() - make_interval(mins => p_stuck_minutes)))
      AND m.attempts < p_max_attempts
    ORDER BY m.created_at
    LIMIT GREATEST(p_limit, 1)
    FOR UPDATE SKIP LOCKED
  )
  UPDATE public.alert_mail m
     SET status = 'sending', attempts = m.attempts + 1, claimed_at = now(), last_attempt_at = now()
    FROM claimable c WHERE m.id = c.id
  RETURNING m.id, m.to_email, m.subject, m.html, m.attempts;
END $$;
REVOKE ALL ON FUNCTION public.alert_mail_claim_batch(int,int,int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.alert_mail_claim_batch(int,int,int) TO service_role;

CREATE OR REPLACE FUNCTION public.alert_mail_mark(
  p_id uuid, p_ok boolean, p_error text DEFAULT NULL, p_max_attempts int DEFAULT 5
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_ok THEN
    UPDATE public.alert_mail SET status='sent', sent_at=now(), error=NULL, claimed_at=NULL WHERE id=p_id;
  ELSE
    UPDATE public.alert_mail
       SET status = CASE WHEN attempts >= p_max_attempts THEN 'failed' ELSE 'pending' END,
           error  = left(coalesce(p_error,''), 2000), claimed_at = NULL
     WHERE id = p_id;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.alert_mail_mark(uuid,boolean,text,int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.alert_mail_mark(uuid,boolean,text,int) TO service_role;
