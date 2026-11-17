-- Migration 20261113410000 · level:secondary-sales · lane:D7 · writes:n2s_autobuy_exec,n2s_autobuy_live_record,sub_finder_config,n2s_autobuy_result_json,sub_finder_autobuys · reads:n2s_items,n2s_gt_order_dryrun,sub_finder_config · pre:20261113400000,20261113270000
--
-- N2S AUTO-BUY RESULTS in the sub finder API (GET /api/v1/subs/autobuys).
--
-- Operator 2026-11-13: "add results to the outbound api ... for buys that go through with
-- marketplace-{ordernumber} we bought and the ordernumber we're buying for and buy details and
-- totals". The CRM reads them the way it reads /results: an `updated_since` sync feed in the
-- count / total / limit / offset / items / generated_at envelope.
--
--   1. n2s_autobuy_exec.buy_total_usd: what the sub's market said it charged us (EVO order
--      `total`, GoTickets `orderTotal`), else the total we priced the buy at. Written once, by
--      n2s_autobuy_live_record() from the worker's buy_sent step (core/n2s_autobuy_live.py).
--   2. n2s_autobuy_live_record(): keeps buy_total_usd (anchor patch, md5-guarded against
--      20261113400000). A value that is not a plain number is ignored, never an error: this
--      write follows a purchase that already went out.
--   3. sub_finder_config.autobuys_key_ids: keys that may read the feed (seeded from
--      balances_key_ids: the same CRM key already reads our money).
--   4. n2s_autobuy_result_json(row) / sub_finder_autobuys(key, updated_since, limit, offset):
--      every LIVE auto-buy that placed a purchase (buy_order_id set), newest change last.
--      `buy_ref` = '<market we bought on>-<its order number>', `for_order` = the CRM order the
--      sub covers, `status` = pending / went_through / stopped / check_manually.
--
-- Nothing here calls a market; the feed only reads our own tables.
--
-- rollback: DROP FUNCTION public.sub_finder_autobuys(bigint, timestamptz, integer, integer),
--           public.n2s_autobuy_result_json(public.n2s_autobuy_exec);
--           ALTER TABLE public.sub_finder_config DROP COLUMN autobuys_key_ids;
--           (buy_total_usd and the record patch are harmless to leave.)

-- ── 1. the charged total ───────────────────────────────────────────────────
ALTER TABLE public.n2s_autobuy_exec ADD COLUMN IF NOT EXISTS buy_total_usd numeric;
COMMENT ON COLUMN public.n2s_autobuy_exec.buy_total_usd IS
  'What the sub''s market charged for the buy (EVO total / GoTickets orderTotal), else the total the worker priced it at. 20261113410000.';

-- ── 2. the record keeps it ─────────────────────────────────────────────────
DO $do$
DECLARE d text; n int;
BEGIN
  d := pg_get_functiondef('public.n2s_autobuy_live_record(bigint, uuid, jsonb)'::regprocedure);
  IF md5(d) <> '0d48f18ed288609b7d32aad2a4fee796' THEN
    RAISE EXCEPTION 'n2s_autobuy_live_record drifted from 20261113400000 — re-derive this migration';
  END IF;
  n := (length(d) - length(replace(d, $r$buy_state    = COALESCE(p_patch ->> 'buy_state', buy_state),$r$, '')))
       / length($r$buy_state    = COALESCE(p_patch ->> 'buy_state', buy_state),$r$);
  IF n <> 1 THEN
    RAISE EXCEPTION 'n2s_autobuy_live_record: % buy_state anchors (want 1) — re-derive this migration', n;
  END IF;
  d := replace(d, $r$buy_state    = COALESCE(p_patch ->> 'buy_state', buy_state),$r$,
    $r$buy_state    = COALESCE(p_patch ->> 'buy_state', buy_state),
         -- 20261113410000: what the market charged (a non-number is ignored, never an error)
         buy_total_usd = COALESCE(buy_total_usd, CASE WHEN p_patch ->> 'buy_total_usd' ~ '^[0-9]{1,9}(\.[0-9]{1,4})?$'
                                                      THEN (p_patch ->> 'buy_total_usd')::numeric END),$r$);
  EXECUTE d;
END $do$;

-- ── 3. who may read the feed ───────────────────────────────────────────────
ALTER TABLE public.sub_finder_config
  ADD COLUMN IF NOT EXISTS autobuys_key_ids bigint[] NOT NULL DEFAULT '{}';   -- keys that may read auto-buy results
