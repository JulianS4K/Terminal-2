CREATE SCHEMA IF NOT EXISTS vault; CREATE SCHEMA IF NOT EXISTS extensions;
CREATE TABLE IF NOT EXISTS vault.decrypted_secrets (name text, decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES ('RESEND_API_KEY','k');
CREATE TABLE IF NOT EXISTS public.n2s_autobuy_config (id boolean primary key default true, email_to text[], email_from text);
INSERT INTO n2s_autobuy_config VALUES (true, ARRAY['a@x.test','b@x.test'], 'Buys <f@x.test>') ON CONFLICT DO NOTHING;
DO $$ BEGIN
  CREATE TYPE extensions.http_header AS (field text, value text);
  CREATE TYPE extensions.http_request AS (method text, uri text, headers extensions.http_header[], content_type text, content text);
  CREATE TYPE extensions.http_response AS (status integer, content_type text, headers extensions.http_header[], content text);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE TABLE IF NOT EXISTS sent_log (uri text, body jsonb);
CREATE OR REPLACE FUNCTION extensions.http_header(text, text) RETURNS extensions.http_header LANGUAGE sql AS $$ SELECT ROW($1,$2)::extensions.http_header $$;
CREATE OR REPLACE FUNCTION extensions.http(r extensions.http_request) RETURNS extensions.http_response LANGUAGE plpgsql AS $$
BEGIN IF (r.content::jsonb->'to'->>0) = 'b@x.test' AND (r.content::jsonb->>'subject') LIKE '%NEEDS%' THEN RAISE EXCEPTION 'boom'; END IF;
  INSERT INTO sent_log VALUES (r.uri, r.content::jsonb); RETURN ROW(200,'',NULL,'')::extensions.http_response; END $$;
