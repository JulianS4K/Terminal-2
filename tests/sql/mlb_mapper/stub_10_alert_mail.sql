-- Stand-ins for what the MLB alert digest sends with (mig 20261120165830): N2S's settings (read once,
-- to copy N2S's recipients), the vault key, and pgsql-http, which records each message in sent_log.
CREATE TABLE IF NOT EXISTS public.n2s_autobuy_config (id boolean PRIMARY KEY DEFAULT true, email_to text[], email_from text);
INSERT INTO public.n2s_autobuy_config VALUES (true, ARRAY['a@x.test','b@x.test'], 'N2S Auto-buy <f@x.test>') ON CONFLICT DO NOTHING;
CREATE SCHEMA IF NOT EXISTS vault;
CREATE TABLE IF NOT EXISTS vault.decrypted_secrets (name text, decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES ('RESEND_API_KEY', 'k');
CREATE TABLE IF NOT EXISTS public.sent_log (uri text, body jsonb);
CREATE OR REPLACE FUNCTION extensions.http_header(text, text) RETURNS extensions.http_header LANGUAGE sql AS $$ SELECT ROW($1, $2)::extensions.http_header $$;
CREATE OR REPLACE FUNCTION extensions.http(r extensions.http_request) RETURNS extensions.http_response LANGUAGE plpgsql AS $$
BEGIN INSERT INTO public.sent_log VALUES (r.uri, r.content::jsonb); RETURN ROW(200, '', NULL, '')::extensions.http_response; END $$;
