-- Migration 20261116010000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_key_gate · reads:sub_finder_key · pre:20261116000000
--
-- WHICH ENTRY OF X-Forwarded-For IS THE CALLER.
--
-- 20261116000000 locks a key to addresses, read from the last X-Forwarded-For entry. Tested on the
-- live service the same day: that entry is a Cloudflare edge address (172.68.x / 172.71.x, a
-- different one on each call), not the caller. Two proxies of ours stand in front of the app:
-- Cloudflare, which appends the address that connected to it (the caller), and the host's
-- router, which appends Cloudflare's. So the caller is the entry before the last.
--
-- sub_finder_config.client_ip_hops says how many of OUR proxies are in front: the caller is the
-- entry that many from the end. 1 (the default here) is the last entry, as before, so applying
-- this changes nothing. Set it to the real count and check with GET /ping (`your_ip`), once
-- plainly and once with a made-up X-Forwarded-For header: the answer must be the caller's own
-- address both times. Too low reads a proxy (every address lock refuses: safe). Too high reads
-- an entry the caller wrote (unsafe), so never raise it past what that test supports. A chain
-- shorter than the setting gives no address, and a key locked to addresses is then refused.
--
-- Counting alone would trust a made-up header on any request that reached the app without
-- passing through every one of those proxies. So the count is not taken on faith: every entry
-- AFTER the caller's (the ones our proxies wrote about each other) must be inside
-- sub_finder_config.trusted_proxy_cidrs, or there is no address. It ships holding the ranges
-- Cloudflare publishes (https://www.cloudflare.com/ips-v4 and /ips-v6, read 2026-11-16); if
-- Cloudflare adds a range, calls through it are refused for address-locked keys until the
-- list is updated: closed, not open. With client_ip_hops = 1 no entry follows the caller's and
-- the list is not used.
--
-- What this rests on: every public request reaches the app through Cloudflare and then the
-- host's router, and that router writes the last entry itself. The app's own socket peer is
-- the router's private address, which looks like any other service on the private network, so
-- checking the peer would prove nothing. A caller already inside our private network could
-- therefore write the whole chain: against one the address lock adds nothing, and it would
-- still need the key.
--
-- sub_finder_key_gate hands the setting to routers/subs_api.py. Shipped whole.
--
-- rollback: UPDATE public.sub_finder_config SET client_ip_hops = 1 WHERE id = true;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS client_ip_hops integer NOT NULL DEFAULT 1 CHECK (client_ip_hops BETWEEN 1 AND 5),
  ADD COLUMN IF NOT EXISTS trusted_proxy_cidrs inet[] NOT NULL DEFAULT
    '{173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,2400:cb00::/32,2606:4700::/32,2803:f800::/32,2405:b500::/32,2405:8100::/32,2a06:98c0::/29,2c0f:f248::/32}'::inet[];

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
    'trusted_proxies', (SELECT coalesce(jsonb_agg(text(a)), '[]'::jsonb) FROM unnest(c.trusted_proxy_cidrs) a))
  FROM public.sub_finder_config c LEFT JOIN public.sub_finder_key k ON k.key_id = p_key_id;
$function$;
