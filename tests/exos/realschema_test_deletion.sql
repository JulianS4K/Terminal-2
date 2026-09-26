-- Real-schema test for mig 20260926010000 (waitlist sign-in + account deletion).
-- Run on a copy of the prod-schema mirror with the migration applied (not part of run_p0.sh:
-- it reshapes the local auth stub to match Supabase first).
\set QUIET on
SET client_min_messages = notice;
-- Give the local auth stub prod's shape (Supabase has all of these).
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS raw_user_meta_data jsonb, ADD COLUMN IF NOT EXISTS banned_until timestamptz,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;
CREATE TABLE IF NOT EXISTS auth.identities (id uuid DEFAULT gen_random_uuid(), user_id uuid);
CREATE TABLE IF NOT EXISTS auth.sessions (id uuid DEFAULT gen_random_uuid(), user_id uuid);
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (id bigserial, user_id varchar);

INSERT INTO auth.users(id,email,email_confirmed_at,raw_user_meta_data) VALUES
  ('dddddddd-0000-0000-0000-0000000000a1','owner@del.test',now(),'{}'),
  ('dddddddd-0000-0000-0000-0000000000a2','fan@del.test',now(),'{"full_name":"Fan Person"}'),
  ('dddddddd-0000-0000-0000-0000000000a3','busy@del.test',now(),'{}'),
  ('dddddddd-0000-0000-0000-0000000000a4','nocf@del.test',NULL,'{}');
INSERT INTO auth.identities(user_id) VALUES ('dddddddd-0000-0000-0000-0000000000a2');
INSERT INTO auth.sessions(user_id) VALUES ('dddddddd-0000-0000-0000-0000000000a2');
INSERT INTO auth.refresh_tokens(user_id) VALUES ('dddddddd-0000-0000-0000-0000000000a2');

