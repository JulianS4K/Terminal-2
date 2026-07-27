-- Migration 20260709230000 · lane:D0 (author) → A1 (apply) · writes:performer_stat_card(+8 cols),refresh_performer_primary_median,cron(performer-primary-median-refresh) · reads:ticketsdata_listings_snapshots,ticketsdata_event_xref,aq_event_map,events,v_axs_listings,axs_event_performer_xref · pre:performer_stat_card (mig 20260709140000), axs_event_performer_xref (mig 20260709170000) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (alters a table + cron + backfills)
--
-- D0 — performer PRIMARY-MARKET (face-value) median: the box-office anchor, split
-- out from the resale ask. Two primary sources, blended per performer:
--
--   * Ticketmaster PRIMARY — ticketsdata_listings_snapshots where
--     raw->'offer'->>'inventoryType' = 'primary' (TM's own flag cleanly separates
--     its box-office inventory from the resale marketplace on the same event page).
--     Resale ('resale') is DELIBERATELY excluded — that is the ask, already on the
--     card via price_median. Join to performer: snapshot event_id → ticketsdata_
--     event_xref → aq_event_map.tevo_event_id → events.performer_ids.
--   * AXS PRIMARY — v_axs_listings where type <> 'FLASHSEATS' (FlashSeats is AXS's
--     fan-to-fan resale marketplace; STANDARD/PREMIUM/PREMIUMVIP/ACCESSIBLE/
--     DEMANDTICKETS are box-office). Join via axs_event_performer_xref.tevo_performer_id.
--
-- Why this matters: measured, primary sits far below the resale ask — e.g. TM
-- primary vs resale on the same MSG slate ran $129.50 vs $339 median; Yankees
-- primary ~$95. The gap is the resale premium. Storing the primary median gives
-- the desk the true face anchor alongside the ask (price_median) and the realized
-- clear (sg_sold_median).
--
-- Method (consistent with the rest of the card): compute an event-level primary
-- median per event (latest capture), then take the per-performer median across
-- those event medians. Per-source medians + event counts are kept for transparency;
-- the blended `primary_median` is the median across the UNION of both sources'
-- event medians. Coverage is partial (TM = MSG + discovery slate; AXS = last poll,
-- which paused ~2026-06-29) — additive layer, NULL where no primary data exists.

ALTER TABLE public.performer_stat_card
  ADD COLUMN IF NOT EXISTS primary_median      numeric,   -- blended median of primary event medians (TM+AXS)
  ADD COLUMN IF NOT EXISTS primary_source      text,      -- 'tm' | 'axs' | 'both'
  ADD COLUMN IF NOT EXISTS primary_events      integer,   -- distinct primary events across both sources
  ADD COLUMN IF NOT EXISTS primary_tm_median   numeric,
  ADD COLUMN IF NOT EXISTS primary_tm_events   integer,
  ADD COLUMN IF NOT EXISTS primary_axs_median  numeric,
  ADD COLUMN IF NOT EXISTS primary_axs_events  integer,
  ADD COLUMN IF NOT EXISTS primary_computed_at timestamptz;

