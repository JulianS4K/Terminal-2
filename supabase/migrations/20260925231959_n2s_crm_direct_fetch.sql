-- Migration 20260925231959 · level:secondary-sales · lane:D7 · writes:n2s_items,n2s_crm_direct_log,cron.job,extensions(http) · reads:vault(crm.s4kcs.com/n2s) · pre:20260910030000
--
-- Already applied to prod · via MCP 2026-09-25 under operator direction.
--
-- ============================================================================
-- Migration 20260925231959 — pull new CRM orders directly, every 20 s,
-- instead of through the shared pg_net queue
--
-- Lane: D7 · Pre-reqs: 20260910030000 (n2s_items + the drain), the live
--       n2s_pipeline_tick (cron 640 — applied via MCP, no file in this repo)
--
-- ── WHY ────────────────────────────────────────────────────────────────────
-- Measured 2026-09-25 (operator: "prioritize CRM to next clip instead of FIFO"):
-- an order took a typical 2 min 5 s from CRM creation to n2s_items. None of it
-- was the CRM. Two stacked waits, both ours:
--
--   1. pg_net is ONE shared FIFO queue. The tick's CRM GETs queue behind ~200
--      edge-function invocations and GoTickets polls, and a batch completes
--      with its slowest member (up to the 60 s timeout). All three CRM pages
--      "responded" at the same instant every time — typical 62 s, never under
--      34 s — i.e. they finished with the batch, not with the CRM. 19% of the
--      fetches (51/264 in 2 h) died on the 60 s timeout.
--   2. The reply is only read by the NEXT tick's first stage, and a tick runs
--      a typical 45 s (p90 2 min): typical 78 s from reply to read.
--
-- pg_net has no priority. The only way to jump its queue is writing rows into
-- net.http_request_queue with a lower id — pg_net internals, unsupported, and
-- the request would still wait for its batch. So the CRM leaves the queue:
--
--   * the `http` extension makes a SYNCHRONOUS call — no queue, no batch;
--   * n2s_crm_fetch_direct() fetches page 0 (the list is sorted updated_at
--     DESC, so every new or changed order lands there) and upserts it in the
--     same statement;
--   * cron `n2s_crm_direct_20s` runs it every 20 s, gated by cron_should_fire.
--
-- Pages 150/300 stay on the tick via pg_net: they only refresh older orders,
-- where a couple of minutes' lag is harmless.
--
-- ── ⚠ THE RACE THIS OPENS, AND THE GUARD ─────────────────────────────────────
-- Two paths now write n2s_items. A pg_net reply captured before a direct fetch
-- can be drained after it and overwrite a newer state with an older one. The
-- shared upsert therefore only updates when the incoming row is at least as
-- new as the stored one (n2s_updated_at, NULLs always allowed through so an
-- untimestamped row is never frozen). Both paths go through the same helper,
-- n2s_items_upsert(), so the rule cannot drift between them.
--
-- ── OBSERVABILITY ─────────────────────────────────────────────────────────
-- n2s_crm_direct_log: one row per fetch (status, ms, items, new orders,
-- error), pruned to 2 days inside the function. RLS on, no policies.
--
-- RULE 2: the CRM is our own system, not a listing source; this is a GET.
--
-- Drift guards: the live n2s_items_drain and n2s_pipeline_tick are asserted by
-- md5 before either is touched, and the tick edit is one anchored removal.
-- A second apply is refused (the log table / anchor are already there).
-- Rollback at the bottom.
-- ============================================================================

DO $$
BEGIN
  IF md5(pg_get_functiondef('public.n2s_items_drain'::regproc)) <> '4da6dd5436d8752aab11e06e1125ae5a' THEN
    RAISE EXCEPTION 'n2s_items_drain drifted from the reviewed body — refusing';
  END IF;
  IF md5(pg_get_functiondef('public.n2s_pipeline_tick'::regproc)) <> '788b378550924526a5686565fce04687' THEN
    RAISE EXCEPTION 'n2s_pipeline_tick drifted from the reviewed body — refusing';
  END IF;
  IF to_regclass('public.n2s_crm_direct_log') IS NOT NULL THEN
    RAISE EXCEPTION 'already applied (n2s_crm_direct_log exists) — refusing';
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

