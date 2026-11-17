-- ============================================================================
-- Migration 20260910530000 — finish the onboarding: the actual URLs
--
-- Lane: D7 · Pre-reqs: 20260910480000
-- The manual described the SHAPE of every call but never stated the project
-- URL, so an integrator (or their AI) still had to be told it out of band. Now
-- the doc is self-contained: fetchable with nothing but its own URL and the
-- publishable key, and it names every other URL you need.
--
-- Seated at step 2, immediately after the overview, because "where do I even
-- point this" is the first question and was previously the last thing answered.
-- ============================================================================

INSERT INTO public.n2s_integration_doc (slug, step_no, title, body) VALUES
 ('endpoints', 2, 'The URLs — start here',
  'PROJECT URL:  https://hzrizjeaxlqcxfrtczpq.supabase.co

THIS MANUAL (no login required — the publishable/anon key is enough):
  GET {PROJECT_URL}/rest/v1/n2s_integration_doc?select=step_no,title,body&order=step_no
      apikey: {PUBLISHABLE_KEY}

  Or as one call:
  POST {PROJECT_URL}/rest/v1/rpc/n2s_manual
      apikey: {PUBLISHABLE_KEY}

ERROR CODES (also no login required):
  GET {PROJECT_URL}/rest/v1/n2s_error_code?select=code,category,severity,title,meaning,what_to_do&retired_at=is.null&order=sort_order
      apikey: {PUBLISHABLE_KEY}

THE FEED ITSELF (login REQUIRED — anon gets 42501 / an empty array):
  GET {PROJECT_URL}/rest/v1/n2s_profitable_cover?select=*&order=profit.desc
      apikey: {PUBLISHABLE_KEY}
      Authorization: Bearer {USER_ACCESS_TOKEN}

  Sign in first:
  POST {PROJECT_URL}/auth/v1/token?grant_type=password
      apikey: {PUBLISHABLE_KEY}
      {"email": "...", "password": "..."}

REALTIME (login required, same rule as the REST read):
  wss://hzrizjeaxlqcxfrtczpq.supabase.co/realtime/v1/websocket
  In supabase-js this is handled for you — see the subscribe step.

The PUBLISHABLE (anon) key is the one labelled "publishable"/"anon" in the
project API settings. It is designed to be shipped in client code. The
service_role key is NOT interchangeable with it and must never be given to an
integrator — it bypasses row-level security on every table in the project.

WHY THE MANUAL IS OPEN AND THE FEED IS NOT: the manual and error codes carry no
order data, prices, buy links or credentials, so they are readable with the
publishable key alone — which means you, or an AI agent working on your behalf,
can work out how to connect before any account exists. The feed carries order
numbers, prices and buy links, so it requires a signed-in user.')
ON CONFLICT (slug) DO UPDATE SET
  step_no=EXCLUDED.step_no, title=EXCLUDED.title, body=EXCLUDED.body, updated_at=now();

UPDATE public.n2s_integration_doc SET step_no = 3  WHERE slug='credentials';
UPDATE public.n2s_integration_doc SET step_no = 4  WHERE slug='set-password';
UPDATE public.n2s_integration_doc SET step_no = 5  WHERE slug='read-current-state';
UPDATE public.n2s_integration_doc SET step_no = 6  WHERE slug='subscribe-realtime';
UPDATE public.n2s_integration_doc SET step_no = 7  WHERE slug='interpret-events';
UPDATE public.n2s_integration_doc SET step_no = 8  WHERE slug='gates';
UPDATE public.n2s_integration_doc SET step_no = 9  WHERE slug='zones';
UPDATE public.n2s_integration_doc SET step_no = 10 WHERE slug='columns';
UPDATE public.n2s_integration_doc SET step_no = 11 WHERE slug='error-codes';
UPDATE public.n2s_integration_doc SET step_no = 12 WHERE slug='troubleshooting';
UPDATE public.n2s_integration_doc SET step_no = 13 WHERE slug='guarantees';
