-- Migration 20260604160000 · lane:D0 (author) → A1 (apply) · writes:wc_price_daily,refresh_wc_price_daily,v_wc_price_latest,get_wc_price_daily,get_wc_price_board,watchlist(seed),cron(wc-price-daily-refresh) · reads:sg_events_canonical,seatgeek_listings_snapshots,cross_source_venue_resolve · pre:20260604120000 · auth:OPERATOR-APPROVED 2026-06-04 (scope: entire World Cup, watchlist=venues, execute=migration/PR). REQUIRES A1 apply (creates table+cron, seeds watchlist, backfills history).
--
-- D0 — 2026 WORLD CUP daily price logger + watchlist seed.
--
-- Why this is SG-sourced, not the TEvo firehose: the 2026 World Cup is FIFA
-- PRIMARY inventory. It does NOT flow through TEvo resale, so the broker `events`
-- table + event_listing_snapshot_daily carry ZERO WC matches (verified 2026-06-04).
-- SeatGeek DOES list them: all 101 matches are in sg_events_canonical, 100 have
-- listings, and seatgeek_listings_snapshots already holds ~154k rows of history.
-- So "pull all sources" = SeatGeek (the only source carrying WC inventory); this
-- logger rolls that firehose into a per-match daily price series.
--
-- WC match identification (the ONE predicate that's correct):
--   sg_event_name ILIKE '%world cup - match%'
--   * Group stage  : "Brazil vs Morocco - World Cup - Match 7 (Group C)"   ✓
--   * Knockouts    : "2026 World Cup - Match 104 (Final)"                  ✓
--   * EXCLUDES the false positive "... (World Cup Scarf Giveaway)" (an MLB
--     promo night) which a bare '%world cup%' wrongly catches. → 101 matches.
--
-- Daily collapse: SG polls each match ~1-2x/day on a horizon-banded cadence (NOT
-- every day this far out). For each (event, day) we take the LATEST pull's book
-- (max(captured_at)) and compute the all-in distribution over it — the end-of-day
-- order book. Headline price = retail_price_all_in (fees in); broadcast_price kept
-- alongside. Gaps are expected per event until the cadence tightens near kickoff.
--
-- Pieces: wc_price_daily (table) · refresh_wc_price_daily(from,to) (idempotent
-- delete+insert) · v_wc_price_latest (live board) · get_wc_price_daily /
-- get_wc_price_board (email-gated RPCs) · daily cron (trailing 4-day re-roll) ·
-- full backfill · watchlist seed (host venues that resolve to a canonical id).

-- ============================================================================
-- 1. Table
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.wc_price_daily (
  sg_event_id       bigint      NOT NULL,
  snapshot_date     date        NOT NULL,
  sg_event_name     text,
  venue_name        text,
  match_date        date,
  captured_at       timestamptz,            -- the SG pull rolled up for this day
  listings_count    integer,
  tickets_count     integer,
  owned_listings    integer,                -- broker-owned subset (is_broker_owned)
  owned_tickets     integer,
  allin_min         numeric,                -- retail_price_all_in (fees in) — headline
  allin_median      numeric,
  allin_p90         numeric,
  broadcast_min     numeric,                -- broadcast/list price
  broadcast_median  numeric,
  computed_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT wc_price_daily_pk PRIMARY KEY (sg_event_id, snapshot_date)
);
CREATE INDEX IF NOT EXISTS wc_price_daily_date_idx  ON public.wc_price_daily (snapshot_date);
CREATE INDEX IF NOT EXISTS wc_price_daily_match_idx ON public.wc_price_daily (match_date);

-- ============================================================================
-- 2. Refresh — roll SeatGeek listings into the daily series for a date range
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refresh_wc_price_daily(
  p_from date DEFAULT current_date,
  p_to   date DEFAULT current_date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_rows integer := 0;
BEGIN
  DELETE FROM public.wc_price_daily WHERE snapshot_date BETWEEN p_from AND p_to;

  WITH wc AS (
    SELECT sg_event_id, sg_event_name, sg_venue_name, sg_event_date
    FROM public.sg_events_canonical
    WHERE sg_event_name ILIKE '%world cup - match%'
  ),
  day_latest AS (
    SELECT s.sg_event_id, s.captured_at::date AS dd, max(s.captured_at) AS max_cap
    FROM public.seatgeek_listings_snapshots s
    WHERE s.sg_event_id IN (SELECT sg_event_id FROM wc)
      AND s.captured_at::date BETWEEN p_from AND p_to
    GROUP BY s.sg_event_id, s.captured_at::date
  ),
  book AS (
    SELECT dl.sg_event_id, dl.dd, dl.max_cap,
           s.retail_price_all_in, s.broadcast_price, s.quantity, s.is_broker_owned
    FROM day_latest dl
    JOIN public.seatgeek_listings_snapshots s
      ON s.sg_event_id = dl.sg_event_id AND s.captured_at = dl.max_cap
    WHERE s.retail_price_all_in > 0
  ),
  rolled AS (
    SELECT b.sg_event_id, b.dd AS snapshot_date, max(b.max_cap) AS captured_at,
           count(*)::int                                              AS listings_count,
           sum(b.quantity)::int                                       AS tickets_count,
           count(*) FILTER (WHERE b.is_broker_owned)::int             AS owned_listings,
           sum(b.quantity) FILTER (WHERE b.is_broker_owned)::int      AS owned_tickets,
           min(b.retail_price_all_in)                                 AS allin_min,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY b.retail_price_all_in) AS allin_median,
           percentile_cont(0.9) WITHIN GROUP (ORDER BY b.retail_price_all_in) AS allin_p90,
           min(b.broadcast_price)                                     AS broadcast_min,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY b.broadcast_price)     AS broadcast_median
    FROM book b
    GROUP BY b.sg_event_id, b.dd
  )
  INSERT INTO public.wc_price_daily
    (sg_event_id, snapshot_date, sg_event_name, venue_name, match_date, captured_at,
     listings_count, tickets_count, owned_listings, owned_tickets,
     allin_min, allin_median, allin_p90, broadcast_min, broadcast_median)
  SELECT r.sg_event_id, r.snapshot_date, wc.sg_event_name, wc.sg_venue_name, wc.sg_event_date,
         r.captured_at, r.listings_count, r.tickets_count, r.owned_listings, r.owned_tickets,
         r.allin_min, r.allin_median, r.allin_p90, r.broadcast_min, r.broadcast_median
  FROM rolled r JOIN wc ON wc.sg_event_id = r.sg_event_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$func$;

