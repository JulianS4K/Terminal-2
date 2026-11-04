-- Migration 20261104170000 · level:secondary-sales · lane:D7 · writes:n2s_dryrun_extra_reasons · reads:n2s_cover_queue,n2s_gt_order_dryrun · pre:20261029170000
--
-- Auto-buy DRY RUN: skip single-letter ↔ double-letter row covers.
--
-- Operator direction 2026-11-04: "adjust the rule to also skip single letter
-- to double letter buys". Dry-run #325 bought 124/H for an order sold in
-- 124/AA. Venues disagree on whether AA sits behind Z (back of the section)
-- or in front of A (front rows), so "same or better row" can't be trusted
-- across that boundary. New skip reason row_letter_mismatch: both rows are
-- letters only and one is a single letter while the other is two or more.
-- Same-shape rows (H vs B, AA vs BB) and numeric rows are unaffected.
--
-- Only n2s_dryrun_extra_reasons() changes (same signature): it reads the
-- order's sold row and the sub row from n2s_cover_queue, so both capture
-- functions pick the rule up without being re-created.
--
-- Nothing is sent to any market.
--
-- rollback: re-create n2s_dryrun_extra_reasons() from 20261029170000.

CREATE OR REPLACE FUNCTION public.n2s_dryrun_extra_reasons(p_n2s_id bigint, p_sub_source text, p_listing text,
                                                         p_section text, p_sub_section text, p_timer_expires_at timestamptz)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v text[] := '{}';
  a text := public.n2s_section_level(p_section);
  b text := public.n2s_section_level(p_sub_section);
  r_sold text;
  r_sub text;
BEGIN
  IF a IS NOT NULL AND b IS NOT NULL AND a <> b THEN
    v := array_append(v, 'level_mismatch');
  END IF;
  IF EXISTS (SELECT 1 FROM public.n2s_gt_order_dryrun d
              WHERE d.decision = 'would_buy' AND d.sub_source = p_sub_source
                AND d.sub_listing_id = p_listing AND d.n2s_id <> p_n2s_id) THEN
    v := array_append(v, 'listing_taken');
  END IF;
  IF p_timer_expires_at IS NOT NULL AND p_timer_expires_at - now() < interval '6 minutes' THEN
    v := array_append(v, 'not_enough_time');
  END IF;
  -- 20261104170000: a single-letter row against a double-letter row (H vs AA) is ambiguous.
  SELECT btrim(q.order_row), btrim(q.sub_row) INTO r_sold, r_sub
    FROM public.n2s_cover_queue q
   WHERE q.n2s_id = p_n2s_id AND q.sub_source = p_sub_source AND q.sub_listing_id = p_listing
   LIMIT 1;
  IF r_sold ~ '^[A-Za-z]+$' AND r_sub ~ '^[A-Za-z]+$'
     AND (length(r_sold) = 1) <> (length(r_sub) = 1) THEN
    v := array_append(v, 'row_letter_mismatch');
  END IF;
  RETURN v;
END $function$;

REVOKE EXECUTE ON FUNCTION public.n2s_dryrun_extra_reasons(bigint, text, text, text, text, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.n2s_dryrun_extra_reasons(bigint, text, text, text, text, timestamptz) TO service_role;
