-- Migration 20261112000000 · level:secondary-sales · lane:D0 · writes:sub_finder_config,sub_finder_job,sub_finder_order,sub_finder_submit,sub_finder_settle,sub_finder_job_json,sub_finder_results,sub_finder_buy · reads:events,n2s_evo_current,n2s_gt_current,n2s_sg_current,n2s_mkt_pull,sg_events_canonical,manual_sub_buy · pre:20261111020000
--
-- SUB FINDER API: a CRM user sends orders, gets back the best substitute per order.
--
-- Operator 2026-11-12, after a sheet tab of 30 failed orders was matched by hand in a session:
-- "turn this into an out bound api trigger where crm user can auto get subs for orders".
-- Answers given the same day: the CRM calls us and reads the answer back (no webhook); the CRM
-- may send ANY order (event + section + row + quantity + sale price), not only ones already in
-- the N2S book; and a CRM user may ask for an EVO cover to be bought.
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
--   read     one job, or every order changed since a cursor.
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
-- rollback: DROP FUNCTION public.sub_finder_buy(bigint, text, uuid, text, text, text),
--             public.sub_finder_results(bigint, timestamptz, integer, integer),
--             public.sub_finder_job_json(bigint, uuid), public.sub_finder_settle(uuid),
--             public.sub_finder_order_json(public.sub_finder_order),
--             public.sub_finder_submit(bigint, text, jsonb, text), public.sub_finder_access(bigint);
--           DROP TABLE public.sub_finder_order, public.sub_finder_job, public.sub_finder_config;

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
  updated_at         timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.sub_finder_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.sub_finder_job (
  job_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key_id          bigint NOT NULL,
  key_label       text,
  idempotency_key text,
  status          text NOT NULL DEFAULT 'pulling' CHECK (status IN ('pulling', 'done')),
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
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (job_id, idx)
);
CREATE INDEX IF NOT EXISTS sub_finder_order_sync ON public.sub_finder_order (key_id, updated_at, job_id, idx);
CREATE INDEX IF NOT EXISTS sub_finder_order_number ON public.sub_finder_order (job_id, order_number);

ALTER TABLE public.sub_finder_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_finder_job    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sub_finder_order  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sub_finder_config, public.sub_finder_job, public.sub_finder_order FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.sub_finder_config, public.sub_finder_job, public.sub_finder_order TO service_role;

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
    'max_orders_per_job', c.max_orders_per_job)
  FROM public.sub_finder_config c;
$$;

