-- Migration 20260615130000 · lane:D0 (author) → A1 (apply) · writes:get_wc_sg_listings, get_wc_sg_sales · reads:seatgeek_listings_snapshots, seatgeek_sales_snapshots · pre:20260615120000_event_watchlist_sg_secondary · auth:operator-requested 2026-06-15 ("fix the rest of the page" for SeatGeek-native World Cup events)
--
-- D0 — sg_event_id-keyed read RPCs so the terminal event page's "SG mode" (the
-- World Cup / SeatGeek-native view, event.html?sg=<id>) can show the SeatGeek
-- data that DOES exist for these events: the current listing book + recent
-- sales. The existing event-page SG RPCs (get_event_sg_listings_full /
-- get_event_sg_sales) are TEvo-event-keyed (p_event_id) and so return nothing
-- for SG-native events, which have no tevo_event_id. These mirror them but key
-- on sg_event_id. Email-gated @s4kent.com, anon revoked — same posture as the
-- other event-page read RPCs.
--
-- Column landmines honored (PROJECT_BIBLE §3):
--   listings: price = retail_price_all_in (all-in) + broadcast_price (list);
--             "current book" = DISTINCT ON (sglid) latest, last 7d (matches the
--             existing SG Listings tab semantics).
--   sales:    sale time = sale_at_utc; pull stamp = pulled_at; UNIQUE
--             (sg_event_id, sg_sale_id, pulled_at) overcounts 11–23× → MANDATORY
--             DISTINCT ON (sg_sale_id) ORDER BY sg_sale_id, pulled_at DESC.
-- Casts are explicit so the RETURNS TABLE types can't drift from the columns.

-- ── Current SeatGeek listing book (cheapest all-in first) ───────────────────
CREATE OR REPLACE FUNCTION public.get_wc_sg_listings(p_sg_event_id bigint, p_limit integer DEFAULT 500)
RETURNS TABLE(
  section              text,
  "row"                text,
  quantity             integer,
  splits               text,
  retail_price_all_in  numeric,
  broadcast_price      numeric,
  is_broker_owned      boolean,
  captured_at          timestamptz
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
#variable_conflict use_column
DECLARE v_email text := coalesce(auth.jwt()->>'email', '');
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;
  -- WC matches are far-future and polled sparsely, so a fixed "last 7d" window
  -- can miss the whole book. Anchor to the event's most recent pull instead.
  RETURN QUERY
  WITH mx AS (
    SELECT max(s.captured_at) AS mc
    FROM public.seatgeek_listings_snapshots s
    WHERE s.sg_event_id = p_sg_event_id
  )
  SELECT l.section::text, l.row::text, l.quantity::integer, l.splits::text,
         l.retail_price_all_in::numeric, l.broadcast_price::numeric,
         l.is_broker_owned::boolean, l.captured_at::timestamptz
  FROM (
    SELECT DISTINCT ON (s.sglid) s.*
    FROM public.seatgeek_listings_snapshots s, mx
    WHERE s.sg_event_id = p_sg_event_id
      AND mx.mc IS NOT NULL
      AND s.captured_at >= mx.mc - interval '6 hours'
    ORDER BY s.sglid, s.captured_at DESC
  ) l
  ORDER BY l.retail_price_all_in NULLS LAST
  LIMIT p_limit;
END;
$func$;

-- ── Recent SeatGeek sales (deduped on sg_sale_id; newest first) ─────────────
CREATE OR REPLACE FUNCTION public.get_wc_sg_sales(p_sg_event_id bigint, p_days integer DEFAULT 90, p_limit integer DEFAULT 200)
RETURNS TABLE(
  sale_at_utc      timestamptz,
  section          text,
  "row"            text,
  quantity         integer,
  broadcast_price  numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
#variable_conflict use_column
DECLARE v_email text := coalesce(auth.jwt()->>'email', '');
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;
  RETURN QUERY
  SELECT s.sale_at_utc::timestamptz, s.section::text, s.row::text,
         s.quantity::integer, s.broadcast_price::numeric
  FROM (
    SELECT DISTINCT ON (sg_sale_id) *
    FROM public.seatgeek_sales_snapshots
    WHERE sg_event_id = p_sg_event_id
      AND sale_at_utc > now() - make_interval(days => p_days)
    ORDER BY sg_sale_id, pulled_at DESC
  ) s
  ORDER BY s.sale_at_utc DESC
  LIMIT p_limit;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_wc_sg_listings(bigint, integer)         FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_wc_sg_sales(bigint, integer, integer)   FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_wc_sg_listings(bigint, integer)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_wc_sg_sales(bigint, integer, integer) TO authenticated;
