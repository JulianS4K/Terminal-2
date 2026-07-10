-- Migration 20260709210000 · lane:D0 (author) → A1 (apply) · writes:performer_stat_card(+3 cols),refresh_performer_sg_sold,cron(performer-sg-sold-refresh) · reads:seatgeek_event_metrics,events · pre:performer_stat_card (mig 20260709140000) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (alters a table + cron + backfills)
--
-- D0 — performer SG SOLD (realized) layer: median + average sold price and
-- volume, per event YEAR, from the LIVE SeatGeek sales feed.
--
-- Source is seatgeek_event_metrics ONLY (sold_price_median/mean, sold_quantity —
-- realized clearing prices, keyed to tracked/current events, captured live).
-- The seatgeek_historic_sales table is DELIBERATELY NOT USED: it is a pre-COVID
-- block (2018/2020, ~1 sale in 2025) — junk for current valuation.
--
-- Realized ≠ listing: e.g. Morgan Wallen sold median $261 vs our listing median
-- $396 — asks overstate value, so the sold line is the truer anchor. Both median
-- AND average are stored per year (the gap shows premium-sale skew). Coverage is
-- ~1/3 of performers (SG sold data concentrates on bigger events) — additive
-- layer, not a replacement for listing metrics.

ALTER TABLE public.performer_stat_card
  ADD COLUMN IF NOT EXISTS sg_sold_by_year jsonb,      -- [{year, events, qty, sold_median, sold_mean}] desc
  ADD COLUMN IF NOT EXISTS sg_sold_median  numeric,    -- overall median across all events (all years)
  ADD COLUMN IF NOT EXISTS sg_sold_qty     bigint;     -- total tickets sold across all years

CREATE OR REPLACE FUNCTION public.refresh_performer_sg_sold()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  UPDATE public.performer_stat_card
     SET sg_sold_by_year = NULL, sg_sold_median = NULL, sg_sold_qty = NULL
   WHERE sg_sold_by_year IS NOT NULL OR sg_sold_median IS NOT NULL;

  WITH latest AS (
    SELECT DISTINCT ON (sg_event_id) sg_event_id, tevo_event_id,
           sold_price_median, sold_price_mean, sold_quantity
    FROM public.seatgeek_event_metrics
    WHERE sold_price_median IS NOT NULL AND tevo_event_id IS NOT NULL
    ORDER BY sg_event_id, captured_at DESC
  ),
  pe AS (
    SELECT u.pid AS performer_id,
           CASE WHEN e.occurs_at_local ~ '^\d{4}' THEN left(e.occurs_at_local, 4)::int END AS yr,
           l.sold_price_median, l.sold_price_mean, l.sold_quantity
    FROM public.events e
    CROSS JOIN LATERAL unnest(e.performer_ids) AS u(pid)
    JOIN latest l ON l.tevo_event_id = e.id
  ),
  by_year AS (
    SELECT performer_id, yr,
           count(*)::int AS events,
           sum(sold_quantity)::bigint AS qty,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sold_price_median)::numeric, 2) AS sold_median,
           round((sum(sold_price_mean * sold_quantity) / nullif(sum(sold_quantity), 0))::numeric, 2) AS sold_mean
    FROM pe WHERE yr IS NOT NULL
    GROUP BY performer_id, yr
  ),
  agg AS (
    SELECT performer_id,
           jsonb_agg(jsonb_build_object('year', yr, 'events', events, 'qty', qty,
                       'sold_median', sold_median, 'sold_mean', sold_mean) ORDER BY yr DESC) AS by_year,
           sum(qty)::bigint AS total_qty
    FROM by_year GROUP BY performer_id
  ),
  overall AS (
    SELECT performer_id,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sold_price_median)::numeric, 2) AS med
    FROM pe WHERE yr IS NOT NULL GROUP BY performer_id
  )
  UPDATE public.performer_stat_card t
     SET sg_sold_by_year = a.by_year, sg_sold_qty = a.total_qty, sg_sold_median = o.med
    FROM agg a JOIN overall o USING (performer_id)
   WHERE t.performer_id = a.performer_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_performer_sg_sold() FROM PUBLIC;

-- Backfill + daily cron (:55; sold feed is live but the rollup is not latency-sensitive)
SELECT public.refresh_performer_sg_sold();

DO $cron$
BEGIN
  PERFORM cron.unschedule('performer-sg-sold-refresh');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$cron$;

SELECT cron.schedule('performer-sg-sold-refresh', '55 6 * * *', $cron$
  SELECT public.refresh_performer_sg_sold();
$cron$);
