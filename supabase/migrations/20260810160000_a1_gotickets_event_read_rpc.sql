-- ============================================================================
-- Migration 20260810160000 — GoTickets Pro-API event read RPC (terminal chart feed)
--
-- Lane:     A1 (data plane — read RPC over the GoTickets firehose) → D0 consumer
-- Touches:  W (NEW fn): get_gotickets_event_series(bigint, int) — SECURITY DEFINER,
--              read-only aggregate over gotickets_listings_snapshots.
--           R: public.gotickets_listings_snapshots (keyed on tevo_event_id).
-- Pre-reqs: 20260804230000 (gotickets_listings_snapshots + idx_gt_ls_event_time).
--
-- WHY: the GoTickets listings firehose (mig 20260804230000) lands in
--   gotickets_listings_snapshots, which is REVOKEd from anon and carries no
--   authenticated grant — so the D0 terminal event page has no way to read it.
--   This adds the single read path the frontend needs: a per-event price/count
--   time series (listing count + min + median display price, grouped per capture)
--   that event.js plots as the "GoTickets" chart series and uses to drive the
--   GOT coverage light + freshness chip.
--
--   GoTickets is platform code **GOT** — deliberately NOT "GT", which is
--   GameTime in the TicketsData feed (event_listing_snapshot_daily.td_gt_*).
--   See gotickets_client.PLATFORM_CODE. Keeping GOT distinct is what stops the
--   two sources colliding on the terminal.
--
-- READ-ONLY (RULE 2 posture): SELECT-only. SECURITY DEFINER so it can read past
--   the table's anon REVOKE; EXECUTE granted to authenticated ONLY (the terminal
--   calls it with the signed-in user's JWT via rpcOrNull — no anon exposure of
--   the raw firehose). No write path exists.
--
-- Idempotent: CREATE OR REPLACE. Re-apply is a no-op. Authored, applied per the
--   Applier protocol (CLAUDE.md Rule 1) once reviewed + CI-green.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_gotickets_event_series(
  p_tevo_event_id bigint,
  p_hours         int DEFAULT 720)
RETURNS TABLE (
  captured_at   timestamptz,
  listing_count integer,
  min_price     numeric,
  median_price  numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  -- One point per capture batch (poll fires share a single captured_at). Uses
  -- idx_gt_ls_event_time (tevo_event_id, captured_at DESC). display_price is the
  -- list price (pre-fee), comparable to the other sources' median list lines;
  -- all_in_price/service_fee remain available for future all-in views.
  SELECT s.captured_at,
         count(*)::int                                                           AS listing_count,
         min(s.display_price)                                                    AS min_price,
         (percentile_cont(0.5) WITHIN GROUP (ORDER BY s.display_price))::numeric AS median_price
  FROM public.gotickets_listings_snapshots s
  WHERE s.tevo_event_id = p_tevo_event_id
    AND s.display_price IS NOT NULL
    AND s.captured_at >= now() - make_interval(hours => greatest(p_hours, 1))
  GROUP BY s.captured_at
  ORDER BY s.captured_at;
$function$;

REVOKE ALL ON FUNCTION public.get_gotickets_event_series(bigint, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_gotickets_event_series(bigint, int) TO authenticated;

COMMENT ON FUNCTION public.get_gotickets_event_series(bigint, int) IS
  'GoTickets (GOT) per-event listings time series for the D0 terminal chart + coverage light: listing_count, min_price, median_price (display/list price) per capture, keyed on tevo_event_id over gotickets_listings_snapshots. SECURITY DEFINER (reads past the table anon REVOKE); EXECUTE = authenticated only. GOT ≠ GameTime/GT. Mig 20260810160000.';

-- ── 2. Per-event LATEST-batch listings — feeds the D0 "GoTickets Listings" tab.
--   Mirrors get_event_td_listings: returns each individual listing from the most
--   recent capture batch (max captured_at within p_hours), price-sorted. Same
--   security posture (SECURITY DEFINER, authenticated-only) as the series RPC.
CREATE OR REPLACE FUNCTION public.get_gotickets_event_listings(
  p_tevo_event_id bigint,
  p_hours         int DEFAULT 26)
RETURNS TABLE (
  captured_at       timestamptz,
  section           text,
  "row"             text,
  quantity          integer,
  display_price     numeric,
  all_in_price      numeric,
  service_fee       numeric,
  face_value        numeric,
  stock_type        text,
  general_admission boolean,
  notes             text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH latest AS (
    SELECT max(s.captured_at) AS mx
    FROM public.gotickets_listings_snapshots s
    WHERE s.tevo_event_id = p_tevo_event_id
      AND s.captured_at >= now() - make_interval(hours => greatest(p_hours, 1))
  )
  SELECT s.captured_at, s.section, s."row", s.quantity,
         s.display_price, s.all_in_price, s.service_fee,
         s.face_value, s.stock_type, s.general_admission, s.notes
  FROM public.gotickets_listings_snapshots s, latest
  WHERE s.tevo_event_id = p_tevo_event_id
    AND latest.mx IS NOT NULL
    AND s.captured_at = latest.mx
  ORDER BY s.display_price NULLS LAST, s.section, s."row";
$function$;

REVOKE ALL ON FUNCTION public.get_gotickets_event_listings(bigint, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_gotickets_event_listings(bigint, int) TO authenticated;

COMMENT ON FUNCTION public.get_gotickets_event_listings(bigint, int) IS
  'GoTickets (GOT) latest-capture individual listings for the D0 GoTickets Listings tab: one row per listing in the most recent capture batch (max captured_at within p_hours), price-sorted, keyed on tevo_event_id. SECURITY DEFINER; EXECUTE = authenticated only. GOT ≠ GameTime/GT. Mig 20260810160000.';