-- The http() family can reach any URL. Nothing outside the database owner
-- needs it; keep it off the API roles.
DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure
      FROM pg_proc p
      JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e'
      JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'http'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
  END LOOP;
END $$;

-- ── log ────────────────────────────────────────────────────────────────────
CREATE TABLE public.n2s_crm_direct_log (
  id          bigserial PRIMARY KEY,
  fetched_at  timestamptz NOT NULL DEFAULT now(),
  status      integer,
  ms          integer,
  items       integer,
  upserted    integer,
  new_orders  integer,
  error       text
);
ALTER TABLE public.n2s_crm_direct_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.n2s_crm_direct_log FROM PUBLIC, anon, authenticated;
CREATE INDEX n2s_crm_direct_log_fetched_at ON public.n2s_crm_direct_log (fetched_at);

-- ── shared upsert (body lifted verbatim from the live drain + the guard) ─────
CREATE FUNCTION public.n2s_items_upsert(p_content jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'n2s_items_upsert: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  WITH items AS (
    SELECT jsonb_array_elements(p_content -> 'items') AS it
  ), up AS (
    INSERT INTO public.n2s_items AS t (
      n2s_id, order_number, marketplace, s4k_source, status, status_label, is_terminal,
      item_source, fail_reason, event_name, venue, event_dt, section, "row", seats, qty,
      price_per_ticket, grand_total, cost, total_cost, sale_profit, profit_loss, listing_id,
      delivery_type, po_number, alert_at, timer_expires_at, timer_expired, subbed_at,
      resolved_at, no_subs_at, n2s_created_at, n2s_updated_at, pulled_at, last_seen_at, raw)
    SELECT
      (it->>'id')::bigint, it->>'order_number', it->>'marketplace',
      CASE it->>'marketplace' WHEN 'Stubhub 2.0' THEN 'StubHub' WHEN 'Go Tickets' THEN 'GoTickets'
                              WHEN 'Ticket Evolution' THEN 'EVO' ELSE it->>'marketplace' END,
      it->>'status', it->>'status_label', (it->>'status') IN ('resolved','allocated'),
      it->>'source', it->>'fail_reason', it->>'event_name', it->>'venue',
      NULLIF(it->>'event_dt','')::timestamp, it->>'section', it->>'row', it->>'seats',
      NULLIF(it->>'qty','')::integer, NULLIF(it->>'price_per_ticket','')::numeric,
      NULLIF(it->>'grand_total','')::numeric, NULLIF(it->>'cost','')::numeric,
      NULLIF(it->>'total_cost','')::numeric, NULLIF(it->>'sale_profit','')::numeric,
      NULLIF(it->>'profit_loss','')::numeric, it->>'listing_id', it->>'delivery_type',
      it->>'po_number', NULLIF(it->>'alert_at','')::timestamptz,
      NULLIF(it->'timer'->>'expires_at','')::timestamptz, (it->'timer'->>'expired')::boolean,
      NULLIF(it->>'subbed_at','')::timestamptz, NULLIF(it->>'resolved_at','')::timestamptz,
      NULLIF(it->>'no_subs_at','')::timestamptz, NULLIF(it->>'created_at','')::timestamptz,
      NULLIF(it->>'updated_at','')::timestamptz, now(), now(),
      (it - 'customer_name' - 'customer_email')
    FROM items
    ON CONFLICT (n2s_id) DO UPDATE SET
      order_number = EXCLUDED.order_number, marketplace = EXCLUDED.marketplace,
      s4k_source = EXCLUDED.s4k_source, status = EXCLUDED.status,
      status_label = EXCLUDED.status_label, is_terminal = EXCLUDED.is_terminal,
      item_source = EXCLUDED.item_source, fail_reason = EXCLUDED.fail_reason,
      event_name = EXCLUDED.event_name, venue = EXCLUDED.venue, event_dt = EXCLUDED.event_dt,
      section = EXCLUDED.section, "row" = EXCLUDED."row", seats = EXCLUDED.seats,
      qty = EXCLUDED.qty,
      price_per_ticket = COALESCE(EXCLUDED.price_per_ticket, t.price_per_ticket),
      grand_total = EXCLUDED.grand_total, cost = EXCLUDED.cost,
      total_cost = EXCLUDED.total_cost, sale_profit = EXCLUDED.sale_profit,
      profit_loss = EXCLUDED.profit_loss, listing_id = EXCLUDED.listing_id,
      delivery_type = EXCLUDED.delivery_type, po_number = EXCLUDED.po_number,
      alert_at = EXCLUDED.alert_at, timer_expires_at = EXCLUDED.timer_expires_at,
      timer_expired = EXCLUDED.timer_expired, subbed_at = EXCLUDED.subbed_at,
      resolved_at = EXCLUDED.resolved_at, no_subs_at = EXCLUDED.no_subs_at,
      n2s_created_at = EXCLUDED.n2s_created_at, n2s_updated_at = EXCLUDED.n2s_updated_at,
      last_seen_at = now(), raw = EXCLUDED.raw
    -- Two writers now (direct 20 s fetch + the tick's pg_net pages): never let
    -- an older snapshot overwrite a newer one.
    WHERE EXCLUDED.n2s_updated_at IS NULL
       OR t.n2s_updated_at IS NULL
       OR EXCLUDED.n2s_updated_at >= t.n2s_updated_at
    RETURNING 1
  )
  SELECT count(*)::int INTO v_n FROM up;
  RETURN COALESCE(v_n, 0);
END
$function$;
REVOKE ALL ON FUNCTION public.n2s_items_upsert(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_items_upsert(jsonb) TO service_role;

-- ── the drain, now on the shared upsert (behaviour otherwise unchanged) ──────
CREATE OR REPLACE FUNCTION public.n2s_items_drain()
RETURNS TABLE(responses integer, rows_upserted integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net', 'pg_temp'
AS $function$
DECLARE v_resp int := 0; v_rows int := 0; r record; v_n int;
BEGIN
  FOR r IN
    SELECT p.request_id, x.status_code, x.content
      FROM public.n2s_items_pending p
      JOIN net._http_response x ON x.id = p.request_id
     WHERE p.resolved_at IS NULL
     ORDER BY p.request_id
  LOOP
    v_resp := v_resp + 1; v_n := 0;
    IF r.status_code = 200 AND r.content IS NOT NULL THEN
      v_n := public.n2s_items_upsert(r.content::jsonb);
      v_rows := v_rows + COALESCE(v_n, 0);
    END IF;
    UPDATE public.n2s_items_pending
       SET resolved_at = now(), status_code = r.status_code, rows_persisted = COALESCE(v_n, 0)
     WHERE request_id = r.request_id;
  END LOOP;
  RETURN QUERY SELECT v_resp, v_rows;
END
$function$;

-- ── the direct fetch ──────────────────────────────────────────────────────
CREATE FUNCTION public.n2s_crm_fetch_direct(p_limit integer DEFAULT 150, p_offset integer DEFAULT 0,
                                            p_timeout_ms integer DEFAULT 15000)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_key     text;
  v_t0      timestamptz := clock_timestamp();
  v_status  int;
  v_body    jsonb;
  v_items   int := 0;
  v_new     int := 0;
  v_rows    int := 0;
  v_ms      int;
  v_err     text;
BEGIN
  IF current_user NOT IN ('postgres', 'service_role', 'supabase_admin') THEN
    RAISE EXCEPTION 'n2s_crm_fetch_direct: caller % not authorized', current_user USING ERRCODE = '42501';
  END IF;
  IF NOT public.cron_should_fire('n2s_crm_direct_20s') THEN
    RETURN jsonb_build_object('skipped', 'gate');
  END IF;

  v_key := btrim(COALESCE(public.get_app_secret('crm.s4kcs.com/n2s'), ''));
  IF v_key = '' THEN
    INSERT INTO public.n2s_crm_direct_log(error) VALUES ('vault secret crm.s4kcs.com/n2s unset');
    RETURN jsonb_build_object('error', 'secret unset');
  END IF;

  BEGIN
    PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', p_timeout_ms::text);
    SELECT r.status, r.content::jsonb INTO v_status, v_body
      FROM extensions.http((
        'GET',
        format('https://crm.s4kcs.com/api/v1/n2s/items?limit=%s&offset=%s', p_limit, p_offset),
        ARRAY[extensions.http_header('X-API-Key', v_key),
              extensions.http_header('Accept', 'application/json')],
        NULL, NULL)::extensions.http_request) r;
  EXCEPTION WHEN OTHERS THEN
    v_err := left(SQLERRM, 300);
  END;
  PERFORM extensions.http_reset_curlopt();

  IF v_status = 200 AND v_body IS NOT NULL THEN
    v_items := COALESCE(jsonb_array_length(v_body -> 'items'), 0);
    SELECT count(*) INTO v_new
      FROM jsonb_array_elements(v_body -> 'items') it
     WHERE NOT EXISTS (SELECT 1 FROM public.n2s_items i WHERE i.n2s_id = (it->>'id')::bigint);
    v_rows := public.n2s_items_upsert(v_body);
  END IF;

  v_ms := (extract(epoch FROM clock_timestamp() - v_t0) * 1000)::int;
  INSERT INTO public.n2s_crm_direct_log(status, ms, items, upserted, new_orders, error)
  VALUES (v_status, v_ms, v_items, v_rows, v_new, v_err);
  DELETE FROM public.n2s_crm_direct_log WHERE fetched_at < now() - interval '2 days';

  RETURN jsonb_build_object('status', v_status, 'ms', v_ms, 'items', v_items,
                            'upserted', v_rows, 'new', v_new, 'error', v_err);
END
$function$;
REVOKE ALL ON FUNCTION public.n2s_crm_fetch_direct(integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_crm_fetch_direct(integer, integer, integer) TO service_role;

-- ── the tick stops fetching page 0 through pg_net (one anchored removal) ─────
DO $$
DECLARE
  v_def text := pg_get_functiondef('public.n2s_pipeline_tick'::regproc);
  v_pat text := 'PERFORM public\.n2s_items_queue\(150, 0\);[ \t]*\n?[ \t]*';
  v_hits int;
BEGIN
  SELECT count(*) INTO v_hits FROM regexp_matches(v_def, v_pat, 'g');
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'n2s_pipeline_tick: expected exactly one page-0 queue call, found %', v_hits;
  END IF;
  v_def := regexp_replace(v_def, v_pat,
    '-- page 0 is fetched directly every 20 s by n2s_crm_fetch_direct (20260925231959)' || E'\n    ');
  EXECUTE v_def;
END $$;

SELECT cron.schedule(
  'n2s_crm_direct_20s',
  '20 seconds',
  $cmd$ SET statement_timeout = '30s'; SELECT public.n2s_crm_fetch_direct(); $cmd$
);

-- ── rollback ───────────────────────────────────────────────────────────────
-- SELECT cron.unschedule('n2s_crm_direct_20s');
-- Restore the tick's page-0 call: re-add `PERFORM public.n2s_items_queue(150, 0);`
--   before the page-150 call in n2s_pipeline_tick (CREATE OR REPLACE from its def).
-- n2s_items_drain may stay on n2s_items_upsert (same behaviour plus the guard).
-- DROP FUNCTION public.n2s_crm_fetch_direct(integer, integer, integer);
-- DROP TABLE public.n2s_crm_direct_log;
-- DROP EXTENSION http;   -- only if nothing else has started using it
