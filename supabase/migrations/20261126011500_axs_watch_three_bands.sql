-- Migration 20261126011500 · level:data-collection · lane:a1 (AXS watch cadence) · writes:axs_watch_cadence(replaced rows) · reads:primary_poll_event
--
-- ============================================================================
-- Migration 20261126011500 — three polling bands, as the operator set them
--
-- Lane:     a1 (AXS watch cadence)
-- Touches:  axs_watch_cadence (its rows replaced; no schema or function change).
-- pre:      20261125214500 (the table), 20261125232000 (the previous intervals).
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market. It changes only how
-- often the existing reader is told to read.
--
-- ── WHAT THE OPERATOR SET ─────────────────────────────────────────────────
-- Operator 2026-11-26: "3 polling bands under 7 days 30 mins, 8-30 days 1 hour
-- 3-120 60 mins and 120 + 90 mins" then "30-120 60 mins*".
--
-- The correction makes it three bands rather than four: 8-30 days and 30-120 days
-- were both given as 60 minutes, so they are one band from 7 to 120 days.
--
--   days out      events   every     reads/h   reads/day
--   <= 7               6   30 min       12.0         288
--   7 - 120           69   60 min       69.0       1,656
--   120 +             13   90 min        8.7         208
--   TOTAL             88               89.7 /h     2,152 /day
--
-- Measured on prod at 01:1xZ with the three-team list of 88 events.
--
-- ── WHAT IT COSTS, AND WHAT IT GIVES UP ───────────────────────────────────
-- Against the budgets: 31% of the reader's measured usable 287 reads/h, and 20%
-- of the day's cap (10,735). That is roughly half the load of the seven-band
-- ladder it replaces (159.5/h, 3,828/day), so the headroom through a restart hour
-- is larger still.
--
-- What it gives up is freshness on the near games: a fixture inside a week reads
-- every 30 minutes rather than every 10, and one at 30-60 days every 60 minutes
-- rather than every 30. That is the operator's call, recorded here because the
-- earlier ladder was argued for on freshness grounds and this reverses part of
-- that argument — not because anything measured changed.
--
-- ⚠ hot_every IS 30 MINUTES, so under these bands only the <= 7-day band counts
-- as hot: once the day's cap is spent, axs_watch_next() hands out the six games
-- inside a week and nothing else. With the previous ladder that was everything
-- inside 60 days. The triage is narrower but still the right end of the list.
-- No band now sits below hot_every, so nothing is served more often than the cap
-- branch allows.
--
-- The seven seeded rows are REPLACED rather than disabled, so the table reads as
-- the three bands the operator named and nothing has to be inferred from an
-- enabled flag. axs_watch_cadence_every() and axs_watch_settle_one() are
-- untouched: the ladder is data, which is the point of the table.
-- ============================================================================

BEGIN;

DELETE FROM public.axs_watch_cadence;

INSERT INTO public.axs_watch_cadence (band, max_days, every, sort_order, note) VALUES
  ('d0_7',     7,  interval '30 minutes', 1, 'inside a week; also the hot_every bound'),
  ('d7_120', 120,  interval '60 minutes', 2, 'operator 2026-11-26: 8-30 and 30-120 are both an hour, so one band'),
  ('d120_up',1e9,  interval '90 minutes', 3, 'to the watch_until_days ceiling');

COMMIT;