CREATE FUNCTION pg_temp.act(p uuid, p_email text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('app.uid', coalesce(p::text, ''), false), set_config('app.jwt', json_build_object('email', p_email)::text, false); $$;
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_msg text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF p_ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL %', p_msg; END IF; END $$;
CREATE FUNCTION pg_temp.ok(p_msg text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RAISE NOTICE 'OK  %', p_msg; END $$;
CREATE FUNCTION pg_temp.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN 'ok'; EXCEPTION WHEN others THEN RETURN SQLERRM; END $$;
GRANT EXECUTE ON FUNCTION pg_temp.act(uuid, text), pg_temp.chk(boolean, text), pg_temp.ok(text), pg_temp.try(text) TO PUBLIC;

SET ROLE authenticated;
SELECT pg_temp.act('dddddddd-0000-0000-0000-0000000000a1','owner@del.test');
SELECT public.exos_create_org('Del Org','del-org') AS org \gset
RESET ROLE;
INSERT INTO public.exos_events(id,org_id,name,slug,status,starts_at,ends_at,timezone,currency,total_tickets,venue_name,created_by) VALUES
  ('eeeeeeee-0000-0000-0000-0000000000e1', :'org', 'Past', 'del-past', 'published', now() - interval '3 days', now() - interval '2 days', 'America/New_York','USD',0,'Hall','dddddddd-0000-0000-0000-0000000000a1'),
  ('eeeeeeee-0000-0000-0000-0000000000e2', :'org', 'Soon', 'del-soon', 'published', now() + interval '3 days', NULL, 'America/New_York','USD',0,'Hall','dddddddd-0000-0000-0000-0000000000a1');
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,buyer_email,attendee_name,status,barcode_secret,price_paid,order_ref) VALUES
  ('ffffffff-0000-0000-0000-000000000001','eeeeeeee-0000-0000-0000-0000000000e1',:'org','dddddddd-0000-0000-0000-0000000000a2','dddddddd-0000-0000-0000-0000000000a2','fan@del.test','Fan Person','used','s',0,'o1'),
  ('ffffffff-0000-0000-0000-000000000002','eeeeeeee-0000-0000-0000-0000000000e2',:'org','dddddddd-0000-0000-0000-0000000000a3','dddddddd-0000-0000-0000-0000000000a3','busy@del.test','Busy','active','s',0,'o2');
INSERT INTO public.exos_profiles(id, display_name) VALUES ('dddddddd-0000-0000-0000-0000000000a2','Fan Person') ON CONFLICT (id) DO NOTHING;
INSERT INTO public.exos_mail(to_email,template,subject,html) VALUES ('fan@del.test','event-reminder','s','h');

-- W. Waitlist needs a signed-in, confirmed account --------------------------------
SET ROLE anon;
SELECT pg_temp.act(NULL, NULL);
SELECT pg_temp.chk(pg_temp.try($$SELECT * FROM public.exos_join_waitlist('eeeeeeee-0000-0000-0000-0000000000e2','x@y.test')$$) <> 'ok', 'W1: anon cannot join');
RESET ROLE; SET ROLE authenticated;
SELECT pg_temp.act('dddddddd-0000-0000-0000-0000000000a4','nocf@del.test');
SELECT pg_temp.chk(pg_temp.try($$SELECT * FROM public.exos_join_waitlist('eeeeeeee-0000-0000-0000-0000000000e2','nocf@del.test')$$) LIKE '%confirm your email%', 'W2: unconfirmed refused');
SELECT pg_temp.act('dddddddd-0000-0000-0000-0000000000a2','fan@del.test');
SELECT pg_temp.chk((SELECT count(*) FROM public.exos_join_waitlist('eeeeeeee-0000-0000-0000-0000000000e2','someone-else@x.test')) = 1, 'W3: confirmed user joins');
RESET ROLE;
SELECT pg_temp.chk((SELECT email FROM public.exos_waitlist WHERE user_id = 'dddddddd-0000-0000-0000-0000000000a2') = 'fan@del.test', 'W4: the session email is used, not p_email');
SELECT pg_temp.ok('W waitlist sign-in');

-- D. Account deletion ------------------------------------------------------------------
SET ROLE anon; SELECT pg_temp.act(NULL, NULL);
SELECT pg_temp.chk(pg_temp.try('SELECT public.exos_delete_my_account()') <> 'ok', 'D1: anon refused');
RESET ROLE; SET ROLE authenticated;
SELECT pg_temp.act('dddddddd-0000-0000-0000-0000000000a1','owner@del.test');
SELECT pg_temp.chk(pg_temp.try('SELECT public.exos_delete_my_account()') LIKE '%own an organization%', 'D2: org owner refused');
SELECT pg_temp.act('dddddddd-0000-0000-0000-0000000000a3','busy@del.test');
SELECT pg_temp.chk(pg_temp.try('SELECT public.exos_delete_my_account()') LIKE '%upcoming event%', 'D3: upcoming ticket refused');
SELECT pg_temp.act('dddddddd-0000-0000-0000-0000000000a2','fan@del.test');
SELECT pg_temp.chk(pg_temp.try('SELECT public.exos_delete_my_account()') = 'ok', 'D4: fan can delete');
RESET ROLE;
SELECT pg_temp.chk((SELECT count(*) FROM public.exos_tickets WHERE id = 'ffffffff-0000-0000-0000-000000000001') = 1, 'D5: ticket record kept');
SELECT pg_temp.chk((SELECT buyer_email IS NULL AND attendee_name IS NULL FROM public.exos_tickets WHERE id = 'ffffffff-0000-0000-0000-000000000001'), 'D6: ticket PII removed');
SELECT pg_temp.chk((SELECT count(*) FROM public.exos_profiles WHERE id = 'dddddddd-0000-0000-0000-0000000000a2') = 0, 'D7: profile removed');
SELECT pg_temp.chk((SELECT count(*) FROM public.exos_waitlist WHERE user_id = 'dddddddd-0000-0000-0000-0000000000a2') = 0, 'D8: waitlist removed');
SELECT pg_temp.chk((SELECT count(*) FROM public.exos_mail WHERE to_email = 'fan@del.test') = 0, 'D9: queued mail removed');
SELECT pg_temp.chk((SELECT email LIKE 'deleted+%@deleted.invalid' AND banned_until = 'infinity' AND raw_user_meta_data = '{}'::jsonb
                      FROM auth.users WHERE id = 'dddddddd-0000-0000-0000-0000000000a2'), 'D10: login closed');
SELECT pg_temp.chk((SELECT count(*) FROM auth.identities WHERE user_id = 'dddddddd-0000-0000-0000-0000000000a2')
                 + (SELECT count(*) FROM auth.sessions WHERE user_id = 'dddddddd-0000-0000-0000-0000000000a2')
                 + (SELECT count(*) FROM auth.refresh_tokens WHERE user_id = 'dddddddd-0000-0000-0000-0000000000a2') = 0, 'D11: sessions gone');
SELECT pg_temp.chk((SELECT email FROM auth.users WHERE id = 'dddddddd-0000-0000-0000-0000000000a3') = 'busy@del.test', 'D12: refused user untouched');
SELECT pg_temp.chk(NOT has_function_privilege('anon', 'public.exos_join_waitlist(uuid, text, uuid, text, integer, jsonb)', 'EXECUTE'), 'D13: anon has no waitlist EXECUTE');
SELECT pg_temp.ok('D account deletion');
