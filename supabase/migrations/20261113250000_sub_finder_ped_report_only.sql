-- Migration 20261113250000 · level:secondary-sales · lane:D0 · writes:sub_finder_report_only,sub_finder_buy,sub_finder_gt_offer_buy · reads:n2s_items · pre:20261113130000
--
-- SUB FINDER: PED Need2Buy orders are report-only. Nothing is bought for them through this API.
--
-- Operator 2026-11-13: "Do not take in 1099 orders, they report only no buys".
--
-- A PED order is a peddled sale we still have to buy, held in n2s_items as item_source 'gmail'
-- (mig 20261009180000). The sub finder may look one up and report its covers, but:
--   automatic buy      already never: sub_finder_autobuy answers 'n2s_order' (unchanged).
--   CRM buy call       POST /orders/{n}/buy, and a `buy` decision read from the CRM's feed, both
--                      go through sub_finder_buy: it now refuses with 403 `forbidden`.
--   accepted offer     sub_finder_gt_offer_buy (EVO seats after a GoTickets customer accepts)
--                      now records buy_note 'report_only' and buys nothing.
-- The operator's own manual sub buy (manual_sub_buy_request from the terminal) is NOT touched:
-- a person can still buy for a PED order by hand.
-- The intake of these orders as lookups (mig 20261113210000, PR #1099) is not applied.
--
-- Both functions are patched in place; each patch fails loudly if its anchor is not there
-- exactly once, and does nothing on a second run.
--
-- rollback: re-apply sub_finder_buy and sub_finder_gt_offer_buy without the added lines;
--           DROP FUNCTION public.sub_finder_report_only(text);

CREATE OR REPLACE FUNCTION public.sub_finder_report_only(p_order_number text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (SELECT 1 FROM public.n2s_items n
                  WHERE n.item_source = 'gmail'
                    AND (n.order_number = p_order_number OR n.n2s_order_key = p_order_number))
$$;
REVOKE ALL ON FUNCTION public.sub_finder_report_only(text) FROM PUBLIC, anon, authenticated;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_buy(bigint, text, uuid, text, text, text)'::regprocedure);
  v_old text := $o$  IF EXISTS (SELECT 1 FROM public.n2s_autobuy_exec x WHERE x.order_number = o.order_number) THEN
    RETURN jsonb_build_object('error', 'conflict', 'detail', 'the Need-to-Sub auto-buy already has this order');$o$;
  v_new text := $n$  IF public.sub_finder_report_only(o.order_number) THEN                    -- 20261113250000
    RETURN jsonb_build_object('error', 'forbidden',
      'detail', 'this is a PED Need2Buy order: it is reported only and never bought through this API');
  END IF;
$n$;
BEGIN
  IF position('sub_finder_report_only' IN v_def) > 0 THEN RETURN; END IF;     -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_buy: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new || v_old);
END
$patch$;

DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_gt_offer_buy(bigint)'::regprocedure);
  v_old text := $o$    WHEN r.market <> 'evo' THEN 'not_on_evo'$o$;
  v_new text := $n$    WHEN public.sub_finder_report_only(r.order_number) THEN 'report_only'   -- 20261113250000
$n$;
BEGIN
  IF position('sub_finder_report_only' IN v_def) > 0 THEN RETURN; END IF;     -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_gt_offer_buy: the line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new || v_old);
END
$patch$;
