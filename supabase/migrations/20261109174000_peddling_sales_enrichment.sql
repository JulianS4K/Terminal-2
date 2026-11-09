-- Migration 20261109174000 · level:secondary-sales · lane:D0 · writes:peddling_sales,peddling_sales_enrich,peddling_sales_ingest_from_apps_script · reads:s4kcs_orders,vivid_orders · pre:20261109172023
--
-- ============================================================================
-- Migration 20261109174000 — enrich peddled sales with marketplace order data
--
-- Lane:     D0 (orders)
-- Touches:  peddling_sales (W), s4kcs_orders (R), vivid_orders (R)
-- Pre-reqs: 20261109172023 (peddling_sales + ingest RPC)
--
-- WHAT: the sale email only carries the ticket. The marketplace order books we
-- already ingest carry more, so each peddled sale is matched to them on its
-- marketplace order id (peddling_sales.site_order) and these are filled in:
--   * market_status            <- s4kcs_orders.order_status (every marketplace;
--                                 matched 36/36 on 2026-11-09)
--   * event_city / event_state <- s4kcs_orders.venue_city/state, else the most
--                                 common city/state seen for that venue name in
--                                 s4kcs_orders (Gametime + Vivid rows carry no
--                                 city); state normalised to its 2-letter code
--   * customer_name / _email   <- vivid_orders.raw_xml firstName/lastName/
--                                 emailAddress (Vivid Seats only: 6/6)
-- Measured on the 36 sales of 2026-11-09: GoTickets marks the buyer contact
-- hidden (buyerContactHidden), TickPick's order feed returns an empty
-- `customer` object (0 of 2,578 stored orders), and there is no Viagogo or
-- Gametime order feed. Those sales get status + city/state but no customer.
--
-- The ingest RPC now runs the enrichment for the sales it received and
-- returns those fields in `rows`, so the Apps Script fills the sheet's
-- Customer Name / Customer Email / City / State (Event) / Status from one
-- call. No new anon-callable surface: the enrich function is service_role
-- only, and the ingest RPC keeps its shared-secret gate.
-- Read-only on every source table; nothing upstream is called.
-- ============================================================================

-- 1. columns ----------------------------------------------------------------------
ALTER TABLE public.peddling_sales
  ADD COLUMN IF NOT EXISTS customer_name  text,
  ADD COLUMN IF NOT EXISTS customer_email text,
  ADD COLUMN IF NOT EXISTS event_city     text,
  ADD COLUMN IF NOT EXISTS event_state    text,
  ADD COLUMN IF NOT EXISTS market_status  text,
  ADD COLUMN IF NOT EXISTS market_source  text,     -- s4kcs_orders.source it matched
  ADD COLUMN IF NOT EXISTS enriched_at    timestamptz;

