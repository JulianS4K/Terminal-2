-- ============================================================================
-- Migration 20260910380000 — N2S manual: how to set the account password,
--                            + the OAuth-only sign-in failure as a code
--
-- Lane:     D7 (n2s obligation-covering) over A1's DB plane
-- Level:    additive — seeds one new doc step and one new error code.
--           No schema change, no existing object altered.
-- Touches:  n2s_integration_doc (+1 row, later steps renumbered),
--           n2s_error_code (+1 row: N2S-A104)
-- Pre-reqs: 20260910370000
--
-- Upstream: no API call at all. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "they have a pw, but just in case in the
-- table add instructions of how to set."
--
-- ── WHY THIS STEP EXISTS ───────────────────────────────────────────────────
-- Observed on this very project while wiring the first external consumer:
-- all 10 auth users are Google-OAuth-only and NONE has a password
-- (users_with_password = 0). The operator believed the designated account
-- "has a pw" — and it does, but it is the GOOGLE WORKSPACE password, which is
-- a different credential from a Supabase Auth password.
--
-- That distinction is the trap. Google authenticates the human to Google,
-- which then OAuths into Supabase; GoTrue never stores a password hash for
-- such a user. signInWithPassword therefore returns "Invalid login
-- credentials" — an error that reads like a typo, so an integrator retries
-- the password, then blames the key, then blames RLS, and never suspects the
-- account simply has no password to check against.
--
-- A machine also cannot complete a browser OAuth consent flow, so an
-- OAuth-only account is not merely inconvenient for a headless receiver: it
-- is unusable, with no amount of correct credentials fixing it.
--
-- ── ⚠ WHY THE STEP SAYS "NEVER SET IT WITH SQL" ────────────────────────────
-- A value passed through a SQL console lands in the POSTGRES QUERY LOG, where
-- it stays readable long after the statement is forgotten. This project has a
-- live incident of exactly that shape (an API key pasted into a session, still
-- in the log, tracked as D7-SEC-1), and the 20260910090000 migration already
-- carries the same warning for vault secrets. Setting a password with
-- `UPDATE auth.users SET encrypted_password = crypt(...)` would repeat it for
-- a credential that is also a staff member's interactive account login.
-- ============================================================================

-- ── 1. make room at step 3, idempotently ───────────────────────────────────
-- Guarded on the new slug's absence so a re-run does not shift twice.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.n2s_integration_doc WHERE slug = 'set-password') THEN
    UPDATE public.n2s_integration_doc SET step_no = step_no + 1 WHERE step_no >= 3;
  END IF;
END $$;

-- ── 2. the new step ────────────────────────────────────────────────────────
INSERT INTO public.n2s_integration_doc (slug, step_no, title, body) VALUES
 ('set-password', 3, 'Setting the account password (one-time, operator side)',
  'The feed grants SELECT to the authenticated role, so the consumer signs in as a real Supabase Auth user. That user needs a password GoTrue can check.

*** A GOOGLE (OR ANY OAUTH) PASSWORD IS NOT A SUPABASE PASSWORD. ***
If the account signs into Supabase through Google, Microsoft, SAML or any other provider, Supabase stores NO password hash for it. signInWithPassword will return "Invalid login credentials" however many times the correct Google password is typed, because there is nothing on the Supabase side to check it against. The error reads like a typo; it is not one.

A machine also cannot complete a browser OAuth consent screen. So an OAuth-only account is not just awkward for a headless receiver — it is unusable, and no combination of correct credentials will fix it.

CHECK WHICH YOU HAVE FIRST — as the operator, in the SQL editor:

  select u.email,
         (u.encrypted_password is not null and u.encrypted_password <> '''') as has_password,
         (select string_agg(i.provider, '','') from auth.identities i where i.user_id = u.id) as providers
    from auth.users u where u.email = ''<the account>'';

has_password = false, or providers listing only an OAuth name, means the step below has not been done yet.

TO SET IT — Supabase dashboard:
  1. Authentication -> Providers -> confirm EMAIL is enabled. If it is off,
     signInWithPassword fails no matter what password is set.
  2. Authentication -> Users -> select the user -> set or reset the password.

TO SET IT — Auth Admin API, if you prefer it scripted:
  PUT {PROJECT_URL}/auth/v1/admin/users/{user_id}
      apikey: {SERVICE_ROLE_KEY}
      Authorization: Bearer {SERVICE_ROLE_KEY}
      {"password": "..."}
  The service_role key is used HERE, by the operator, and never leaves your
  side. It is never given to the integrator — it bypasses row-level security
  on every table in the project.

*** NEVER SET A PASSWORD WITH SQL. *** Do not run
`update auth.users set encrypted_password = crypt(...)`. A value passed
through a SQL console lands in the Postgres query log and stays readable there
long afterwards. This is the same rule that applies to vault secrets, and this
project already has a live exposure of exactly that kind.

AFTERWARDS, confirm the account gained an `email` identity alongside its OAuth
one, then hand the integrator three things: the project URL, the PUBLISHABLE
(anon) key, and this email + password. Nothing else.

One operational note: the access token returned by signInWithPassword expires
in about an hour. supabase-js refreshes it automatically; a hand-rolled HTTP
client must use the refresh_token to stay signed in, or it will start seeing
401s (N2S-A100) after the first hour of an otherwise working integration.

Prefer a DEDICATED integration account over a person''s login where you can. A
password on a real staff account means a leak is an account takeover, not just
feed exposure, and the account cannot be revoked without disrupting that
person.')
ON CONFLICT (slug) DO UPDATE SET
  step_no = EXCLUDED.step_no, title = EXCLUDED.title,
  body    = EXCLUDED.body,    updated_at = now();

-- ── 3. the failure it produces, as a trackable code ────────────────────────
INSERT INTO public.n2s_error_code
  (code, category, severity, title, meaning, emitted_by, what_to_do, sort_order)
VALUES
 ('N2S-A104','access','error','Invalid login credentials on an OAuth-only account',
  'signInWithPassword was called for a user that has no Supabase password — typically because the account signs in through Google or another OAuth provider. GoTrue has no hash to check, so it rejects every attempt.',
  'Supabase Auth (GoTrue) /auth/v1/token?grant_type=password',
  'Do not keep retrying the password — an OAuth password is a different credential and will never work here. Confirm with: select encrypted_password is not null, and the providers list, from auth.users / auth.identities for that email. Then set a real Supabase password per step 3 of n2s_integration_doc. A headless receiver cannot use an OAuth-only account at all, since it cannot complete a browser consent flow.',
  215)
ON CONFLICT (code) DO UPDATE SET
  category   = EXCLUDED.category,   severity   = EXCLUDED.severity,
  title      = EXCLUDED.title,      meaning    = EXCLUDED.meaning,
  emitted_by = EXCLUDED.emitted_by, what_to_do = EXCLUDED.what_to_do,
  sort_order = EXCLUDED.sort_order;
