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
-- sub_finder_key_gate hands the setting to routers/subs_api.py. Shipped whole.
--
-- rollback: UPDATE public.sub_finder_config SET client_ip_hops = 1 WHERE id = true;

ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS client_ip_hops integer NOT NULL DEFAULT 1 CHECK (client_ip_hops BETWEEN 1 AND 5);

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
    'client_ip_hops', c.client_ip_hops)       -- 20261116010000: which X-Forwarded-For entry is the caller
  FROM public.sub_finder_config c LEFT JOIN public.sub_finder_key k ON k.key_id = p_key_id;
$function$;
