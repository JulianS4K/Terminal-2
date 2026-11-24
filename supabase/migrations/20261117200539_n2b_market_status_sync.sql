-- Migration 20261117200539 · level:secondary-sales · lane:D7 (N2S — the PED / Need2Buy book) · writes:n2s_items(+market_status, market_status_src, market_status_seen_at, market_checked_at; status of gmail N2B rows — DML via fn),n2b_market_status_sync() fn (new),n2b_ingest_from_apps_script() fn (sticky marketplace close),cron:n2b_market_status_10min · reads:evo_orders,gotickets_sales,seatgeek_orders,tickpick_orders,vivid_orders,v_s4kcs_orders · pre:20261112010040
--
-- Lane:     D7 (n2s_* schema, PED / Need2Buy book)
-- Touches:  n2s_items (W: 4 new columns; status/status_label/is_terminal/fail_reason/resolved_at on
--           item_source='gmail' rows only), n2b_market_status_sync (new), n2b_ingest_from_apps_script (W),
--           cron n2b_market_status_10min (new); evo_orders, gotickets_sales, seatgeek_orders,
--           tickpick_orders, vivid_orders, v_s4kcs_orders (R)
-- Pre-reqs: 20261112010040 (current n2b_ingest_from_apps_script body, reused verbatim below except the
--           five sticky checks)
--
-- WHY (operator 2026-11-17, "why isnt the book updating status of orders?" → "fix"): a PED order
-- (Gmail "PEDDLING SALE RECEIVED" thread labelled Need2Buy/WaitToBuy, n2s_items item_source 'gmail')
-- only ever changes status from Gmail — the label comes off, a cancel label / CANCEL email, or the
-- event passes. Nothing read the marketplace, so an order filled or cancelled there stayed open in the
-- book (and kept being priced) until someone edited the label.
--
-- WHAT:
--   1. n2s_items gains market_status / market_status_src / market_status_seen_at / market_checked_at —
--      the order's status on its marketplace, where it came from, when that source last saw it, and
--      when we last looked. Filled for every open PED order.
--   2. n2b_market_status_sync(p_apply) reads, per order, OUR OWN order book first (we hold API pulls
--      for five markets):
--          EVO        evo_orders.state            (order no. "<po>-<evo_order_id>": the tail)
--          GoTickets  gotickets_sales.seller_status (gt_sale_id)
--          SeatGeek   seatgeek_orders.status        (sg_order_id)
--          TickPick   tickpick_orders.order_status  (tp_order_id)
--          Vivid      vivid_orders.status           (vivid_order_id)
--      and the CRM (v_s4kcs_orders, matched on s4k_order_id) for everything else — Gametime and
--      Viagogo (filed by the CRM under StubHub) have no book of our own — or when our book lacks the
--      order. It then closes an order ONLY on a final status from our own book:
--          fulfilled  → status 'n2b_closed'    : EVO completed · GoTickets COMPLETED · SeatGeek fulfilled
--          cancelled  → status 'n2b_cancelled' : EVO rejected / canceled / canceled_post_acceptance ·
--                                                TickPick REJECTED
--      fail_reason = 'marketplace: <source> <status>'. Status values measured on prod 2026-11-17.
--      Vivid, Gametime and Viagogo/StubHub have no final status in any feed (a done order just stops
--      appearing), and a CRM gap is not proof (owxwc509yg2 left the CRM feed on 11-09 while SeatGeek
--      still has it 'confirmed') — so those are recorded, never closed. A stale market_status_seen_at
--      is the visible signal for them.
--   3. n2b_ingest_from_apps_script: a row closed this way stays closed when the Apps Script reports the
--      thread again (same rule as n2b_cancelled). Body is mig 20261112010040's, byte-for-byte except
--      the five `WHEN t.status = 'n2b_cancelled' THEN` checks (prod definition verified identical by
--      md5 of the whitespace-stripped body before authoring).
--   4. cron n2b_market_status_10min at :08/:18/… — just after the CRM's 10-minute pull lands — behind
--      cron_should_fire. ~35 rows, every lookup on a primary / unique index.
--
-- Nothing upstream is called (RULE 2): reads of tables our own pulls already fill.
--
-- DRY RUN on prod before authoring (2026-11-17, read-only SELECT of the same rules): of the 34 open
-- orders, 0 would close; all 34 get a market_status (22 from our own books — gotickets 8, seatgeek 5,
-- evo 3, tickpick 3, vivid 3 — and 12 from the CRM: Gametime 6, Viagogo 5, and SeatGeek 8707tqrv5mw,
-- which seatgeek_orders does not hold). Over open + recently closed rows the
-- same rules find 3 fulfilled (1 EVO completed, 2 GoTickets COMPLETED) — all already closed by label.
--
-- rollback:
--   SELECT cron.unschedule('n2b_market_status_10min');
--   DROP FUNCTION public.n2b_market_status_sync(boolean);
--   re-run the n2b_ingest_from_apps_script definition from mig 20261112010040;
--   ALTER TABLE public.n2s_items DROP COLUMN market_status, DROP COLUMN market_status_src,
--     DROP COLUMN market_status_seen_at, DROP COLUMN market_checked_at;
--   (rows already closed by the sync keep fail_reason 'marketplace: …'; reopen by hand if wanted)

