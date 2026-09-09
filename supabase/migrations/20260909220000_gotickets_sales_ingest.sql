-- ============================================================================
-- Migration 20260909220000 — GoTickets SALES ingest: our own GoTickets order
--                            book, closing the last price-less feed
--
-- Lane:     A1 (data plane — a new upstream book) serving D0's orders surface
-- Touches:  gotickets_sales (CREATE TABLE), gt_sales_sync_state (CREATE TABLE),
--           gt_sales_sync() / gt_sales_drain() (CREATE FUNCTION),
--           v_s4kcs_orders (CREATE OR REPLACE VIEW — adds the GT price repair)
-- Pre-reqs: 20260901180000 (s4kcs_orders), the vault GOTICKETS_* secrets
--
-- READ-ONLY UPSTREAM (RULE 2): one call, `GET /rest/sales`, on the already
-- allowlisted sc.gotickets.com broker host. Nothing is pushed to GoTickets.
--
-- WHY. The CRM ships GoTickets orders with price `0.00` on every row — not
-- NULL, so the COALESCE that repairs Vivid in `v_s4kcs_orders` cannot catch it,
-- and RESOURCES_BIBLE §1 recorded it as unfixable: "we have no GoTickets order
-- book to substitute". We do now. Operator direction 2026-09-09: "for GoTickets
-- and Vivid use our order system instead, we should have an API."
--
-- ⚠ THE CLIENT DOCSTRING WAS WRONG. `gotickets_client.py` states "There is no
-- list endpoint in the surfaced API" and exposes only `GET /rest/sales/:id`.
-- `GET /rest/sales` returns 200 with the full recent book. Corrected in this
-- PR. `/rest/sales/delta` does NOT exist (400: it parses "delta" as the id).
--
-- ── Paging: `limit` works, `offset` does NOT ────────────────────────────────
-- Measured live: `?limit=5` returns 5, `?limit=5000` returns 5000 (back to
-- 2026-08-21), but `?offset=`, `?page=`/`?size=` and `?updateTimeFrom=` are all
-- IGNORED — each returns the same newest-first page starting at the same id.
-- So there is no cursor: the only lever is a bigger limit, and the feed is a
-- newest-first window, not a queryable history. Sync therefore pulls a window
-- and UPSERTS by sale id; it can never backfill an order older than the window,
-- which is why `v_s4kcs_orders` must degrade to NULL rather than to 0.
--
-- ── The join key, and how it looked wrong ───────────────────────────────────
-- `s4kcs_orders.s4k_order_id` IS the GoTickets sale `id`: 1,762 of the 1,823
-- CRM GoTickets orders inside the feed window match on it.
-- ⚠ A first check of this appeared to show ZERO overlap on every candidate id
-- (`id`, `orderItemId`, `externalTicketId`, `listingId`). That was a sampling
-- error, not a schema fact: an UNORDERED `LIMIT 2000` over the CRM rows drew
-- almost entirely from old orders whose ids predate the feed's window. When
-- comparing two windows, constrain BOTH to the overlap before concluding the
-- keys differ.
--
-- ── Prices are unambiguous here, unlike the CRM ─────────────────────────────
-- Each sale carries BOTH `unitCost` (per ticket) and `totalPayout` (order
-- total), and they agree: `round(unitCost*quantity,2) = totalPayout` held for
-- 1000 of 1000 sampled. So this feed needs no per-source unit rule (§3) — it
-- states both bases. `originalSection` also ships the bare section ("135")
-- beside the zoned label ("Infield Box 135"), so GoTickets orders need no
-- section normalisation guesswork at all.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.gotickets_sales (
  gt_sale_id        bigint      PRIMARY KEY,          -- == s4kcs_orders.s4k_order_id
  gt_order_item_id  bigint,
  gt_listing_id     bigint,
  external_ticket_id text,
  gt_event_id       bigint,
  event_name        text,
  event_time_local  timestamp,                        -- local wall clock, as sent
  venue_id          bigint,
  venue_name        text,
  venue_city        text,
  venue_state       text,
  section           text,                             -- zoned label, e.g. "Infield Box 135"
  original_section  text,                             -- GT's own bare section, e.g. "135"
  row               text,
  low_seat          text,
  high_seat         text,
  quantity          integer,
  unit_cost         numeric,                          -- PER TICKET
  total_payout      numeric,                          -- ORDER TOTAL
  seller_status     text,
  delivery_method   text,
  stock_type        text,
  in_hand_date      date,
  fulfilled         boolean,
  create_time       timestamp,
  raw               jsonb,
  pulled_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.gotickets_sales IS
  'Our GoTickets sell-side order book (GET /rest/sales). The CRM ships these '
  'orders with price 0.00, so this is the substitute v_s4kcs_orders reads — the '
  'GoTickets analogue of vivid_orders. Carries BOTH unit_cost (per ticket) and '
  'total_payout (order total), which agree, so no per-source unit rule applies. '
  'gt_sale_id IS s4kcs_orders.s4k_order_id for GoTickets rows.';

CREATE INDEX IF NOT EXISTS idx_gt_sales_event   ON public.gotickets_sales (gt_event_id);
CREATE INDEX IF NOT EXISTS idx_gt_sales_created ON public.gotickets_sales (create_time DESC);

ALTER TABLE public.gotickets_sales ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.gotickets_sales FROM PUBLIC, anon;
GRANT SELECT ON public.gotickets_sales TO authenticated, service_role;

CREATE TABLE IF NOT EXISTS public.gt_sales_sync_state (
  request_id   bigint PRIMARY KEY,
  fired_at     timestamptz NOT NULL DEFAULT now(),
  req_limit    integer,
  sales_upserted integer,
  drained_at   timestamptz
);
REVOKE ALL ON public.gt_sales_sync_state FROM PUBLIC, anon;

-- ── Fire ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.gt_sales_sync(p_limit integer DEFAULT 5000)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_req bigint;
BEGIN
  SELECT net.http_get(
    url := 'https://sc.gotickets.com/rest/sales?limit=' || greatest(p_limit, 1)::text,
    headers := jsonb_build_object(
      'X-Api-Access-Id',     trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='GOTICKETS_ACCESS_ID')),
      'X-Api-Access-Secret', trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name='GOTICKETS_API_SECRET')),
      'Accept','application/json'),
    timeout_milliseconds := 120000
  ) INTO v_req;
  INSERT INTO public.gt_sales_sync_state(request_id, req_limit) VALUES (v_req, p_limit);
  RETURN v_req;
