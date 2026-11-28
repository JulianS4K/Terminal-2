-- Migration 20261128060000 · level:data-collection · lane:a1 (ProVenue watch) · writes:provenue_watch_config.club_order_max(+WSH) · reads:—
--
-- The Nationals' order cap, 19, for every game whose capture does not show one (mig 20261128050000). Operator
-- 2026-11-28, with the Nationals' checkout ("ERROR: Exceeded the price option maximum. ERROR: You can only select
-- 19 seats as Regular Ticket."): "nationals". The first reads of Nationals games showed no cap: every block sold whole,
-- the largest 33, so their events went to the CRM with no order_max; now they carry 19, and a block over it is sent
-- as pieces of 19.

BEGIN;

UPDATE public.provenue_watch_config SET club_order_max = club_order_max || '{"WSH": 19}'::jsonb;

COMMIT;