CREATE OR REPLACE FUNCTION public.refresh_performer_primary_median()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  -- clear prior values (rebuild)
  UPDATE public.performer_stat_card
     SET primary_median = NULL, primary_source = NULL, primary_events = NULL,
         primary_tm_median = NULL, primary_tm_events = NULL,
         primary_axs_median = NULL, primary_axs_events = NULL,
         primary_computed_at = now()
   WHERE primary_median IS NOT NULL OR primary_source IS NOT NULL;

  WITH
  -- ---- Ticketmaster PRIMARY: event-level median → performer ----
  tm_latest AS (
    SELECT DISTINCT ON (event_id) event_id, captured_at
    FROM public.ticketsdata_listings_snapshots
    WHERE platform = 'TM'
    ORDER BY event_id, captured_at DESC
  ),
  tm_ev AS (
    SELECT s.event_id,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY s.list_price)::numeric, 2) AS ev_median
    FROM public.ticketsdata_listings_snapshots s
    JOIN tm_latest l ON l.event_id = s.event_id AND l.captured_at = s.captured_at
    WHERE s.platform = 'TM'
      AND s.raw->'offer'->>'inventoryType' = 'primary'
      AND coalesce(s.is_parking, false) = false
      AND s.list_price > 0
    GROUP BY s.event_id
  ),
  tm_perf AS (   -- (performer_id, tevo_event_id, ev_median), distinct per event
    SELECT DISTINCT u.pid AS performer_id, a.tevo_event_id AS ev_key, t.ev_median
    FROM tm_ev t
    JOIN public.ticketsdata_event_xref x ON x.event_id = t.event_id AND x.platform = 'TM'
    JOIN public.aq_event_map a ON a.aq_short_event_id = x.aq_short_event_id
    JOIN public.events e ON e.id = a.tevo_event_id
    CROSS JOIN LATERAL unnest(e.performer_ids) AS u(pid)
  ),
  -- ---- AXS PRIMARY: event-level median → performer ----
  ax_latest AS (
    SELECT DISTINCT ON (axs_event_id) axs_event_id, captured_at
    FROM public.v_axs_listings
    ORDER BY axs_event_id, captured_at DESC
  ),
  ax_ev AS (
    SELECT v.axs_event_id,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v.retail_price)::numeric, 2) AS ev_median
    FROM public.v_axs_listings v
    JOIN ax_latest l ON l.axs_event_id = v.axs_event_id AND l.captured_at = v.captured_at
    WHERE v.type <> 'FLASHSEATS' AND v.retail_price > 0
    GROUP BY v.axs_event_id
  ),
  ax_perf AS (   -- (performer_id, axs_event_id, ev_median)
    SELECT DISTINCT xr.tevo_performer_id AS performer_id, ax.axs_event_id AS ev_key, ax.ev_median
    FROM ax_ev ax
    JOIN public.axs_event_performer_xref xr ON xr.axs_event_id = ax.axs_event_id
    WHERE xr.tevo_performer_id IS NOT NULL
  ),
  -- ---- per-source rollups ----
  tm_agg AS (
    SELECT performer_id,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ev_median)::numeric, 2) AS tm_median,
           count(*)::int AS tm_events
    FROM tm_perf GROUP BY performer_id
  ),
  ax_agg AS (
    SELECT performer_id,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ev_median)::numeric, 2) AS axs_median,
           count(*)::int AS axs_events
    FROM ax_perf GROUP BY performer_id
  ),
  -- ---- blended: median across the union of both sources' event medians ----
  blend AS (
    SELECT performer_id,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ev_median)::numeric, 2) AS med,
           count(*)::int AS events
    FROM (
      SELECT performer_id, ev_median FROM tm_perf
      UNION ALL
      SELECT performer_id, ev_median FROM ax_perf
    ) u
    GROUP BY performer_id
  ),
  combined AS (
    SELECT coalesce(b.performer_id, t.performer_id, a.performer_id) AS performer_id,
           b.med AS primary_median, b.events AS primary_events,
           t.tm_median, t.tm_events, a.axs_median, a.axs_events,
           CASE WHEN t.performer_id IS NOT NULL AND a.performer_id IS NOT NULL THEN 'both'
                WHEN t.performer_id IS NOT NULL THEN 'tm'
                ELSE 'axs' END AS src
    FROM blend b
    FULL JOIN tm_agg t USING (performer_id)
    FULL JOIN ax_agg a USING (performer_id)
  )
  UPDATE public.performer_stat_card c
     SET primary_median = k.primary_median,
         primary_source = k.src,
         primary_events = k.primary_events,
         primary_tm_median = k.tm_median,
         primary_tm_events = k.tm_events,
         primary_axs_median = k.axs_median,
         primary_axs_events = k.axs_events,
         primary_computed_at = now()
    FROM combined k
   WHERE c.performer_id = k.performer_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_performer_primary_median() FROM PUBLIC;

-- Backfill now + daily cron (:05; primary feed is not latency-sensitive, and the
-- TM/AXS snapshots that feed it land on their own poll cadence)
SELECT public.refresh_performer_primary_median();

DO $cron$
BEGIN
  PERFORM cron.unschedule('performer-primary-median-refresh');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$cron$;

SELECT cron.schedule('performer-primary-median-refresh', '5 7 * * *', $cron$
  SELECT public.refresh_performer_primary_median();
$cron$);
