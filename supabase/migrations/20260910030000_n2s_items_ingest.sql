-- ============================================================================
-- Migration 20260910030000 — ingest the CRM's N2S ("Need to Sub") book
--
-- Lane:     D0 (orders surface) over A1's ingest plane
-- Touches:  n2s_items (CREATE TABLE), n2s_items_pending (CREATE TABLE),
--           n2s_items_queue() / n2s_items_drain() (pg_net queue+drain pattern,
--           mirroring s4kcs_orders_queue), two offset crons
-- Pre-reqs: vault secret `crm.s4kcs.com/n2s` (seeded 2026-09-09),
--           get_app_secret() allowlist (mig 20260908170721)
--
-- READ-ONLY upstream: GET /api/v1/n2s/items only. RULE 2 holds — the N2S API
-- is read-only to us and no write endpoint is called from anywhere.
--
-- Operator direction 2026-09-09: "just use the key."
--
-- ── What this is ───────────────────────────────────────────────────────────
-- The CRM's SECOND book. `s4kcs_orders` (the marketplace book) carries orders
-- that PROCESSED. N2S carries orders that FAILED and now need a substitute —
-- a different population, on a different API surface, behind a separate key
-- with its own scope (`n2s:read`, disjoint from `marketplace:read`).
--
-- ⚠ N2S IS NOT A STATUS DECORATION ON THE EXISTING QUEUE — IT IS LARGELY A
-- SET OF ORDERS WE CANNOT OTHERWISE SEE. Measured against the live book on
-- 2026-09-09 (433 items, 432 of them status `n2s`):
--
--   marketplace        n2s items   found in ANY of our order books
--   Gametime                  91   79
--   Stubhub 2.0               81   73
--   Vivid Seats               99    0
--   TickPick                  88    0
--   Go Tickets                43    0
--   Ticket Evolution          17    0
--   SeatGeek                  13    0
--
-- Checked against `s4kcs_orders`, `vivid_orders` AND `gotickets_sales`, not
-- just one. 260 of 432 orders that actively need a sub are invisible to the
-- whole substitution pipeline today. Anyone who assumes N2S merely annotates
-- rows we already have will silently drop three fifths of the demand.
--
-- ⚠ THE EVO ORDER NUMBER IS COMPOSITE AND WILL NOT JOIN NAIVELY. N2S spells a
-- Ticket Evolution order `8046564-19082001` (order-item pair); `evo_orders`
-- keys on `18535124`. Every other marketplace's order_number is the same
-- string our feed already stores — verified by shape on live samples — so EVO
-- is the one source needing a split before it can be matched. Not attempted
-- here: this migration lands the book faithfully and does no joining.
--
-- ⚠ `event_dt` IS LOCAL WALL CLOCK WITH NO ZONE — the §3 mixed-timezone
-- landmine. Stored as `timestamp` (not `timestamptz`) so nothing silently
-- reinterprets it in UTC. `alert_at` / `timer_expires_at` / the `*_at`
-- lifecycle stamps ARE genuine UTC instants and are `timestamptz`.
--
-- ⚠ PII IS DELIBERATELY NOT INGESTED. The API exposes `customer_name` and
-- `customer_email`. Neither is needed to find a substitute, and storing them
-- would put customer PII in a broker analytics database. Both are stripped
-- from `raw` as well as omitted as columns — see the `- 'customer_name'`
-- in the drain. Do not add them back "for completeness".
--
-- ── Pagination is honest here, unlike GoTickets ────────────────────────────
-- Verified live: `?limit=1000` returned all 433 with total=433 (no silent
-- cap), and `?limit=5&offset=430` returned exactly the last 3 — `offset` is
-- genuinely honoured. Contrast `gotickets_sales`, whose feed IGNORES offset
-- and silently caps at 10,000 (mig 20260909220000). So a simple
-- limit/offset loop is safe here; the whole book currently fits in one call.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.n2s_items (
  n2s_id            bigint PRIMARY KEY,
  order_number      text NOT NULL,
  marketplace       text,                 -- as N2S spells it
  s4k_source        text,                 -- normalised to v_sub_orders.source
  status            text NOT NULL,        -- n2s|subbed|resolved|no_subs|allocated
  status_label      text,
  is_terminal       boolean,              -- resolved + allocated (from /n2s/meta)
  item_source       text,                 -- manual | automatiq
  fail_reason       text,
  event_name        text,
  venue             text,
  event_dt          timestamp,            -- LOCAL wall clock, no zone (§3)
  section           text,
  "row"             text,
  seats             text,
  qty               integer,
  price_per_ticket  numeric,              -- explicit per-ticket, no unit guess
  grand_total       numeric,
  cost              numeric,
  total_cost        numeric,
  sale_profit       numeric,
  profit_loss       numeric,
  listing_id        text,
  delivery_type     text,
  po_number         text,
  alert_at          timestamptz,
  timer_expires_at  timestamptz,
  timer_expired     boolean,
  subbed_at         timestamptz,
  resolved_at       timestamptz,
  no_subs_at        timestamptz,
  n2s_created_at    timestamptz,
  n2s_updated_at    timestamptz,
  pulled_at         timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  raw               jsonb                 -- PII-stripped
);

