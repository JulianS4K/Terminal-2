-- Migration 20261118003000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tm_link_seller()(new),tm_link_channel()(new),tm_discovery_event(+seller,channel generated),v_tm_discovery_link(replaced: + seller, channel),v_tm_discovery_channel(new view),v_event_xmap(replaced when present: + ticketmaster_seller, ticketmaster_channel) · reads:tm_discovery_event.url · pre:20261117190000
--
-- MAPPING PROGRAM — WHO SELLS A TICKETMASTER EVENT, AND ON WHICH SIDE, READ FROM ITS LINK.
--
-- Operator 2026-11-19: "Does it differentiate between primary and secondary?" — Discovery does not: it lists the event,
-- not the tickets, carries no `source` field on prod rows, and its few price ranges are all `standard`. "Base by link
-- url then." The event's `url` is the one thing that names the seller: ticketmaster.com / .ca and am.ticketmaster.com
-- (the box office), universe.com, ticketweb.com, Front Gate (fgtix), Etix, AXS, Fevo, Paciolan's evenue.net, Eventim,
-- ATG, a long tail of venues' own box offices — and, now and then, a resale marketplace (seatgeek.com) or a
-- Ticketmaster resale page, or a package seller (travel.ticketmaster.com, vipnation.com). Doubleclick ad wrappers
-- carry the real link after ";?".
--
-- What this migration does (no upstream call; derived from a column we already hold):
--   `tm_link_seller(url)`   IMMUTABLE → the seller: 'ticketmaster', 'universe', 'ticketweb', 'frontgate', 'etix', 'axs',
--                           'fevo', 'evenue', 'eventim', 'atg', 'seatgeek', 'vipnation', 'ticketmaster_travel' … else the
--                           bare host (a venue's own box office); NULL for no link.
--   `tm_link_channel(url)`  IMMUTABLE → 'primary' | 'secondary' (a resale marketplace host, or "resale" in the link) |
--                           'package' (travel / VIP package sellers) | 'unknown' (no link).
--   `tm_discovery_event.seller`, `.channel`: STORED generated columns over `url` (a one-time rewrite of the table).
--   `v_tm_discovery_link` shows both; `v_tm_discovery_channel` counts events by channel and seller;
--   `v_event_xmap` gains `ticketmaster_seller` / `ticketmaster_channel` at the end (only where the spine exists —
--   the Discovery harness has no spine).
--
-- Apply: `BEGIN;` / `COMMIT;` stripped; away from :27 (the drip) — the table rewrite takes a short exclusive lock.
-- Harness: tests/sql/tm_discovery (section G).

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.tm_link_host(p_url text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 PARALLEL SAFE
AS $function$
  -- the host of the link, unwrapped from a doubleclick ad redirect (";?https://real.host/…")
  SELECT lower(nullif(regexp_replace(
           CASE WHEN p_url ~* '^https?://ad\.doubleclick\.net/.*;\?https?://' THEN regexp_replace(p_url, '^.*;\?(https?://)', '\1')
                ELSE coalesce(p_url, '') END,
           '^https?://([^/?#]+).*$', '\1'), ''))
$function$;

CREATE OR REPLACE FUNCTION public.tm_link_seller(p_url text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 PARALLEL SAFE
AS $function$
  SELECT CASE
           WHEN h IS NULL OR h !~ '\.' THEN NULL
           WHEN h = 'travel.ticketmaster.com' THEN 'ticketmaster_travel'
           WHEN h ~ '(^|\.)ticketmaster\.(com|ca)$' THEN 'ticketmaster'
           WHEN h ~ '(^|\.)universe\.com$' THEN 'universe'
           WHEN h ~ '(^|\.)ticketweb\.(com|ca)$' THEN 'ticketweb'
           WHEN h ~ '(^|\.)(fgtix|frontgatetickets)\.com$' THEN 'frontgate'
           WHEN h ~ '(^|\.)etix\.com$' THEN 'etix'
           WHEN h ~ '(^|\.)axs\.com$' THEN 'axs'
           WHEN h ~ '(^|\.)gofevo\.com$' THEN 'fevo'
           WHEN h ~ '(^|\.)evenue\.net$' THEN 'evenue'
           WHEN h ~ '(^|\.)eventim\.(us|com)$' THEN 'eventim'
           WHEN h ~ '(^|\.)atgtickets\.com$' THEN 'atg'
           WHEN h ~ '(^|\.)seatgeek\.com$' THEN 'seatgeek'
           WHEN h ~ '(^|\.)stubhub\.(com|ca)$' THEN 'stubhub'
           WHEN h ~ '(^|\.)vividseats\.com$' THEN 'vividseats'
           WHEN h ~ '(^|\.)tickpick\.com$' THEN 'tickpick'
           WHEN h ~ '(^|\.)gametime\.co$' THEN 'gametime'
           WHEN h ~ '(^|\.)vipnation\.com$' THEN 'vipnation'
           ELSE regexp_replace(h, '^www\.', '')
         END
    FROM (SELECT public.tm_link_host(p_url) AS h) s
$function$;

CREATE OR REPLACE FUNCTION public.tm_link_channel(p_url text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 PARALLEL SAFE
AS $function$
  SELECT CASE
           WHEN s.seller IS NULL THEN 'unknown'
           WHEN s.seller IN ('seatgeek', 'stubhub', 'vividseats', 'tickpick', 'gametime') THEN 'secondary'
           WHEN p_url ~* '(^|[^a-z])resale([^a-z]|$)' THEN 'secondary'
           WHEN s.seller IN ('ticketmaster_travel', 'vipnation') OR p_url ~* 'package-forward' THEN 'package'
           ELSE 'primary'
         END
    FROM (SELECT public.tm_link_seller(p_url) AS seller) s
$function$;
COMMENT ON FUNCTION public.tm_link_seller(text) IS 'The seller a Ticketmaster Discovery event links to (ticketmaster, universe, ticketweb, frontgate, etix, axs, fevo, evenue, eventim, atg, a resale marketplace, a package seller, else the venue''s own host); doubleclick wrappers unwrapped. Mig 20261118003000.';
COMMENT ON FUNCTION public.tm_link_channel(text) IS 'primary | secondary (resale marketplace host or "resale" in the link) | package (travel / VIP sellers) | unknown (no link), from the event''s url. Mig 20261118003000.';

-- the columns, kept by the database from the link
ALTER TABLE public.tm_discovery_event
  ADD COLUMN IF NOT EXISTS seller  text GENERATED ALWAYS AS (public.tm_link_seller(url)) STORED,
  ADD COLUMN IF NOT EXISTS channel text GENERATED ALWAYS AS (public.tm_link_channel(url)) STORED;
CREATE INDEX IF NOT EXISTS tm_discovery_event_channel_idx ON public.tm_discovery_event (channel, seller);
COMMENT ON COLUMN public.tm_discovery_event.channel IS 'primary | secondary | package | unknown, read from url by tm_link_channel(). Mig 20261118003000.';

-- the review view, with both
CREATE OR REPLACE VIEW public.v_tm_discovery_link AS
SELECT d.tm_event_id, d.name AS tm_name, d.local_date, d.local_time, d.status_code, d.segment, d.genre, d.venue_name, d.venue_city, d.venue_state,
       d.tm_venue_id, x.tevo_venue_id, x.method AS venue_method,
       d.tevo_event_id, d.tevo_match_method, e.name AS evo_name, e.occurs_at_local AS evo_start,
       d.public_onsale, jsonb_array_length(coalesce(d.presales, '[]'::jsonb)) AS presales, d.ticket_limit, d.url,
       d.seller, d.channel
  FROM public.tm_discovery_event d
  LEFT JOIN public.tm_venue_xref x ON x.tm_venue_id = d.tm_venue_id
  LEFT JOIN public.events e ON e.id = d.tevo_event_id;
COMMENT ON VIEW public.v_tm_discovery_link IS 'Ticketmaster Discovery events with their venue xref, TEvo match, seller and channel (from the link), for review. Migs 20261117180000 / 20261118003000.';

CREATE OR REPLACE VIEW public.v_tm_discovery_channel AS
SELECT d.channel, d.seller, count(*) AS events,
       count(*) FILTER (WHERE d.local_date >= current_date) AS upcoming,
       count(*) FILTER (WHERE d.tevo_event_id IS NOT NULL) AS matched_tevo,
       count(*) FILTER (WHERE d.is_product) AS products
  FROM public.tm_discovery_event d
 GROUP BY d.channel, d.seller;
COMMENT ON VIEW public.v_tm_discovery_channel IS 'Ticketmaster Discovery events by channel (primary / secondary / package / unknown) and seller, from the link. Mig 20261118003000.';
REVOKE ALL ON public.v_tm_discovery_link, public.v_tm_discovery_channel FROM anon, authenticated;
GRANT SELECT ON public.v_tm_discovery_link, public.v_tm_discovery_channel TO service_role;
REVOKE ALL ON FUNCTION public.tm_link_host(text), public.tm_link_seller(text), public.tm_link_channel(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tm_link_host(text), public.tm_link_seller(text), public.tm_link_channel(text) TO service_role;

-- the spine view, where the spine exists: the Ticketmaster seller and channel at the end (CREATE OR REPLACE may only append)
DO $spine$
BEGIN
  IF to_regclass('public.event_xmap') IS NULL OR to_regclass('public.v_event_xmap') IS NULL THEN RETURN; END IF;
  EXECUTE $v$
    CREATE OR REPLACE VIEW public.v_event_xmap AS
    SELECT x.xmap_id AS internal_event_id, x.xmap_id, x.local_day, x.start_local, x.name, x.venue_name, x.venue_city, x.venue_state, x.tevo_venue_id, x.sources, x.seed_source,
           x.tevo_event_id, e.name AS evo_name,
           x.espn_event_id, g2.name AS espn_name, g2.espn_league,
           tm.tm_event_id, tm.name AS ticketmaster_name,
           x.tp_event_id, tp.name AS tickpick_name,
           x.vivid_event_id, vv.name AS vivid_name,
           x.gt_event_id, gt.name AS gotickets_name,
           x.axs_event_id, coalesce(ax.event_title_clean, ax.event_title) AS axs_name,
           x.sg_event_id, sg.sg_event_name AS seatgeek_name,
           x.mlb_schedule_id, CASE WHEN g.schedule_id IS NOT NULL THEN g.away_name || ' at ' || g.home_name END AS mlb_name,
           x.methods, x.updated_at,
           tm.seller AS ticketmaster_seller, tm.channel AS ticketmaster_channel
      FROM public.event_xmap x
      LEFT JOIN public.events e ON e.id = x.tevo_event_id
      LEFT JOIN public.espn_ticket_game g2 ON g2.espn_event_id = x.espn_event_id::text
      LEFT JOIN public.tm_discovery_event tm ON tm.tm_seq = x.tm_event_seq
      LEFT JOIN public.tickpick_catalog_event tp ON tp.tp_event_id = x.tp_event_id
      LEFT JOIN public.vivid_catalog_event vv ON vv.vivid_event_id = x.vivid_event_id
      LEFT JOIN public.gotickets_event gt ON gt.gt_event_id = x.gt_event_id
      LEFT JOIN public.axs_export_event ax ON ax.axs_event_id = x.axs_event_id
      LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = x.sg_event_id
      LEFT JOIN public.mlb_ticket_game g ON g.schedule_id = x.mlb_schedule_id$v$;
  EXECUTE 'REVOKE ALL ON public.v_event_xmap FROM anon, authenticated';
  EXECUTE 'GRANT SELECT ON public.v_event_xmap TO service_role';
END
$spine$;

COMMIT;