END $function$;

COMMENT ON FUNCTION public.gt_sales_sync(integer) IS
  'Queue a GET /rest/sales?limit=N pull. The endpoint honours `limit` but NOT '
  '`offset`/`page`/`updateTimeFrom` — it is a newest-first window with no '
  'cursor, so a bigger limit is the only lever and old orders fall out of reach.';

-- ── Drain ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.gt_sales_drain()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE r RECORD; v_n int := 0; v_batch int;
BEGIN
  SET LOCAL statement_timeout = '180s';
  FOR r IN
    SELECT s.request_id, resp.status_code, resp.content
      FROM public.gt_sales_sync_state s
      JOIN net._http_response resp ON resp.id = s.request_id
     WHERE s.drained_at IS NULL
     ORDER BY s.fired_at
  LOOP
    v_batch := 0;
    IF r.status_code = 200 AND r.content IS NOT NULL AND left(r.content, 1) = '[' THEN
      WITH src AS (SELECT e FROM jsonb_array_elements(r.content::jsonb) AS e),
      up AS (
        INSERT INTO public.gotickets_sales AS g (
          gt_sale_id, gt_order_item_id, gt_listing_id, external_ticket_id,
          gt_event_id, event_name, event_time_local, venue_id, venue_name,
          venue_city, venue_state, section, original_section, "row", low_seat,
          high_seat, quantity, unit_cost, total_payout, seller_status,
          delivery_method, stock_type, in_hand_date, fulfilled, create_time,
          raw, pulled_at)
        SELECT (e->>'id')::bigint,
               NULLIF(e->>'orderItemId','')::bigint,
               NULLIF(e->>'listingId','')::bigint,
               NULLIF(e->>'externalTicketId',''),
               NULLIF(e->'event'->>'id','')::bigint,
               e->'event'->>'name',
               NULLIF(e->'event'->>'eventTimeLocal','')::timestamp,
               NULLIF(e->'event'->>'venueId','')::bigint,
               e->'event'->>'venueName', e->'event'->>'venueCity',
               e->'event'->>'venueState',
               e->>'section', NULLIF(e->>'originalSection',''), e->>'row',
               NULLIF(e->>'lowSeat',''), NULLIF(e->>'highSeat',''),
               NULLIF(e->>'quantity','')::int,
               NULLIF(e->>'unitCost','')::numeric,
               NULLIF(e->>'totalPayout','')::numeric,
               e->>'sellerStatus', e->>'deliveryMethod', e->>'stockType',
               NULLIF(e->>'inHandDate','')::date,
               NULLIF(e->>'fulfilled','')::boolean,
               NULLIF(e->>'createTime','')::timestamp,
               e, now()
          FROM src
         WHERE (e->>'id') IS NOT NULL
        ON CONFLICT (gt_sale_id) DO UPDATE SET
          seller_status = EXCLUDED.seller_status,
          fulfilled     = EXCLUDED.fulfilled,
          unit_cost     = EXCLUDED.unit_cost,
          total_payout  = EXCLUDED.total_payout,
          quantity      = EXCLUDED.quantity,
          in_hand_date  = EXCLUDED.in_hand_date,
          raw           = EXCLUDED.raw,
          pulled_at     = now()
        RETURNING 1)
      SELECT count(*) INTO v_batch FROM up;
    END IF;
    UPDATE public.gt_sales_sync_state
       SET drained_at = now(), sales_upserted = v_batch
     WHERE request_id = r.request_id;
    v_n := v_n + v_batch;
  END LOOP;
  RETURN v_n;
