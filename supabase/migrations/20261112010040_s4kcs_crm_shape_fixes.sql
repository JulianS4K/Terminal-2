-- Migration 20261112010040 · level:secondary-sales · lane:A1 (CRM ingest) + D7 (N2B intake) · writes:s4kcs_orders_pending,n2s_items(s4k_source of gmail rows) · reads:s4kcs_orders,v_s4kcs_orders,vivid_orders,gotickets_sales,n2s_items · pre:20261112010000
--
-- S4K CRM (crm.s4kcs.com) feed — four shape gaps found reading what the API actually returns
-- (operator 2026-11-11: "look at its shape", then "fix vivid and anything else").
--
-- 1. VIVID PRICE, in the two readers that skipped the repair.
--    The CRM ships every Vivid Seats order with price = "" (and price/quantity as strings): all
--    2,457 Vivid rows seen in the last two days have s4kcs_orders.price NULL. v_s4kcs_orders
--    already repairs this from our own book (vivid_orders.total, which is PER TICKET — checked
--    on 619 N2S Vivid orders: it equals price_per_ticket on all 619, including 363 with qty > 1;
--    2,409 of the 2,457 CRM Vivid rows match a vivid_orders row by id, quantities agree on all).
--    Two functions read the raw table instead of the view, so they still saw no Vivid price:
--      * crm_order_status_lookup()  — the Apps Script order-status lookup; returned no 'price'.
--      * inbox_n2b_report()         — the N2B inbox report; sold_ea fell through to the email.
--    Both now read v_s4kcs_orders. crm_order_status_lookup also returns price_per_ticket and
--    price_source (additive keys; 'price' keeps its meaning — the order's price as stored, now
--    repaired). Neither function existed in any migration file (applied to prod directly);
--    this file carries their full source from prod, edited, so the repo matches prod again.
--    The raw table stays the CRM's own answer (crm_price in the view) on purpose.
--    New expression index gotickets_sales((gt_sale_id::text)): the view's GoTickets join had none,
--    so each by-id read seq-scanned 21k rows (~30 ms/order) — it must not ride 500-order calls.
--
-- 2. PARTIAL BOOKS ARE RETRIED, once, per failed market.
--    One /marketplace/orders fetch returns every market, and a market that fails its own
--    upstream fetch is listed in 'errors' and contributes no rows while the rest succeed. In
--    the 48 h to 2026-11-11 that was 57 of 288 fetches: Vivid 22 (429 from Vivid's getOrders),
--    GoTickets 9 (429 from GoTickets' sales endpoint), TickPick 26 (401 for four hours straight).
--    Nothing re-asked, so that market's orders went up to 10+ minutes stale per miss (and
--    crm_order_status_lookup's per-source freshness test saw it as 'feed_stale' after 45 min).
--    New s4kcs_orders_retry_failed() (cron :06/:16/…): if the latest full fetch resolved with
--    errors, it queues one GET per failed market (markets=<name> — the CRM takes the display
--    names, e.g. 'Vivid Seats'; keys like 'vividseats' are a 400), once per full fetch.
--    ONLY StubHub and Gametime are retried (operator 2026-11-12: "we only need to fetch markets
--    we can't pull via our own apis"). Vivid, GoTickets, SeatGeek and TickPick each have their
--    own book here (vivid_orders, gotickets_sales, seatgeek_orders, tickpick_orders), so a CRM
--    miss on them is not re-asked — and re-asking would spend the same marketplace rate limit
--    that produced the 429. 401s are not retried either (a dead credential on the CRM side
--    does not heal in 6 minutes). The existing s4kcs_orders_process() lands the reply
--    unchanged (same body shape). GET only, to our own CRM; RULE 2 unaffected. Live-fetch
--    budget: CRM allows 10/min, this adds at most 2 calls in a minute nothing else fetches.
--
-- 3. N2B MARKET NAMES are normalised.
--    N2B rows (item_source 'gmail', from n2b_ingest_from_apps_script) carry the site name as the
--    Gmail labels spell it — 'Seatgeek', 'Tickpick', 'Gametime.Co' — while every CRM row says
--    'SeatGeek', 'TickPick', 'Gametime'. Money paths compare lower(s4k_source) LIKE 'seatgeek%'
--    and were fine; the exact-match ones were not: n2s_sg_queue / n2s_sg_drain (SeatGeek
--    inventory pulls) and the SeatGeek / Vivid identity rules in n2s_map_events /
--    event_mapper_map_surface never saw an N2B 'Seatgeek' sale. New n2s_market_canon() maps
--    the spellings; the intake uses it and the 47 existing gmail rows are renamed
--    (24 Gametime.Co, 18 Seatgeek, 5 Tickpick; 22 still open). n2s_items has no triggers.
--    `marketplace` keeps the raw spelling.
--
-- Not changed (reported to the operator instead): the TickPick 401s on the CRM side line up
-- with our own TickPick token refresh window (14:17–17:17 UTC 2026-11-11; CRM 401s 14:20–18:10),
-- which suggests the shared TickPick login issues one live token at a time. That is a D7
-- decision, not a feed-shape fix.

BEGIN;

-- ── 1. v_s4kcs_orders joins gotickets_sales ON gt_sale_id::text = s4k_order_id, and nothing
-- indexed that expression: every by-order-id read of the view seq-scanned all of
-- gotickets_sales (21k rows, ~30 ms per order — 1.5 s for 50 Vivid ids, measured 2026-11-12).
-- The two functions below send up to 500 orders per call through the view, so index it first.
-- 21k rows: builds in well under a second; the brief lock only queues gt_sales_drain writes.
CREATE INDEX IF NOT EXISTS gotickets_sales_sale_id_text_idx
  ON public.gotickets_sales ((gt_sale_id::text));

-- ── 1a. crm_order_status_lookup: read v_s4kcs_orders (Vivid / GoTickets price repaired) ──────
CREATE OR REPLACE FUNCTION public.crm_order_status_lookup(p_orders jsonb, p_shared_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expected_secret text;
  v_out             jsonb;
  c_gone_grace      constant interval := interval '35 minutes';
  c_feed_max_age    constant interval := interval '45 minutes';
BEGIN
  v_expected_secret := get_app_secret('APPSCRIPT_INGEST_SECRET');
  IF v_expected_secret IS NULL OR v_expected_secret = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected_secret THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_orders) <> 'array' THEN
    RAISE EXCEPTION 'p_orders must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  IF jsonb_array_length(p_orders) > 500 THEN
    RAISE EXCEPTION 'p_orders: max 500 per call' USING ERRCODE = '54000';
  END IF;

  WITH req AS (
    SELECT t.ord,
           lower(btrim(t.o->>'site')) AS site,
           btrim(t.o->>'id')          AS id
      FROM jsonb_array_elements(p_orders) WITH ORDINALITY AS t(o, ord)
  ),
  req2 AS (
    SELECT r.*,
           CASE r.site
             WHEN 'vivid'     THEN 'Vivid Seats'
             WHEN 'seatgeek'  THEN 'SeatGeek'
             WHEN 'tickpick'  THEN 'TickPick'
             WHEN 'gotickets' THEN 'GoTickets'
             WHEN 'gametime'  THEN 'Gametime'
             WHEN 'stubhub'   THEN 'StubHub'
             WHEN 'viagogo'   THEN 'StubHub'
           END AS crm_source,
           -- TEVO site order #s arrive as "<office>-<order>"; the order id is the tail.
           CASE WHEN r.site = 'tevo' THEN regexp_replace(r.id, '^.*-', '') END AS evo_tail
      FROM req r
  ),
  feed AS (
    SELECT o.source, max(o.last_seen_at) AS last_pull
      FROM public.s4kcs_orders o
     WHERE o.source IN (SELECT DISTINCT crm_source FROM req2 WHERE crm_source IS NOT NULL)
     GROUP BY o.source
  ),
  j AS (
    SELECT r.ord, r.site, r.id, r.crm_source,
           c.s4k_order_id AS c_id, c.order_status AS c_status, c.event_name, c.event_date,
           c.venue_name, c.section, c."row", c.quantity, c.price, c.price_per_ticket,
           c.price_source, c.delivery,
           c.inhand_date, c.payout_date, c.purchase_date, c.notes, c.last_seen_at,
           f.last_pull,
           x.canonical_status, x.is_terminal, x.is_sale_succeeded,
           m.m_status, m.m_fulfilled, m.m_seen_at,
           n.n2s_status, n.n2s_label, n.fail_reason, n.timer_expires_at, n.timer_expired,
           n.subbed_at, n.po_number, n.total_cost, n.profit_loss, n.n2s_seen_at,
           pc.cover_label, pc.cover_gate, pc.profit AS cover_profit, pc.buy_url,
           pc.sub_section, pc.sub_row, pc.sub_qty, pc.sub_view
      FROM req2 r
      -- mig 20261112010040: the view, not the raw table — the CRM ships Vivid prices empty.
      LEFT JOIN public.v_s4kcs_orders c
             ON c.source = r.crm_source AND c.s4k_order_id = r.id
      LEFT JOIN feed f ON f.source = r.crm_source
      LEFT JOIN LATERAL (
             SELECT x1.canonical_status, x1.is_terminal, x1.is_sale_succeeded
               FROM public.order_status_xref x1
              WHERE x1.source = 's4kcs' AND lower(x1.source_status) = lower(c.order_status)
              LIMIT 1) x ON true
      LEFT JOIN LATERAL (
             -- Marketplace order tables: only their TERMINAL states are trusted below;
             -- their open states can be weeks stale.
             SELECT e.state AS m_status, NULL::boolean AS m_fulfilled, e.last_seen_at AS m_seen_at
               FROM public.evo_orders e
              WHERE r.site = 'tevo' AND r.evo_tail ~ '^\d{1,18}$' AND e.evo_order_id = r.evo_tail::bigint
             UNION ALL
             SELECT s.status, NULL, s.last_status_at
               FROM public.seatgeek_orders s
              WHERE r.site = 'seatgeek' AND s.sg_order_id = r.id
             UNION ALL
             SELECT g.seller_status, g.fulfilled, g.pulled_at
               FROM public.gotickets_sales g
              WHERE r.site = 'gotickets' AND r.id ~ '^\d{1,18}$' AND g.gt_sale_id = r.id::bigint
             UNION ALL
             SELECT v.status, NULL, v.last_seen_at
               FROM public.vivid_orders v
              WHERE r.site = 'vivid' AND v.vivid_order_id = r.id
             UNION ALL
             SELECT t.status, NULL, t.last_seen_at
               FROM public.tickpick_orders t
              WHERE r.site = 'tickpick' AND t.tp_order_id = r.id
             LIMIT 1) m ON true
      LEFT JOIN LATERAL (
             SELECT ni.status AS n2s_status, ni.status_label AS n2s_label, ni.fail_reason,
                    ni.timer_expires_at, ni.timer_expired, ni.subbed_at, ni.po_number,
                    ni.total_cost, ni.profit_loss, ni.last_seen_at AS n2s_seen_at, ni.n2s_id
               FROM public.n2s_items ni
              WHERE ni.order_number = r.id
                 OR (r.site = 'tevo' AND ni.order_number LIKE '%-' || r.evo_tail)
              ORDER BY ni.last_seen_at DESC NULLS LAST
              LIMIT 1) n ON true
      LEFT JOIN LATERAL (
             SELECT p.* FROM public.n2s_profitable_cover p
              WHERE p.n2s_id = n.n2s_id
              ORDER BY p.profit DESC NULLS LAST
              LIMIT 1) pc ON true
  ),
  v AS (
    SELECT j.*,
           CASE
             WHEN j.m_fulfilled
               OR lower(j.m_status) IN ('completed','fulfilled','delivered','shipped','filled')
               THEN 'filled'
             WHEN lower(j.m_status) ~ '(cancel|reject)' THEN 'cancelled'
           END AS market_verdict,
           (j.last_pull IS NOT NULL AND j.last_pull > now() - c_feed_max_age) AS feed_ok,
           (j.c_id IS NOT NULL AND j.last_seen_at >= j.last_pull - c_gone_grace) AS in_feed,
           -- Marketplace table refreshed AFTER the order left the CRM feed and still shows a
           -- live seller-side state: trust the fresher source. PENDING_TRANSFER_PROOF is
           -- excluded -- our transfer is done, and the CRM drops those by design.
           (j.m_status IS NOT NULL AND j.m_seen_at IS NOT NULL
             AND j.m_seen_at > COALESCE(j.last_seen_at, '-infinity'::timestamptz) + interval '1 hour'
             AND upper(j.m_status) ~ '(PENDING|UNCONFIRMED|CONFIRMED|ACCEPTED|OPEN)'
             AND upper(j.m_status) <> 'PENDING_TRANSFER_PROOF') AS market_open_fresh
      FROM j
  )
  SELECT COALESCE(jsonb_agg(
           jsonb_strip_nulls(jsonb_build_object(
             'site', v.site,
             'id', v.id,
             'verdict',
               CASE
                 WHEN v.market_verdict IS NOT NULL                           THEN v.market_verdict
                 WHEN v.c_id IS NOT NULL AND v.is_terminal AND v.is_sale_succeeded THEN 'filled'
                 WHEN v.c_id IS NOT NULL AND v.is_terminal                   THEN 'cancelled'
                 WHEN v.in_feed                                              THEN 'open'
                 WHEN v.c_id IS NOT NULL AND v.market_open_fresh             THEN 'open'
                 WHEN v.c_id IS NOT NULL AND NOT v.feed_ok                   THEN 'feed_stale'
                 WHEN v.c_id IS NOT NULL                                     THEN 'closed'
                 ELSE 'not_found'
               END,
             'verdict_source',
               CASE
                 WHEN v.market_verdict IS NOT NULL THEN 'marketplace'
                 WHEN v.c_id IS NOT NULL AND NOT v.in_feed AND v.market_open_fresh THEN 'marketplace'
                 WHEN v.c_id IS NOT NULL           THEN 'crm'
               END,
             'crm_status', v.c_status,
             'canonical_status', v.canonical_status,
             'market_status', v.m_status,
             'event_name', v.event_name,
             'event_date', v.event_date,
             'venue', v.venue_name,
             'section', v.section,
             'row', v."row",
             'quantity', v.quantity,
             'price', v.price,
             'price_per_ticket', v.price_per_ticket,
             'price_source', v.price_source,
             'delivery', v.delivery,
             'inhand_date', v.inhand_date,
             'payout_date', v.payout_date,
             'purchase_date', v.purchase_date,
             'notes', NULLIF(v.notes, ''),
             'crm_last_seen_at', v.last_seen_at,
             'crm_feed_pulled_at', v.last_pull,
             'n2s', CASE WHEN v.n2s_status IS NOT NULL THEN jsonb_strip_nulls(jsonb_build_object(
                      'status', v.n2s_status, 'label', v.n2s_label, 'fail_reason', v.fail_reason,
                      'timer_expires_at', v.timer_expires_at, 'timer_expired', v.timer_expired,
                      'subbed_at', v.subbed_at, 'po_number', v.po_number,
                      'total_cost', v.total_cost, 'profit_loss', v.profit_loss,
                      'seen_at', v.n2s_seen_at)) END,
             'cover', CASE WHEN v.cover_label IS NOT NULL OR v.buy_url IS NOT NULL THEN jsonb_strip_nulls(jsonb_build_object(
                      'label', v.cover_label, 'gate', v.cover_gate, 'profit', v.cover_profit,
                      'section', v.sub_section, 'row', v.sub_row, 'qty', v.sub_qty,
                      'view', v.sub_view, 'buy_url', v.buy_url)) END
           )) ORDER BY v.ord), '[]'::jsonb)
    INTO v_out
    FROM v;

  RETURN v_out;
END;
$function$;

-- ── 1b. inbox_n2b_report: read v_s4kcs_orders; sold_ea from its price_per_ticket ─────────────
CREATE OR REPLACE FUNCTION public.inbox_n2b_report(p_orders jsonb, p_shared_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_rows jsonb; v_pull jsonb;
BEGIN
  PERFORM public.inbox_n2b_check_secret_(p_shared_secret);
  IF jsonb_typeof(p_orders) <> 'array' THEN
    RAISE EXCEPTION 'p_orders must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  IF jsonb_array_length(p_orders) > 500 THEN
    RAISE EXCEPTION 'p_orders: max 500 per call' USING ERRCODE = '54000';
  END IF;

  WITH req AS (
    SELECT DISTINCT ON (lower(btrim(o->>'site')), btrim(o->>'id'))
           lower(btrim(o->>'site')) AS site, btrim(o->>'id') AS id,
           NULLIF(btrim(o->>'order_no'), '') AS order_no,
           NULLIF(o->>'thread_id', '') AS thread_id,
           left(o->>'subject', 300) AS subject,
           CASE WHEN o->>'total' ~ '^\d+(\.\d+)?$' THEN (o->>'total')::numeric END AS total,
           CASE WHEN o->>'sale_at_ms' ~ '^\d{10,16}$'
                THEN to_timestamp((o->>'sale_at_ms')::bigint / 1000.0) END AS sale_at
      FROM jsonb_array_elements(p_orders) AS o
     WHERE COALESCE(btrim(o->>'id'), '') <> ''
     ORDER BY lower(btrim(o->>'site')), btrim(o->>'id')
  ),
  req2 AS (
    SELECT r.*,
           CASE r.site WHEN 'vivid' THEN 'Vivid Seats' WHEN 'seatgeek' THEN 'SeatGeek'
                       WHEN 'tickpick' THEN 'TickPick' WHEN 'gotickets' THEN 'GoTickets'
                       WHEN 'gametime' THEN 'Gametime' WHEN 'stubhub' THEN 'StubHub'
                       WHEN 'viagogo' THEN 'StubHub' END AS want_source,
           CASE WHEN r.site = 'tevo' OR (r.site = 'auto' AND r.id ~ '^\d+-\d+$')
                THEN regexp_replace(r.id, '^.*-', '') END AS evo_tail
      FROM req r
  ),
  m AS (
    SELECT r.*,
           c.source AS c_source,
           c.tevo_event_id AS c_ev, c.event_name AS c_name, c.event_date AS c_date, c.venue_name AS c_venue,
           c.section AS c_sec, c."row" AS c_row, c.quantity AS c_qty,
           -- mig 20261112010040: the view's per-ticket price (same basis rule as
           -- s4kcs_price_per_ticket, plus the vivid_orders / gotickets_sales repair).
           c.price_per_ticket AS c_ea,
           c.price_source AS c_price_source,
           n.s4k_source AS n_source,
           n.tevo_event_id AS n_ev, n.event_name AS n_name, n.event_dt::date AS n_date, n.venue AS n_venue,
           n.section AS n_sec, n."row" AS n_row, n.qty AS n_qty, n.price_per_ticket AS n_ea,
           t.event_id AS t_ev, t.event_name AS t_name, t.occurs_at::date AS t_date, t.venue_name AS t_venue,
           t.ticket_group_section AS t_sec, t.ticket_group_row AS t_row, t.quantity AS t_qty, t.price AS t_ea
      FROM req2 r
      LEFT JOIN LATERAL (
             SELECT c1.* FROM public.v_s4kcs_orders c1
              WHERE c1.s4k_order_id = r.id
                AND (r.site = 'auto' OR c1.source = r.want_source)
              ORDER BY c1.last_seen_at DESC NULLS LAST LIMIT 1) c ON true
      LEFT JOIN LATERAL (
             SELECT ni.* FROM public.n2s_items ni
              WHERE ni.order_number = r.id
                 OR (r.evo_tail IS NOT NULL AND ni.order_number LIKE '%-' || r.evo_tail)
              ORDER BY ni.last_seen_at DESC NULLS LAST LIMIT 1) n ON true
      LEFT JOIN LATERAL (
             SELECT oi.* FROM public.evo_order_items oi
              WHERE r.evo_tail ~ '^\d{1,18}$' AND oi.evo_order_id = r.evo_tail::bigint
              ORDER BY oi.id LIMIT 1) t ON true
  ),
  up AS (
    INSERT INTO public.inbox_n2b AS i (
      site, site_order_id, order_no, thread_id, subject, sale_total, sale_at,
      first_reported_at, last_reported_at, crm_source, tevo_event_id, event_name, event_date,
      venue, section, "row", quantity, sold_ea, price_basis, map_via)
    SELECT m.site, m.id, m.order_no, m.thread_id, m.subject, m.total, m.sale_at, now(), now(),
           COALESCE(m.c_source, m.n_source, m.want_source, CASE WHEN m.t_ev IS NOT NULL THEN 'EVO' END),
           COALESCE(m.c_ev, m.n_ev, m.t_ev),
           COALESCE(m.c_name, m.n_name, m.t_name),
           COALESCE(m.c_date, m.n_date, m.t_date),
           COALESCE(m.c_venue, m.n_venue, m.t_venue),
           COALESCE(m.c_sec, m.n_sec, m.t_sec),
           COALESCE(m.c_row, m.n_row, m.t_row),
           COALESCE(m.c_qty, m.n_qty, m.t_qty),
           COALESCE(m.c_ea, m.n_ea, m.t_ea,
                    m.total / NULLIF(COALESCE(m.c_qty, m.n_qty, m.t_qty), 0)),
           -- 'crm' when the CRM priced it; the repair source ('vivid_orders' /
           -- 'gotickets_sales') when the view filled a price the CRM left empty.
           CASE WHEN m.c_ea IS NOT NULL THEN COALESCE(m.c_price_source, 'crm')
                WHEN m.n_ea IS NOT NULL THEN 'n2s'
                WHEN m.t_ea IS NOT NULL THEN 'evo'
                WHEN m.total IS NOT NULL AND COALESCE(m.c_qty, m.n_qty, m.t_qty) > 0 THEN 'email_total' END,
           CASE WHEN m.c_ev IS NOT NULL THEN 'crm' WHEN m.n_ev IS NOT NULL THEN 'n2s'
                WHEN m.t_ev IS NOT NULL THEN 'evo_order' END
      FROM m
    ON CONFLICT (site, site_order_id) DO UPDATE SET
      order_no = EXCLUDED.order_no, thread_id = EXCLUDED.thread_id, subject = EXCLUDED.subject,
      sale_total = EXCLUDED.sale_total, sale_at = EXCLUDED.sale_at,
      last_reported_at = now(), crm_source = EXCLUDED.crm_source,
      tevo_event_id = EXCLUDED.tevo_event_id, event_name = EXCLUDED.event_name,
      event_date = EXCLUDED.event_date, venue = EXCLUDED.venue, section = EXCLUDED.section,
      "row" = EXCLUDED."row", quantity = EXCLUDED.quantity, sold_ea = EXCLUDED.sold_ea,
      price_basis = EXCLUDED.price_basis, map_via = EXCLUDED.map_via
    RETURNING i.site, i.site_order_id, i.crm_source, i.tevo_event_id, i.map_via, i.event_name
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('site', site, 'id', site_order_id, 'source', crm_source,
           'tevo_event_id', tevo_event_id, 'map_via', map_via, 'event_name', event_name)), '[]'::jsonb)
    INTO v_rows FROM up;

  v_pull := public.inbox_n2b_pull(interval '5 minutes');
  RETURN jsonb_build_object('orders', v_rows, 'pull', v_pull);
END $function$;

-- ── 2. retry the markets a full fetch came back without ──────────────────────────────────────
ALTER TABLE public.s4kcs_orders_pending
  ADD COLUMN IF NOT EXISTS retry_of bigint;
COMMENT ON COLUMN public.s4kcs_orders_pending.retry_of IS
  'For a single-market retry (query_str retry:<market>): the s4kcs_orders_pending.id of the full '
  'fetch that came back without that market. NULL on full fetches. Mig 20261112010040.';
CREATE INDEX IF NOT EXISTS s4kcs_orders_pending_retry_of_idx
  ON public.s4kcs_orders_pending (retry_of) WHERE retry_of IS NOT NULL;

CREATE OR REPLACE FUNCTION public.s4kcs_orders_retry_failed()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'vault'
AS $function$
DECLARE
  v_key    text := btrim(COALESCE(public.get_app_secret('crm.s4kcs.com'), ''));
  v_full   record;
  v_market text;
  v_req    bigint;
  v_n      int := 0;
BEGIN
  IF v_key = '' THEN
    RETURN 0;
  END IF;

  -- The latest full fetch, if it has resolved recently (the queue fires every 10 min).
  SELECT p.id, p.errors INTO v_full
    FROM public.s4kcs_orders_pending p
   WHERE p.query_str = 'all-markets'
     AND p.resolved_at IS NOT NULL
     AND p.created_at > now() - interval '12 minutes'
   ORDER BY p.created_at DESC
   LIMIT 1;

  IF v_full.id IS NULL OR jsonb_array_length(COALESCE(v_full.errors, '[]'::jsonb)) = 0 THEN
    RETURN 0;
  END IF;
  -- Once per full fetch.
  IF EXISTS (SELECT 1 FROM public.s4kcs_orders_pending WHERE retry_of = v_full.id) THEN
    RETURN 0;
  END IF;

  FOR v_market IN
    SELECT DISTINCT e->>'market'
      FROM jsonb_array_elements(v_full.errors) AS e
     -- Only the markets we cannot pull through our own APIs (operator 2026-11-12); the CRM's
     -- own display names (GET /marketplace/marketplaces). Anything else is never put in a URL.
     WHERE e->>'market' IN ('StubHub', 'Gametime')
       -- A 401 is a dead credential on the CRM side; retrying in 6 minutes does not heal it.
       AND COALESCE(e->>'error', '') !~ '\m401\M'
     ORDER BY 1
  LOOP
    SELECT net.http_get(
      url := 'https://crm.s4kcs.com/api/v1/marketplace/orders?markets=' || replace(v_market, ' ', '%20'),
      headers := jsonb_build_object('X-API-Key', v_key, 'Accept', 'application/json'),
      timeout_milliseconds := 120000
    ) INTO v_req;

    INSERT INTO public.s4kcs_orders_pending (request_id, query_str, retry_of)
    VALUES (v_req, 'retry:' || v_market, v_full.id);
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.s4kcs_orders_retry_failed() FROM PUBLIC, anon, authenticated;

-- Full fetch queued :00 (cron 578), landed :03 (cron 579); retry queued :06, landed :13.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 's4kcs_orders_retry_10min') THEN
    PERFORM cron.unschedule('s4kcs_orders_retry_10min');
  END IF;
  PERFORM cron.schedule('s4kcs_orders_retry_10min', '6-59/10 * * * *',
                        'SELECT public.s4kcs_orders_retry_failed();');
END
$cron$;

-- ── 3. N2B market names: one spelling per market ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_market_canon(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT CASE lower(btrim(p_name))
           WHEN 'ticket evolution' THEN 'EVO'
           WHEN 'stubhub 2.0'      THEN 'StubHub'
           WHEN 'stubhub'          THEN 'StubHub'
           WHEN 'go tickets'       THEN 'GoTickets'
           WHEN 'gotickets'        THEN 'GoTickets'
           WHEN 'seatgeek'         THEN 'SeatGeek'
           WHEN 'tickpick'         THEN 'TickPick'
           WHEN 'gametime'         THEN 'Gametime'
           WHEN 'gametime.co'      THEN 'Gametime'
           WHEN 'vivid seats'      THEN 'Vivid Seats'
           WHEN 'vividseats'       THEN 'Vivid Seats'
           ELSE NULLIF(btrim(p_name), '')
         END;
$function$;
COMMENT ON FUNCTION public.n2s_market_canon(text) IS
  'One spelling per market for n2s_items.s4k_source (the CRM''s names). N2B Gmail labels spell '
  'them Seatgeek / Tickpick / Gametime.Co; exact-match readers (n2s_sg_queue, n2s_map_events) '
  'missed those rows. Unknown names pass through trimmed. Mig 20261112010040.';

CREATE OR REPLACE FUNCTION public.n2b_ingest_from_apps_script(p_items jsonb, p_shared_secret text, p_full_sync boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expected text := public.get_app_secret('APPSCRIPT_INGEST_SECRET');
  v_ids bigint[];
  v_new int := 0; v_upd int := 0; v_closed int := 0; v_total int;
BEGIN
  IF v_expected IS NULL OR v_expected = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_items);
  IF v_total > 2000 THEN
    RAISE EXCEPTION 'p_items too large (% > 2000)', v_total USING ERRCODE = '22023';
  END IF;

  WITH src AS (
    SELECT it,
           -((it->>'pos_order')::bigint)                         AS nid,
           NULLIF(btrim(it->>'site'), '')                        AS site,
           NULLIF(btrim(it->>'site_order'), '')                  AS site_order,
           NULLIF(it->>'event_dt', '')::timestamp                AS event_dt,
           COALESCE((it->>'cancelled')::boolean, false)          AS cancelled
      FROM jsonb_array_elements(p_items) AS it
     WHERE it->>'pos_order' ~ '^[0-9]{1,15}$'
  ),
  s AS (
    SELECT src.*,
           CASE WHEN cancelled THEN 'n2b_cancelled'
                WHEN event_dt < (now() AT TIME ZONE 'America/New_York') - interval '1 day' THEN 'n2b_closed'
                ELSE 'n2b' END AS st
      FROM src
  ),
  up AS (
    INSERT INTO public.n2s_items AS t (
      n2s_id, order_number, marketplace, s4k_source,
      status, status_label, is_terminal, item_source, fail_reason,
      event_name, venue, event_dt, section, "row", seats, qty,
      price_per_ticket, grand_total, alert_at, timer_expires_at, timer_expired,
      resolved_at, n2s_created_at, n2s_updated_at, pulled_at, last_seen_at, raw)
    SELECT
      s.nid,
      COALESCE(s.site_order, s.it->>'pos_order'),
      s.site,
      public.n2s_market_canon(s.site),   -- mig 20261112010040 (was a 3-name CASE)
      s.st,
      CASE s.st WHEN 'n2b' THEN 'N2B' WHEN 'n2b_cancelled' THEN 'N2B cancelled' ELSE 'N2B closed' END,
      s.st <> 'n2b', 'gmail',
      CASE s.st WHEN 'n2b_cancelled' THEN 'cancelled' WHEN 'n2b_closed' THEN 'event passed' END,
      NULLIF(btrim(s.it->>'event_name'), ''), NULLIF(btrim(s.it->>'venue'), ''), s.event_dt,
      NULLIF(btrim(s.it->>'section'), ''), NULLIF(btrim(s.it->>'row'), ''),
      NULLIF(btrim(s.it->>'seats'), ''),
      NULLIF(s.it->>'qty', '')::integer,
      NULLIF(s.it->>'price_each', '')::numeric, NULLIF(s.it->>'total', '')::numeric,
      NULL, NULL, false,
      CASE WHEN s.st <> 'n2b' THEN now() END,
      COALESCE(NULLIF(s.it->>'sale_at', '')::timestamptz, now()), now(), now(), now(),
      s.it
    FROM s
    ON CONFLICT (n2s_id) DO UPDATE SET
      order_number   = EXCLUDED.order_number,
      marketplace    = EXCLUDED.marketplace,
      s4k_source     = EXCLUDED.s4k_source,
      status         = CASE WHEN t.status = 'n2b_cancelled' THEN t.status ELSE EXCLUDED.status END,
      status_label   = CASE WHEN t.status = 'n2b_cancelled' THEN t.status_label ELSE EXCLUDED.status_label END,
      is_terminal    = CASE WHEN t.status = 'n2b_cancelled' THEN true ELSE EXCLUDED.is_terminal END,
      fail_reason    = CASE WHEN t.status = 'n2b_cancelled' THEN t.fail_reason ELSE EXCLUDED.fail_reason END,
      resolved_at    = CASE WHEN t.status = 'n2b_cancelled' THEN t.resolved_at
                            WHEN EXCLUDED.status = 'n2b' THEN NULL
                            ELSE COALESCE(t.resolved_at, now()) END,
      event_name     = EXCLUDED.event_name,
      venue          = EXCLUDED.venue,
      event_dt       = EXCLUDED.event_dt,
      section        = EXCLUDED.section,
      "row"          = EXCLUDED."row",
      seats          = EXCLUDED.seats,
      qty            = EXCLUDED.qty,
      price_per_ticket = EXCLUDED.price_per_ticket,
      grand_total    = EXCLUDED.grand_total,
      tevo_event_id  = CASE WHEN (t.event_name, t.venue, t.event_dt)
                                 IS DISTINCT FROM (EXCLUDED.event_name, EXCLUDED.venue, EXCLUDED.event_dt)
                            THEN NULL ELSE t.tevo_event_id END,
      mapped_via     = CASE WHEN (t.event_name, t.venue, t.event_dt)
                                 IS DISTINCT FROM (EXCLUDED.event_name, EXCLUDED.venue, EXCLUDED.event_dt)
                            THEN NULL ELSE t.mapped_via END,
      n2s_updated_at = now(),
      last_seen_at   = now(),
      raw            = EXCLUDED.raw
    WHERE t.item_source = 'gmail'
    RETURNING t.n2s_id, (xmax = 0) AS is_new
  )
  SELECT array_agg(n2s_id), count(*) FILTER (WHERE is_new), count(*) FILTER (WHERE NOT is_new)
    INTO v_ids, v_new, v_upd
    FROM up;

  IF p_full_sync THEN
    UPDATE public.n2s_items n
       SET status = 'n2b_closed', status_label = 'N2B closed', is_terminal = true,
           fail_reason = 'label removed', resolved_at = now(), n2s_updated_at = now()
     WHERE n.item_source = 'gmail' AND n.status = 'n2b'
       AND NOT (n.n2s_id = ANY(COALESCE(v_ids, ARRAY[]::bigint[])))
       AND n.last_seen_at < now() - interval '30 minutes';
    GET DIAGNOSTICS v_closed = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'received', v_total, 'inserted', COALESCE(v_new, 0), 'updated', COALESCE(v_upd, 0),
    'skipped', v_total - COALESCE(v_new, 0) - COALESCE(v_upd, 0), 'closed', v_closed,
    'open', (SELECT count(*) FROM public.n2s_items WHERE item_source = 'gmail' AND status = 'n2b'));
END;
$function$;

-- The rows already in (47 on 2026-11-11). n2s_updated_at is left alone: the name changed,
-- the sale did not.
UPDATE public.n2s_items
   SET s4k_source = public.n2s_market_canon(s4k_source)
 WHERE item_source = 'gmail'
   AND s4k_source IS DISTINCT FROM public.n2s_market_canon(s4k_source);

COMMIT;
