-- ============================================================================
-- Migration 20260910200000 — authoritative SeatGeek order facts for N2S
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_sg_order (CREATE TABLE), n2s_sg_pending (CREATE TABLE),
--           n2s_sg_queue(), n2s_sg_drain(), n2s_pull_all_sources() (calls them)
-- Pre-reqs: 20260910190000
--
-- ⚠ READ-ONLY UPSTREAM. GET https://sellerdirect-api.seatgeek.com/order only.
-- No order is created, held, priced or mutated. RULE 2 holds; no *_client.py
-- is touched and no guard is weakened.
--
-- Operator direction 2026-09-10: use the Seller Direct /order endpoint for
-- SeatGeek.
--
-- ── WHY: SEATGEEK IS THE ONLY SOURCE WITH BROKEN ORDER ECONOMICS ──────────
-- Measured across the open book: every marketplace reports a sold price on
-- every open obligation EXCEPT SeatGeek, where 3 of 4 carry price_per_ticket
-- NULL. The N2S feed is parsed from Automatiq/SeatGeek email alerts, and those
-- alerts do not always carry a per-ticket figure. cover_cost is
-- (cover - what we sold for), so a NULL sale price makes the panel's entire
-- question — "what is the least this can be settled for" — unanswerable for
-- those rows.
--
-- ⚠ DO NOT DERIVE THE PRICE AS grand_total / qty. It is wrong, and wrong in
-- the flattering direction. Measured on order 0yoyfn6p6ow: CRM grand_total
-- 1250.20 over qty 2 gives 625.10, while SeatGeek reports the actual per-ticket
-- price as 658.00. The 1250.20 is the NET after 65.80 of fees, so dividing it
-- understates the sale by ~5% and makes every cover look better than it is.
--
-- ⚠ AND grand_total IS NOT CONSISTENTLY GROSS OR NET. Two orders, same
-- marketplace, same feed:
--     dwkwc6vnqxr  CRM 816.00  = SG SUBTOTAL (gross; SG total was 775.20)
--     0yoyfn6p6ow  CRM 1250.20 = SG TOTAL   (net;   SG subtotal was 1316.00)
-- So no single interpretation of the CRM figure is safe. That is the whole
-- argument for holding SeatGeek's own numbers separately rather than trying to
-- reinterpret the feed's. subtotal, fees AND total are all stored, so choosing
-- which one drives economics later is a one-line change and not another
-- round-trip to the vendor.
--
-- ⚠ THE TOKEN GOES IN THE QUERY STRING BECAUSE THE HEADER FORM DOES NOT WORK.
-- The vendor's own curl snippet shows `--header 'token: ...'`. Measured against
-- the live endpoint, that returns 400 {"code":400113,"message":"Token is
-- required"} on both `token` and `Token`, while `?token=` returns 200. This is
-- not pg_net dropping headers — the CRM poll in 20260910030000 sends X-API-Key
-- as a header and works. It is this endpoint requiring the query parameter.
-- CONSEQUENCE: the token lands in net.http_request_queue.url in plaintext,
-- the same exposure already noted for the SG listings feed. Treat the SeatGeek
-- token as exposed; it wants rotating and it cannot be fixed from our side.
--
-- ⚠ FILL-ONLY, NEVER OVERWRITE. The backfill sets n2s_items.price_per_ticket
-- only where it IS NULL. SeatGeek's figure is authoritative, but silently
-- rewriting a value the CRM already stated would make the two books disagree
-- with no record of it. Discrepancies stay visible in n2s_sg_order instead.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.n2s_sg_order (
  order_number   text PRIMARY KEY,
  sg_event_id    bigint,
  sg_listing_id  text,
  price_ea       numeric,   -- listing.price — per-ticket, GROSS
  quantity       integer,
  subtotal       numeric,   -- gross
  fees           numeric,
  total          numeric,   -- net of fees; what SeatGeek actually pays out
  sg_status      text,      -- e.g. 'denied'
  section        text,
  sg_row         text,
  event_name     text,
  event_date     date,
  event_time     text,
  venue          text,
  delivery       text,
  stock_type     text,
  http_status    integer,
  fetched_at     timestamptz NOT NULL DEFAULT now(),
  raw            jsonb
);

COMMENT ON TABLE public.n2s_sg_order IS
  'SeatGeek Seller Direct /order facts for N2S obligations — the authoritative '
  'economics, because the CRM feed reports price_per_ticket NULL on most SG '
  'orders and its grand_total is gross on some orders and net on others. '
  'subtotal/fees/total are all kept so the gross-vs-net choice stays reversible. '
  'Populated by n2s_sg_queue()/n2s_sg_drain(). See migration 20260910200000.';

-- request_id -> order, mirroring n2s_items_pending. pg_net is async and can lag
-- 1-3 minutes, so the fetch and the parse are separate passes.
CREATE TABLE IF NOT EXISTS public.n2s_sg_pending (
  request_id    bigint PRIMARY KEY,
  order_number  text NOT NULL,
  fired_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  http_status   integer,
  error_msg     text
);
CREATE INDEX IF NOT EXISTS n2s_sg_pending_open_idx
  ON public.n2s_sg_pending (fired_at) WHERE resolved_at IS NULL;

ALTER TABLE public.n2s_sg_order   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n2s_sg_pending ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_sg_order, public.n2s_sg_pending FROM PUBLIC, anon;
GRANT SELECT ON public.n2s_sg_order TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- n2s_sg_queue — fire one GET per open SeatGeek obligation we have not yet
-- resolved. Bounded by p_max; re-fetches nothing already fetched successfully.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.n2s_sg_queue(p_max integer DEFAULT 10)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp','net'
AS $function$
DECLARE
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_n integer := 0;
  r RECORD;
  v_req bigint;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN
    RAISE WARNING 'n2s_sg_queue: no SEATGEEK_API_TOKEN; nothing queued';
    RETURN 0;
  END IF;

  FOR r IN
    SELECT n.order_number
      FROM public.n2s_items n
     WHERE n.s4k_source = 'SeatGeek'
       AND NOT n.is_terminal
       AND n.event_dt::date >= current_date
       AND n.order_number IS NOT NULL
       -- ⚠ URL-SAFE ONLY. Order numbers are parsed out of vendor EMAILS, so
       -- they are untrusted text. The token has to ride in the query string
       -- (the header form is refused), which means an order number containing
       -- '&' or '?' would splice extra parameters into our own request. There
       -- is no urlencode() in this database, so rather than hand-roll one the
       -- rule is: anything not [A-Za-z0-9._~-] is skipped and left visible as
       -- un-enriched. All 14 SeatGeek orders on the book today pass. NEVER
       -- relax this to interpolate an arbitrary string into the URL.
       AND n.order_number ~ '^[A-Za-z0-9._~-]{1,64}$'
       -- not already resolved, and not already in flight
       AND NOT EXISTS (SELECT 1 FROM public.n2s_sg_order o
                        WHERE o.order_number = n.order_number AND o.http_status = 200)
       AND NOT EXISTS (SELECT 1 FROM public.n2s_sg_pending p
                        WHERE p.order_number = n.order_number
                          AND p.resolved_at IS NULL
                          AND p.fired_at > now() - interval '10 minutes')
     ORDER BY n.alert_at DESC NULLS LAST
     LIMIT GREATEST(p_max, 0)
  LOOP
    -- Token in the query string: the header form is refused by this endpoint
    -- (see the header note above). Nothing here mutates anything at SeatGeek.
    SELECT net.http_get(
      url := 'https://sellerdirect-api.seatgeek.com/order?order_id='
             || r.order_number || '&token=' || v_token,
      timeout_milliseconds := 15000) INTO v_req;
    INSERT INTO public.n2s_sg_pending (request_id, order_number)
    VALUES (v_req, r.order_number)
    ON CONFLICT (request_id) DO NOTHING;
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END $function$;

-- ---------------------------------------------------------------------------
-- n2s_sg_drain — parse whatever has landed, store it, fill the missing price.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.n2s_sg_drain()
RETURNS TABLE(resolved integer, stored integer, prices_filled integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp','net'
AS $function$
DECLARE
  v_res integer := 0; v_store integer := 0; v_fill integer := 0;
  r RECORD; j jsonb;
BEGIN
  FOR r IN
    SELECT p.request_id, p.order_number, x.status_code, x.content
      FROM public.n2s_sg_pending p
      -- Scoped by request_id: an unscoped join against net._http_response is
      -- large enough to time out (learned the hard way, mig 20260910080000).
      JOIN net._http_response x ON x.id = p.request_id
     WHERE p.resolved_at IS NULL
     LIMIT 200
  LOOP
    v_res := v_res + 1;
    BEGIN
      j := CASE WHEN r.status_code = 200 THEN r.content::jsonb ELSE NULL END;
    EXCEPTION WHEN others THEN j := NULL;
    END;

    IF j IS NOT NULL THEN
      INSERT INTO public.n2s_sg_order (
        order_number, sg_event_id, sg_listing_id, price_ea, quantity,
        subtotal, fees, total, sg_status, section, sg_row,
        event_name, event_date, event_time, venue, delivery, stock_type,
        http_status, fetched_at, raw)
      VALUES (
        r.order_number,
        NULLIF(j #>> '{event,seatgeek_event_id}', '')::bigint,
        NULLIF(j #>> '{listing,id}', ''),
        NULLIF(j #>> '{listing,price}', '')::numeric,
        NULLIF(j #>> '{listing,quantity}', '')::integer,
        NULLIF(j ->> 'subtotal', '')::numeric,
        NULLIF(j ->> 'fees', '')::numeric,
        NULLIF(j ->> 'total', '')::numeric,
        j ->> 'status',
        j #>> '{listing,section}',
        j #>> '{listing,row}',
        j #>> '{event,name}',
        NULLIF(j #>> '{event,date}', '')::date,
        j #>> '{event,time}',
        j #>> '{event,venue}',
        j ->> 'delivery',
        j ->> 'stock_type',
        r.status_code, now(), j)
      ON CONFLICT (order_number) DO UPDATE SET
        sg_event_id = EXCLUDED.sg_event_id, sg_listing_id = EXCLUDED.sg_listing_id,
        price_ea = EXCLUDED.price_ea, quantity = EXCLUDED.quantity,
        subtotal = EXCLUDED.subtotal, fees = EXCLUDED.fees, total = EXCLUDED.total,
        sg_status = EXCLUDED.sg_status, section = EXCLUDED.section,
        sg_row = EXCLUDED.sg_row, event_name = EXCLUDED.event_name,
        event_date = EXCLUDED.event_date, event_time = EXCLUDED.event_time,
        venue = EXCLUDED.venue, delivery = EXCLUDED.delivery,
        stock_type = EXCLUDED.stock_type, http_status = EXCLUDED.http_status,
        fetched_at = now(), raw = EXCLUDED.raw;
      v_store := v_store + 1;
    END IF;

    UPDATE public.n2s_sg_pending
       SET resolved_at = now(), http_status = r.status_code,
           error_msg = CASE WHEN r.status_code = 200 THEN NULL
                            ELSE left(COALESCE(r.content, ''), 200) END
     WHERE request_id = r.request_id;
  END LOOP;

  -- Fill-only. SeatGeek's listing.price is the per-ticket GROSS, which is what
  -- price_per_ticket means everywhere else in this table.
  UPDATE public.n2s_items n
     SET price_per_ticket = o.price_ea
    FROM public.n2s_sg_order o
   WHERE o.order_number = n.order_number
     AND n.s4k_source = 'SeatGeek'
     AND n.price_per_ticket IS NULL
     AND o.price_ea IS NOT NULL;
  GET DIAGNOSTICS v_fill = ROW_COUNT;

  RETURN QUERY SELECT v_res, v_store, v_fill;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_sg_queue(integer)  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.n2s_sg_drain()         FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_sg_queue(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.n2s_sg_drain()        TO service_role;