END $function$;

COMMENT ON FUNCTION public.gt_sales_drain() IS
  'Parse queued GET /rest/sales responses into gotickets_sales. Upsert by sale '
  'id: the feed is a newest-first window, so re-pulls overlap heavily and only '
  'the mutable fields (status, fulfilment, price, quantity) are refreshed.';

REVOKE ALL ON FUNCTION public.gt_sales_sync(integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gt_sales_drain() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gt_sales_sync(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.gt_sales_drain() TO service_role;

-- ── v_s4kcs_orders: repair GoTickets, and end the unit guessing ─────────────
-- ⚠ GoTickets needs NULLIF(price, 0), NOT COALESCE. Its CRM rows carry 0.00,
-- not NULL, so a COALESCE would keep the zero and silently report every
-- GoTickets order as a free sale. That difference from the Vivid arm is the
-- whole reason this gap survived (RESOURCES_BIBLE §1).
--
-- ⚠⚠ `price` ON THIS VIEW IS A MIXED BASIS — FOUR SOURCES, THREE STORIES, and
-- nothing in the row said which until now. Measured 2026-09-09:
--     StubHub, SeatGeek   (crm)              ORDER TOTAL
--     Gametime, TickPick  (crm)              PER TICKET
--     Vivid Seats         (vivid_orders)     PER TICKET  ← despite the column
--                                              literally being named `total`
--     GoTickets           (gotickets_sales)  ORDER TOTAL (total_payout)
-- The Vivid one is the trap: `vivid_orders.total` is NOT a total. Ratio-tested
-- against live GoTickets all-in market prices over 151 same-event/section
-- pairs — median 0.83 read as per-ticket vs 0.28 read as a total. Selling at
-- 28% of market is not a thing; 0.83 matches every other source we measured.
-- The aggregate shape hides this: avg(total) is FLAT (~$138-211) across
-- quantities 1-6, which looks like neither reading until you price it against
-- the market.
--
-- So this revision ADDS two columns rather than changing `price`:
--   price_per_ticket  — normalised, correct for every source
--   price_basis       — what `price` itself means for that row
-- `price` keeps its existing meaning so current consumers (order-lookup and
-- the subs screen) are untouched; new code should read `price_per_ticket` and
-- never re-derive the rule.
CREATE OR REPLACE VIEW public.v_s4kcs_orders AS
 SELECT s.source,
    s.s4k_order_id,
    s.order_status,
    s.seller_status,
    s.event_name,
    s.event_date,
    s.venue_name,
    s.venue_city,
    s.venue_state,
    s.section,
    s."row",
    s.seats,
    s.quantity,
    COALESCE(NULLIF(s.price, 0), v.total, g.total_payout) AS price,
    s.price AS crm_price,
        CASE
            WHEN NULLIF(s.price, 0) IS NOT NULL THEN 'crm'::text
            WHEN v.total IS NOT NULL THEN 'vivid_orders'::text
            WHEN g.total_payout IS NOT NULL THEN 'gotickets_sales'::text
            ELSE NULL::text
        END AS price_source,
    s.delivery,
    s.inhand_date,
    s.payout_date,
    s.purchase_date,
    s.notes,
    COALESCE(s.tevo_event_id, v.tevo_event_id) AS tevo_event_id,
    COALESCE(s.aq_short_event_id, v.aq_short_event_id) AS aq_short_event_id,
    s.venue_short_id,
    s.performer_short_id,
    s.pulled_at,
    s.last_seen_at,
    s.map_method,
    s.map_confidence,
    s.mapped_at,
    -- ⚠ APPENDED, NOT INSERTED. CREATE OR REPLACE VIEW can only ADD columns at
    -- the END — reordering or inserting one fails with "cannot change name of
    -- view column". These two must stay last, and anything added later must go
    -- after them, or the replace stops being a drop-free upgrade.
    -- what the `price` column above means for THIS row
        CASE
            WHEN NULLIF(s.price, 0) IS NOT NULL
                 AND s.source IN ('StubHub','SeatGeek')   THEN 'order_total'::text
            WHEN NULLIF(s.price, 0) IS NOT NULL           THEN 'per_ticket'::text
            WHEN v.total IS NOT NULL                      THEN 'per_ticket'::text
            WHEN g.total_payout IS NOT NULL               THEN 'order_total'::text
            ELSE NULL::text
        END AS price_basis,
    -- always per ticket, whatever the source did
        CASE
            WHEN NULLIF(s.price, 0) IS NOT NULL AND s.source IN ('StubHub','SeatGeek')
                 THEN round(s.price / NULLIF(s.quantity, 0), 4)
            WHEN NULLIF(s.price, 0) IS NOT NULL           THEN s.price
            WHEN v.total IS NOT NULL                      THEN v.total
            WHEN g.unit_cost IS NOT NULL                  THEN g.unit_cost
            WHEN g.total_payout IS NOT NULL
                 THEN round(g.total_payout / NULLIF(s.quantity, 0), 4)
            ELSE NULL::numeric
        END AS price_per_ticket
   FROM s4kcs_orders s
     LEFT JOIN vivid_orders v
       ON s.source = 'Vivid Seats'::text AND v.vivid_order_id = s.s4k_order_id
     LEFT JOIN gotickets_sales g
       ON s.source = 'GoTickets'::text AND g.gt_sale_id::text = s.s4k_order_id;

COMMENT ON VIEW public.v_s4kcs_orders IS
  'S4K CRM orders with both price-less feeds repaired from our own books: Vivid '
  'from vivid_orders.total (CRM ships NULL) and GoTickets from gotickets_sales '
  '(CRM ships 0.00 — needs NULLIF, not COALESCE). READ price_per_ticket, not '
  'price: `price` is a MIXED basis (StubHub/SeatGeek + GoTickets = order total; '
  'Gametime/TickPick + Vivid = per ticket — and vivid_orders.total is per '
  'ticket despite its name, ratio-tested 0.83 vs 0.28 against live market). '
  'price_basis says which `price` is for a given row.';

-- ── Cron (authored, NOT scheduled here — Rule 1) ────────────────────────────
--   SELECT cron.schedule('gt_sales_sync_15min', '3,18,33,48 * * * *',
--     $$ SELECT public.gt_sales_sync(5000); $$);
--   SELECT cron.schedule('gt_sales_drain_15min', '8,23,38,53 * * * *',
--     $$ SELECT public.gt_sales_drain(); $$);
-- Two jobs 5 minutes apart because pg_net is async — same queue/process shape
-- as the s4kcs ingest and the venue sweep.