UPDATE public.sub_finder_config SET autobuys_key_ids = balances_key_ids WHERE autobuys_key_ids = '{}';

-- ── 4. the feed ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_autobuy_result_json(e public.n2s_autobuy_exec)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'buy_ref',             CASE e.sub_source WHEN 'tevo' THEN 'evo' ELSE e.sub_source END || '-' || e.buy_order_id,
    'bought_on',           CASE e.sub_source WHEN 'tevo' THEN 'evo' ELSE e.sub_source END,
    'bought_order_number', e.buy_order_id,
    'for_order', jsonb_build_object(
        'order_number', e.order_number,
        'ref',          coalesce(e.sell_market, 'unknown') || '-' || e.order_number,
        'sold_on',      e.sell_market,
        'section',      coalesce(d.sold_section, i.section),
        'row',          coalesce(d.sold_row, i.row),
        'qty',          coalesce(d.sold_qty, i.qty),
        'sold_total_usd', e.sold_total_usd,
        'state',        e.sale_state),
    'status', CASE WHEN e.phase = 'accepted' THEN 'went_through'
                   WHEN e.phase IN ('buy_sent', 'sub_accepted', 'buying') THEN 'pending'
                   WHEN e.phase IN ('buy_unknown', 'accept_unknown', 'accept_failed') THEN 'check_manually'
                   ELSE 'stopped' END,
    'went_through', e.phase = 'accepted',
    'phase',        e.phase,
    'reasons',      to_jsonb(e.reasons),
    'event', jsonb_build_object('name', e.event_name, 'local_start', e.event_dt_local,
                                'start_utc', e.event_start_utc, 'venue', i.venue,
                                'tevo_event_id', e.tevo_event_id, 'gotickets_event_id', d.gt_event_id),
    'bought', jsonb_build_object('listing_id', e.sub_listing_id, 'section', d.sub_section, 'row', d.sub_row,
                                 'qty', e.qty, 'state', e.buy_state),
    'totals', jsonb_build_object(
        'quoted_usd',  round(e.sub_total_usd + coalesce(e.est_tax_usd, 0), 2),
        'charged_usd', e.buy_total_usd,
        'sold_usd',    e.sold_total_usd,
        'margin_usd',  round(e.sold_total_usd - coalesce(e.buy_total_usd, e.sub_total_usd + coalesce(e.est_tax_usd, 0)), 2)),
    'bought_at',  e.live_started_at,
    'updated_at', e.live_updated_at)
  FROM (SELECT 1) one
  LEFT JOIN public.n2s_items i ON i.n2s_id = e.n2s_id
  LEFT JOIN public.n2s_gt_order_dryrun d ON d.dryrun_id = e.dryrun_id;
$$;

CREATE OR REPLACE FUNCTION public.sub_finder_autobuys(
  p_key_id bigint, p_updated_since timestamptz DEFAULT NULL, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  c       public.sub_finder_config;
  v_now   timestamptz := now();
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_off   integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  SELECT * INTO c FROM public.sub_finder_config;
  IF NOT coalesce(c.enabled, false) OR NOT (p_key_id = ANY (c.key_ids)) OR NOT (p_key_id = ANY (c.autobuys_key_ids)) THEN
    RETURN jsonb_build_object('error', 'forbidden', 'detail', 'this key may not read auto-buy results');
  END IF;
  RETURN (
    WITH f AS (
      SELECT e.* FROM public.n2s_autobuy_exec e
      WHERE e.mode = 'live' AND e.buy_order_id IS NOT NULL
        AND (p_updated_since IS NULL OR e.live_updated_at >= p_updated_since)
    ), page AS (
      SELECT * FROM f ORDER BY live_updated_at, exec_id LIMIT v_limit OFFSET v_off
    )
    SELECT jsonb_build_object(
      'count', (SELECT count(*) FROM page), 'total', (SELECT count(*) FROM f),
      'limit', v_limit, 'offset', v_off,
      'items', (SELECT coalesce(jsonb_agg(public.n2s_autobuy_result_json(p::public.n2s_autobuy_exec)
                                          ORDER BY p.live_updated_at, p.exec_id), '[]'::jsonb) FROM page p),
      'generated_at', to_char(v_now AT TIME ZONE 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')));
END
$$;

REVOKE ALL ON FUNCTION public.n2s_autobuy_result_json(public.n2s_autobuy_exec),
                       public.sub_finder_autobuys(bigint, timestamptz, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_autobuy_result_json(public.n2s_autobuy_exec),
                          public.sub_finder_autobuys(bigint, timestamptz, integer, integer) TO service_role;
