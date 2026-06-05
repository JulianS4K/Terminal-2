-- ============================================================
-- Add the New York Knicks Gametime performer to the TD discovery set.
-- A1 2026-05-30.
--
-- Gap found while investigating missing Gametime data for the Knicks NBA Finals
-- home games: td_gt_discover() iterates ONLY rows in td_gt_performers, which held
-- just MLB teams (Yankees active; Mets/Phillies/Blue Jays inactive) — no Knicks.
-- So Gametime was never queried for the Knicks, and GT had zero Knicks xref/listings.
--
-- With the Knicks performer added, the daily td_gt_discover() + td_gt_discover_drain()
-- cron queries Gametime for the Knicks, matches returned events to sg_events_canonical
-- by datetime (±30min), and creates GT xref automatically. Verified live 2026-05-30:
-- Gametime returned the 3 Finals home games and 179/201/162 listings flowed for
-- tevo 3346011/3346012/3346026 (Home Games 1/2/3). (Gametime, like SeatGeek, lists
-- no Home Game 4 — the Knicks are the lower seed, so they only host Games 3/4/6.)
--
-- Mirrors the Knicks seeds already in td_tm_performers / td_tp_performers
-- (migrations 20260529200000 / 20260529180000). Idempotent.
-- ============================================================
INSERT INTO public.td_gt_performers (performer_url, active, updated_at)
SELECT 'https://gametime.co/new-york-knicks-tickets/performers/nbanyk', true, now()
WHERE NOT EXISTS (
  SELECT 1 FROM public.td_gt_performers
  WHERE performer_url = 'https://gametime.co/new-york-knicks-tickets/performers/nbanyk');
