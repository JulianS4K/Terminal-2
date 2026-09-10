-- ============================================================================
-- Migration 20260910470000 — open the onboarding doc + error codes to anon
--
-- Lane: D7 · Level: security (widens a grant) · Pre-reqs: 20260910380000
-- Operator 2026-09-10: "allow any user plugged into this feed to access the
-- onboarding document in the sql for themselves and their AI."
--
-- WHAT CHANGES: n2s_integration_doc + n2s_error_code become readable with the
-- PUBLISHABLE (anon) key alone.
-- WHAT DOES NOT: n2s_profitable_cover is untouched and stays authenticated-
-- only. Verified as anon after applying: manual 10 rows, codes 25 rows,
-- has_table_privilege('anon','n2s_profitable_cover','SELECT') = false.
-- The instructions are public; the order book is not.
--
-- ── WHY THIS REVERSES 20260910370000 ───────────────────────────────────────
-- That migration argued a reader who cannot authenticate cannot use the feed
-- either, so anon access "would buy nothing". The reasoning missed the
-- integrator's AGENT — an AI reading the manual to work out how to connect,
-- before any Auth user exists. Under the old grant the only way to learn how
-- to authenticate was to already be authenticated.
--
-- These tables carry no order data, prices, buy links or credentials. They
-- describe a schema and an access model, both useless without a user JWT that
-- this grant does not provide.
--
-- ── ⚠ THIS INVALIDATES A DIAGNOSTIC, SO THE MANUAL CHANGES WITH IT ─────────
-- Troubleshooting step 1 said "if n2s_integration_doc is ALSO empty, it is
-- authentication, not data" — a test that depended on the doc being
-- authenticated-only. Now wrong: the doc always reads.
-- The replacement is strictly better: manual-reads-but-feed-is-empty is a
-- POSITIVE signal of "you are anon, sign in", where before there were two
-- indistinguishable empty results. N2S-A102's CODE and meaning are unchanged
-- (still "200 OK but empty, RLS filtered"), only its remedy text — so this is
-- a clarification, not a re-pointing. The stability promise holds.
-- ============================================================================

GRANT SELECT ON public.n2s_error_code      TO anon;
GRANT SELECT ON public.n2s_integration_doc TO anon;

DROP POLICY IF EXISTS n2s_error_code_read_anon ON public.n2s_error_code;
CREATE POLICY n2s_error_code_read_anon ON public.n2s_error_code
  FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS n2s_integration_doc_read_anon ON public.n2s_integration_doc;
CREATE POLICY n2s_integration_doc_read_anon ON public.n2s_integration_doc
  FOR SELECT TO anon USING (true);

-- n2s_manual() is SECURITY INVOKER, so anon resolves it through the policy
-- above; granting EXECUTE widens nothing the direct SELECT would not.
GRANT EXECUTE ON FUNCTION public.n2s_manual() TO anon;

COMMENT ON TABLE public.n2s_integration_doc IS
  'Step-by-step N2S integration manual, served from the database because the audience is external and has no access to the repo. Readable with the PUBLISHABLE (anon) key so an integrator OR THEIR AI AGENT can read it before any Auth user exists (operator 2026-09-10). Contains no order data, prices, buy links or credentials. The feed itself (n2s_profitable_cover) remains authenticated-only.';

COMMENT ON TABLE public.n2s_error_code IS
  'Stable N2S error/status codes, readable with the publishable (anon) key so an integrator or their AI can diagnose a connection before authenticating. A code is a PROMISE: never re-point one at a new meaning — retire it (set retired_at, keep the row so lookups still resolve) and issue a new code instead.';

UPDATE public.n2s_error_code
   SET what_to_do = 'Confirm the Authorization header carries a signed-in user JWT, not the bare anon key. Quick test: the manual (n2s_integration_doc) is readable with the anon key ALONE, so if the manual returns rows while the feed returns an empty array, you are acting as anon and simply need to sign in. If neither returns rows, the apikey itself is wrong — see N2S-A100.'
 WHERE code = 'N2S-A102';

UPDATE public.n2s_integration_doc
   SET body = 'You need exactly two things to READ THE MANUAL: the project URL, and the PUBLISHABLE (anon) API key. The manual and the error-code registry are deliberately readable with the anon key alone, so you — or an AI agent working on your behalf — can learn how to connect before any account exists.

To read the FEED ITSELF you additionally need a Supabase Auth user (email + password), because n2s_profitable_cover grants SELECT to the `authenticated` role only. Ask the operator to create one for you; the anon key alone will return an empty array from the feed (see N2S-A102).

*** NEVER ASK FOR, AND NEVER ACCEPT, THE service_role KEY. *** It bypasses row-level security on every table in the project, not just this feed. Handing it to an integrator hands over the entire database. If anyone offers it to you, decline and ask for an Auth user instead.',
       updated_at = now()
 WHERE slug = 'credentials';

UPDATE public.n2s_integration_doc
   SET body = '1. Empty array, 200 OK from the feed -> you are almost certainly the anon role. N2S-A102. Send the user JWT in Authorization, not just the apikey. QUICK TEST: read n2s_integration_doc. It is readable with the anon key ALONE, so if the manual returns rows and the feed does not, that is a positive confirmation you are anon and simply need to sign in.

2. 401, or the manual is empty too -> the apikey header is missing or wrong. N2S-A100.

3. permission denied / 42501 on the feed -> anon has no grant on n2s_profitable_cover by design. N2S-A101.

4. "Invalid login credentials" when signing in -> the account may be OAuth-only with no Supabase password. N2S-A104; an OAuth password is a different credential and will never work here.

5. Socket connects, nothing arrives -> sign in before subscribing. N2S-A103. Then confirm with a REST read that rows exist at all; if the REST read returns rows and the socket stays silent, the subscription is the problem, not the data.

6. Rows exist but far fewer than expected -> that is real. Only covers that clear a gate reach you, and only obligations that are mapped, catalogued and polled produce one. Ask the operator to check N2S-M100 / N2S-M101 / N2S-S100 counts.

7. A buy_url 404s or the listing is gone -> live inventory moved. Expect a DELETE event shortly. This is normal, not a data-quality fault.',
       updated_at = now()
 WHERE slug = 'troubleshooting';
