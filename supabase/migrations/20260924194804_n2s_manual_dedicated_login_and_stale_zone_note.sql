-- Migration 20260924194804 · level:secondary-sales · lane:D7 · writes:n2s_integration_doc · reads:none · pre:20260910650000
--
-- Already applied to prod · via MCP 2026-09-24 under operator direction.
--
-- ============================================================================
-- Migration 20260924194804 — onboarding manual: dedicated login first, and
-- remove a stale zone caveat that contradicted the label step
--
-- Lane: D7 · Pre-reqs: 20260910380000 (set-password step), 20260910620000
--       (downgrade zone cap), 20260910630000 (sub_view / sub_notes)
--
-- Reviewed 2026-09-24 when the first external consumer went to connect. Three
-- steps of n2s_integration_doc no longer matched the pipeline or the account
-- situation:
--
-- 1. 'set-password' (step 4) only described adding a password to an EXISTING
--    account. Every auth user on this project is Google-only (checked
--    2026-09-24: 10 of 10, none with a password hash), and the step's own
--    closing paragraph already says to prefer a dedicated integration account
--    — without saying how to make one. The step now leads with creating the
--    dedicated user (Add user -> Create new user, Auto Confirm), keeps the
--    add-a-password-to-an-OAuth-account path as the fallback, and names the
--    dashboard page as it is labelled today (Sign In / Providers).
--
-- 2. 'zones' (step 9) still closed with "⚠ A gate 5/6 downgrade is NOT
--    zone-capped ... a deliberate operator decision". 20260910620000 reversed
--    that (gates 5/6 now require sub_zone IS NOT DISTINCT FROM order_zone) and
--    rewrote the 'gates' step to say so — but not this one. So the manual said
--    both things, two steps apart. A receiver that believes the stale line
--    re-checks rows needlessly; one that believes it about the label step
--    stops trusting either. Replaced with the current rule and a pointer to
--    the " zone unverified" suffix.
--
-- 3. 'columns' (step 11) listed the context columns as of 20260910600000 and
--    missed n2s_id, sub_view and sub_notes (20260910630000). n2s_id is the key
--    N2S-G900 asks receivers to report, so a manual that never names it is
--    asking for something it does not describe.
--
-- Text-only: no schema, grant, RLS or function change. Each edit is anchored
-- and asserted, so a drifted body raises instead of half-patching, and a
-- second apply is refused (the anchors are gone).
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.n2s_integration_doc
                  WHERE slug = 'zones' AND body LIKE '%A gate 5/6 downgrade is NOT zone-capped%') THEN
    RAISE EXCEPTION 'zones step drifted or already patched — refusing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.n2s_integration_doc
                  WHERE slug = 'columns' AND body LIKE '%Context columns: marketplace, event_name,%') THEN
    RAISE EXCEPTION 'columns step drifted — refusing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.n2s_integration_doc
                  WHERE slug = 'set-password' AND body NOT LIKE '%Create new user%') THEN
    RAISE EXCEPTION 'set-password step missing or already patched — refusing';
  END IF;
END $$;

-- ── 1. set-password: dedicated account first ──────────────────────────────
UPDATE public.n2s_integration_doc SET
  title = 'Getting the integrator a login (one-time, operator side)',
  body = $doc$The feed grants SELECT to the authenticated role, so the consumer signs in as a real Supabase Auth user. That user needs a password GoTrue can check.

*** A GOOGLE (OR ANY OAUTH) PASSWORD IS NOT A SUPABASE PASSWORD. ***
If the account signs into Supabase through Google, Microsoft, SAML or any other provider, Supabase stores NO password hash for it. signInWithPassword will return "Invalid login credentials" however many times the correct Google password is typed, because there is nothing on the Supabase side to check it against. The error reads like a typo; it is not one (N2S-A104).

A machine also cannot complete a browser OAuth consent screen. So an OAuth-only account is not just awkward for a headless receiver — it is unusable, and no combination of correct credentials will fix it. Every staff account on this project signs in with Google, so none of them works as-is.

FIRST — Supabase dashboard -> Authentication -> Sign In / Providers -> confirm EMAIL is enabled. If it is off, signInWithPassword fails no matter what password is set.