-- Store a batch of orders, resolve their events, fire the pulls. Returns the job header.
-- p_orders: [{order_number, site?, tevo_event_id? | event_name + event_date, venue?, section, row, qty, sold_ea?}]
CREATE OR REPLACE FUNCTION public.sub_finder_submit(
  p_key_id bigint, p_key_label text, p_orders jsonb, p_idempotency_key text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c      public.sub_finder_config;
  v_job  uuid;
  v_n    integer;
  v_evs  bigint[];
  v_idem text := nullif(btrim(coalesce(p_idempotency_key, '')), '');
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
  v_n := jsonb_array_length(p_orders);
  IF v_n > c.max_orders_per_job THEN
    RETURN jsonb_build_object('error', 'invalid',
                              'detail', format('at most %s orders per job', c.max_orders_per_job));
  END IF;

  INSERT INTO public.sub_finder_job (key_id, key_label, idempotency_key, order_count)
  VALUES (p_key_id, p_key_label, v_idem, v_n) RETURNING job_id INTO v_job;

  -- An event is taken on its id when we hold that event, else on an exact name + local date
  -- that names exactly one event. Anything else is 'unmapped' — never a guess.
  INSERT INTO public.sub_finder_order (job_id, idx, key_id, order_number, site, tevo_event_id, event_name,
                                       event_date, venue, section, seat_row, qty, sold_ea, state)
  SELECT v_job, o.ord::int, p_key_id, btrim(o.j->>'order_number'), nullif(btrim(o.j->>'site'), ''),
         ev.id, coalesce(ev.name, nullif(btrim(o.j->>'event_name'), '')),
         coalesce(ev.occurs_at_local::date, (o.j->>'event_date')::date), nullif(btrim(o.j->>'venue'), ''),
         btrim(o.j->>'section'), btrim(o.j->>'row'), (o.j->>'qty')::int, (o.j->>'sold_ea')::numeric,
         CASE WHEN ev.id IS NULL THEN 'unmapped' ELSE 'pending' END
  FROM jsonb_array_elements(p_orders) WITH ORDINALITY o(j, ord)
  LEFT JOIN LATERAL (
    SELECT e.id, e.name, e.occurs_at_local
    FROM public.events e
    WHERE CASE WHEN (o.j->>'tevo_event_id') IS NOT NULL THEN e.id = (o.j->>'tevo_event_id')::bigint
               ELSE lower(e.name) = lower(btrim(o.j->>'event_name'))
                    AND e.occurs_at_local::date = (o.j->>'event_date')::date
                    AND (SELECT count(*) FROM public.events e2
                         WHERE lower(e2.name) = lower(btrim(o.j->>'event_name'))
                           AND e2.occurs_at_local::date = (o.j->>'event_date')::date) = 1
          END
    LIMIT 1) ev ON true;

  SELECT array_agg(DISTINCT tevo_event_id) INTO v_evs
  FROM public.sub_finder_order WHERE job_id = v_job AND tevo_event_id IS NOT NULL;
  IF v_evs IS NOT NULL THEN
    PERFORM public.n2s_pull_events(v_evs, c.pull_refresh);
  ELSE
    UPDATE public.sub_finder_job SET status = 'done', done_at = now(), updated_at = now() WHERE job_id = v_job;
  END IF;

  RETURN (SELECT jsonb_build_object('job_id', j.job_id, 'status', j.status, 'order_count', j.order_count,
                                    'created_at', j.created_at, 'replayed', false,
                                    'unmapped', (SELECT count(*) FROM public.sub_finder_order o
                                                 WHERE o.job_id = v_job AND o.state = 'unmapped'))
          FROM public.sub_finder_job j WHERE j.job_id = v_job);
END
$$;

-- Match a job's orders against the fresh listings, once its pulls have answered. Idempotent:
-- a 'done' job is left alone. Called on read, so there is no cron.
CREATE OR REPLACE FUNCTION public.sub_finder_settle(p_job_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c public.sub_finder_config;
  j public.sub_finder_job;
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  SELECT * INTO j FROM public.sub_finder_job WHERE job_id = p_job_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF j.status = 'done' THEN RETURN 'done'; END IF;
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

  WITH o AS (
    SELECT * FROM public.sub_finder_order WHERE job_id = p_job_id AND state = 'pending'
  ), l AS (
    SELECT 'evo'::text AS market, x.event_id AS eid, x.tevo_ticket_group_id::text AS lid, x.section, x.row,
           x.quantity, x.retail_price AS px, x.splits::int[] AS sp, x.pulled_at,
           'https://core.ticketevolution.com/buy/event/' || x.event_id || '/tickets/' || x.tevo_ticket_group_id AS link
    FROM public.n2s_evo_current x
    WHERE x.event_id IN (SELECT tevo_event_id FROM o)
      AND NOT coalesce(x.is_owned, false) AND NOT coalesce(x.is_ancillary, false)
    UNION ALL
    SELECT 'gotickets', x.tevo_event_id, x.gt_listing_id::text, x.section, x.row, x.quantity, x.all_in_price,
           x.splits::int[], x.pulled_at,
           'https://pro.gotickets.com/tickets/' || x.gt_event_id || '/?sortBy=price&sortDirection=asc'
    FROM public.n2s_gt_current x WHERE x.tevo_event_id IN (SELECT tevo_event_id FROM o)
    UNION ALL
    -- SeatGeek link: the stored event URL plus the listing's display id — both or neither
    -- (see mig 20260910310000: half a link is worse than none).
    SELECT 'seatgeek', x.tevo_event_id, x.sglid::text, x.section, x.row, x.quantity, x.retail_price_all_in,
           ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(x.splits) = 'array' THEN x.splits
                                                       ELSE '[]'::jsonb END)::int),
           x.pulled_at,
           CASE WHEN s.sg_url IS NOT NULL AND x.display_id IS NOT NULL
                THEN s.sg_url || '#listing=' || x.display_id END
    FROM public.n2s_sg_current x
    LEFT JOIN public.sg_events_canonical s ON s.sg_event_id = x.sg_event_id
    WHERE x.tevo_event_id IN (SELECT tevo_event_id FROM o) AND NOT coalesce(x.is_broker_owned, false)
  ), cand AS (
    SELECT o.job_id, o.idx, o.qty, o.sold_ea, l.*,
           CASE WHEN o.qty = ANY (l.sp) THEN o.qty WHEN l.quantity = o.qty + 1 THEN o.qty + 1 END AS buy_qty,
           public.seat_row_rank(l.row) - public.seat_row_rank(o.seat_row) AS row_delta
    FROM o JOIN l ON l.eid = o.tevo_event_id
     AND public.seat_section_norm(l.section) = public.seat_section_norm(o.section)
     AND public.seat_row_kind(l.row) = public.seat_row_kind(o.seat_row)
     AND public.seat_row_rank(l.row) <= public.seat_row_rank(o.seat_row) + c.rows_back
    WHERE l.px > 0
  ), ranked AS (
    SELECT *, buy_qty * px AS total,
           CASE WHEN sold_ea IS NOT NULL THEN round(sold_ea * qty - buy_qty * px, 2) END AS profit,
           row_number() OVER (PARTITION BY job_id, idx, market
                              ORDER BY (row_delta > 0), buy_qty * px, lid) AS rn
    FROM cand WHERE buy_qty IS NOT NULL
  ), per_order AS (
    SELECT job_id, idx,
           jsonb_agg(jsonb_build_object(
             'market', market, 'listing_id', lid, 'section', section, 'row', row,
             'listing_qty', quantity, 'buy_qty', buy_qty, 'spare', buy_qty - qty,
             'price_ea', px, 'total', round(total, 2), 'profit', profit,
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

  UPDATE public.sub_finder_job SET status = 'done', done_at = now(), updated_at = now() WHERE job_id = p_job_id;
  RETURN 'done';
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
    'state', o.state, 'best', o.best, 'covers', o.covers,
    'buy', (SELECT jsonb_build_object('buy_id', b.buy_id, 'state', b.state, 'evo_order_id', b.buy_order_id,
                                      'evo_state', b.buy_state, 'total', b.bought_total_usd, 'reasons', b.reasons)
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
  FOR r IN SELECT job_id FROM public.sub_finder_job WHERE key_id = p_key_id AND status = 'pulling' LOOP
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
REVOKE ALL ON FUNCTION public.sub_finder_order_json(public.sub_finder_order) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_job_json(bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_results(bigint, timestamptz, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sub_finder_buy(bigint, text, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_access(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_submit(bigint, text, jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_settle(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_order_json(public.sub_finder_order) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_job_json(bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_results(bigint, timestamptz, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.sub_finder_buy(bigint, text, uuid, text, text, text) TO service_role;