CREATE INDEX IF NOT EXISTS n2s_items_status_idx      ON public.n2s_items (status);
CREATE INDEX IF NOT EXISTS n2s_items_order_idx       ON public.n2s_items (order_number);
CREATE INDEX IF NOT EXISTS n2s_items_source_open_idx ON public.n2s_items (s4k_source) WHERE NOT is_terminal;

CREATE TABLE IF NOT EXISTS public.n2s_items_pending (
  request_id     bigint PRIMARY KEY,
  requested_at   timestamptz NOT NULL DEFAULT now(),
  query_str      text,
  resolved_at    timestamptz,
  status_code    int,
  rows_persisted int
);

CREATE INDEX IF NOT EXISTS n2s_items_pending_unresolved_idx
  ON public.n2s_items_pending (resolved_at) WHERE resolved_at IS NULL;

ALTER TABLE public.n2s_items         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n2s_items_pending ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.n2s_items IS
  'The S4K CRM N2S ("Need to Sub") book: orders that FAILED and need a '
  'substitute. A different population from s4kcs_orders (which carries orders '
  'that processed) — as of 2026-09-09, 260 of 432 open N2S orders appear in '
  'NO order book we hold. Read-only ingest of GET /api/v1/n2s/items via the '
  'n2s:read key. Customer PII (customer_name, customer_email) is deliberately '
  'never stored, including inside raw. event_dt is LOCAL wall clock with no '
  'zone (§3) and is typed `timestamp` on purpose.';

