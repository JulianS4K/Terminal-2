-- Migration 20261113130000 · level:secondary-sales · lane:D0 · writes:sub_finder_match,sub_finder_autobuy,sub_finder_cover_flags,sub_finder_buy_confirmed,sub_finder_gt_offer_confirmed · reads:sub_finder_order · pre:20261113120000
--
-- SUB FINDER: suffixed covers go through to the CRM, and the CRM confirms them.
--
-- Operator 2026-11-13: "push through the suffixes and ask crm to confirm".
--
-- A cover's label can end in a suffix that says something is off about it:
--   ' zone unverified'   rows back, and neither seat has a curated zone      -> zone_unverified
--   ' obstructed view'                                                        -> obstructed_view
--   ' single ticket'     the order is for one ticket                          -> single_ticket
--   ' repost single'     the listing forces one more ticket than was sold     -> repost_single
--   ' no sale price'     we do not know what the order sold for               -> no_sale_price
-- These covers were always sent, with the suffix inside the label text. Now:
--
--   1. every cover carries `flags` (the codes above, an array, empty when clean) and
--      `confirm_needed` (true when there is any flag);
--   2. nothing is done automatically with a flagged cover: sub_finder_autobuy skips it and
--      says why (auto_buy_note 'needs_crm_confirm'). Obstructed and spare-ticket covers were
--      already skipped; the new case is single_ticket;
--   3. the CRM's yes for a flagged cover must say it has seen the flags: the buy and offer-sub
--      routes now go through sub_finder_buy_confirmed / sub_finder_gt_offer_confirmed, which
--      answer 'confirm_needed' with the flags unless p_confirm is true, and otherwise hand over
--      to sub_finder_buy / sub_finder_gt_offer_request unchanged.
--
-- sub_finder_match and sub_finder_autobuy are patched in place (they are long, and what is in
-- the database is the source of truth). Each patch edits one line, fails loudly if that line is
-- not there exactly once, and does nothing on a second run. Covers stored before this ran get
-- their flags at the next re-match (a watched order's, within minutes); until then the
-- wrappers read the flags from the label's suffixes.
--
-- rollback: DROP FUNCTION public.sub_finder_buy_confirmed(bigint, text, uuid, text, text, text, boolean),
--             public.sub_finder_gt_offer_confirmed(bigint, text, text, text, text, text, numeric, boolean),
--             public.sub_finder_cover_flags(jsonb);
--           re-apply sub_finder_match from 20261113070000 and sub_finder_autobuy from 20261113080000.

-- The flags of one cover: its `flags`, or, for a cover matched before 20261113130000, its label's suffixes.
CREATE OR REPLACE FUNCTION public.sub_finder_cover_flags(cv jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path = public, pg_temp
AS $$
  SELECT CASE WHEN cv ? 'flags' THEN coalesce(cv->'flags', '[]'::jsonb)
              ELSE to_jsonb(array_remove(ARRAY[
                     CASE WHEN cv->>'label' LIKE '% zone unverified%' THEN 'zone_unverified' END,
                     CASE WHEN cv->>'label' LIKE '% obstructed view%' THEN 'obstructed_view' END,
                     CASE WHEN cv->>'label' LIKE '% single ticket%'   THEN 'single_ticket' END,
                     CASE WHEN cv->>'label' LIKE '% repost single%'   THEN 'repost_single' END,
                     CASE WHEN cv->>'label' LIKE '% no sale price%'   THEN 'no_sale_price' END], NULL)) END;
$$;
REVOKE ALL ON FUNCTION public.sub_finder_cover_flags(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_cover_flags(jsonb) TO service_role;

-- 1. the match: every cover says its flags
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.sub_finder_match(uuid, boolean)'::regprocedure);
  v_old text := $o$'needs_buyer_ok', coalesce(gate >= 3, false),$o$;
  v_new text := $n$'needs_buyer_ok', coalesce(gate >= 3, false),
             'flags', to_jsonb(array_remove(ARRAY[
                        CASE WHEN gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL THEN 'zone_unverified' END,
                        CASE WHEN view_note = 'obstructed' THEN 'obstructed_view' END,
                        CASE WHEN qty = 1 THEN 'single_ticket' END,
                        CASE WHEN buy_qty > qty THEN 'repost_single' END,
                        CASE WHEN sold_ea IS NULL AND gate IS NOT NULL THEN 'no_sale_price' END], NULL)),
             'confirm_needed', (gate IN (5, 6) AND o_zone IS NULL AND l_zone IS NULL)
                               OR view_note IS NOT DISTINCT FROM 'obstructed' OR qty = 1 OR buy_qty > qty
                               OR (sold_ea IS NULL AND gate IS NOT NULL),$n$;
BEGIN
  IF position($t$'confirm_needed'$t$ IN v_def) > 0 THEN RETURN; END IF;       -- already patched
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_match: the cover line to patch was not found exactly once';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END
$patch$;

-- 2. the automatic buy: never a flagged cover
DO $patch$
DECLARE
  v_def  text := pg_get_functiondef('public.sub_finder_autobuy(uuid)'::regprocedure);
  v_old1 text := $o$AND (x->>'spare')::int = 0 AND x->>'view' IS DISTINCT FROM 'obstructed'$o$;
  v_new1 text := $n$AND (x->>'spare')::int = 0 AND x->>'view' IS DISTINCT FROM 'obstructed'
       AND jsonb_array_length(public.sub_finder_cover_flags(x)) = 0     -- a flagged cover waits for the CRM$n$;
  v_old2 text := $o$ELSE 'profit_too_thin' END;$o$;
  v_new2 text := $n$WHEN NOT EXISTS (SELECT 1 FROM jsonb_array_elements(o.covers) x
                       WHERE x->>'market' = 'evo' AND public.sub_finder_autobuy_gate(x) AND (x->>'spare')::int = 0
                         AND x->>'view' IS DISTINCT FROM 'obstructed'
                         AND jsonb_array_length(public.sub_finder_cover_flags(x)) = 0)
        THEN 'needs_crm_confirm'
      ELSE 'profit_too_thin' END;$n$;
BEGIN
  IF position('needs_crm_confirm' IN v_def) > 0 THEN RETURN; END IF;          -- already patched
  IF (length(v_def) - length(replace(v_def, v_old1, ''))) / length(v_old1) <> 1
     OR (length(v_def) - length(replace(v_def, v_old2, ''))) / length(v_old2) <> 1 THEN
    RAISE EXCEPTION 'sub_finder_autobuy: the lines to patch were not each found exactly once';
  END IF;
  EXECUTE replace(replace(v_def, v_old1, v_new1), v_old2, v_new2);
END
$patch$;

-- 3a. the CRM's buy: a flagged cover needs p_confirm
CREATE OR REPLACE FUNCTION public.sub_finder_buy_confirmed(
  p_key_id bigint, p_key_label text, p_job_id uuid, p_order_number text, p_listing_id text,
  p_requested_by text, p_confirm boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  v_flags jsonb;
BEGIN
  SELECT public.sub_finder_cover_flags(x) INTO v_flags
    FROM public.sub_finder_order o, jsonb_array_elements(o.covers) x
   WHERE o.job_id = p_job_id AND o.key_id = p_key_id AND o.order_number = p_order_number
     AND x->>'market' = 'evo' AND x->>'listing_id' = p_listing_id
   LIMIT 1;
  IF NOT coalesce(p_confirm, false) AND jsonb_array_length(coalesce(v_flags, '[]'::jsonb)) > 0 THEN
    RETURN jsonb_build_object('error', 'confirm_needed', 'flags', v_flags,
      'detail', 'this cover is flagged: send "confirm": true to buy it anyway');
  END IF;
  RETURN public.sub_finder_buy(p_key_id, p_key_label, p_job_id, p_order_number, p_listing_id, p_requested_by);
END
$$;
REVOKE ALL ON FUNCTION public.sub_finder_buy_confirmed(bigint, text, uuid, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_buy_confirmed(bigint, text, uuid, text, text, text, boolean) TO service_role;

-- 3b. the CRM's yes to a GoTickets offer: a flagged cover needs p_confirm
CREATE OR REPLACE FUNCTION public.sub_finder_gt_offer_confirmed(
  p_key_id bigint, p_key_label text, p_order_number text, p_listing_id text,
  p_market text, p_requested_by text, p_rebate_amount numeric, p_confirm boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $$
DECLARE
  v_flags jsonb;
BEGIN
  SELECT public.sub_finder_cover_flags(c.x) INTO v_flags
    FROM (SELECT o.covers FROM public.sub_finder_order o
           WHERE o.key_id = p_key_id AND o.order_number = p_order_number AND o.watching
           ORDER BY o.updated_at DESC LIMIT 1) w,
         jsonb_array_elements(w.covers) WITH ORDINALITY c(x, n)
   WHERE c.x->>'listing_id' = p_listing_id AND c.x->>'source' = 'native'
     AND (p_market IS NULL OR c.x->>'market' = lower(btrim(p_market)))
   ORDER BY c.n LIMIT 1;
  IF NOT coalesce(p_confirm, false) AND jsonb_array_length(coalesce(v_flags, '[]'::jsonb)) > 0 THEN
    RETURN jsonb_build_object('error', 'confirm_needed', 'flags', v_flags,
      'detail', 'this cover is flagged: send "confirm": true to offer it anyway');
  END IF;
  RETURN public.sub_finder_gt_offer_request(p_key_id, p_key_label, p_order_number, p_listing_id,
                                            p_market, p_requested_by, p_rebate_amount);
END
$$;
REVOKE ALL ON FUNCTION public.sub_finder_gt_offer_confirmed(bigint, text, text, text, text, text, numeric, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sub_finder_gt_offer_confirmed(bigint, text, text, text, text, text, numeric, boolean) TO service_role;