RECOMMENDED — CREATE A DEDICATED INTEGRATION USER:
  1. Authentication -> Users -> Add user -> Create new user.
  2. Use an address that names the integration, not a person
     (e.g. n2s-cover-feed@<your domain>), and set a strong password.
  3. Tick "Auto Confirm User". Without it the account waits on an email
     confirmation nobody will click, and sign-in is refused.
A dedicated user can be revoked (delete it, or reset its password) without
touching anyone's own login, and a leaked password exposes the feed rather
than a staff account.

FALLBACK — ADD A PASSWORD TO AN EXISTING ACCOUNT:
  Dashboard: Authentication -> Users -> select the user -> set or reset the password.
  Or the Auth Admin API, if you prefer it scripted:
  PUT {PROJECT_URL}/auth/v1/admin/users/{user_id}
      apikey: {SERVICE_ROLE_KEY}
      Authorization: Bearer {SERVICE_ROLE_KEY}
      {"password": "..."}
  The service_role key is used HERE, by the operator, and never leaves your
  side. It is never given to the integrator — it bypasses row-level security
  on every table in the project.
  Avoid this path for a staff account: a password on a real person's login
  means a leak is an account takeover, not just feed exposure.

*** NEVER SET A PASSWORD WITH SQL. *** Do not run
`update auth.users set encrypted_password = crypt(...)`. A value passed
through a SQL console lands in the Postgres query log and stays readable there
long afterwards. This is the same rule that applies to vault secrets, and this
project already has a live exposure of exactly that kind.

CHECK IT WORKED — as the operator, in the SQL editor (reads no secret):

  select u.email,
         (u.encrypted_password is not null and u.encrypted_password <> '') as has_password,
         u.email_confirmed_at is not null as confirmed,
         (select string_agg(i.provider, ',') from auth.identities i where i.user_id = u.id) as providers,
         u.last_sign_in_at
    from auth.users u where u.email = '<the account>';

You want has_password = true, confirmed = true, and 'email' among the
providers. last_sign_in_at fills in the first time the integrator connects,
which is the operator-side confirmation that it worked.

THEN hand the integrator three things, over a private channel: the project
URL, the PUBLISHABLE (anon) key, and this email + password. Nothing else.

One operational note: the access token returned by signInWithPassword expires
in about an hour. supabase-js refreshes it automatically; a hand-rolled HTTP
client must use the refresh_token to stay signed in, or it will start seeing
401s (N2S-A100) after the first hour of an otherwise working integration.$doc$,
  updated_at = now()
WHERE slug = 'set-password';

-- ── 2. zones: drop the pre-20260910620000 caveat ──────────────────────────
UPDATE public.n2s_integration_doc SET
  body = regexp_replace(body,
    E'⚠ A gate 5/6 downgrade is NOT zone-capped.*$',
    $doc$Gates 5/6 (a downgrade of up to five rows) are held to the same rule as of
2026-09-10: the substitute must resolve to the SAME zone as the sold seat, so a
row move cannot cross a row-based price tier. Where the venue has no curated
zones at all, the row still ships and its label ends " zone unverified"
(N2S-G1000) — the rule could not be checked, which is not the same as it being
broken. A downgrade we can see crossing a zone gets no gate and never reaches you.$doc$,
    's'),
  updated_at = now()
WHERE slug = 'zones';

-- ── 3. columns: name n2s_id, sub_view, sub_notes ──────────────────────────
UPDATE public.n2s_integration_doc SET
  body = replace(body,
    'Context columns: marketplace, event_name,',
    $doc$Sightline columns (see the sightlines step): sub_view (obstructed | clear | unknown — "unknown" is NOT "clear") and sub_notes (the seller's wording, verbatim).

n2s_id is the row's stable key. Quote it, with the timestamp, when you report a problem with a row (e.g. N2S-G900).

Context columns: marketplace, event_name,$doc$),
  updated_at = now()
WHERE slug = 'columns';

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.n2s_integration_doc WHERE body LIKE '%NOT zone-capped%') THEN
    RAISE EXCEPTION 'stale zone-cap caveat still present';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.n2s_integration_doc WHERE slug = 'columns' AND body LIKE '%sub_view (obstructed%') THEN
    RAISE EXCEPTION 'columns patch did not land';
  END IF;
END $$;