BEGIN;

-- 1. columns -----------------------------------------------------------------------------------
ALTER TABLE public.n2s_items
  ADD COLUMN IF NOT EXISTS market_status          text,
  ADD COLUMN IF NOT EXISTS market_status_src      text,
  ADD COLUMN IF NOT EXISTS market_status_seen_at  timestamptz,
  ADD COLUMN IF NOT EXISTS market_checked_at      timestamptz;

COMMENT ON COLUMN public.n2s_items.market_status IS
  'PED (item_source gmail) rows: the order''s current status on its marketplace, from our own order book '
  '(evo / gotickets / seatgeek / tickpick / vivid) or the CRM. n2b_market_status_sync, mig 20261117200539.';
COMMENT ON COLUMN public.n2s_items.market_status_src IS
  'Where market_status came from: evo | gotickets | seatgeek | tickpick | vivid | crm. Mig 20261117200539.';
COMMENT ON COLUMN public.n2s_items.market_status_seen_at IS
  'When that source last saw the order. Stale while the order is open = it dropped out of the feed. Mig 20261117200539.';
COMMENT ON COLUMN public.n2s_items.market_checked_at IS
  'When n2b_market_status_sync last looked the order up. Mig 20261117200539.';

-- 2. the sync ----------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.n2b_market_status_sync(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_rows   jsonb;
  v_seen   int := 0;
  v_closed int := 0;
  v_cancel int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'n2b_market_status_sync: not allowed for %', current_user USING ERRCODE = '42501';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS n2b_mss_tmp (
    n2s_id bigint PRIMARY KEY, order_number text, src text, st text, seen timestamptz, verdict text
  ) ON COMMIT DROP;
  TRUNCATE n2b_mss_tmp;

  INSERT INTO n2b_mss_tmp
  WITH o AS (
    SELECT n.n2s_id, n.order_number, n.s4k_source,
           CASE WHEN n.order_number ~ '^\d+-\d+$' THEN split_part(n.order_number, '-', 2)
                ELSE n.order_number END AS tail
      FROM public.n2s_items n
     WHERE n.item_source = 'gmail' AND n.status = 'n2b'
  ),
  own AS (
    SELECT o.*, b.src, b.st, b.seen
      FROM o
      LEFT JOIN LATERAL (
        SELECT 'evo'::text AS src, e.state AS st, COALESCE(e.last_seen_at, e.pulled_at) AS seen
          FROM public.evo_orders e
         WHERE o.s4k_source = 'EVO' AND o.tail ~ '^\d{1,18}$' AND e.evo_order_id = o.tail::bigint
        UNION ALL
        SELECT 'gotickets', g.seller_status, g.pulled_at
          FROM public.gotickets_sales g
         WHERE o.s4k_source = 'GoTickets' AND o.order_number ~ '^\d{1,18}$'
           AND g.gt_sale_id = o.order_number::bigint
        UNION ALL
        SELECT 'seatgeek', s.status, COALESCE(s.last_status_at, s.pulled_at)
          FROM public.seatgeek_orders s
         WHERE o.s4k_source = 'SeatGeek' AND s.sg_order_id = o.order_number
        UNION ALL
        SELECT 'tickpick', t.order_status, t.last_seen_at
          FROM public.tickpick_orders t
         WHERE o.s4k_source = 'TickPick' AND t.tp_order_id = o.order_number
        UNION ALL
        SELECT 'vivid', v.status, v.last_seen_at
          FROM public.vivid_orders v
         WHERE o.s4k_source = 'Vivid Seats' AND v.vivid_order_id = o.order_number
        LIMIT 1) b ON true
  ),
  r AS (
    SELECT own.n2s_id, own.order_number,
           COALESCE(own.src, CASE WHEN c.order_status IS NOT NULL THEN 'crm' END) AS src,
           COALESCE(own.st, c.order_status) AS st,
           COALESCE(own.seen, c.last_seen_at) AS seen
      FROM own
      LEFT JOIN LATERAL (
        SELECT c1.order_status, c1.last_seen_at
          FROM public.v_s4kcs_orders c1
         WHERE own.src IS NULL AND c1.s4k_order_id = own.order_number
         ORDER BY c1.last_seen_at DESC NULLS LAST
         LIMIT 1) c ON true
  )
  SELECT r.n2s_id, r.order_number, r.src, r.st, r.seen,
         CASE
           WHEN (r.src = 'evo' AND r.st = 'completed')
             OR (r.src = 'gotickets' AND r.st = 'COMPLETED')
             OR (r.src = 'seatgeek' AND r.st = 'fulfilled')                      THEN 'fulfilled'
           WHEN (r.src = 'evo' AND r.st IN ('rejected', 'canceled', 'canceled_post_acceptance'))
             OR (r.src = 'tickpick' AND r.st = 'REJECTED')                       THEN 'cancelled'
         END
    FROM r;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('order', order_number, 'source', src, 'status', st,
                                               'verdict', verdict) ORDER BY order_number), '[]'::jsonb)
    INTO v_rows
    FROM n2b_mss_tmp WHERE verdict IS NOT NULL;

  IF p_apply THEN
    UPDATE public.n2s_items n
       SET market_status = m.st, market_status_src = m.src,
           market_status_seen_at = m.seen, market_checked_at = now()
      FROM n2b_mss_tmp m
     WHERE n.n2s_id = m.n2s_id AND m.st IS NOT NULL;
    GET DIAGNOSTICS v_seen = ROW_COUNT;

    UPDATE public.n2s_items n
       SET status = 'n2b_closed', status_label = 'N2B closed', is_terminal = true,
           fail_reason = 'marketplace: ' || m.src || ' ' || m.st,
           resolved_at = now(), n2s_updated_at = now()
      FROM n2b_mss_tmp m
     WHERE n.n2s_id = m.n2s_id AND m.verdict = 'fulfilled'
       AND n.item_source = 'gmail' AND n.status = 'n2b';
    GET DIAGNOSTICS v_closed = ROW_COUNT;

    UPDATE public.n2s_items n
       SET status = 'n2b_cancelled', status_label = 'N2B cancelled', is_terminal = true,
           fail_reason = 'marketplace: ' || m.src || ' ' || m.st,
           resolved_at = now(), n2s_updated_at = now()
      FROM n2b_mss_tmp m
     WHERE n.n2s_id = m.n2s_id AND m.verdict = 'cancelled'
       AND n.item_source = 'gmail' AND n.status = 'n2b';
    GET DIAGNOSTICS v_cancel = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'applied', p_apply,
    'open_checked', (SELECT count(*) FROM n2b_mss_tmp),
    'with_status', (SELECT count(*) FROM n2b_mss_tmp WHERE st IS NOT NULL),
    'by_source', (SELECT COALESCE(jsonb_object_agg(k, c), '{}'::jsonb)
                    FROM (SELECT COALESCE(src, 'none') AS k, count(*) AS c FROM n2b_mss_tmp GROUP BY 1) x),
    'status_written', v_seen, 'closed_fulfilled', v_closed, 'cancelled', v_cancel,
    'final', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.n2b_market_status_sync(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2b_market_status_sync(boolean) TO service_role;

COMMENT ON FUNCTION public.n2b_market_status_sync(boolean) IS
  'PED (Need2Buy/WaitToBuy) orders: writes each open order''s marketplace status (own order book first — '
  'evo / gotickets / seatgeek / tickpick / vivid — else the CRM) into n2s_items.market_*, and closes an order '
  'only on a final status from our own book (fulfilled → n2b_closed, cancelled → n2b_cancelled, fail_reason '
  '''marketplace: …''). p_apply=false is a dry run. Cron n2b_market_status_10min. Mig 20261117200539.';

-- 3. ingest: a marketplace close is sticky ------------------------------------------------------
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
      status         = CASE WHEN (t.status = 'n2b_cancelled' OR (t.status = 'n2b_closed' AND t.fail_reason LIKE 'marketplace:%')) THEN t.status ELSE EXCLUDED.status END,
      status_label   = CASE WHEN (t.status = 'n2b_cancelled' OR (t.status = 'n2b_closed' AND t.fail_reason LIKE 'marketplace:%')) THEN t.status_label ELSE EXCLUDED.status_label END,
      is_terminal    = CASE WHEN (t.status = 'n2b_cancelled' OR (t.status = 'n2b_closed' AND t.fail_reason LIKE 'marketplace:%')) THEN true ELSE EXCLUDED.is_terminal END,
      fail_reason    = CASE WHEN (t.status = 'n2b_cancelled' OR (t.status = 'n2b_closed' AND t.fail_reason LIKE 'marketplace:%')) THEN t.fail_reason ELSE EXCLUDED.fail_reason END,
      resolved_at    = CASE WHEN (t.status = 'n2b_cancelled' OR (t.status = 'n2b_closed' AND t.fail_reason LIKE 'marketplace:%')) THEN t.resolved_at
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

-- 4. cron ----------------------------------------------------------------------------------------
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'n2b_market_status_10min') THEN
    PERFORM cron.unschedule('n2b_market_status_10min');
  END IF;
  PERFORM cron.schedule('n2b_market_status_10min', '8-58/10 * * * *',
    $j$BEGIN; SET LOCAL statement_timeout = '60s';
       DO $b$ BEGIN
         IF NOT public.cron_should_fire('n2b_market_status_10min') THEN RETURN; END IF;
         PERFORM public.n2b_market_status_sync(true);
       END $b$;
       COMMIT;$j$);
END
$cron$;

COMMIT;

-- VERIFY:
--   SELECT public.n2b_market_status_sync(false);                         -- dry run: by_source, final[]
--   SELECT order_number, market_status_src, market_status, market_status_seen_at
--     FROM n2s_items WHERE item_source = 'gmail' AND status = 'n2b' ORDER BY market_status_seen_at NULLS FIRST;
--   SELECT order_number, status, fail_reason FROM n2s_items WHERE fail_reason LIKE 'marketplace:%';
--   SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'n2b_market_status_10min';
