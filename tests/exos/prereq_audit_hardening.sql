-- Extra stubs for run_audit_hardening.sh: tables the cart-holds + waitlist
-- migrations reference but the lifecycle chain doesn't create. Shapes are the
-- minimum those migrations touch (FK target / CHECK constraint / INSERT cols).
CREATE TABLE IF NOT EXISTS public.exos_checkout_sessions (
  session_id text PRIMARY KEY
);
CREATE TABLE IF NOT EXISTS public.exos_mail (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template text, to_email text, subject text, html text,
  created_by uuid, status text
);
