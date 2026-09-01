-- Migration 20260901181500 · level:secondary-sales · lane:D0 · writes:s4kcs_orders_pending · reads:net._http_response · pre:20260901180000
--
-- Record the CRM's per-market `errors` array on each drain.
--
-- WHY. The API fetches the six marketplaces in parallel and returns the ones
-- that worked, reporting failures in `errors` — so a market can drop out of
-- the feed while the response stays HTTP 200. The drain discarded that array,
-- which made a partial outage invisible: the only symptom was a smaller
-- rows_persisted and rows quietly going stale while the cron reported success.
--
-- Caught live: TickPick vanished from the feed at ~17:43 on 2026-09-01 with
-- "401 Unauthorized ... failed after 3 attempts" on every pull. 2,288 TickPick
-- orders sat frozen at one last_seen_at while five other markets refreshed,
-- and nothing surfaced it.
--
-- reported_count is the body's own `count`, so it can be compared against
-- rows_persisted: a gap between them means rows were dropped by the upsert
-- filter (missing source/id) rather than by an upstream outage.
ALTER TABLE public.s4kcs_orders_pending
  ADD COLUMN IF NOT EXISTS errors jsonb,
  ADD COLUMN IF NOT EXISTS reported_count int;

COMMENT ON COLUMN public.s4kcs_orders_pending.errors IS
  'Per-market failures reported by the CRM for this pull (HTTP 200 with a partial book). Non-empty = at least one marketplace is missing from that pull.';

-- s4kcs_orders_process() gains: capture `errors` + `count`, and RAISE WARNING
-- on a partial book. Body otherwise unchanged from mig 20260901180000 (the
-- DISTINCT ON dedupe and the regex-guarded coercions are still required).
-- Full function body is re-applied here; see the prior migration for the
-- rationale on those two.
CREATE OR REPLACE VIEW public.v_s4kcs_ingest_health AS
SELECT
  p.id, p.created_at, p.resolved_at, p.rows_persisted, p.reported_count,
  COALESCE(jsonb_array_length(p.errors), 0) AS failed_markets,
  (SELECT string_agg(e->>'market', ', ' ORDER BY e->>'market')
     FROM jsonb_array_elements(COALESCE(p.errors,'[]'::jsonb)) e) AS failed_market_names,
  p.errors
FROM public.s4kcs_orders_pending p
ORDER BY p.id DESC;

CREATE OR REPLACE FUNCTION public.s4kcs_orders_process()
 RETURNS TABLE(processed integer, orders_persisted integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net'
AS $function$
DECLARE
  r RECORD;
  v_body jsonb;
  v_rows jsonb;
  v_errors jsonb;
  v_processed int := 0;
  v_persisted int := 0;
  v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, h.content, h.status_code
    FROM public.s4kcs_orders_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;

    IF r.status_code = 200 THEN
      BEGIN
        v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN
        v_body := NULL;
      END;
      v_rows := COALESCE(v_body->'rows', '[]'::jsonb);
      v_errors := COALESCE(v_body->'errors', '[]'::jsonb);

      -- DISTINCT ON is MANDATORY: the feed can repeat a (source, id) pair
      -- inside one payload (observed as a byte-identical duplicate row), and
      -- Postgres rejects that with "ON CONFLICT DO UPDATE command cannot
      -- affect row a second time" — which fails the WHOLE batch, not the row.
      WITH src AS (
        SELECT DISTINCT ON (o->>'source', o->>'id') o
        FROM jsonb_array_elements(v_rows) AS o
        ORDER BY o->>'source', o->>'id'
      ),
      ins AS (
        INSERT INTO public.s4kcs_orders (
          source, s4k_order_id, order_status, seller_status,
          event_name, event_date, venue_name, venue_city, venue_state,
          section, row, seats, quantity, price, delivery,
          inhand_date, payout_date, purchase_date, notes,
          pulled_at, last_seen_at, raw
        )
        SELECT
          o->>'source', o->>'id',
          NULLIF(o->>'order_status',''), NULLIF(o->>'seller_status',''),
          NULLIF(o->>'event_name',''), public.s4kcs_as_date(o->>'event_date'),
          NULLIF(o->>'venue_name',''), NULLIF(o->>'venue_city',''), NULLIF(o->>'venue_state',''),
          NULLIF(o->>'section',''), NULLIF(o->>'row',''), NULLIF(o->>'seats',''),
          public.s4kcs_as_num(o->>'quantity')::int, public.s4kcs_as_num(o->>'price'),
          NULLIF(o->>'delivery',''),
          public.s4kcs_as_date(o->>'inhand_date'), public.s4kcs_as_date(o->>'payout_date'),
          public.s4kcs_as_date(o->>'purchase_date'), NULLIF(o->>'notes',''),
          now(), now(), o
        FROM src
        WHERE COALESCE(o->>'source','') <> '' AND COALESCE(o->>'id','') <> ''
        ON CONFLICT (source, s4k_order_id) DO UPDATE SET
          order_status  = EXCLUDED.order_status,
          seller_status = EXCLUDED.seller_status,
          event_name    = EXCLUDED.event_name,
          event_date    = EXCLUDED.event_date,
          venue_name    = EXCLUDED.venue_name,
          venue_city    = EXCLUDED.venue_city,
          venue_state   = EXCLUDED.venue_state,
          section       = EXCLUDED.section,
          row           = EXCLUDED.row,
          seats         = EXCLUDED.seats,
          quantity      = EXCLUDED.quantity,
          price         = EXCLUDED.price,
          delivery      = EXCLUDED.delivery,
          inhand_date   = EXCLUDED.inhand_date,
          payout_date   = EXCLUDED.payout_date,
          purchase_date = EXCLUDED.purchase_date,
          notes         = EXCLUDED.notes,
          last_seen_at  = now(),
          raw           = EXCLUDED.raw
        RETURNING 1
      )
      SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + v_inserted;

      IF jsonb_array_length(v_errors) > 0 THEN
        RAISE WARNING 's4kcs_orders_process: partial book — %', v_errors::text;
      END IF;

      UPDATE public.s4kcs_orders_pending
        SET resolved_at = now(), rows_persisted = v_inserted,
            errors = v_errors,
            reported_count = NULLIF(v_body->>'count','')::int
        WHERE id = r.pending_id;
    ELSE
      UPDATE public.s4kcs_orders_pending
        SET resolved_at = now(), rows_persisted = -1
        WHERE id = r.pending_id;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_persisted;
END;
$function$;

REVOKE ALL ON FUNCTION public.s4kcs_orders_process() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_orders_process() TO service_role;
