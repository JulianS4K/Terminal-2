-- Migration 20261118172530 · level:secondary-sales · lane:D0 · writes:sub_finder_n2s_window(new),sub_finder_feed(new),sub_finder_results · reads:sub_finder_order,n2s_items,manual_sub_buy,sub_finder_gt_offer
--
-- THE RESULTS FEED SHOWS ONLY WHAT IS STILL IN PLAY.
-- Operator 2026-11-18: "Fix the results feed, only show n2s within the timeframe allotted, ped is
-- now merged into need2buy, and remove duplicates when it makes sense".
--
-- BEFORE. GET /results returned every answered lookup the account ever made: 94 rows for 63
-- orders on 2026-11-18. 67 of them were closed (an older lookup replaced by a newer one, a sale
-- that ended, an N2S alert from five days earlier), and an order looked up three times was there
-- three times.
--
-- NOW (scope 'n2s', the default).
--   - One row per order: the lookup that holds a purchase or an offer, else the one still being
--     refreshed, else the newest.
--   - An order is shown while it is being watched AND it is in the Need-to-Sub book inside its
--     time:
--       an N2S alert: while its item is open and its timer is running (n2s_items.timer_expires_at,
--                     15 minutes after the alert). Operator 2026-11-18, asked which cut-off was
--                     meant: "15 mins timer". So a lookup of an alert older than 15 minutes
--                     (the CRM's "Find sub" button can start one) is answered by
--                     GET /orders/{n} but is not in this feed.
--       need2buy:     while its item is open and the event day has not passed. PED items (the
--                     e-mailed Need2Buy list, item_source 'gmail', status 'n2b') ARE need2buy
--                     here: one group, not two.
--   - An order with a purchase or an offer that is not final, or that became final in the last 7
--     days, stays whatever its timer says: the caller is following that outcome.
--   - Each row carries `n2s`: {"kind": "n2s" | "need2buy", "alert_at", "timer_expires_at"}.
-- Scope 'all' is the feed as it was: every answered lookup, nothing merged (and the same `n2s`).
--
-- NOT CHANGED: what may be bought. A PED item is still report-only (sub_finder_report_only), and
-- an N2S alert is still not bought through this API. GET /orders/{n} and GET /jobs/{id} read any
-- order as before. sub_finder_results keeps its signature and answers scope 'n2s'.
--
-- rollback: re-apply sub_finder_results from 20261113260000 (tests/sql/sub_finder/functions at
--           the parent commit); the two new functions may stay, nothing else calls them.

-- where an order stands in the Need-to-Sub book: its open item if it has one, else its newest
CREATE OR REPLACE FUNCTION public.sub_finder_n2s_window(p_order_number text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
           'kind', x.kind,
           'alert_at', to_char(x.alert_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'timer_expires_at', CASE WHEN x.kind = 'n2s'
                                    THEN to_char(x.timer_expires_at AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') END,
           -- inside its time. An alert: until its 15-minute timer runs out. need2buy: until the
           -- event day has passed. Either way the item must still be open.
           'in_window', x.open AND CASE WHEN x.kind = 'n2s' THEN coalesce(x.timer_expires_at > now(), false)
                                        ELSE x.event_dt IS NULL
                                             OR x.event_dt::date >= (now() AT TIME ZONE 'America/New_York')::date END)
    -- need2buy: the PED list (item_source 'gmail'), the CRM's label `need2buy`, or its status `n2b`.
    -- Everything else in the book is a Need-to-Sub alert, and only those have a timer.
    FROM (SELECT CASE WHEN n.item_source = 'gmail' OR n.status = 'n2b'
                        OR public.sub_finder_need2buy(n.status, n.status_label, n.raw)
                      THEN 'need2buy' ELSE 'n2s' END AS kind,
                 NOT coalesce(n.is_terminal, false) AS open, n.alert_at, n.timer_expires_at, n.event_dt
            FROM public.n2s_items n
           WHERE n.order_number = p_order_number OR n.n2s_order_key = p_order_number
           ORDER BY coalesce(n.is_terminal, false), n.last_seen_at DESC NULLS LAST, n.n2s_id DESC
           LIMIT 1) x
$function$;

CREATE OR REPLACE FUNCTION public.sub_finder_feed(p_key_id bigint, p_updated_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0, p_scope text DEFAULT 'n2s'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now   timestamptz := now();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
  v_scope text := coalesce(p_scope, 'n2s');
  r       record;
BEGIN
  IF NOT coalesce((public.sub_finder_access(p_key_id)->>'find')::boolean, false) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not use the sub finder');
  END IF;
  IF v_scope NOT IN ('n2s', 'all') THEN
    RETURN jsonb_build_object('error', 'invalid', 'detail', 'scope must be n2s or all');
  END IF;
  -- settle this key's open jobs first, so a caller that only ever syncs still gets answers
  FOR r IN SELECT job_id FROM public.sub_finder_job
            WHERE key_id = p_key_id AND status <> 'done' AND NOT public.sub_finder_bg_settle() LOOP
    PERFORM public.sub_finder_settle(r.job_id);
  END LOOP;
  RETURN (
    WITH base AS (
      SELECT o, public.sub_finder_n2s_window(o.order_number) AS w,
             -- a purchase or an offer the caller is still following: not final, or final this week
             (EXISTS (SELECT 1 FROM public.manual_sub_buy b
                       WHERE b.buy_id = o.buy_id AND (b.final_at IS NULL OR b.final_at > v_now - interval '7 days'))
              OR EXISTS (SELECT 1 FROM public.sub_finder_gt_offer g
                          WHERE g.job_id = o.job_id AND g.idx = o.idx
                            AND (g.final_at IS NULL OR g.final_at > v_now - interval '7 days'))) AS acted
        FROM public.sub_finder_order o
       WHERE o.key_id = p_key_id AND o.state <> 'pending'
    ), ranked AS (
      -- one row per order: the lookup with the purchase or offer, else the watched one, else the newest
      SELECT b.*, row_number() OVER (PARTITION BY (b.o).order_number
                                     ORDER BY b.acted DESC, (b.o).watching DESC, (b.o).updated_at DESC,
                                              (b.o).job_id, (b.o).idx) AS rn
        FROM base b
    ), f AS (
      SELECT k.* FROM ranked k
       WHERE (p_updated_since IS NULL OR (k.o).updated_at >= p_updated_since)
         AND (v_scope = 'all'
              OR (k.rn = 1 AND (k.acted OR ((k.o).watching AND coalesce((k.w->>'in_window')::boolean, false)))))
    ), page AS (
      SELECT * FROM f ORDER BY (f.o).updated_at, (f.o).job_id, (f.o).idx LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off, 'scope', v_scope,
      'items', (SELECT coalesce(jsonb_agg(public.sub_finder_order_json(p.o)
                                          || jsonb_build_object('n2s', p.w - 'in_window')
                                          ORDER BY (p.o).updated_at, (p.o).job_id, (p.o).idx),
                                '[]'::jsonb) FROM page p),
      'generated_at', to_char(v_now AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$function$;

-- the name the router called before this migration: the same feed, default scope
CREATE OR REPLACE FUNCTION public.sub_finder_results(p_key_id bigint, p_updated_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.sub_finder_feed(p_key_id, p_updated_since, p_limit, p_offset, 'n2s')
$function$;

REVOKE ALL ON FUNCTION public.sub_finder_n2s_window(text),
  public.sub_finder_feed(bigint, timestamp with time zone, integer, integer, text),
  public.sub_finder_results(bigint, timestamp with time zone, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_n2s_window(text),
  public.sub_finder_feed(bigint, timestamp with time zone, integer, integer, text),
  public.sub_finder_results(bigint, timestamp with time zone, integer, integer) TO service_role;

NOTIFY pgrst, 'reload schema';
