-- Migration 20260709240000 · lane:D0 (author) → A1 (apply) · writes:performer_stat_card_history,snapshot_performer_stat_card_history,get_performer_stat_card_history,cron(performer-stat-card-history-snapshot) · reads:performer_stat_card,performer_metrics_daily · pre:performer_stat_card (mig 20260709140000 + primary cols 20260709230000) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (creates a table + cron + backfills)
--
-- D0 — performer stat-card HISTORY: a persisted daily timeseries of the card's
-- headline price layers, so the desk can see the resale premium expanding or
-- compressing over time instead of only today's snapshot.
--
-- performer_stat_card is OVERWRITTEN every refresh (one row/performer), so the
-- new layers (primary/face, realized-sold, spread) have no history. This table
-- APPENDS one row per (performer, day) — never overwrites a past day — capturing
-- the four lenses: ask (price_median), face (primary_median), realized
-- (sg_sold_median), plus get-in, spread, ask-over-sold, and float.
--
-- The ask + get-in + float columns are ALSO backfilled 120d from
-- performer_metrics_daily (split='all'), which already carries that history — so
-- the ask line has immediate depth. The face/sold/spread columns only exist from
-- today forward (no upstream history to backfill), so they are NULL for
-- backfilled dates and the sparkline renders them as a gap until they accrue.

-- ============================================================
-- 1. Table (RLS-locked; SECDEF RPC is the only read path)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.performer_stat_card_history (
  performer_id      bigint  NOT NULL,
  snapshot_date     date    NOT NULL,
  price_median      numeric,   -- ask (resale listing median)
  getin_median      numeric,
  primary_median    numeric,   -- face (box-office, non-resale) — forward only
  sg_sold_median    numeric,   -- realized clearing — forward only
  ask_over_sold_pct numeric,   -- forward only
  spread_ratio      numeric,
  market_tickets    bigint,
  owned_tickets     bigint,
  captured_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (performer_id, snapshot_date)
);

ALTER TABLE public.performer_stat_card_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.performer_stat_card_history FROM anon, authenticated;

-- ============================================================
-- 2. Daily append — upsert today's row from the live card
-- ============================================================
CREATE OR REPLACE FUNCTION public.snapshot_performer_stat_card_history()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  INSERT INTO public.performer_stat_card_history AS h (
    performer_id, snapshot_date, price_median, getin_median, primary_median,
    sg_sold_median, ask_over_sold_pct, spread_ratio, market_tickets, owned_tickets, captured_at)
  SELECT performer_id, CURRENT_DATE, price_median, getin_median, primary_median,
         sg_sold_median, ask_over_sold_pct, spread_ratio, market_tickets, owned_tickets, now()
  FROM public.performer_stat_card
  ON CONFLICT (performer_id, snapshot_date) DO UPDATE SET
    price_median = EXCLUDED.price_median, getin_median = EXCLUDED.getin_median,
    primary_median = EXCLUDED.primary_median, sg_sold_median = EXCLUDED.sg_sold_median,
    ask_over_sold_pct = EXCLUDED.ask_over_sold_pct, spread_ratio = EXCLUDED.spread_ratio,
    market_tickets = EXCLUDED.market_tickets, owned_tickets = EXCLUDED.owned_tickets,
    captured_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.snapshot_performer_stat_card_history() FROM PUBLIC;

-- ============================================================
-- 3. Read RPC (@s4kent.com-gated SECDEF) — the sparkline series
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_performer_stat_card_history(
  p_performer_id bigint, p_days integer DEFAULT 120)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.snapshot_date), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT snapshot_date, price_median, getin_median, primary_median,
           sg_sold_median, ask_over_sold_pct, spread_ratio, market_tickets, owned_tickets
    FROM public.performer_stat_card_history
    WHERE performer_id = p_performer_id
      AND snapshot_date >= CURRENT_DATE - greatest(p_days, 1)
    ORDER BY snapshot_date
  ) s;

  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_performer_stat_card_history(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_performer_stat_card_history(bigint, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_performer_stat_card_history(bigint, integer) IS
  'D0 performer stat-card history: daily ask/face/sold/spread series for the sparkline. @s4kent.com-gated SECDEF read.';

-- ============================================================
-- 4. Backfill ask-side history (120d) + capture today's full row
-- ============================================================
-- 4a. Ask / get-in / float from the existing daily metrics history. DO NOTHING so
--     a same-day row from step 4b (full card) is never clobbered by the partial.
INSERT INTO public.performer_stat_card_history (
  performer_id, snapshot_date, price_median, getin_median, market_tickets, owned_tickets, captured_at)
SELECT performer_id, snapshot_date, price_median, getin_median,
       (coalesce(evo_tickets_total,0) + coalesce(sg_all_tickets_total,0))::bigint,
       (coalesce(evo_owned_tickets_total,0) + coalesce(sg_owned_tickets_total,0))::bigint,
       now()
FROM public.performer_metrics_daily
WHERE split = 'all' AND snapshot_date >= CURRENT_DATE - 120
ON CONFLICT (performer_id, snapshot_date) DO NOTHING;

-- 4b. Today's full row (all four lenses) from the live card.
SELECT public.snapshot_performer_stat_card_history();

-- ============================================================
-- 5. Daily cron — after all the card refreshes land (primary :05, axs :25)
-- ============================================================
DO $cron$
BEGIN
  PERFORM cron.unschedule('performer-stat-card-history-snapshot');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$cron$;

SELECT cron.schedule('performer-stat-card-history-snapshot', '45 7 * * *', $cron$
  SELECT public.snapshot_performer_stat_card_history();
$cron$);
