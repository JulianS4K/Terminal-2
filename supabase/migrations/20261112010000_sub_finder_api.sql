-- Migration 20261112010000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_job,sub_finder_order,sub_finder_td_pull,sub_finder_submit,sub_finder_latest_job,sub_finder_settle,sub_finder_match,sub_finder_job_json,sub_finder_order_read,sub_finder_results,sub_finder_buy · reads:events,n2s_items,v_s4kcs_orders,n2s_evo_current,n2s_gt_current,n2s_sg_current,n2s_mkt_pull,sg_events_canonical,aq_event_map,manual_sub_buy · pre:20261112000000
--
-- SUB FINDER API: a CRM user sends orders, gets back the best substitute per order.
--
-- Operator 2026-11-12, after a sheet tab of 30 failed orders was matched by hand in a session:
-- "turn this into an out bound api trigger where crm user can auto get subs for orders".
-- Answers given the same day: the CRM calls us and reads the answer back (no webhook); the CRM
-- may send ANY order (event + section + row + quantity + sale price), not only ones already in
-- the N2S book; and a CRM user may ask for an EVO cover to be bought. Then: "it's going to be
-- getting info from crm so look at how it has orders and simplify process" — so an order can be
-- sent as just its number, or as the CRM's own row, and is filled in from our mirror of the
-- CRM's books (see sub_finder_submit).
--
-- This is the SQL half; routers/subs_api.py is the HTTP half (/api/v1/subs/*). The API shape
-- copies the CRM's own (s4kcs_client.py): X-API-Key, an envelope of count/total/limit/offset/
-- items/generated_at, and `updated_since` fed from the last `generated_at` as the sync cursor.
--
-- HOW ONE JOB RUNS
--   submit   store the orders, resolve each to a TEvo event, and fire the SAME on-demand pull
--            N2S uses (n2s_pull_events: EVO, GoTickets, SeatGeek — GETs only). No new poller.
--   settle   lazily, when the job is read: once every event's pulls have answered (or the
--            timeout passes) match each order against the fresh listings and store the covers.
--   fallback ONLY for orders those three markets found nothing for, and only when td_enabled:
--            one TicketsData /match per event (GET; 12 credits + 1 report each; at most 3 in
--            flight, the account's own limit), keyed off the StubHub event id we already hold
--            in aq_event_map. Its other markets' listings (StubHub, Viagogo, Vivid Seats,
--            TickPick, Gametime, Ticketmaster) are then matched the same way. An order that
--            already has a cover never costs a credit.
--   read     one job, one order, or every order changed since a cursor. Each order carries its
--            buy, if one was asked for: EVO order number, seller outcome (pending / confirmed /
--            rejected / canceled), what EVO charged, and seat numbers once the seller gives
--            them (mig 20261112000000 keeps those current). A change there moves the order's
--            updated_at, so the sync feed hands the order out again.
--
-- WHAT COUNTS AS A COVER: same section, row the same or better, or up to 5 rows back (flagged
-- `back`), quantity the listing's splits allow or a lot of exactly one more (the spare is
-- reported). Our own listings are never offered. Covers that lose money ARE returned, with the
-- loss — the caller decides; nothing here applies an N2S gate.
--
-- SEPARATE FROM N2S. Nothing here writes an n2s_* table; the N2S queue, dry run, auto-buy and
-- caps never see these orders. It reads the three n2s_*_current listing tables and calls the
-- N2S pull function, nothing else.
--
-- BUYING (sub_finder_buy) adds NO write path. It files a row in manual_sub_buy — the path
-- built 2026-11-11 — for an EVO cover THIS API quoted for THAT order, at the quoted quantity
-- with the quoted price as the ceiling. Everything that protects that path still applies: its
-- enabled flag and kill switch, MANUAL_SUB_BUY_LIVE on the web service, one live request per
-- sale, the per-order and per-day spend ceilings, the fresh re-read of the listing. On top:
-- buying is off until sub_finder_config.buy_enabled is true AND the calling key is in
-- buy_key_ids. Both default to nothing. No sale is accepted, rejected or repriced.
--
-- ACCESS: only keys listed in sub_finder_config.key_ids (ids from mcp_api_keys) may call; a
-- key reads only the jobs it submitted. The whole API is off until `enabled` is true.
--
-- No upstream call is made by this migration itself.
--
-- rollback: DROP TRIGGER sub_finder_buy_touch ON public.manual_sub_buy;
--           DROP FUNCTION public.sub_finder_buy_touch_trg(), public.sub_finder_order_read(bigint, uuid, text),
--             public.sub_finder_match(uuid, boolean), public.sub_finder_buy(bigint, text, uuid, text, text, text),
--             public.sub_finder_results(bigint, timestamptz, integer, integer),
--             public.sub_finder_job_json(bigint, uuid), public.sub_finder_settle(uuid),
--             public.sub_finder_order_json(public.sub_finder_order),
--             public.sub_finder_submit(bigint, text, jsonb, text), public.sub_finder_latest_job(bigint, text),
--             public.sub_finder_access(bigint);
--           DROP TABLE public.sub_finder_td_pull, public.sub_finder_order, public.sub_finder_job, public.sub_finder_config;

CREATE TABLE IF NOT EXISTS public.sub_finder_config (
  id                 boolean PRIMARY KEY DEFAULT true CHECK (id),
  enabled            boolean  NOT NULL DEFAULT false,
  key_ids            bigint[] NOT NULL DEFAULT '{}',      -- mcp_api_keys.id allowed to call
  buy_enabled        boolean  NOT NULL DEFAULT false,
  buy_key_ids        bigint[] NOT NULL DEFAULT '{}',      -- subset allowed to ask for a buy
  max_orders_per_job integer  NOT NULL DEFAULT 200,
  pull_refresh       interval NOT NULL DEFAULT interval '2 minutes',
  settle_min_s       integer  NOT NULL DEFAULT 20,        -- never match before the pulls can land
  settle_timeout_s   integer  NOT NULL DEFAULT 180,       -- match with what we have after this
  rows_back          integer  NOT NULL DEFAULT 5,
  td_enabled         boolean  NOT NULL DEFAULT false,     -- TicketsData fallback (costs credits)
  td_max_events_per_job integer NOT NULL DEFAULT 6,       -- 12 credits + 1 report per event
  td_concurrency     integer  NOT NULL DEFAULT 3,         -- the account's own limit; more answers 429
  td_timeout_s       integer  NOT NULL DEFAULT 150,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.sub_finder_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.sub_finder_job (
  job_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key_id          bigint NOT NULL,
  key_label       text,
  idempotency_key text,
  status          text NOT NULL DEFAULT 'pulling' CHECK (status IN ('pulling', 'pulling_td', 'done')),
  order_count     integer NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  done_at         timestamptz
);
-- a retried submit with the same key + idempotency key returns the first job, never a second
CREATE UNIQUE INDEX IF NOT EXISTS sub_finder_job_idem
  ON public.sub_finder_job (key_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.sub_finder_order (
  job_id        uuid NOT NULL REFERENCES public.sub_finder_job (job_id) ON DELETE CASCADE,
  idx           integer NOT NULL,
  key_id        bigint NOT NULL,
  order_number  text NOT NULL,
  site          text,
  tevo_event_id bigint,
  event_name    text,
  event_date    date,
  venue         text,
  section       text NOT NULL,
  seat_row      text NOT NULL,
  qty           integer NOT NULL CHECK (qty BETWEEN 1 AND 50),
  sold_ea       numeric,
  state         text NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending', 'cover', 'no_cover', 'unmapped')),
  best          jsonb,
  covers        jsonb NOT NULL DEFAULT '[]'::jsonb,
  buy_id        bigint,
  -- TicketsData fallback for this order: NULL = not needed (a cover was found) or switched off;
  -- queued -> searched | failed; no_event_link = we hold no StubHub id for the event; over_limit
  td_state      text CHECK (td_state IN ('queued', 'searched', 'failed', 'no_event_link', 'over_limit')),
  -- where the order's details came from: 'request' (all sent) | 'n2s' | 'marketplace' (our CRM mirror)
  order_source  text NOT NULL DEFAULT 'request',
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (job_id, idx)
);

-- One TicketsData /match per (job, event). request_id is the pg_net request once fired.
CREATE TABLE IF NOT EXISTS public.sub_finder_td_pull (
  job_id        uuid NOT NULL REFERENCES public.sub_finder_job (job_id) ON DELETE CASCADE,
  tevo_event_id bigint NOT NULL,
  event_url     text NOT NULL,
  request_id    bigint,
  fired_at      timestamptz,
  resolved_at   timestamptz,
  status_code   integer,
  offers        integer,
  note          text,
  PRIMARY KEY (job_id, tevo_event_id)
);
CREATE INDEX IF NOT EXISTS sub_finder_td_pull_open ON public.sub_finder_td_pull (fired_at) WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS sub_finder_order_sync ON public.sub_finder_order (key_id, updated_at, job_id, idx);
CREATE INDEX IF NOT EXISTS sub_finder_order_number ON public.sub_finder_order (job_id, order_number);

ALTER TABLE public.sub_finder_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_finder_job    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_finder_order  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_finder_td_pull ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_config, public.sub_finder_job, public.sub_finder_order, public.sub_finder_td_pull
  FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.sub_finder_config, public.sub_finder_job, public.sub_finder_order,
  public.sub_finder_td_pull TO service_role;

-- What this key may do: {"enabled":…, "find":…, "buy":…}. Never raises.
CREATE OR REPLACE FUNCTION public.sub_finder_access(p_key_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'enabled', c.enabled,
    'find', c.enabled AND p_key_id = ANY (c.key_ids),
    'buy',  c.enabled AND c.buy_enabled AND p_key_id = ANY (c.key_ids) AND p_key_id = ANY (c.buy_key_ids),
    'max_orders_per_job', c.max_orders_per_job, 'ticketsdata_fallback', c.td_enabled)
  FROM public.sub_finder_config c;
$$;

-- Store a batch of orders, resolve their events, fire the pulls. Returns the job header.
--
-- BUILT AROUND HOW THE CRM HOLDS ORDERS. An order may be sent three ways:
--   * just its number        {"order_number": "JY8EGX10HP"}
--   * the CRM's own row      (routers/subs_api.py maps the CRM's field names onto ours)
--   * spelled out            order_number, section, row, qty, and an event
-- Whatever is missing is filled from OUR MIRROR of the CRM's two books, looked up by order
-- number: n2s_items first (the Need-to-Sub book, incl. the Gmail peddled orders), then
-- v_s4kcs_orders (the marketplace book). The mirror also carries the event our mappers already
-- resolved for that order, which beats matching an event by name: the CRM's names often differ
-- from Ticket Evolution's ("... (Thursday Night Football)").
--
-- The event is taken, in order: the tevo_event_id sent -> the mirror's -> an exact name + local
-- date that names exactly one event. Otherwise the order is 'unmapped' — never a guess.
-- An order with no section / row / quantity anywhere (not sent, not in the mirror) is not
-- stored; its number comes back in `not_found`.
CREATE OR REPLACE FUNCTION public.sub_finder_submit(
  p_key_id bigint, p_key_label text, p_orders jsonb, p_idempotency_key text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c       public.sub_finder_config;
  v_job   uuid;
  v_n     integer;
  v_evs   bigint[];
  v_miss  jsonb;
  v_idem  text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT c.enabled OR NOT (p_key_id = ANY (c.key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF v_idem IS NOT NULL THEN
    SELECT job_id INTO v_job FROM public.sub_finder_job WHERE key_id = p_key_id AND idempotency_key = v_idem;
    IF FOUND THEN
      RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                        'created_at', j.created_at, 'replayed', true)
              FROM public.sub_finder_job j WHERE j.job_id = v_job);
    END IF;
  END IF;
  IF jsonb_typeof(p_orders) IS DISTINCT FROM 'array' OR jsonb_array_length(p_orders) = 0 THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'orders must be a non-empty array');
  END IF;
  IF jsonb_array_length(p_orders) > c.max_orders_per_job THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', format('at most %s orders per job', c.max_orders_per_job));
  END IF;

  IF to_regclass('pg_temp._sf_in') IS NOT NULL THEN DROP TABLE _sf_in; END IF;
  CREATE TEMP TABLE _sf_in ON COMMIT DROP AS
  SELECT o.ord::int AS idx, btrim(o.j->>'order_number') AS order_number,
         coalesce(nullif(btrim(o.j->>'site'), ''), m.site)                 AS site,
         coalesce(nullif(btrim(o.j->>'section'), ''), m.section)           AS section,
         coalesce(nullif(btrim(o.j->>'row'), ''), m.seat_row)              AS seat_row,
         coalesce((o.j->>'qty')::int, m.qty)                               AS qty,
         coalesce((o.j->>'sold_ea')::numeric, m.sold_ea)                   AS sold_ea,
         (o.j->>'tevo_event_id')::bigint                                   AS sent_event,
         m.tevo_event_id                                                   AS book_event,
         coalesce(nullif(btrim(o.j->>'event_name'), ''), m.event_name)     AS event_name,
         coalesce((o.j->>'event_date')::date, m.event_date)                AS event_date,
         coalesce(nullif(btrim(o.j->>'venue'), ''), m.venue)               AS venue,
         m.book
  FROM jsonb_array_elements(p_orders) WITH ORDINALITY o(j, ord)
  LEFT JOIN LATERAL (
    SELECT u.* FROM (
      SELECT 1 AS pri, 'n2s'::text AS book, n.marketplace AS site, n.tevo_event_id, n.event_name,
             n.event_dt::date AS event_date, n.venue, n.section, n.row AS seat_row, n.qty,
             n.price_per_ticket AS sold_ea, n.pulled_at
      FROM public.n2s_items n
      WHERE n.order_number = btrim(o.j->>'order_number') OR n.n2s_order_key = btrim(o.j->>'order_number')
      UNION ALL
      SELECT 2, 'marketplace', v.source, v.tevo_event_id, v.event_name, v.event_date, v.venue_name,
             v.section, v.row, v.quantity, v.price_per_ticket, v.pulled_at
      FROM public.v_s4kcs_orders v
      WHERE v.s4k_order_id = btrim(o.j->>'order_number')) u
    ORDER BY u.pri, u.pulled_at DESC NULLS LAST LIMIT 1) m ON true;

  SELECT jsonb_agg(order_number ORDER BY idx) INTO v_miss FROM _sf_in
   WHERE section IS NULL OR seat_row IS NULL OR qty IS NULL OR qty NOT BETWEEN 1 AND 50;
  SELECT count(*) INTO v_n FROM _sf_in
   WHERE section IS NOT NULL AND seat_row IS NOT NULL AND qty BETWEEN 1 AND 50;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('error', 'not_found', 'not_found', v_miss,
      'detail', 'none of these orders is in the CRM books we mirror; send section, row, qty and the event');
  END IF;

  INSERT INTO public.sub_finder_job (key_id, key_label, idempotency_key, order_count)
  VALUES (p_key_id, p_key_label, v_idem, v_n) RETURNING job_id INTO v_job;

  INSERT INTO public.sub_finder_order (job_id, idx, key_id, order_number, site, tevo_event_id, event_name,
                                       event_date, venue, section, seat_row, qty, sold_ea, state, order_source)
  SELECT v_job, i.idx, p_key_id, i.order_number, i.site, ev.id, coalesce(ev.name, i.event_name),
         coalesce(ev.occurs_at_local::date, i.event_date), i.venue, i.section, i.seat_row, i.qty, i.sold_ea,
         CASE WHEN ev.id IS NULL THEN 'unmapped' ELSE 'pending' END,
         coalesce(i.book, 'request')
  FROM _sf_in i
  LEFT JOIN LATERAL (
    SELECT e.id, e.name, e.occurs_at_local
    FROM public.events e
    WHERE CASE WHEN i.sent_event IS NOT NULL THEN e.id = i.sent_event
               WHEN i.book_event IS NOT NULL THEN e.id = i.book_event
               ELSE lower(e.name) = lower(i.event_name) AND e.occurs_at_local::date = i.event_date
                    AND (SELECT count(*) FROM public.events e2
                         WHERE lower(e2.name) = lower(i.event_name)
                           AND e2.occurs_at_local::date = i.event_date) = 1
          END
    LIMIT 1) ev ON true
  WHERE i.section IS NOT NULL AND i.seat_row IS NOT NULL AND i.qty BETWEEN 1 AND 50;

  SELECT array_agg(DISTINCT tevo_event_id) INTO v_evs
  FROM public.sub_finder_order WHERE job_id = v_job AND tevo_event_id IS NOT NULL;
  IF v_evs IS NOT NULL THEN
    PERFORM public.n2s_pull_events(v_evs, c.pull_refresh);
  ELSE
    UPDATE public.sub_finder_job SET status = 'done', done_at = now(), updated_at = now() WHERE job_id = v_job;
  END IF;

  RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                    'created_at', j.created_at, 'replayed', false,
                                    'not_found', coalesce(v_miss, '[]'::jsonb),
                                    'unmapped', (SELECT count(*) FROM public.sub_finder_order o
                                                 WHERE o.job_id = v_job AND o.state = 'unmapped'))
          FROM public.sub_finder_job j WHERE j.job_id = v_job);
END
$$;

-- The newest job of this key that holds an order number: lets a caller address an order by
-- its number alone (read it, buy for it) without keeping job ids. NULL when there is none.
CREATE OR REPLACE FUNCTION public.sub_finder_latest_job(p_key_id bigint, p_order_number text)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT o.job_id FROM public.sub_finder_order o JOIN public.sub_finder_job j USING (job_id)
  WHERE o.key_id = p_key_id AND o.order_number = p_order_number
  ORDER BY j.created_at DESC, o.job_id LIMIT 1;
$$;

-- Rank the listings in the caller's temp table _sf_l against a job's still-'pending' orders
-- and store the covers. One rule for every market: same section, same row kind, the row the
-- same or better or up to rows_back behind; a quantity the listing's splits allow, the whole
-- lot when it is exactly the quantity, or a lot of exactly one more. Returns orders touched.
-- p_td_answered: take only the orders whose TicketsData pull has answered (the fallback pass).
CREATE OR REPLACE FUNCTION public.sub_finder_match(p_job_id uuid, p_td_answered boolean DEFAULT false)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  v_back integer := (SELECT rows_back FROM public.sub_finder_config);
  v_n    integer;
BEGIN
  WITH o AS (
    SELECT * FROM public.sub_finder_order
    WHERE job_id = p_job_id AND state = 'pending' AND (NOT p_td_answered OR td_state IN ('searched', 'failed'))
  ), cand AS (
    SELECT o.job_id, o.idx, o.qty, o.sold_ea, l.*,
           CASE WHEN o.qty = ANY (l.sp) OR l.quantity = o.qty THEN o.qty
                WHEN l.quantity = o.qty + 1 THEN o.qty + 1 END AS buy_qty,
           public.seat_row_rank(l.seat_row) - public.seat_row_rank(o.seat_row) AS row_delta
    FROM o JOIN _sf_l l ON l.eid = o.tevo_event_id
     AND public.seat_section_norm(l.section) = public.seat_section_norm(o.section)
     AND public.seat_row_kind(l.seat_row) = public.seat_row_kind(o.seat_row)
     AND public.seat_row_rank(l.seat_row) <= public.seat_row_rank(o.seat_row) + v_back
    WHERE l.px > 0 AND l.quantity > 0
  ), ranked AS (
    SELECT *, buy_qty * px AS total,
           CASE WHEN sold_ea IS NOT NULL THEN round(sold_ea * qty - buy_qty * px, 2) END AS profit,
           row_number() OVER (PARTITION BY job_id, idx, market
                              ORDER BY (row_delta > 0), buy_qty * px, lid) AS rn
    FROM cand WHERE buy_qty IS NOT NULL
  ), per_order AS (
    SELECT job_id, idx,
           jsonb_agg(jsonb_build_object(
             'market', market, 'source', via, 'listing_id', lid, 'section', section, 'row', seat_row,
             'listing_qty', quantity, 'buy_qty', buy_qty, 'spare', buy_qty - qty,
             'price_ea', px, 'total', round(total, 2), 'profit', profit, 'price_note', price_note,
             'row_relation', CASE WHEN row_delta < 0 THEN 'better' WHEN row_delta = 0 THEN 'same' ELSE 'back' END,
             'link', link, 'buyable', market = 'evo', 'listing_seen_at', pulled_at)
             ORDER BY (row_delta > 0), total, lid) AS covers
    FROM ranked WHERE rn <= 3 GROUP BY job_id, idx
  )
  UPDATE public.sub_finder_order t
     SET covers = coalesce(p.covers, '[]'::jsonb),
         best   = p.covers -> 0,                    -- same-or-better row first, then cheapest
         state  = CASE WHEN p.covers IS NULL THEN 'no_cover' ELSE 'cover' END,
         updated_at = now()
    FROM o LEFT JOIN per_order p ON p.job_id = o.job_id AND p.idx = o.idx
   WHERE t.job_id = o.job_id AND t.idx = o.idx;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$$;

-- Move a job forward as far as its pulls allow. Idempotent; called on read, so no cron.
--   pulling     wait for the EVO / GoTickets / SeatGeek pulls, then match
--   pulling_td  only for orders still uncovered: TicketsData, a few events at a time
--   done
CREATE OR REPLACE FUNCTION public.sub_finder_settle(p_job_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, extensions, pg_temp
AS $$
DECLARE
  c      public.sub_finder_config;
  j      public.sub_finder_job;
  r      record;
  v_open integer;
  v_user text;
  v_pass text;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  SELECT * INTO j FROM public.sub_finder_job WHERE job_id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF j.status = 'done' THEN RETURN 'done'; END IF;

  -- the listings to rank, for sub_finder_match (one table per transaction; several jobs may settle in one)
  IF to_regclass('pg_temp._sf_l') IS NULL THEN
    CREATE TEMP TABLE _sf_l (
      market text, via text, eid bigint, lid text, section text, seat_row text, quantity integer,
      px numeric, sp integer[], pulled_at timestamptz, link text, price_note text) ON COMMIT DROP;
  END IF;
  TRUNCATE _sf_l;

  IF j.status = 'pulling' THEN
    IF now() < j.created_at + make_interval(secs => c.settle_min_s) THEN RETURN 'pulling'; END IF;
    IF now() < j.created_at + make_interval(secs => c.settle_timeout_s) AND EXISTS (
         -- an event with a pull still out, or with no answered pull at all since the job began
         SELECT 1 FROM (SELECT DISTINCT tevo_event_id FROM public.sub_finder_order
                        WHERE job_id = p_job_id AND tevo_event_id IS NOT NULL) e
         WHERE EXISTS (SELECT 1 FROM public.n2s_mkt_pull p
                       WHERE p.tevo_event_id = e.tevo_event_id
                         AND p.fired_at >= j.created_at - c.pull_refresh AND p.resolved_at IS NULL)
            OR NOT EXISTS (SELECT 1 FROM public.n2s_mkt_pull p
                           WHERE p.tevo_event_id = e.tevo_event_id
                             AND p.fired_at >= j.created_at - c.pull_refresh AND p.resolved_at IS NOT NULL)) THEN
      RETURN 'pulling';
    END IF;

    INSERT INTO _sf_l
    SELECT 'evo', 'native', x.event_id, x.tevo_ticket_group_id::text, x.section, x.row, x.quantity,
           x.retail_price, x.splits::int[], x.pulled_at,
           'https://core.ticketevolution.com/buy/event/' || x.event_id || '/tickets/' || x.tevo_ticket_group_id, NULL
    FROM public.n2s_evo_current x
    WHERE x.event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
      AND NOT coalesce(x.is_owned, false) AND NOT coalesce(x.is_ancillary, false)
    UNION ALL
    SELECT 'gotickets', 'native', x.tevo_event_id, x.gt_listing_id::text, x.section, x.row, x.quantity,
           x.all_in_price, x.splits::int[], x.pulled_at,
           'https://pro.gotickets.com/tickets/' || x.gt_event_id || '/?sortBy=price&sortDirection=asc', NULL
    FROM public.n2s_gt_current x
    WHERE x.tevo_event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
    UNION ALL
    -- SeatGeek link: the stored event URL plus the listing's display id — both or neither
    -- (see mig 20260910310000: half a link is worse than none).
    SELECT 'seatgeek', 'native', x.tevo_event_id, x.sglid::text, x.section, x.row, x.quantity,
           x.retail_price_all_in,
           ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(x.splits) = 'array' THEN x.splits
                                                       ELSE '[]'::jsonb END)::int),
           x.pulled_at,
           CASE WHEN sg.sg_url IS NOT NULL AND x.display_id IS NOT NULL
                THEN sg.sg_url || '#listing=' || x.display_id END, NULL
    FROM public.n2s_sg_current x
    LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = x.sg_event_id
    WHERE x.tevo_event_id IN (SELECT tevo_event_id FROM public.sub_finder_order WHERE job_id = p_job_id)
      AND NOT coalesce(x.is_broker_owned, false);
    PERFORM public.sub_finder_match(p_job_id);

    -- TicketsData: only events that still have an uncovered order, cheapest way in first
    -- (most uncovered orders per credit), capped per job.
    IF c.td_enabled THEN
      INSERT INTO public.sub_finder_td_pull (job_id, tevo_event_id, event_url)
      SELECT p_job_id, e.tevo_event_id, 'https://www.stubhub.com/event/' || x.sh_event_id
      FROM (SELECT tevo_event_id, count(*) AS n FROM public.sub_finder_order
            WHERE job_id = p_job_id AND state = 'no_cover' GROUP BY 1) e
      JOIN LATERAL (SELECT a.sh_event_id FROM public.aq_event_map a
                    WHERE a.tevo_event_id = e.tevo_event_id AND a.sh_event_id IS NOT NULL
                    ORDER BY a.id LIMIT 1) x ON true
      ORDER BY e.n DESC, e.tevo_event_id LIMIT c.td_max_events_per_job
      ON CONFLICT DO NOTHING;
      UPDATE public.sub_finder_order o
         SET td_state = CASE
               WHEN EXISTS (SELECT 1 FROM public.sub_finder_td_pull p
                            WHERE p.job_id = o.job_id AND p.tevo_event_id = o.tevo_event_id) THEN 'queued'
               WHEN EXISTS (SELECT 1 FROM public.aq_event_map a
                            WHERE a.tevo_event_id = o.tevo_event_id AND a.sh_event_id IS NOT NULL) THEN 'over_limit'
               ELSE 'no_event_link' END
       WHERE o.job_id = p_job_id AND o.state = 'no_cover';
      -- a queued order is not answered yet: hold it back as 'pending' until TicketsData is in
      UPDATE public.sub_finder_order SET state = 'pending'
       WHERE job_id = p_job_id AND td_state = 'queued';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sub_finder_td_pull WHERE job_id = p_job_id) THEN
      UPDATE public.sub_finder_job SET status = 'done', done_at = now(), updated_at = now() WHERE job_id = p_job_id;
      RETURN 'done';
    END IF;
    UPDATE public.sub_finder_job SET status = 'pulling_td', updated_at = now() WHERE job_id = p_job_id;
    TRUNCATE _sf_l;
  END IF;

  -- ── pulling_td ──────────────────────────────────────────────────────────────────────────
  -- 1. land every answer that has arrived (or give up on one that is overdue)
  FOR r IN
    SELECT p.tevo_event_id, p.fired_at, h.id AS resp_id, h.status_code, h.content, h.timed_out
    FROM public.sub_finder_td_pull p
    LEFT JOIN net._http_response h ON h.id = p.request_id
    WHERE p.job_id = p_job_id AND p.request_id IS NOT NULL AND p.resolved_at IS NULL
      AND (h.id IS NOT NULL OR p.fired_at < now() - make_interval(secs => c.td_timeout_s))
  LOOP
    BEGIN
      IF r.resp_id IS NULL OR r.status_code IS DISTINCT FROM 200 OR r.content !~ '^\s*\{' THEN
        RAISE EXCEPTION 'no usable answer';
      END IF;
      INSERT INTO _sf_l
      SELECT CASE pl.key WHEN 'vividseats' THEN 'vivid' ELSE pl.key END, 'ticketsdata', r.tevo_event_id,
             x->>'listing_id', x->>'section', x->>'row', (x->>'quantity')::int, (x->>'price_total')::numeric,
             ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(x->'available_lots') = 'array'
                                                         THEN x->'available_lots' ELSE '[]'::jsonb END)::int),
             now(), r.content::jsonb->'matches'->>pl.key,
             CASE WHEN pl.key IN ('stubhub', 'viagogo') THEN 'before buyer fees' END
      FROM jsonb_each(r.content::jsonb->'fetch_results'->'normalized') pl,
           jsonb_array_elements(CASE WHEN jsonb_typeof(pl.value->'offers') = 'array'
                                     THEN pl.value->'offers' ELSE '[]'::jsonb END) x
      WHERE pl.key NOT IN ('seatgeek', 'dice')              -- SeatGeek is already searched natively
        AND NOT coalesce((x->'flags'->>'parking')::boolean, false)
        AND x->>'section' IS NOT NULL AND x->>'row' IS NOT NULL
        AND (x->>'quantity') ~ '^\d+$' AND (x->>'price_total') ~ '^\d+(\.\d+)?$';
      UPDATE public.sub_finder_td_pull
         SET resolved_at = now(), status_code = r.status_code,
             offers = (SELECT count(*) FROM _sf_l WHERE eid = r.tevo_event_id)
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      UPDATE public.sub_finder_order SET td_state = 'searched'
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
    EXCEPTION WHEN OTHERS THEN
      UPDATE public.sub_finder_td_pull
         SET resolved_at = now(), status_code = r.status_code,
             note = CASE WHEN r.resp_id IS NULL THEN 'timeout' WHEN r.timed_out THEN 'timeout'
                         WHEN r.status_code = 429 THEN 'rate_limited' ELSE 'unusable_answer' END
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      UPDATE public.sub_finder_order SET td_state = 'failed'
       WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
    END;
  END LOOP;
  -- match the orders whose event has now answered (the rest stay pending)
  IF EXISTS (SELECT 1 FROM public.sub_finder_order
             WHERE job_id = p_job_id AND state = 'pending' AND td_state IN ('searched', 'failed')) THEN
    PERFORM public.sub_finder_match(p_job_id, true);   -- a failed pull has no rows: those end 'no_cover'
  END IF;

  -- 2. fire the next ones, never more in flight (across all jobs) than the account allows
  SELECT count(*) INTO v_open FROM public.sub_finder_td_pull
   WHERE request_id IS NOT NULL AND resolved_at IS NULL
     AND fired_at > now() - make_interval(secs => c.td_timeout_s);
  IF v_open < c.td_concurrency
     AND EXISTS (SELECT 1 FROM public.sub_finder_td_pull WHERE job_id = p_job_id AND request_id IS NULL) THEN
    v_user := public.get_app_secret('TICKETSDATA_USERNAME');
    v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');
    FOR r IN SELECT tevo_event_id, event_url FROM public.sub_finder_td_pull
              WHERE job_id = p_job_id AND request_id IS NULL
              ORDER BY tevo_event_id LIMIT c.td_concurrency - v_open
    LOOP
      IF coalesce(v_user, '') = '' OR coalesce(v_pass, '') = '' THEN
        UPDATE public.sub_finder_td_pull SET resolved_at = now(), note = 'no_credentials'
         WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
        UPDATE public.sub_finder_order SET td_state = 'failed', state = 'no_cover', updated_at = now()
         WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id AND td_state = 'queued';
      ELSE
        UPDATE public.sub_finder_td_pull
           SET fired_at = now(),
               request_id = net.http_get(
                 url := 'https://ticketsdata.com/match',
                 params := jsonb_build_object('event_url', r.event_url, 'username', v_user, 'password', v_pass),
                 headers := '{}'::jsonb,
                 timeout_milliseconds := c.td_timeout_s * 1000 - 5000)
         WHERE job_id = p_job_id AND tevo_event_id = r.tevo_event_id;
      END IF;
    END LOOP;
  END IF;

  -- 3. finished when nothing is left to fire or to wait for
  IF NOT EXISTS (SELECT 1 FROM public.sub_finder_td_pull WHERE job_id = p_job_id AND resolved_at IS NULL) THEN
    UPDATE public.sub_finder_job SET status = 'done', done_at = now(), updated_at = now() WHERE job_id = p_job_id;
    RETURN 'done';
  END IF;
  RETURN 'pulling_td';
END
$$;

-- One order as the API returns it.
CREATE OR REPLACE FUNCTION public.sub_finder_order_json(o public.sub_finder_order)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'job_id', o.job_id, 'order_number', o.order_number, 'site', o.site,
    'tevo_event_id', o.tevo_event_id, 'event_name', o.event_name, 'event_date', o.event_date, 'venue', o.venue,
    'section', o.section, 'row', o.seat_row, 'qty', o.qty, 'sold_ea', o.sold_ea,
    'order_source', o.order_source, 'state', o.state, 'best', o.best, 'covers', o.covers,
    'markets_searched', CASE WHEN o.state IN ('cover', 'no_cover')
                             THEN to_jsonb(ARRAY['evo', 'gotickets', 'seatgeek']
                                           || CASE WHEN o.td_state = 'searched' THEN ARRAY['ticketsdata']
                                                   ELSE ARRAY[]::text[] END) END,
    'ticketsdata', o.td_state,
    -- request_state: requested -> buying -> bought | stopped | unknown (our side).
    -- outcome: the seller's answer once bought: pending -> confirmed | rejected | canceled.
    'buy', (SELECT jsonb_build_object(
                     'buy_id', b.buy_id, 'request_state', b.state, 'reasons', b.reasons,
                     'evo_order_id', b.buy_order_id, 'outcome', b.outcome,
                     'seller_state', b.seller_state, 'order_state', b.order_state,
                     'rejection_reason', b.rejection_reason,
                     'qty', b.qty, 'price_ea', b.bought_price_ea,
                     'total', coalesce(b.order_total_usd, b.bought_total_usd),
                     'section', b.bought_section, 'row', b.bought_row, 'seats', b.seats,
                     'status_checked_at', b.status_checked_at, 'final_at', b.final_at)
            FROM public.manual_sub_buy b WHERE b.buy_id = o.buy_id),
    'updated_at', to_char(o.updated_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
$$;

-- Read one job (settling it first if its pulls are in). NULL when the job is not this key's.
CREATE OR REPLACE FUNCTION public.sub_finder_job_json(p_key_id bigint, p_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sub_finder_job WHERE job_id = p_job_id AND key_id = p_key_id) THEN
    RETURN NULL;
  END IF;
  PERFORM public.sub_finder_settle(p_job_id);
  RETURN (
    SELECT jsonb_build_object(
      'job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
      'created_at', j.created_at, 'done_at', j.done_at,
      'summary', (SELECT jsonb_object_agg(s.state, s.n) FROM (
                    SELECT o.state, count(*) AS n FROM public.sub_finder_order o
                    WHERE o.job_id = j.job_id GROUP BY o.state) s),
      'items', (SELECT coalesce(jsonb_agg(public.sub_finder_order_json(o) ORDER BY o.idx), '[]'::jsonb)
                FROM public.sub_finder_order o WHERE o.job_id = j.job_id))
    FROM public.sub_finder_job j WHERE j.job_id = p_job_id);
END
$$;

-- Read one order of a job (settling the job first). NULL when it is not this key's.
CREATE OR REPLACE FUNCTION public.sub_finder_order_read(p_key_id bigint, p_job_id uuid, p_order_number text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.sub_finder_order
                 WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number) THEN
    RETURN NULL;
  END IF;
  PERFORM public.sub_finder_settle(p_job_id);
  RETURN (SELECT jsonb_build_object(
            'items', jsonb_agg(public.sub_finder_order_json(o) ORDER BY o.idx), 'count', count(*))
          FROM public.sub_finder_order o
          WHERE o.job_id = p_job_id AND o.key_id = p_key_id AND o.order_number = p_order_number);
END
$$;

-- A buy that changed (bought, confirmed, rejected, seats arrived) moves its order's
-- updated_at, so the sync feed hands that order out again.
CREATE OR REPLACE FUNCTION public.sub_finder_buy_touch_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
BEGIN
  IF (NEW.state, NEW.outcome, NEW.buy_order_id, NEW.seats, NEW.order_total_usd, NEW.seller_state)
     IS DISTINCT FROM
     (OLD.state, OLD.outcome, OLD.buy_order_id, OLD.seats, OLD.order_total_usd, OLD.seller_state) THEN
    UPDATE public.sub_finder_order SET updated_at = now() WHERE buy_id = NEW.buy_id;
  END IF;
  RETURN NULL;
END
$$;
DROP TRIGGER IF EXISTS sub_finder_buy_touch ON public.manual_sub_buy;
CREATE TRIGGER sub_finder_buy_touch AFTER UPDATE ON public.manual_sub_buy
  FOR EACH ROW EXECUTE FUNCTION public.sub_finder_buy_touch_trg();
CREATE INDEX IF NOT EXISTS sub_finder_order_buy ON public.sub_finder_order (buy_id) WHERE buy_id IS NOT NULL;

-- The sync feed: this key's orders changed at or after p_updated_since, oldest change first,
-- in the CRM's own envelope. Feed `generated_at` back as the next `updated_since`.
CREATE OR REPLACE FUNCTION public.sub_finder_results(
  p_key_id bigint, p_updated_since timestamptz DEFAULT NULL, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  v_now   timestamptz := now();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
  r       record;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  -- settle this key's open jobs first, so a caller that only ever syncs still gets answers
  FOR r IN SELECT job_id FROM public.sub_finder_job WHERE key_id = p_key_id AND status <> 'done' LOOP
    PERFORM public.sub_finder_settle(r.job_id);
  END LOOP;
  RETURN (
    WITH f AS (
      SELECT o.* FROM public.sub_finder_order o
      WHERE o.key_id = p_key_id AND o.state <> 'pending'
        AND (p_updated_since IS NULL OR o.updated_at >= p_updated_since)
    ), page AS (
      SELECT * FROM f ORDER BY updated_at, job_id, idx LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off,
      'items', (SELECT coalesce(jsonb_agg(public.sub_finder_order_json(p) ORDER BY p.updated_at, p.job_id, p.idx),
                                '[]'::jsonb) FROM page p),
      'generated_at', to_char(v_now AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$$;

-- Ask for one quoted EVO cover to be bought. Files a manual_sub_buy request; that path's own
-- switches, ceilings and one-per-sale rule decide whether anything is actually sent.
CREATE OR REPLACE FUNCTION public.sub_finder_buy(
  p_key_id bigint, p_key_label text, p_job_id uuid, p_order_number text, p_listing_id text,
  p_requested_by text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  o     public.sub_finder_order;
  cv    jsonb;
  v_buy bigint;
  v_n   integer;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'buy')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'buying is not enabled for this key');
  END IF;
  SELECT count(*) INTO v_n FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number;
  IF v_n = 0 THEN RETURN jsonb_build_object('error', 'not_found', 'detail', 'no such order in this job'); END IF;
  IF v_n > 1 THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'this order number appears more than once in the job');
  END IF;
  SELECT * INTO o FROM public.sub_finder_order
   WHERE job_id = p_job_id AND key_id = p_key_id AND order_number = p_order_number FOR UPDATE;
  IF o.buy_id IS NOT NULL THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy was already requested for this order',
                              'buy_id', o.buy_id);
  END IF;
  SELECT x INTO cv FROM jsonb_array_elements(o.covers) x
   WHERE x->>'market' = 'evo' AND x->>'listing_id' = p_listing_id LIMIT 1;
  IF cv IS NULL THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', 'that listing is not an EVO cover this job quoted for this order');
  END IF;
  BEGIN
    v_buy := public.manual_sub_buy_request(
      coalesce(o.site, 'CRM'), o.order_number, o.tevo_event_id, (cv->>'listing_id')::bigint,
      (cv->>'buy_qty')::int, (cv->>'price_ea')::numeric, o.sold_ea, o.event_name,
      'crm api key ' || coalesce(p_key_label, p_key_id::text)
        || coalesce(' / ' || nullif(btrim(p_requested_by), ''), ''),
      'sub finder job ' || p_job_id || ': sold ' || o.section || ' row ' || o.seat_row || ' x' || o.qty
        || '; sub ' || (cv->>'section') || ' row ' || (cv->>'row') || ' x' || (cv->>'buy_qty'));
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'a buy already exists for this sale');
  END;
  UPDATE public.sub_finder_order SET buy_id = v_buy, updated_at = now()
   WHERE job_id = o.job_id AND idx = o.idx;
  RETURN jsonb_build_object('buy_id', v_buy, 'state', 'requested', 'order_number', o.order_number,
                            'listing_id', cv->>'listing_id', 'qty', (cv->>'buy_qty')::int,
                            'max_price_ea', (cv->>'price_ea')::numeric);
END
$$;

REVOKE ALL ON FUNCTION public.sub_finder_access(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_submit(bigint, text, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_settle(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_latest_job(bigint, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_match(uuid, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_order_read(bigint, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_buy_touch_trg() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_order_json(public.sub_finder_order) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_job_json(bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_results(bigint, timestamptz, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_buy(bigint, text, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_access(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_submit(bigint, text, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_settle(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_latest_job(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_match(uuid, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_order_read(bigint, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_order_json(public.sub_finder_order) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_job_json(bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_results(bigint, timestamptz, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_buy(bigint, text, uuid, text, text, text) TO service_role;