-- ============================================================================
-- 3. Live board view (latest snapshot per match) + read RPCs (email-gated)
-- ============================================================================
CREATE OR REPLACE VIEW public.v_wc_price_latest AS
SELECT DISTINCT ON (sg_event_id) *
FROM public.wc_price_daily
ORDER BY sg_event_id, snapshot_date DESC;

CREATE OR REPLACE FUNCTION public.get_wc_price_daily(
  p_sg_event_id bigint,
  p_days        integer DEFAULT 120)
RETURNS SETOF public.wc_price_daily
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    SELECT * FROM public.wc_price_daily
    WHERE sg_event_id = p_sg_event_id
      AND snapshot_date >= current_date - make_interval(days => p_days)
    ORDER BY snapshot_date;
END;
$func$;

-- Cheapest-first board across the whole tournament (latest price per match).
CREATE OR REPLACE FUNCTION public.get_wc_price_board()
RETURNS SETOF public.wc_price_daily
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    SELECT * FROM public.v_wc_price_latest ORDER BY allin_min NULLS LAST;
END;
$func$;

GRANT EXECUTE ON FUNCTION public.get_wc_price_daily(bigint, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_wc_price_board()                TO authenticated;

-- ============================================================================
-- 4. Cron — re-roll a trailing 4-day window daily (idempotent; catches the
--    sparse, late-arriving SG pulls without missing a poll)
-- ============================================================================
DO $$ BEGIN
  PERFORM cron.unschedule('wc-price-daily-refresh');
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT cron.schedule('wc-price-daily-refresh', '40 7 * * *', $cron$
  SELECT public.refresh_wc_price_daily(current_date - 3, current_date);
$cron$);

-- ============================================================================
-- 5. Backfill all existing SeatGeek WC history
-- ============================================================================
SELECT public.refresh_wc_price_daily(DATE '2026-05-01', current_date);

-- ============================================================================
-- 6. Watchlist seed — host venues that resolve to a canonical venue id
--    (kind='venue'; label 'World Cup 2026'). Venues that don't resolve
--    (BC Place, Estadio Azteca/BBVA/Akron, Arrowhead's "GEHA Field at ..."
--    alias) are skipped — they have no canonical id to key on. NOTE: WC events
--    are SeatGeek-native (not TEvo-linked), so these venue bookmarks are a
--    portfolio marker; the live tracking is wc_price_daily above. Idempotent —
--    as of authoring, all 11 resolvable host venues are ALREADY watched, so this
--    inserts 0 today; it's kept so any not-yet-watched host venue is picked up.
-- ============================================================================
INSERT INTO public.watchlist (kind, ext_id, label)
SELECT 'venue', r.tevo_venue_id, 'World Cup 2026'
FROM (
  SELECT DISTINCT public.cross_source_venue_resolve(v.sg_venue_name, v.sg_venue_city, v.sg_venue_state) AS tevo_venue_id
  FROM (
    SELECT DISTINCT sg_venue_name, sg_venue_city, sg_venue_state
    FROM public.sg_events_canonical
    WHERE sg_event_name ILIKE '%world cup - match%'
  ) v
) r
WHERE r.tevo_venue_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.watchlist w
    WHERE w.kind = 'venue' AND w.ext_id = r.tevo_venue_id
  );
