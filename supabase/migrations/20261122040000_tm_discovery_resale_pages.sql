-- Migration 20261122040000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tm_link_seller()(replaced: Ticketmaster resale pages),tm_link_channel()(replaced),tm_discovery_event(seller/channel recomputed for Z7r9j ids) · reads:tm_discovery_event · pre:20261118003000
--
-- MAPPING PROGRAM — TICKETMASTER RESALE PAGES ARE SECONDARY, NOT PRIMARY.
--
-- Mig 20261118003000 read the seller and the channel from the event's link, and every ticketmaster.com link read as
-- primary. The Sub Finder session (2026-11-22, from Ticketmaster's bulk Discovery Feed, column SOURCE) showed that
-- Ticketmaster lists RESALE PAGES as events of their own: source `tmr`, ids starting `Z7r9j`, links of the form
-- ticketmaster.com/event/Z7r9j… with no slug — a resale page for an event whose primary sale is elsewhere. On prod
-- 44,671 of 129,727 events are such pages (every one has the `/event/Z7r9j` marker in its link; none has a primary
-- twin at the same venue, date and name, so they are not duplicates in the spine — they are Ticketmaster's resale
-- presence for shows it does not sell first-hand).
--
-- What this migration does (derived from columns we hold; no upstream call):
--   `tm_link_seller(url)`  → 'ticketmaster_resale' for a link carrying `/event/Z7r9j`.
--   `tm_link_channel(url)` → 'secondary' for that seller.
--   The STORED columns `seller` / `channel` are recomputed for the Z7r9j rows (a no-op UPDATE on `url` makes the
--   database recompute both; the change-log trigger on prod watches status / date / time / venue, not these).
--   When the feed's `source` column lands on prod (Sub Finder PR #1170), it is the authority; this reading agrees
--   with it for the rows the feed covers and stands in for the rest.
--
-- Apply: `BEGIN;` / `COMMIT;` stripped; away from :27 (the drip). Harness: tests/sql/tm_discovery (section G).

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.tm_link_seller(p_url text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 PARALLEL SAFE
AS $function$
  SELECT CASE
           WHEN h IS NULL OR h !~ '\.' THEN NULL
           WHEN h ~ '(^|\.)ticketmaster\.(com|ca)$' AND p_url ~ '/event/Z7r9j' THEN 'ticketmaster_resale'   -- a TMR resale page (mig 20261122040000)
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
           WHEN s.seller IN ('ticketmaster_resale', 'seatgeek', 'stubhub', 'vividseats', 'tickpick', 'gametime') THEN 'secondary'
           WHEN p_url ~* '(^|[^a-z])resale([^a-z]|$)' THEN 'secondary'
           WHEN s.seller IN ('ticketmaster_travel', 'vipnation') OR p_url ~* 'package-forward' THEN 'package'
           ELSE 'primary'
         END
    FROM (SELECT public.tm_link_seller(p_url) AS seller) s
$function$;
COMMENT ON FUNCTION public.tm_link_seller(text) IS 'The seller a Ticketmaster Discovery event links to (ticketmaster; ticketmaster_resale for a TMR resale page — a /event/Z7r9j… link; universe, ticketweb, frontgate, etix, axs, fevo, evenue, eventim, atg, a resale marketplace, a package seller, else the venue''s own host); doubleclick wrappers unwrapped. Migs 20261118003000 / 20261122040000.';
COMMENT ON FUNCTION public.tm_link_channel(text) IS 'primary | secondary (a Ticketmaster resale page, a resale marketplace host, or "resale" in the link) | package (travel / VIP sellers) | unknown (no link), from the event''s url. Migs 20261118003000 / 20261122040000.';

-- recompute the stored columns for the resale pages (generated columns are rebuilt on any update of the row)
UPDATE public.tm_discovery_event SET url = url WHERE tm_event_id LIKE 'Z7r9j%' AND channel IS DISTINCT FROM 'secondary';

COMMIT;
