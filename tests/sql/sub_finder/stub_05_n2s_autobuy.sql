-- Stand-ins for the N2S auto-buyer objects the manual sub buy migrations patch.
CREATE TABLE IF NOT EXISTS public.n2s_autobuy_config (
  id boolean PRIMARY KEY DEFAULT true, email_to text[], email_from text, evo_email_address_id bigint);
INSERT INTO public.n2s_autobuy_config VALUES (true, ARRAY['a@x.test','b@x.test'], 'Buys <f@x.test>', 1) ON CONFLICT DO NOTHING;
CREATE FUNCTION public.n2s_autobuy_live_claim() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c public.n2s_autobuy_config;
BEGIN
  SELECT * INTO c FROM public.n2s_autobuy_config WHERE id;
  RETURN jsonb_build_object('cfg', jsonb_build_object(
      'evo_email_address_id', c.evo_email_address_id));
END $$;
