-- Migration 20261116020000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_key_gate · reads:sub_finder_key · pre:20261116010000
--
-- THE CALLER'S ADDRESS CAN COME FROM A NAMED HEADER, AND /ping CAN SHOW WHAT ARRIVED.
--
-- 20261116010000 reads the caller from X-Forwarded-For, counting back over our own proxies.
-- Tested live the same day: on this host that header holds two Cloudflare addresses and never
-- the caller's, whatever the count (a made-up header sent by the caller is dropped before it
-- reaches us). The host's own request log does show the caller's address, so the edge knows it
-- and hands it on some other way.
--
--   client_ip_header (NULL as shipped): when set, the caller's address is read from that one
--     request header (for example cf-connecting-ip) instead of from X-Forwarded-For. It is
--     believed only on a request whose last X-Forwarded-For entry is inside
--     trusted_proxy_cidrs, that is, one our edge handed to the host's router; otherwise there is
--     no address and an address-locked key is refused. The router accepts only cf-connecting-ip
--     or true-client-ip here (headers Cloudflare itself writes on every request and lets no
--     caller, Worker or rule set), sent exactly once; any other name gives no address. Check
--     with GET /ping: `your_ip` must be the caller's own address both plainly and when the
--     caller sends that header itself.
--   ping_shows_headers (false as shipped): while true, GET /ping also returns the forwarding
--     headers exactly as they reached the app (`forwarding_headers`), to the key that called.
--     For setting the above; switch it off afterwards.
--
-- sub_finder_key_gate hands both to routers/subs_api.py. Shipped whole.
--
-- rollback: UPDATE public.sub_finder_config SET client_ip_header = NULL, ping_shows_headers = false WHERE id = true;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS client_ip_header   text CHECK (client_ip_header IS NULL OR client_ip_header ~ '^[a-z0-9-]{1,40}$'),
  ADD COLUMN IF NOT EXISTS ping_shows_headers boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.sub_finder_key_gate(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'account_id', coalesce(k.account_id, p_key_id),
    'listed', k.key_id IS NOT NULL,
    'buy', coalesce(k.can_buy, true), 'offer', coalesce(k.can_offer, true),
    'allowed_ips', coalesce((SELECT jsonb_agg(host(a) || CASE WHEN masklen(a) < (CASE family(a) WHEN 4 THEN 32 ELSE 128 END)
                                                              THEN '/' || masklen(a) ELSE '' END)
                               FROM unnest(k.allowed_ips) a), '[]'::jsonb),
    'write_requires_ip', c.write_requires_ip,
    -- 20261116010000: which X-Forwarded-For entry is the caller, and whose word that rests on
    'client_ip_hops', c.client_ip_hops,
    'trusted_proxies', (SELECT coalesce(jsonb_agg(text(a)), '[]'::jsonb) FROM unnest(c.trusted_proxy_cidrs) a),
    -- 20261116020000: or the one header our edge puts the caller's address in; and the /ping aid
    'client_ip_header', c.client_ip_header,
    'ping_shows_headers', c.ping_shows_headers)
  FROM public.sub_finder_config c LEFT JOIN public.sub_finder_key k ON k.key_id = p_key_id;
$function$;