-- ── queue: one GET, recorded for the drain ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_items_queue(
  p_limit  integer DEFAULT 1000,
  p_offset integer DEFAULT 0
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','net','vault','pg_temp'
AS $function$
DECLARE
  v_key   text := btrim(COALESCE(public.get_app_secret('crm.s4kcs.com/n2s'), ''));
  v_qs    text := format('?limit=%s&offset=%s', p_limit, p_offset);
  v_req   bigint;
BEGIN
  IF v_key = '' THEN
    RAISE NOTICE 'crm.s4kcs.com/n2s vault secret unset; skipping queue';
    RETURN NULL;
  END IF;

  SELECT net.http_get(
    url := 'https://crm.s4kcs.com/api/v1/n2s/items' || v_qs,
    headers := jsonb_build_object('X-API-Key', v_key, 'Accept', 'application/json'),
    timeout_milliseconds := 60000
  ) INTO v_req;

  INSERT INTO public.n2s_items_pending(request_id, query_str) VALUES (v_req, v_qs);
  RETURN v_req;
END $function$;

-- ── drain: parse whatever has come back, upsert, mark resolved ─────────────
CREATE OR REPLACE FUNCTION public.n2s_items_drain()
RETURNS TABLE(responses integer, rows_upserted integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','net','pg_temp'
AS $function$
DECLARE
  v_resp  int := 0;
  v_rows  int := 0;
  r       record;
  v_n     int;
BEGIN
  FOR r IN
    SELECT p.request_id, x.status_code, x.content
      FROM public.n2s_items_pending p
      JOIN net._http_response x ON x.id = p.request_id
     WHERE p.resolved_at IS NULL
     ORDER BY p.request_id
  LOOP
    v_resp := v_resp + 1;

    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      WITH items AS (
        SELECT jsonb_array_elements(r.content::jsonb -> 'items') AS it
      ),
      up AS (
        INSERT INTO public.n2s_items AS t (
          n2s_id, order_number, marketplace, s4k_source, status, status_label,
          is_terminal, item_source, fail_reason, event_name, venue, event_dt,
          section, "row", seats, qty, price_per_ticket, grand_total, cost,
          total_cost, sale_profit, profit_loss, listing_id, delivery_type,
          po_number, alert_at, timer_expires_at, timer_expired, subbed_at,
          resolved_at, no_subs_at, n2s_created_at, n2s_updated_at,
          pulled_at, last_seen_at, raw)
        SELECT (it->>'id')::bigint,
               it->>'order_number',
               it->>'marketplace',
               -- N2S spells marketplaces differently from every other feed.
               CASE it->>'marketplace'
                 WHEN 'Stubhub 2.0'      THEN 'StubHub'
                 WHEN 'Go Tickets'       THEN 'GoTickets'
                 WHEN 'Ticket Evolution' THEN 'EVO'
                 ELSE it->>'marketplace'     -- Gametime/SeatGeek/TickPick/Vivid Seats match
               END,
               it->>'status',
               it->>'status_label',
               -- terminal set is from GET /n2s/meta, not guessed
               (it->>'status') IN ('resolved','allocated'),
               it->>'source',
               it->>'fail_reason',
               it->>'event_name',
               it->>'venue',
               NULLIF(it->>'event_dt','')::timestamp,      -- LOCAL, no zone (§3)
               it->>'section',
               it->>'row',
               it->>'seats',
               NULLIF(it->>'qty','')::integer,
               NULLIF(it->>'price_per_ticket','')::numeric,
               NULLIF(it->>'grand_total','')::numeric,
               NULLIF(it->>'cost','')::numeric,
               NULLIF(it->>'total_cost','')::numeric,
               NULLIF(it->>'sale_profit','')::numeric,
               NULLIF(it->>'profit_loss','')::numeric,
               it->>'listing_id',
               it->>'delivery_type',
               it->>'po_number',
               NULLIF(it->>'alert_at','')::timestamptz,
               NULLIF(it->'timer'->>'expires_at','')::timestamptz,
               (it->'timer'->>'expired')::boolean,
               NULLIF(it->>'subbed_at','')::timestamptz,
               NULLIF(it->>'resolved_at','')::timestamptz,
               NULLIF(it->>'no_subs_at','')::timestamptz,
               NULLIF(it->>'created_at','')::timestamptz,
               NULLIF(it->>'updated_at','')::timestamptz,
               now(), now(),
               -- PII stripped from raw too, not just from the columns.
               (it - 'customer_name' - 'customer_email')
          FROM items
        ON CONFLICT (n2s_id) DO UPDATE SET
               order_number = EXCLUDED.order_number,
               marketplace = EXCLUDED.marketplace,
               s4k_source = EXCLUDED.s4k_source,
               status = EXCLUDED.status,
               status_label = EXCLUDED.status_label,
               is_terminal = EXCLUDED.is_terminal,
               item_source = EXCLUDED.item_source,
               fail_reason = EXCLUDED.fail_reason,
               event_name = EXCLUDED.event_name,
               venue = EXCLUDED.venue,
               event_dt = EXCLUDED.event_dt,
               section = EXCLUDED.section,
               "row" = EXCLUDED."row",
               seats = EXCLUDED.seats,
               qty = EXCLUDED.qty,
               price_per_ticket = EXCLUDED.price_per_ticket,
               grand_total = EXCLUDED.grand_total,
               cost = EXCLUDED.cost,
               total_cost = EXCLUDED.total_cost,
               sale_profit = EXCLUDED.sale_profit,
               profit_loss = EXCLUDED.profit_loss,
               listing_id = EXCLUDED.listing_id,
               delivery_type = EXCLUDED.delivery_type,
               po_number = EXCLUDED.po_number,
               alert_at = EXCLUDED.alert_at,
               timer_expires_at = EXCLUDED.timer_expires_at,
               timer_expired = EXCLUDED.timer_expired,
               subbed_at = EXCLUDED.subbed_at,
               resolved_at = EXCLUDED.resolved_at,
               no_subs_at = EXCLUDED.no_subs_at,
               n2s_created_at = EXCLUDED.n2s_created_at,
               n2s_updated_at = EXCLUDED.n2s_updated_at,
               last_seen_at = now(),
               raw = EXCLUDED.raw
        RETURNING 1)
      SELECT count(*)::int INTO v_n FROM up;

      v_rows := v_rows + COALESCE(v_n, 0);
    ELSE
      v_n := 0;
    END IF;

    UPDATE public.n2s_items_pending
       SET resolved_at = now(), status_code = r.status_code, rows_persisted = COALESCE(v_n, 0)
     WHERE request_id = r.request_id;
  END LOOP;

  RETURN QUERY SELECT v_resp, v_rows;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_items_queue(integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_items_queue(integer,integer) TO service_role;
REVOKE ALL ON FUNCTION public.n2s_items_drain() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_items_drain() TO service_role;

-- ── reconciliation poll ────────────────────────────────────────────────────
-- Queue and drain are SEPARATE crons five minutes apart, not one job, because
-- pg_net is asynchronous and its worker backlogs: measured 1-3 minutes from
-- queue to response under normal load on this project. A single job that
-- queued and drained in one pass would drain the PREVIOUS run's responses and
-- read as working while always being one cycle stale.
--
-- ⚠ PAGE AT 150, NOT 1000. `?limit=1000` returns all 433 items in one body and
-- TIMED OUT at 60s in live testing (it had succeeded minutes earlier at the
-- same size — the endpoint is slow and variable under load). limit=150
-- returned in well under the timeout. Three pages cover 450 items; the book
-- was 433 on 2026-09-09. If it grows past 450, add a page here — a silently
-- truncated book means orders that need a sub never appear.
--
-- This poll stays useful even once a push receiver exists: webhook deliveries
-- are lost to downtime, deploys and transient 5xx, and the N2S timer is only
-- 15 minutes, so a missed delivery costs a fill. Receiver-primary plus slow
-- reconciliation is the intended end state, NOT receiver-only.
SELECT cron.schedule(
  'n2s_items_sync_10min', '*/10 * * * *',
  $cron$
    SELECT public.n2s_items_queue(150, 0);
    SELECT public.n2s_items_queue(150, 150);
    SELECT public.n2s_items_queue(150, 300);
  $cron$
);

SELECT cron.schedule(
  'n2s_items_drain_10min', '5,15,25,35,45,55 * * * *',
  $cron$ SELECT public.n2s_items_drain(); $cron$
);