-- 2. enrichment -------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.peddling_sales_enrich(p_ids bigint[] DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'peddling_sales_enrich: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;

  WITH st(name, code) AS (VALUES
    ('alabama','AL'),('alaska','AK'),('arizona','AZ'),('arkansas','AR'),('california','CA'),
    ('colorado','CO'),('connecticut','CT'),('delaware','DE'),('district of columbia','DC'),
    ('florida','FL'),('georgia','GA'),('hawaii','HI'),('idaho','ID'),('illinois','IL'),
    ('indiana','IN'),('iowa','IA'),('kansas','KS'),('kentucky','KY'),('louisiana','LA'),
    ('maine','ME'),('maryland','MD'),('massachusetts','MA'),('michigan','MI'),('minnesota','MN'),
    ('mississippi','MS'),('missouri','MO'),('montana','MT'),('nebraska','NE'),('nevada','NV'),
    ('new hampshire','NH'),('new jersey','NJ'),('new mexico','NM'),('new york','NY'),
    ('north carolina','NC'),('north dakota','ND'),('ohio','OH'),('oklahoma','OK'),('oregon','OR'),
    ('pennsylvania','PA'),('rhode island','RI'),('south carolina','SC'),('south dakota','SD'),
    ('tennessee','TN'),('texas','TX'),('utah','UT'),('vermont','VT'),('virginia','VA'),
    ('washington','WA'),('west virginia','WV'),('wisconsin','WI'),('wyoming','WY')),
  m AS (
    SELECT p.pos_order,
           s.source                                            AS m_source,
           s.order_status                                      AS m_status,
           NULLIF(btrim(COALESCE(s.venue_city,  vf.city)), '')  AS m_city,
           NULLIF(btrim(COALESCE(s.venue_state, vf.state)), '') AS m_state,
           NULLIF(btrim(concat_ws(' ',
             NULLIF(btrim(substring(v.raw_xml from '<firstName>([^<]*)</firstName>')), ''),
             NULLIF(btrim(substring(v.raw_xml from '<lastName>([^<]*)</lastName>')), ''))), '') AS m_name,
           NULLIF(btrim(substring(v.raw_xml from '<emailAddress>([^<]*)</emailAddress>')), '') AS m_email
      FROM public.peddling_sales p
      -- the marketplace order: same id, and the same quantity when both know it
      LEFT JOIN LATERAL (
        SELECT s.* FROM public.s4kcs_orders s
         WHERE s.s4k_order_id = p.site_order
           AND (s.quantity IS NULL OR p.qty IS NULL OR s.quantity = p.qty)
         ORDER BY s.last_seen_at DESC NULLS LAST
         LIMIT 1) s ON true
      -- no city on that order: the city/state most often seen for the venue
      LEFT JOIN LATERAL (
        SELECT s2.venue_city AS city, s2.venue_state AS state
          FROM public.s4kcs_orders s2
         WHERE s.venue_city IS NULL AND p.venue IS NOT NULL
           AND s2.venue_name = p.venue AND s2.venue_city IS NOT NULL
         GROUP BY 1, 2 ORDER BY count(*) DESC LIMIT 1) vf ON true
      LEFT JOIN public.vivid_orders v
             ON p.site ILIKE 'vivid%' AND v.vivid_order_id = p.site_order
     WHERE p.site_order IS NOT NULL
       AND (p_ids IS NULL OR p.pos_order = ANY(p_ids))
  )
  UPDATE public.peddling_sales t SET
    market_source  = COALESCE(m.m_source, t.market_source),
    market_status  = COALESCE(m.m_status, t.market_status),
    event_city     = COALESCE(m.m_city, t.event_city),
    event_state    = COALESCE(
                       (SELECT st.code FROM st WHERE st.name = lower(m.m_state)),
                       CASE WHEN m.m_state ~ '^[A-Za-z]{2}$' THEN upper(m.m_state) ELSE m.m_state END,
                       t.event_state),
    customer_name  = COALESCE(replace(replace(replace(m.m_name, '&amp;', '&'), '&apos;', ''''), '&quot;', '"'), t.customer_name),
    customer_email = COALESCE(lower(m.m_email), t.customer_email),
    enriched_at    = now()
  FROM m
  WHERE t.pos_order = m.pos_order;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.peddling_sales_enrich(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.peddling_sales_enrich(bigint[]) TO service_role;

COMMENT ON FUNCTION public.peddling_sales_enrich(bigint[]) IS
  'Fills peddling_sales market_status / event_city / event_state (s4kcs_orders, venue fallback) and customer_name / customer_email (vivid_orders.raw_xml) by marketplace order id. NULL = all rows. Read-only on sources. Mig 20261109174000.';

-- 3. ingest RPC: enrich what it received and hand the fields back --------------------
CREATE OR REPLACE FUNCTION public.peddling_sales_ingest_from_apps_script(
  p_items jsonb, p_shared_secret text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_expected text := public.get_app_secret('APPSCRIPT_INGEST_SECRET');
  v_total int;
  v_new int := 0; v_upd int := 0;
  v_ids bigint[];
  v_rows jsonb;
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
    SELECT DISTINCT ON ((it->>'pos_order')::bigint)
           (it->>'pos_order')::bigint AS pos_order, it
      FROM jsonb_array_elements(p_items) AS it
     WHERE it->>'pos_order' ~ '^[0-9]{1,15}$'
     ORDER BY (it->>'pos_order')::bigint
  ),
  up AS (
    INSERT INTO public.peddling_sales AS t (
      pos_order, source, site, site_order, sale_dt, email_at, tnow_ticket, tu_ticket,
      event_name, venue, event_dt, section, "row", seats, seat_start, seat_end,
      qty, price_each, total, cancelled, mailbox, gmail_message_id, gmail_thread_id,
      raw, first_seen_at, updated_at)
    SELECT
      s.pos_order,
      COALESCE(NULLIF(btrim(s.it->>'source'), ''), 'PACIOLAN'),
      NULLIF(btrim(s.it->>'site'), ''),
      NULLIF(btrim(s.it->>'site_order'), ''),
      CASE WHEN s.it->>'sale_dt'  ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' THEN (s.it->>'sale_dt')::timestamp END,
      CASE WHEN s.it->>'email_at' ~ '^\d{4}-\d{2}-\d{2}T' THEN (s.it->>'email_at')::timestamptz END,
      NULLIF(btrim(s.it->>'tnow_ticket'), ''),
      NULLIF(btrim(s.it->>'tu_ticket'), ''),
      NULLIF(btrim(s.it->>'event_name'), ''),
      NULLIF(btrim(s.it->>'venue'), ''),
      CASE WHEN s.it->>'event_dt' ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}' THEN (s.it->>'event_dt')::timestamp END,
      NULLIF(btrim(s.it->>'section'), ''),
      NULLIF(btrim(s.it->>'row'), ''),
      NULLIF(btrim(s.it->>'seats'), ''),
      NULLIF(btrim(s.it->>'seat_start'), ''),
      NULLIF(btrim(s.it->>'seat_end'), ''),
      CASE WHEN s.it->>'qty' ~ '^\d{1,6}$' THEN (s.it->>'qty')::integer END,
      CASE WHEN s.it->>'price_each' ~ '^\d+(\.\d+)?$' THEN (s.it->>'price_each')::numeric END,
      CASE WHEN s.it->>'total'      ~ '^\d+(\.\d+)?$' THEN (s.it->>'total')::numeric END,
      COALESCE((s.it->>'cancelled')::boolean, false),
      NULLIF(btrim(s.it->>'mailbox'), ''),
      NULLIF(btrim(s.it->>'gmail_message_id'), ''),
      NULLIF(btrim(s.it->>'gmail_thread_id'), ''),
      s.it, now(), now()
    FROM src s
    ON CONFLICT (pos_order) DO UPDATE SET
      source           = EXCLUDED.source,
      site             = COALESCE(EXCLUDED.site, t.site),
      site_order       = COALESCE(EXCLUDED.site_order, t.site_order),
      sale_dt          = COALESCE(EXCLUDED.sale_dt, t.sale_dt),
      email_at         = COALESCE(t.email_at, EXCLUDED.email_at),
      tnow_ticket      = COALESCE(EXCLUDED.tnow_ticket, t.tnow_ticket),
      tu_ticket        = COALESCE(EXCLUDED.tu_ticket, t.tu_ticket),
      event_name       = COALESCE(EXCLUDED.event_name, t.event_name),
      venue            = COALESCE(EXCLUDED.venue, t.venue),
      event_dt         = COALESCE(EXCLUDED.event_dt, t.event_dt),
      section          = COALESCE(EXCLUDED.section, t.section),
      "row"            = COALESCE(EXCLUDED."row", t."row"),
      seats            = COALESCE(EXCLUDED.seats, t.seats),
      seat_start       = COALESCE(EXCLUDED.seat_start, t.seat_start),
      seat_end         = COALESCE(EXCLUDED.seat_end, t.seat_end),
      qty              = COALESCE(EXCLUDED.qty, t.qty),
      price_each       = COALESCE(EXCLUDED.price_each, t.price_each),
      total            = COALESCE(EXCLUDED.total, t.total),
      cancelled        = t.cancelled OR EXCLUDED.cancelled,          -- sticky
      mailbox          = COALESCE(t.mailbox, EXCLUDED.mailbox),      -- first inbox wins
      gmail_message_id = COALESCE(t.gmail_message_id, EXCLUDED.gmail_message_id),
      gmail_thread_id  = COALESCE(t.gmail_thread_id, EXCLUDED.gmail_thread_id),
      raw              = EXCLUDED.raw,
      updated_at       = now()
    RETURNING t.pos_order, (xmax = 0) AS is_new
  )
  SELECT array_agg(pos_order), count(*) FILTER (WHERE is_new), count(*) FILTER (WHERE NOT is_new)
    INTO v_ids, v_new, v_upd
    FROM up;

  -- mig 20261109174000: match to the marketplace order books, return the fields
  PERFORM public.peddling_sales_enrich(COALESCE(v_ids, ARRAY[]::bigint[]));

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'pos_order',      p.pos_order::text,
           'customer_name',  p.customer_name,
           'customer_email', p.customer_email,
           'event_city',     p.event_city,
           'event_state',    p.event_state,
           'status',         CASE WHEN p.cancelled THEN 'Cancelled' ELSE p.market_status END)
           ORDER BY p.pos_order), '[]'::jsonb)
    INTO v_rows
    FROM public.peddling_sales p
   WHERE p.pos_order = ANY(COALESCE(v_ids, ARRAY[]::bigint[]));

  RETURN jsonb_build_object(
    'received', v_total, 'inserted', COALESCE(v_new, 0), 'updated', COALESCE(v_upd, 0),
    'skipped', v_total - COALESCE(v_new, 0) - COALESCE(v_upd, 0),
    'rows', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.peddling_sales_ingest_from_apps_script(jsonb, text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.peddling_sales_ingest_from_apps_script(jsonb, text) TO anon, service_role;

COMMENT ON FUNCTION public.peddling_sales_ingest_from_apps_script(jsonb, text) IS
  'Peddling-sales intake from scripts/apps_script/peddling_sales_sync.gs: upserts Gmail "PEDDLING SALE RECEIVED" sales into peddling_sales keyed on our order number, enriches them from the marketplace order books (peddling_sales_enrich) and returns customer / event city+state / status per sale in `rows`. cancelled is sticky; mailbox keeps the first inbox. Secret-gated on APPSCRIPT_INGEST_SECRET (20261109172023, 20261109174000).';

-- 4. backfill what is already there -------------------------------------------------
SELECT public.peddling_sales_enrich(NULL);

NOTIFY pgrst, 'reload schema';

-- rollback:
--   re-apply 20261109172023's ingest function (no enrich call, no `rows`);
--   DROP FUNCTION public.peddling_sales_enrich(bigint[]);
--   ALTER TABLE public.peddling_sales DROP COLUMN customer_name, DROP COLUMN customer_email,
--     DROP COLUMN event_city, DROP COLUMN event_state, DROP COLUMN market_status,
--     DROP COLUMN market_source, DROP COLUMN enriched_at;
